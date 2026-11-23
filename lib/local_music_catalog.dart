import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const localMusicCatalogName = 'local_music.json';
const localMusicDirectoryName = 'local_music';
const localMusicMaxBytes = 8 * 1024 * 1024 * 1024;
const localLyricMaxBytes = 256 * 1024;
const localArtworkMaxBytes = 4 * 1024 * 1024;
const _maxCatalogBytes = 64 * 1024 * 1024;
const _maxLocalId = 0x1000000000000; // Exactly representable in JSON clients.
final _digest = RegExp(r'^[0-9a-f]{64}$');
final _asset = RegExp(r'^local_(audio|cover)_([0-9a-f]{64})\.(mp3|jpg)$');

bool isLocalDigest(Object? value) => value is String && _digest.hasMatch(value);

String? localTrackDigest(dynamic track) {
  if (track is! Map || !isLocalId(track['id'])) return null;
  final key = track['local_key'];
  if (key is! String || !key.startsWith('local:')) return null;
  final hash = key.substring(6);
  return isLocalDigest(hash) ? hash : null;
}

bool isLocalMusic(dynamic track) => localTrackDigest(track) != null;
bool isLocalId(Object? id) => id is int && id < 0 && id >= -_maxLocalId;

String localAudioName(String digest) => 'local_audio_$digest.mp3';
String localCoverName(String digest) => 'local_cover_$digest.jpg';

String? localAssetDigest(String name) {
  final match = _asset.firstMatch(name);
  if (match == null || (match[1] == 'audio') != (match[3] == 'mp3')) {
    return null;
  }
  return match[2];
}

Directory localMusicDirectory(Directory root) =>
    Directory('${root.path}/$localMusicDirectoryName');

File localMusicAsset(Directory root, String name) {
  if (localAssetDigest(name) == null) throw ArgumentError.value(name);
  return File('${localMusicDirectory(root).path}/$name');
}

Future<void> ensureLocalMusicDirectory(Directory root) async {
  final directory = localMusicDirectory(root);
  final type = await FileSystemEntity.type(directory.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    await directory.create();
  } else if (type != FileSystemEntityType.directory) {
    throw const FileSystemException('Local music storage is not a directory');
  }
}

/// The integer ID is a device-side alias; the digest is the durable identity.
int allocateLocalTrackId(String digest, Set<int> used) {
  if (!isLocalDigest(digest)) throw ArgumentError.value(digest);
  var number = int.parse(digest.substring(0, 12), radix: 16) + 1;
  while (!used.add(-number)) {
    number = number == _maxLocalId ? 1 : number + 1;
  }
  return -number;
}

int _metadataId(String scope, String value) {
  final normalized = value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  final hash = sha256
      .convert(utf8.encode('$scope\u0000$normalized'))
      .toString();
  return -int.parse(hash.substring(0, 12), radix: 16) - 1;
}

class LocalMusicEntry {
  const LocalMusicEntry({
    required this.id,
    required this.digest,
    required this.title,
    this.artist = '',
    this.album = '',
    this.trackNumber,
    this.discNumber,
    this.duration = 0,
    this.lyrics = '',
  });

  final int id, duration;
  final String digest, title, artist, album, lyrics;
  final int? trackNumber, discNumber;

  LocalMusicEntry withIdAndLyrics(int id, String lyrics) => LocalMusicEntry(
    id: id,
    digest: digest,
    title: title,
    artist: artist,
    album: album,
    trackNumber: trackNumber,
    discNumber: discNumber,
    duration: duration,
    lyrics: lyrics,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'sha256': digest,
    'title': title,
    'artist': artist,
    'album': album,
    'duration': duration,
    if (trackNumber != null) 'track_number': trackNumber,
    if (discNumber != null) 'disc_number': discNumber,
    if (lyrics.isNotEmpty) 'lyrics': lyrics,
  };

  Map<String, Object?> toTrack({
    String unknownArtist = 'Unknown artist',
    String unknownAlbum = 'Unknown album',
  }) {
    final credit = {
      'id': _metadataId('artist', artist),
      'name': artist.isEmpty ? unknownArtist : artist,
    };
    return {
      'id': id,
      'local_key': 'local:$digest',
      'title': title,
      'duration': duration,
      'audio_file': '',
      'video_file': '',
      'lyrics': lyrics,
      'track_number': trackNumber,
      'disc_number': discNumber,
      'artists': [credit],
      'album': {
        'id': _metadataId('album', '$artist\u0000$album'),
        'title': album.isEmpty ? unknownAlbum : album,
        'artist': credit,
        'cover': '',
      },
    };
  }
}

List<LocalMusicEntry> decodeLocalMusicCatalog(dynamic data) {
  if (data is! Map || data['version'] != 1 || data['tracks'] is! List) {
    throw const FormatException('Invalid local music catalog');
  }
  final rows = data['tracks'] as List;
  if (rows.length > 100000) {
    throw const FormatException('Too many local tracks');
  }
  final ids = <int>{};
  final keys = <String>{};
  bool tag(Object? value) => value is String && value.length <= 1024;
  bool number(Object? value) =>
      value == null || (value is int && value > 0 && value <= 9999);
  return [
    for (final row in rows)
      if (row is Map &&
          isLocalId(row['id']) &&
          isLocalDigest(row['sha256']) &&
          ids.add(row['id'] as int) &&
          keys.add(row['sha256'] as String) &&
          tag(row['title']) &&
          (row['title'] as String).trim().isNotEmpty &&
          tag(row['artist']) &&
          tag(row['album']) &&
          row['duration'] is int &&
          (row['duration'] as int) >= 0 &&
          number(row['track_number']) &&
          number(row['disc_number']) &&
          (row['lyrics'] == null ||
              (row['lyrics'] is String &&
                  (row['lyrics'] as String).length <= localLyricMaxBytes &&
                  utf8.encode(row['lyrics'] as String).length <=
                      localLyricMaxBytes)))
        LocalMusicEntry(
          id: row['id'],
          digest: row['sha256'],
          title: row['title'],
          artist: row['artist'],
          album: row['album'],
          duration: row['duration'],
          trackNumber: row['track_number'],
          discNumber: row['disc_number'],
          lyrics: row['lyrics'] ?? '',
        )
      else
        throw const FormatException('Invalid or duplicate local track'),
  ];
}

Map<String, Object> encodeLocalMusicCatalog(
  Iterable<LocalMusicEntry> entries,
) => {'version': 1, 'tracks': entries.map((entry) => entry.toJson()).toList()};

Future<List<LocalMusicEntry>> readLocalMusicCatalog(Directory root) async {
  final file = File('${root.path}/$localMusicCatalogName');
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return [];
  if (type != FileSystemEntityType.file ||
      await file.length() > _maxCatalogBytes) {
    throw const FormatException('Invalid local music catalog file');
  }
  return decodeLocalMusicCatalog(jsonDecode(await file.readAsString()));
}

String encodeLocalMusicCatalogText(Iterable<LocalMusicEntry> entries) {
  final text = jsonEncode(encodeLocalMusicCatalog(entries));
  if (text.length > _maxCatalogBytes ||
      utf8.encode(text).length > _maxCatalogBytes) {
    throw const FormatException('Local music catalog is too large');
  }
  return text;
}
