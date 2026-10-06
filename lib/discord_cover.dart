import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'music_import.dart';

enum DiscordCoverSource { itunes, deezer, lastfm, artistPhoto }

class DiscordCoverResult {
  const DiscordCoverResult(this.url, this.source);
  final String url;
  final DiscordCoverSource source;
  bool get isTrackCover => source != DiscordCoverSource.artistPhoto;
}

String? selectDiscordCoverImage({
  DiscordCoverResult? discovered,
  String? stored,
  String? animated,
}) => discovered?.isTrackCover == true
    ? discovered!.url
    : animated ?? publicDiscordArtworkUrl(stored) ?? discovered?.url;

/// A single background lookup and one latest pending selection. iTunes wins
/// permanently for an unchanged track identity; fallbacks are retried later.
class DiscordCoverLookup {
  DiscordCoverLookup({
    required this.onResolved,
    http.Client Function()? clientFactory,
    DateTime Function()? now,
    this.itunesInterval = const Duration(milliseconds: 3100),
    this.requestTimeout = const Duration(seconds: 3),
  }) : _clientFactory = clientFactory ?? http.Client.new,
       _now = now ?? DateTime.now;

  final void Function(String trackKey) onResolved;
  final http.Client Function() _clientFactory;
  final DateTime Function() _now;
  final Duration itunesInterval;
  final Duration requestTimeout;
  final _cache = <String, _CachedCover>{};
  final _artists = <String, _CachedCover>{};
  _CoverIdentity? _pending;
  String? _currentKey;
  String? _activeKey;
  http.Client? _client;
  Future<void>? _worker;
  DateTime? _lastItunes;
  bool _disposed = false;
  static const _fallbackTtl = Duration(minutes: 30);
  static const _lastFmKey = 'b25b959554ed76058ac220b7b2e0a026';

  Future<void> get idle => _worker ?? Future<void>.value();
  static String? trackKey(dynamic track) =>
      _CoverIdentity.fromTrack(track)?.key;

  bool isResolved(dynamic track) {
    final key = trackKey(track);
    return key != null && (_cache[key]?.valid(_now()) ?? false);
  }

  /// Cached covers are synchronous, so a slow provider never delays RPC text.
  DiscordCoverResult? imageFor(dynamic track) {
    if (_disposed) return null;
    final identity = _CoverIdentity.fromTrack(track);
    _currentKey = identity?.key;
    if (identity == null) {
      _pending = null;
      return null;
    }
    final cached = _cache.remove(identity.key);
    if (cached != null) _cache[identity.key] = cached;
    if (cached?.valid(_now()) ?? false) {
      _pending = null;
      return cached!.result;
    }
    _pending = _activeKey == identity.key ? null : identity;
    _worker ??= _run().whenComplete(() => _worker = null);
    return cached?.result;
  }

  void dispose() {
    _disposed = true;
    _pending = null;
    _client?.close();
  }

  Future<void> _run() async {
    while (!_disposed && _pending != null) {
      final identity = _pending!;
      _pending = null;
      _activeKey = identity.key;
      final client = _clientFactory();
      _client = client;
      DiscordCoverResult? result;
      try {
        result = await _lookup(client, identity);
      } catch (_) {
        // A malformed provider response must not escape a background task.
        result = _cache[identity.key]?.result;
      } finally {
        client.close();
        _client = null;
        _activeKey = null;
      }
      if (_disposed) return;
      _cache.remove(identity.key);
      _cache[identity.key] = _CachedCover(
        result,
        result?.source == DiscordCoverSource.itunes
            ? null
            : _now().add(_fallbackTtl),
      );
      _trim(_cache, 512);
      if (_currentKey == identity.key) onResolved(identity.key);
    }
  }

