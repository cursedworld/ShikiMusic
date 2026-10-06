import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'atomic_file_store.dart';

/// Discovers existing animated album artwork, without decoding or playing it.
/// Only the current album and one latest pending album are retained. Ordinary
/// RPC updates never wait for network I/O; misses survive player restarts.
class DiscordAnimatedArtwork {
  DiscordAnimatedArtwork({
    this.cacheFile,
    required this.onAvailable,
    http.Client Function()? clientFactory,
    DateTime Function()? now,
    this.searchInterval = const Duration(milliseconds: 1100),
    this.lookupTimeout = const Duration(seconds: 12),
  }) : _clientFactory = clientFactory ?? http.Client.new,
       _now = now ?? DateTime.now;

  final File? cacheFile;
  final void Function(String albumKey) onAvailable;
  final http.Client Function() _clientFactory;
  final DateTime Function() _now;
  final Duration searchInterval;
  final Duration lookupTimeout;
  final _cache = <String, _ArtworkCacheEntry>{};
  static const _maxEntries = 512;
  static const _maxJsonBytes = 256 * 1024;
  static const _maxCacheBytes = 1024 * 1024;
  static const _maxImageBytes = 2 * 1024 * 1024;
  static const _headers = {
    'User-Agent': 'ShikiMusic/1.0 (https://github.com/cursedworld/ShikiMusic)',
  };

  bool _loaded = false;
  bool _disposed = false;
  String? _currentKey;
  String? _activeKey;
  _AlbumIdentity? _pending;
  Future<void>? _worker;
  http.Client? _activeClient;
  DateTime? _lastSearch;

  Future<void> get idle => _worker ?? Future<void>.value();

  static String? albumKey(dynamic track) =>
      _AlbumIdentity.fromTrack(track)?.key;

  /// Returns immediately. A static cover remains visible during discovery.
  String? imageFor(dynamic track) {
    if (_disposed) return null;
    final album = _AlbumIdentity.fromTrack(track);
    _currentKey = album?.key;
    if (album == null) {
      _pending = null;
      return null;
    }
    final cached = _cache.remove(album.key);
    if (cached != null) _cache[album.key] = cached;
    if (_loaded && cached != null && cached.expires.isAfter(_now())) {
      _pending = null;
      return cached.url;
    }
    // Fast skips replace pending work, rather than enqueueing the whole library.
    _pending = _activeKey == album.key ? null : album;
    _startWorker();
    return cached?.url;
  }

  void dispose() {
    _disposed = true;
    _pending = null;
    _activeClient?.close();
  }

  void _startWorker() {
    if (_worker != null || _disposed) return;
    _worker = _run().whenComplete(() {
      _worker = null;
      if (!_disposed && _pending != null) _startWorker();
    });
  }

  Future<void> _run() async {
    if (!_loaded) await _load();
    while (!_disposed && _pending != null) {
      final album = _pending!;
      _pending = null;
      final cached = _cache[album.key];
      if (cached != null && cached.expires.isAfter(_now())) {
        if (cached.url != null && _currentKey == album.key) {
          onAvailable(album.key);
        }
        continue;
      }
      _activeKey = album.key;
      final client = _clientFactory();
      _activeClient = client;
      String? url;
      var ttl = const Duration(days: 14);
      try {
        url = await _lookup(client, album).timeout(
          lookupTimeout,
          onTimeout: () {
            client.close();
            throw TimeoutException('Animated artwork lookup timed out');
          },
        );
        if (url != null) ttl = const Duration(days: 7);
      } catch (_) {
        // Outages and throttling are not permanent "no animated cover" results.
        ttl = const Duration(minutes: 10);
        url = cached?.url;
      } finally {
        client.close();
        _activeClient = null;
        _activeKey = null;
      }
      if (_disposed) return;
      _cache.remove(album.key);
      _cache[album.key] = _ArtworkCacheEntry(url, _now().add(ttl));
      while (_cache.length > _maxEntries) {
        _cache.remove(_cache.keys.first);
      }
      await _save();
      if (!_disposed && url != null && _currentKey == album.key) {
        onAvailable(album.key);
      }
    }
  }

