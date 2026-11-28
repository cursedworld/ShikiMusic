import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'atomic_file_store.dart';
import 'local_music_catalog.dart';
import 'music_import.dart';
import 'server_config.dart';

typedef TrackDetails = ({String title, String artist, String album});
typedef TrackDetailsPatch = ({String? title, String? artist, String? album});

const trackDetailsMaxLength = 512;
final _keyPattern = RegExp(r'^[a-f0-9]{64}$');
final _controls = RegExp(r'[\x00-\x1f\x7f]');
final _bindings = Expando<({TrackDetailsStore owner, String? key})>();

bool _validText(String value, {bool required = false}) =>
    value.length <= trackDetailsMaxLength &&
    !_controls.hasMatch(value) &&
    (!required || value.trim().isNotEmpty);

bool validTrackDetails(TrackDetails value) =>
    _validText(value.title, required: true) &&
    _validText(value.artist) &&
    _validText(value.album);

TrackDetailsPatch? trackDetailsPatch(dynamic track) {
  final binding = track is Map ? _bindings[track] : null;
  return binding == null ? null : binding.owner._edits[binding.key];
}

String trackDisplayTitle(dynamic track, {String fallback = ''}) =>
    trackDetailsPatch(track)?.title ??
    (track is Map ? track['title']?.toString() : null) ??
    fallback;

String trackDisplayArtist(dynamic track) =>
    trackDetailsPatch(track)?.artist ?? trackArtistLabel(track);

String _originalAlbum(dynamic track) {
  final album = track is Map ? track['album'] : null;
  return album is Map ? album['title']?.toString() ?? '' : '';
}

String trackDisplayAlbum(dynamic track) =>
    trackDetailsPatch(track)?.album ?? _originalAlbum(track);

TrackDetails originalTrackDetails(dynamic track) => (
  title: track is Map ? track['title']?.toString() ?? '' : '',
  artist: trackArtistLabel(track),
  album: _originalAlbum(track),
);

TrackDetails displayTrackDetails(dynamic track) => (
  title: trackDisplayTitle(track),
  artist: trackDisplayArtist(track),
  album: trackDisplayAlbum(track),
);

bool matchesTrackDetailsSearch(dynamic track, String query) {
  final patch = trackDetailsPatch(track);
  return matchesTrackSearch(
    track,
    query,
    displayTitle: patch?.title,
    displayArtist: patch?.artist,
    displayAlbum: patch?.album,
  );
}

TrackDetailsPatch? resolveTrackDetailsEdit({
  required TrackDetails shown,
  required TrackDetails edited,
  required TrackDetails original,
  TrackDetailsPatch? previous,
}) {
  String? field(String value, String initial, String base, String? saved) {
    if (value == initial.trim()) return saved == base ? null : saved;
    return value == base.trim() ? null : value;
  }

  final patch = (
    title: field(edited.title, shown.title, original.title, previous?.title),
    artist: field(
      edited.artist,
      shown.artist,
      original.artist,
      previous?.artist,
    ),
    album: field(edited.album, shown.album, original.album, previous?.album),
  );
  return _empty(patch) ? null : patch;
}

bool _empty(TrackDetailsPatch patch) =>
    patch.title == null && patch.artist == null && patch.album == null;

bool _validPatch(TrackDetailsPatch patch) =>
    (patch.title == null || _validText(patch.title!, required: true)) &&
    (patch.artist == null || _validText(patch.artist!)) &&
    (patch.album == null || _validText(patch.album!));

/// Attaches presentation-only corrections to live track objects. The map
/// used for playback, the cache, and network lookups is never edited here.
class TrackDetailsStore {
  TrackDetailsStore(Directory directory, {required Uri server})
    : _file = File('${directory.path}/track_details.json'),
      _server = server;

  static const _maxBytes = 4 * 1024 * 1024;
  final File _file;
  final Uri _server;
  Map<String, TrackDetailsPatch> _edits = const {};
  Future<void>? _loading;
  Future<void> _tail = Future<void>.value();

  Future<void> load() => _loading ??= _read();

  String? bind(dynamic track) {
    if (track is! Map) return null;
    final binding = _bindings[track];
    if (binding != null && identical(binding.owner, this)) return binding.key;
    final key = _identity(track);
    _bindings[track] = (owner: this, key: key);
    return key;
  }