  Future<DiscordCoverResult?> _lookup(
    http.Client client,
    _CoverIdentity identity,
  ) async {
    final last = _lastItunes;
    if (last != null) {
      final wait = itunesInterval - _now().difference(last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    if (_disposed) return null;
    _lastItunes = _now();
    final itunes = await _json(
      client,
      Uri.https('itunes.apple.com', '/search', {
        'term': '${identity.primary} ${identity.title}',
        'entity': 'song',
        'media': 'music',
        'limit': '10',
      }),
    );
    final appleCover = identity.select(
      itunes?['results'],
      source: DiscordCoverSource.itunes,
    );
    if (appleCover != null || _disposed) return appleCover;

    final deezer = await _json(
      client,
      Uri.https('api.deezer.com', '/search', {
        'q': '${identity.primary} ${identity.title}',
        'limit': '10',
      }),
    );
    final deezerCover = identity.select(
      deezer?['data'],
      source: DiscordCoverSource.deezer,
    );
    if (deezerCover != null || _disposed) return deezerCover;

    final info = await _json(
      client,
      _lastFm('track.getInfo', {
        'artist': identity.primary,
        'track': identity.title,
      }),
    );
    final infoTrack = info?['track'];
    final lastFmCover = identity.select(
      infoTrack is Map ? [infoTrack] : null,
      source: DiscordCoverSource.lastfm,
    );
    if (lastFmCover != null || _disposed) return lastFmCover;

    final search = await _json(
      client,
      _lastFm('track.search', {
        'artist': identity.primary,
        'track': identity.title,
        'limit': '5',
      }),
    );
    final searchResults = search?['results'];
    final trackMatches = searchResults is Map
        ? searchResults['trackmatches']
        : null;
    final searchCover = identity.select(
      trackMatches is Map ? trackMatches['track'] : null,
      source: DiscordCoverSource.lastfm,
    );
    if (searchCover != null || _disposed) return searchCover;

    // No arbitrary album by this artist: only a verified artist portrait.
    final artistKey = _name(identity.primary);
    final cachedArtist = _artists[artistKey];
    if (cachedArtist?.valid(_now()) ?? false) return cachedArtist!.result;
    final artistSearch = await _json(
      client,
      Uri.https('api.deezer.com', '/search/artist', {
        'q': identity.primary,
        'limit': '5',
      }),
    );
    final artistResults = artistSearch?['data'];
    DiscordCoverResult? photo;
    if (artistResults is List) {
      for (final artist in artistResults.whereType<Map>()) {
        if (!_sameName(identity.primary, artist['name']?.toString() ?? '')) {
          continue;
        }
        final url =
            publicDiscordArtworkUrl(artist['picture_big']) ??
            publicDiscordArtworkUrl(artist['picture_medium']);
        if (url != null) {
          photo = DiscordCoverResult(url, DiscordCoverSource.artistPhoto);
          break;
        }
      }
    }
    if (photo == null && !_disposed) {
      final artistInfo = await _json(
        client,
        _lastFm('artist.getInfo', {'artist': identity.primary}),
      );
      final artist = artistInfo?['artist'];
      if (artist is Map &&
          _sameName(identity.primary, artist['name']?.toString() ?? '')) {
        final url = _lastFmImage(artist['image']);
        if (url != null) {
          photo = DiscordCoverResult(url, DiscordCoverSource.artistPhoto);
        }
      }
    }
    _artists.remove(artistKey);
    _artists[artistKey] = _CachedCover(photo, _now().add(_fallbackTtl));
    _trim(_artists, 256);
    return photo;
  }

  Future<Map?> _json(http.Client client, Uri uri) async {
    if (_disposed) return null;
    final abort = Completer<void>();
    try {
      final request = http.AbortableRequest(
        'GET',
        uri,
        abortTrigger: abort.future,
      );
      final operation = () async {
        final response = await client.send(request);
        if (response.statusCode != 200 ||
            (response.contentLength ?? 0) > 256 * 1024) {
          await response.stream.listen(null).cancel();
          return null;
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          if (_disposed || bytes.length + chunk.length > 256 * 1024) {
            return null;
          }
          bytes.add(chunk);
        }
        final data = jsonDecode(utf8.decode(bytes.takeBytes()));
        return data is Map ? data : null;
      }();
      return await operation.timeout(
        requestTimeout,
        onTimeout: () {
          abort.complete();
          return null;
        },
      );
    } catch (_) {
      return null;
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }
}

Uri _lastFm(String method, Map<String, String> parameters) =>
    Uri.https('ws.audioscrobbler.com', '/2.0/', {
      'method': method,
      'api_key': DiscordCoverLookup._lastFmKey,
      'format': 'json',
      ...parameters,
    });

void _trim(Map<String, _CachedCover> cache, int maximum) {
  while (cache.length > maximum) {
    cache.remove(cache.keys.first);
  }
}

class _CachedCover {
  const _CachedCover(this.result, this.expires);
  final DiscordCoverResult? result;
  final DateTime? expires;
  bool valid(DateTime now) => expires == null || expires!.isAfter(now);
}

class _CoverIdentity {
  _CoverIdentity(
    this.title,
    this.primary,
    this.artists,
    this.album,
    this.duration,
  );
  final String title;
  final String primary;
  final List<String> artists;
  final String album;
  final double duration;
  String get key => jsonEncode([title, primary, artists, album, duration]);

  static _CoverIdentity? fromTrack(dynamic track) {
    if (track is! Map || track['album'] is! Map) return null;
    final album = track['album'] as Map;
    final artist = album['artist'];
    if (artist is! Map) return null;
    final title = track['title']?.toString().trim() ?? '';
    final primary = artist['name']?.toString().trim() ?? '';
    if (_name(title).isEmpty || _name(primary).isEmpty) return null;
    final credits = track['artists'];
    final artists = <String>{primary};
    if (credits is List) {
      for (final credit in credits.whereType<Map>()) {
        final name = credit['name']?.toString().trim() ?? '';
        if (name.isNotEmpty) artists.add(name);
      }
    }
    return _CoverIdentity(
      title,
      primary,
      artists.toList()..sort(),
      album['title']?.toString() ?? '',
      _number(track['duration']),
    );
  }

  bool knownArtist(String value) =>
      artists.any((artist) => _sameName(artist, value));

  bool artistMatches(String value) {
    if (_sameName(primary, value)) return true;
    final credits = _credits(value);
    return credits.isNotEmpty &&
        credits.every(knownArtist) &&
        credits.any((artist) => _sameName(primary, artist));
  }

  String songName(String value) {
    final feature = _featureSuffix.firstMatch(value);
    final guests = feature == null
        ? const <String>[]
        : _credits(feature.group(1)!);
    if (feature != null && guests.isNotEmpty && guests.every(knownArtist)) {
      value = value.substring(0, feature.start);
    }
    return _name(value);
  }

  DiscordCoverResult? select(
    dynamic values, {
    required DiscordCoverSource source,
  }) {
    if (values is! List) return null;
    DiscordCoverResult? best;
    var bestScore = double.negativeInfinity;
    for (final candidate in values.whereType<Map>()) {
      String candidateTitle;
      String candidateArtist;
      String candidateAlbum;
      String? url;
      double candidateDuration;
      switch (source) {
        case DiscordCoverSource.itunes:
          if (candidate['kind'] != null && candidate['kind'] != 'song') {
            continue;
          }
          candidateTitle = candidate['trackName']?.toString() ?? '';
          candidateArtist = candidate['artistName']?.toString() ?? '';
          candidateAlbum = candidate['collectionName']?.toString() ?? '';
          candidateDuration = _number(candidate['trackTimeMillis']) / 1000;
          url = publicDiscordArtworkUrl(candidate['artworkUrl100']);
          if (url != null) url = url.replaceAll('100x100', '600x600');
        case DiscordCoverSource.deezer:
          candidateTitle = candidate['title']?.toString() ?? '';
          candidateArtist = _artistName(candidate['artist']);
          candidateAlbum = candidate['album'] is Map
              ? candidate['album']['title']?.toString() ?? ''
              : '';
          candidateDuration = _number(candidate['duration']);
          url = candidate['album'] is Map
              ? publicDiscordArtworkUrl(candidate['album']['cover_big']) ??
                    publicDiscordArtworkUrl(candidate['album']['cover_medium'])
              : null;
        case DiscordCoverSource.lastfm:
          candidateTitle = candidate['name']?.toString() ?? '';
          candidateArtist = _artistName(candidate['artist']);
          candidateAlbum = candidate['album'] is Map
              ? candidate['album']['title']?.toString() ?? ''
              : '';
          candidateDuration = _number(candidate['duration']) / 1000;
          url = _lastFmImage(
            candidate['album'] is Map
                ? candidate['album']['image']
                : candidate['image'],
          );
        case DiscordCoverSource.artistPhoto:
          continue;
      }
      if (url == null ||
          !artistMatches(candidateArtist) ||
          songName(candidateTitle) != songName(title)) {
        continue;
      }
      final difference = (candidateDuration - duration).abs();
      if (duration > 0 && candidateDuration > 0 && difference > 8) continue;
      final score =
          (_name(album).isNotEmpty && _name(album) == _name(candidateAlbum)
              ? 1000.0
              : 0.0) +
          (duration > 0 && candidateDuration > 0 ? 100 - difference : 0);
      if (score > bestScore) {
        bestScore = score;
        best = DiscordCoverResult(url, source);
      }
    }
    return best;
  }
}

final _nonNameCharacters = RegExp(r'[^\p{L}\p{N}]', unicode: true);
final _creditSeparators = RegExp(
  r'\s*[,;&]\s*|\s+(?:feat\.?|ft\.?|featuring|with|x|\+)\s+',
  caseSensitive: false,
);
final _featureSuffix = RegExp(
  r'\s*[\(\[]\s*(?:feat\.?|ft\.?|featuring)\s+(.+?)\s*[\)\]]\s*$',
  caseSensitive: false,
);
String _name(String value) {
  final name = normalizeMusicSearch(value).replaceAll(_nonNameCharacters, '');
  return name == 'семьсотсемь' ? '707' : name;
}

List<String> _credits(String value) => value
    .split(_creditSeparators)
    .map((value) => value.trim())
    .where((value) => value.isNotEmpty)
    .toList();
String _artistName(dynamic value) =>
    value is Map ? value['name']?.toString() ?? '' : value?.toString() ?? '';
double _number(dynamic value) {
  final number = double.tryParse(value?.toString() ?? '') ?? 0;
  return number.isFinite && number > 0 ? number : 0;
}

bool _sameName(String first, String second) {
  final a = _name(first);
  final b = _name(second);
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;
  String transliterate(String value) {
    const letters = {
      'а': 'a',
      'б': 'b',
      'в': 'v',
      'г': 'g',
      'д': 'd',
      'е': 'e',
      'ж': 'zh',
      'з': 'z',
      'и': 'i',
      'й': 'y',
      'к': 'k',
      'л': 'l',
      'м': 'm',
      'н': 'n',
      'о': 'o',
      'п': 'p',
      'р': 'r',
      'с': 's',
      'т': 't',
      'у': 'u',
      'ф': 'f',
      'х': 'h',
      'ц': 'ts',
      'ч': 'ch',
      'ш': 'sh',
      'щ': 'sh',
      'ъ': '',
      'ы': 'y',
      'ь': '',
      'э': 'e',
      'ю': 'yu',
      'я': 'ya',
    };
    return value.split('').map((letter) => letters[letter] ?? letter).join();
  }

  return transliterate(a) == transliterate(b);
}

String? _lastFmImage(dynamic values) {
  if (values is! List) return null;
  const sizes = ['mega', 'extralarge', 'large', 'medium', 'small'];
  for (final size in sizes) {
    for (final image in values.whereType<Map>()) {
      if (image['size'] != size) continue;
      final url = publicDiscordArtworkUrl(image['#text']);
      if (url != null) return url;
    }
  }
  return null;
}

/// Discord cannot fetch files from a user's local server or private network.
String? publicDiscordArtworkUrl(dynamic value) {
  if (value is! String || value.length > 2048) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !['https', 'http'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  final host = uri.host.toLowerCase();
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.lan') ||
      host.endsWith('.internal')) {
    return null;
  }
  final address = InternetAddress.tryParse(host);
  if (address != null) {
    if (address.isLoopback || address.isLinkLocal) return null;
    final bytes = address.rawAddress;
    final ipv4 = bytes.length == 4
        ? bytes
        : (bytes.length == 16 &&
                  bytes.take(10).every((byte) => byte == 0) &&
                  bytes[10] == 255 &&
                  bytes[11] == 255
              ? bytes.sublist(12)
              : null);
    if (ipv4 != null &&
        (ipv4[0] == 0 ||
            ipv4[0] == 10 ||
            ipv4[0] == 127 ||
            ipv4[0] >= 224 ||
            (ipv4[0] == 172 && ipv4[1] >= 16 && ipv4[1] <= 31) ||
            (ipv4[0] == 192 && ipv4[1] == 168) ||
            (ipv4[0] == 100 && ipv4[1] >= 64 && ipv4[1] <= 127))) {
      return null;
    }
    if (bytes.length == 16 &&
        (bytes[0] & 0xfe == 0xfc || bytes.every((byte) => byte == 0))) {
      return null;
    }
  } else if (!host.contains('.')) {
    return null;
  }
  if (uri.path.contains('2a96cbd8b46e442fc41c2b86b821562f') ||
      uri.path.contains('182879f0815c4de88b3f2f24c0843114') ||
      uri.path.toLowerCase().contains('noimage')) {
    return null;
  }
  return uri.toString();
}