  Future<String?> _lookup(http.Client client, _AlbumIdentity album) async {
    final lastSearch = _lastSearch;
    if (lastSearch != null) {
      final wait = searchInterval - _now().difference(lastSearch);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    if (_disposed) return null;
    _lastSearch = _now();
    String quoted(String value) =>
        value.replaceAllMapped(RegExp(r'[\\"]'), (match) => '\\${match[0]}');
    final search = Uri.https('musicbrainz.org', '/ws/2/release-group/', {
      'query':
          'releasegroup:"${quoted(album.title)}" AND artist:"${quoted(album.artist)}"',
      'fmt': 'json',
      'limit': '5',
    });
    final searchData = await _json(client, search);
    final groups = searchData?['release-groups'];
    if (groups is! List) return null;
    final matches = groups.whereType<Map>().where(album.matches).toList();
    // Do not guess between unrelated releases with the same artist and title.
    if (matches.length != 1) return null;
    final id = matches.single['id']?.toString() ?? '';
    if (!_uuid.hasMatch(id)) return null;
    final covers = await _json(
      client,
      Uri.https('coverartarchive.org', '/release-group/$id/'),
      allowMissing: true,
    );
    final images = covers?['images'];
    if (images is! List) return null;
    // The original image is necessary: CAA thumbnails flatten animation to JPG.
    var checked = 0;
    for (final image in images.whereType<Map>()) {
      if (image['front'] != true || image['approved'] != true) continue;
      final uri = _originalImage(image['image']);
      if (uri == null) continue;
      if (checked++ >= 2) break;
      final bytes = await _read(client, uri, maxBytes: _maxImageBytes);
      if (bytes != null && isAnimatedDiscordImage(bytes)) return uri.toString();
    }
    return null;
  }

  Future<Map?> _json(
    http.Client client,
    Uri uri, {
    bool allowMissing = false,
  }) async {
    final bytes = await _read(
      client,
      uri,
      maxBytes: _maxJsonBytes,
      allowMissing: allowMissing,
    );
    if (bytes == null) return null;
    final data = jsonDecode(utf8.decode(bytes));
    return data is Map ? data : null;
  }

  Future<Uint8List?> _read(
    http.Client client,
    Uri uri, {
    required int maxBytes,
    bool allowMissing = false,
  }) async {
    final request = http.Request('GET', uri)..headers.addAll(_headers);
    final response = await client.send(request);
    if (allowMissing && response.statusCode == 404) {
      await response.stream.listen(null).cancel();
      return null;
    }
    if (response.statusCode != 200) {
      await response.stream.listen(null).cancel();
      throw HttpException('Artwork HTTP ${response.statusCode}');
    }
    if ((response.contentLength ?? 0) > maxBytes) {
      await response.stream.listen(null).cancel();
      return null;
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (_disposed) return null;
      if (bytes.length + chunk.length > maxBytes) return null;
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<void> _load() async {
    try {
      final file = cacheFile;
      if (file == null ||
          !await file.exists() ||
          await file.length() > _maxCacheBytes) {
        return;
      }
      final data = jsonDecode(await file.readAsString());
      if (data is! Map || data['version'] != 1 || data['entries'] is! Map) {
        return;
      }
      for (final entry in (data['entries'] as Map).entries.take(_maxEntries)) {
        final value = entry.value;
        if (entry.key is! String ||
            (entry.key as String).length > 512 ||
            value is! Map ||
            value['expires'] is! int) {
          continue;
        }
        final url = value['url'];
        if (url != null && _originalImage(url) == null) continue;
        _cache[entry.key as String] = _ArtworkCacheEntry(
          url as String?,
          DateTime.fromMillisecondsSinceEpoch(value['expires'] as int),
        );
      }
    } catch (_) {
      // Missing/corrupt/read-only caches never affect playback or startup.
    } finally {
      _loaded = true;
    }
  }

  Future<void> _save() async {
    final file = cacheFile;
    if (file == null || _disposed) return;
    try {
      await atomicFileStore.writeString(
        file,
        jsonEncode({
          'version': 1,
          'entries': _cache.map(
            (key, value) => MapEntry(key, {
              'url': value.url,
              'expires': value.expires.millisecondsSinceEpoch,
            }),
          ),
        }),
      );
    } catch (_) {
      // Memory caching is still useful when the user's data folder is read-only.
    }
  }
}

final _uuid = RegExp(r'^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$');
final _originalImagePath = RegExp(
  r'^/release/[0-9a-f-]{36}/\d+\.(?:gif|webp)$',
);
final _nonNameCharacters = RegExp(r'[^\p{L}\p{N}]', unicode: true);

Uri? _originalImage(dynamic value) {
  if (value is! String || value.length > 256) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !['https', 'http'].contains(uri.scheme) ||
      uri.host != 'coverartarchive.org' ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      uri.hasQuery ||
      uri.hasFragment ||
      !_originalImagePath.hasMatch(uri.path)) {
    return null;
  }
  return uri.replace(scheme: 'https');
}

String _normalize(String value) =>
    value.toLowerCase().replaceAll('ё', 'е').replaceAll(_nonNameCharacters, '');

class _AlbumIdentity {
  _AlbumIdentity(this.title, this.artist);
  final String title;
  final String artist;
  String get key => jsonEncode([_normalize(artist), _normalize(title)]);

  static _AlbumIdentity? fromTrack(dynamic track) {
    if (track is! Map || track['album'] is! Map) return null;
    final album = track['album'] as Map;
    final artistData = album['artist'];
    final title = album['title']?.toString().trim() ?? '';
    final artist = artistData is Map
        ? artistData['name']?.toString().trim() ?? ''
        : '';
    if (_normalize(title).isEmpty ||
        _normalize(artist).isEmpty ||
        title.length > 100 ||
        artist.length > 100) {
      return null;
    }
    return _AlbumIdentity(title, artist);
  }

  bool matches(Map group) {
    if (group['score'].toString() != '100' ||
        _normalize(group['title']?.toString() ?? '') != _normalize(title)) {
      return false;
    }
    final credits = group['artist-credit'];
    if (credits is! List || credits.length != 1 || credits.single is! Map) {
      return false;
    }
    final credit = credits.single as Map;
    final creditedArtist = credit['artist'];
    return _normalize(credit['name']?.toString() ?? '') == _normalize(artist) ||
        (creditedArtist is Map &&
            _normalize(creditedArtist['name']?.toString() ?? '') ==
                _normalize(artist));
  }
}

class _ArtworkCacheEntry {
  _ArtworkCacheEntry(this.url, this.expires);
  final String? url;
  final DateTime expires;
}

/// Examines image structure only. No image codecs, pixel buffers or tickers.
bool isAnimatedDiscordImage(List<int> bytes) {
  bool tag(int offset, String text) {
    if (offset + text.length > bytes.length) return false;
    for (var i = 0; i < text.length; i++) {
      if (bytes[offset + i] != text.codeUnitAt(i)) return false;
    }
    return true;
  }

  if (bytes.length >= 13 && (tag(0, 'GIF89a') || tag(0, 'GIF87a'))) {
    var offset = 13;
    if (bytes[10] & 0x80 != 0) offset += 3 * (1 << ((bytes[10] & 7) + 1));
    var frames = 0;
    bool skipBlocks() {
      while (offset < bytes.length) {
        final size = bytes[offset++];
        if (size == 0) return true;
        if (offset + size > bytes.length) return false;
        offset += size;
      }
      return false;
    }

    while (offset < bytes.length) {
      final marker = bytes[offset++];
      if (marker == 0x21) {
        if (offset >= bytes.length) return false;
        offset++; // Extension label; all extension payloads use sub-blocks.
        if (!skipBlocks()) return false;
      } else if (marker == 0x2c) {
        if (offset + 9 >= bytes.length) return false;
        final packed = bytes[offset + 8];
        offset += 9;
        if (packed & 0x80 != 0) offset += 3 * (1 << ((packed & 7) + 1));
        if (offset >= bytes.length) return false;
        offset++; // LZW minimum code size.
        if (!skipBlocks()) return false;
        if (++frames >= 2) return true;
      } else {
        return false;
      }
    }
    return false;
  }
  if (bytes.length < 12 || !tag(0, 'RIFF') || !tag(8, 'WEBP')) return false;
  int uint32(int offset) =>
      bytes[offset] |
      bytes[offset + 1] << 8 |
      bytes[offset + 2] << 16 |
      bytes[offset + 3] << 24;
  final end = uint32(4) + 8;
  if (end > bytes.length) return false;
  var animated = false;
  var animationHeader = false;
  var frames = 0;
  for (var offset = 12; offset + 8 <= end;) {
    final size = uint32(offset + 4);
    final data = offset + 8;
    if (data + size > end) return false;
    if (tag(offset, 'VP8X') && size >= 10) animated = bytes[data] & 2 != 0;
    if (tag(offset, 'ANIM') && size >= 6) animationHeader = true;
    if (tag(offset, 'ANMF') && size >= 16) frames++;
    offset = data + size + (size & 1);
  }
  return animated && animationHeader && frames >= 2;
}
