import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'atomic_file_store.dart';
import 'local_music_metadata.dart';

const localMusicCatalogName = 'local_music.json';
const _legacyLocalMusicDirectoryName = 'local_music';
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

File localMusicVideo(Directory root, String digest) {
  if (!isLocalDigest(digest)) throw ArgumentError.value(digest);
  return File('${root.path}/local_video_$digest.mp4');
}

String? localAssetDigest(String name) {
  final match = _asset.firstMatch(name);
  if (match == null || (match[1] == 'audio') != (match[3] == 'mp3')) {
    return null;
  }
  return match[2];
}

File localMusicAsset(Directory root, String name) {
  if (localAssetDigest(name) == null) throw ArgumentError.value(name);
  return File('${root.path}/$name');
}

/// The first release kept assets in a subdirectory. Keep reading those
/// copies without moving them or creating a second copy on reimport.
File resolveLocalMusicAsset(Directory root, String name) {
  final target = localMusicAsset(root, name);
  if (FileSystemEntity.typeSync(target.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    return target;
  }
  final legacyDirectory = '${root.path}/$_legacyLocalMusicDirectoryName';
  if (FileSystemEntity.typeSync(legacyDirectory, followLinks: false) !=
      FileSystemEntityType.directory) {
    return target;
  }
  final legacy = File('$legacyDirectory/$name');
  return FileSystemEntity.typeSync(legacy.path, followLinks: false) ==
          FileSystemEntityType.file
      ? legacy
      : target;
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
    this.metadata,
  });

  final int id, duration;
  final String digest, title, artist, album, lyrics;
  final int? trackNumber, discNumber;
  final LocalMusicMetadata? metadata;

  String get preferredLyrics =>
      lyrics.trim().isNotEmpty ? lyrics : metadata?.lyrics ?? '';

  LocalMusicEntry withIdAndLyrics(int id, String lyrics) =>
      _copy(id, lyrics, metadata);

  LocalMusicEntry withMetadata(LocalMusicMetadata value) =>
      _copy(id, lyrics, value);

  LocalMusicEntry _copy(int id, String lyrics, LocalMusicMetadata? metadata) =>
      LocalMusicEntry(
        id: id,
        digest: digest,
        title: title,
        artist: artist,
        album: album,
        trackNumber: trackNumber,
        discNumber: discNumber,
        duration: duration,
        lyrics: lyrics,
        metadata: metadata,
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
    if (metadata != null) 'metadata': metadata!.toJson(),
  };

  Map<String, Object?> toTrack({
    String unknownArtist = 'Unknown artist',
    String unknownAlbum = 'Unknown album',
    Map? serverTrack,
    Uri? matchedServer,
  }) {
    Map<String, Object?> ownCredit(String name) => {
      'id': _metadataId('artist', name),
      'name': name.isEmpty ? unknownArtist : name,
    };
    final serverAlbum = serverTrack?['album'];
    final serverArtists = serverTrack?['artists'];
    final credits =
        serverArtists is List && serverArtists.whereType<Map>().isNotEmpty
        ? serverArtists.whereType<Map>().toList()
        : serverAlbum is Map && serverAlbum['artist'] is Map
        ? [serverAlbum['artist'] as Map]
        : (metadata?.artists ?? [artist]).map(ownCredit).toList();
    final mainCredit = serverAlbum is Map && serverAlbum['artist'] is Map
        ? serverAlbum['artist'] as Map
        : credits.first;
    final albumName =
        (serverAlbum is Map ? serverAlbum['title']?.toString() : null) ??
        (metadata?.album.isNotEmpty == true ? metadata!.album : album);
    final serverText = serverTrack?['lyrics'];
    final displayedLyrics = lyrics.trim().isNotEmpty
        ? lyrics
        : serverText is String && serverText.trim().isNotEmpty
        ? serverText
        : preferredLyrics;
    final catalogId = serverTrack?['id'];
    final cover = localMatchMediaUrl(
      matchedServer,
      serverAlbum is Map ? serverAlbum['cover'] : metadata?.cover,
      externalArtwork: true,
    );
    final video = localMatchMediaUrl(
      matchedServer,
      serverTrack == null ? metadata?.video : serverTrack['video_file'],
    );
    return {
      'id': id,
      'local_key': 'local:$digest',
      if (catalogId is int && catalogId > 0) 'local_match_id': catalogId,
      'title': serverTrack?['title'] ?? metadata?.title ?? title,
      'duration': duration,
      'audio_file': '',
      'video_file': video,
      'lyrics': displayedLyrics,
      'track_number': trackNumber ?? serverTrack?['track_number'],
      'disc_number': discNumber ?? serverTrack?['disc_number'],
      'artists': credits,
      'album': {
        'id':
            (serverAlbum is Map ? serverAlbum['id'] : null) ??
            _metadataId('album', '${mainCredit['name']}\u0000$albumName'),
        'title': albumName.isEmpty ? unknownAlbum : albumName,
        'artist': mainCredit,
        'cover': cover.isNotEmpty
            ? cover
            : localMatchMediaUrl(
                matchedServer,
                metadata?.cover,
                externalArtwork: true,
              ),
        if (serverAlbum is Map) 'cover_version': serverAlbum['cover_version'],
      },
    };
  }
}