  String? _identity(Map track) {
    final id = track['id'];
    if (id is! int || id == 0) return null;
    if (id < 0) {
      final digest = localTrackDigest(track);
      return digest == null ? null : _fingerprint(['local', digest]);
    }

    final source = track['source_id'];
    final sourceId = source is String ? source.trim() : '';
    if (sourceId.length > trackDetailsMaxLength) return null;
    final audio = track['audio_file'];
    Uri? media;
    if (audio is String && audio.trim().isNotEmpty) {
      if (audio.length > 4096) return null;
      media = Uri.tryParse(resolveMediaUrlForBase(_server.toString(), audio));
      if (media == null ||
          media.scheme != _server.scheme ||
          media.host != _server.host ||
          media.port != _server.port ||
          media.userInfo.isNotEmpty) {
        return null;
      }
    }
    final scope = [_server.origin, _server.path, id];
    if (sourceId.isNotEmpty) {
      return _fingerprint([...scope, 'source', sourceId]);
    }
    final versions = track['content_versions'];
    final audioVersion = versions is Map ? versions['audio'] : null;
    if (audioVersion is String && _keyPattern.hasMatch(audioVersion)) {
      return _fingerprint([...scope, 'audio', audioVersion]);
    }
    if (media == null || media.path.isEmpty) return null;
    // Old catalogs don't have a recording ID. Fail closed when a reused ID
    // or filename no longer agrees with the original recording details.
    final original = originalTrackDetails(track);
    if (original.title.length > trackDetailsMaxLength ||
        original.artist.length > trackDetailsMaxLength ||
        original.album.length > trackDetailsMaxLength) {
      return null;
    }
    return _fingerprint([
      ...scope,
      'legacy',
      media.path,
      track['duration']?.toString(),
      original.title,
      original.artist,
      original.album,
    ]);
  }

  Future<FileSystemEntityType> _fileType() async {
    final type = await FileSystemEntity.type(_file.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw const FormatException('Invalid track details file type');
    }
    return type;
  }

  Future<void> _read() async {
    if (await _fileType() == FileSystemEntityType.notFound) return;
    final reader = await _file.open();
    final Object? decoded;
    try {
      final size = await reader.length();
      if (size > _maxBytes) {
        throw const FormatException('Track details file too large');
      }
      decoded = jsonDecode(utf8.decode(await reader.read(size + 1)));
    } finally {
      await reader.close();
    }
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['edits'] is! Map) {
      throw const FormatException('Invalid track details');
    }

    final edits = <String, TrackDetailsPatch>{};
    for (final entry in (decoded['edits'] as Map).entries) {
      final key = entry.key;
      final row = entry.value;
      if (key is! String ||
          !_keyPattern.hasMatch(key) ||
          row is! Map ||
          !row.keys.every(const {'title', 'artist', 'album'}.contains) ||
          !row.values.every((value) => value is String)) {
        throw const FormatException('Invalid track details entry');
      }
      final patch = (
        title: row['title'] as String?,
        artist: row['artist'] as String?,
        album: row['album'] as String?,
      );
      if (!_validPatch(patch) || _empty(patch)) {
        throw const FormatException('Invalid track details values');
      }
      edits[key] = patch;
    }
    _edits = edits;
  }

  Future<void> save(String key, TrackDetailsPatch? patch) {
    final result = _tail.then((_) async {
      if (!_keyPattern.hasMatch(key) ||
          (patch != null && !_validPatch(patch))) {
        throw const FormatException('Invalid track details edit');
      }
      await load();
      if (_edits[key] == patch) return;
      final next = {..._edits};
      if (patch == null || _empty(patch)) {
        next.remove(key);
      } else {
        next[key] = patch;
      }
      final body = jsonEncode({
        'version': 1,
        'edits': {
          for (final entry in next.entries)
            entry.key: {
              if (entry.value.title case final String title) 'title': title,
              if (entry.value.artist case final String artist) 'artist': artist,
              if (entry.value.album case final String album) 'album': album,
            },
        },
      });
      final bytes = utf8.encode(body);
      if (bytes.length > _maxBytes) {
        throw const FormatException('Track details file too large');
      }
      await _fileType();
      await atomicFileStore.writeBytes(_file, bytes);
      _edits = next;
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

String _fingerprint(List<Object?> identity) =>
    sha256.convert(utf8.encode(jsonEncode(identity))).toString();