Map<int, Map<String, Object?>> projectLocalMusic(
  Iterable<LocalMusicEntry> entries,
  Iterable<dynamic> catalog, {
  required Uri server,
  required String unknownArtist,
  required String unknownAlbum,
}) {
  final serverKey = localMusicServerKey(server);
  final byId = <int, Map>{};
  final bySource = <String, Map>{};
  if (entries.any((entry) => entry.metadata?.serverKey == serverKey)) {
    for (final row in catalog.whereType<Map>()) {
      final id = row['id'];
      if (id is! int || id <= 0) continue;
      byId[id] = row;
      final source = row['source_id'];
      if (source is String && source.isNotEmpty) bySource[source] = row;
    }
  }
  return {
    for (final entry in entries)
      entry.id: _projectEntry(
        entry,
        server,
        serverKey,
        byId,
        bySource,
        unknownArtist: unknownArtist,
        unknownAlbum: unknownAlbum,
      ),
  };
}

Map<String, Object?> _projectEntry(
  LocalMusicEntry entry,
  Uri server,
  String serverKey,
  Map<int, Map> byId,
  Map<String, Map> bySource, {
  required String unknownArtist,
  required String unknownAlbum,
}) {
  final metadata = entry.metadata;
  final sameServer = metadata?.serverKey == serverKey;
  final candidate = !sameServer
      ? null
      : metadata!.sourceId.isEmpty
      ? byId[metadata.trackId]
      : bySource[metadata.sourceId] ?? byId[metadata.trackId];
  final verified =
      candidate != null &&
      metadata!.matchesCatalogRow(candidate, entry.duration);
  return entry.toTrack(
    unknownArtist: unknownArtist,
    unknownAlbum: unknownAlbum,
    serverTrack: verified ? candidate : null,
    matchedServer: sameServer && (candidate == null || verified)
        ? server
        : null,
  );
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
          metadata: LocalMusicMetadata.decode(row['metadata']),
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

/// A late lookup must not recreate an entry that has already been deleted.
Future<List<LocalMusicEntry>?> updateLocalMusicMetadata({
  required Directory directory,
  required LocalMusicEntry target,
  required LocalMusicMetadata metadata,
}) async {
  List<LocalMusicEntry>? updated;
  await atomicFileStore.writeStringLazy(
    File('${directory.path}/$localMusicCatalogName'),
    () async {
      final entries = await readLocalMusicCatalog(directory);
      final index = entries.indexWhere(
        (entry) => entry.id == target.id && entry.digest == target.digest,
      );
      if (index >= 0) {
        entries[index] = entries[index].withMetadata(metadata);
        updated = entries;
      }
      return encodeLocalMusicCatalogText(entries);
    },
  );
  return updated;
}

/// Unlist the exact owned recording before deleting either managed copy.
/// The same catalog FIFO turn excludes an import of those bytes during cleanup.
Future<({bool removed, bool cleanupComplete})> removeLocalMusic({
  required Directory directory,
  required int id,
  required String digest,
  FutureOr<void> Function(List<LocalMusicEntry>)? onRemoved,
}) async {
  if (!isLocalId(id) || !isLocalDigest(digest)) {
    return (removed: false, cleanupComplete: true);
  }
  var removed = false;
  var cleanupComplete = true;
  late List<LocalMusicEntry> remaining;
  await atomicFileStore.writeStringLazy(
    File('${directory.path}/$localMusicCatalogName'),
    () async {
      final entries = await readLocalMusicCatalog(directory);
      remaining = entries.where((entry) {
        if (entry.id != id || entry.digest != digest) return true;
        removed = true;
        return false;
      }).toList();
      return encodeLocalMusicCatalogText(remaining);
    },
    afterCommit: () async {
      if (!removed) return;
      try {
        await onRemoved?.call(remaining);
      } catch (_) {
        // Publication has happened. A caller that couldn't relinquish audio
        // must not be told that its files were erased.
        cleanupComplete = false;
        return;
      }
      final legacy = Directory(
        '${directory.path}/$_legacyLocalMusicDirectoryName',
      );
      final roots = [
        directory,
        if (await FileSystemEntity.type(legacy.path, followLinks: false) ==
            FileSystemEntityType.directory)
          legacy,
      ];
      for (final file in [
        for (final root in roots) ...[
          localMusicAsset(root, localAudioName(digest)),
          localMusicAsset(root, localCoverName(digest)),
        ],
        localMusicVideo(directory, digest),
      ]) {
        try {
          final type = await FileSystemEntity.type(
            file.path,
            followLinks: false,
          );
          if (type == FileSystemEntityType.file) {
            await file.delete();
          } else if (type != FileSystemEntityType.notFound) {
            cleanupComplete = false;
          }
        } on FileSystemException {
          cleanupComplete = false;
        }
      }
    },
  );
  return (removed: removed, cleanupComplete: cleanupComplete);
}
