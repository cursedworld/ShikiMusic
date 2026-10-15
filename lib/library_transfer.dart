import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'atomic_file_store.dart';
import 'playlist_artwork.dart';
import 'server_config.dart';
import 'statistics_store.dart';

const _manifest = 'shiki-transfer.json';
const _pending = 'transfer_pending.json';
const _jsonLimit = 64 * 1024 * 1024;
const _totalLimit = 64 * 1024 * 1024 * 1024;
const _jsonFiles = {
  'my_playlists.json',
  'liked_tracks.json',
  'offline_tracks.json',
  'offline_artists.json',
  'track_versions.json',
  'shiki_settings.json',
  'listening_statistics.json',
};
final _mediaName = RegExp(
  r'^(?:track_[0-9]+(?:_[a-f0-9]{64})?\.(?:mp3|lrc)|video_[0-9]+(?:_[a-f0-9]{64})?\.mp4)$',
);
final _imageName = RegExp(
  r'^(?:(?:cover|artist)_[0-9]+(?:_[^<>:"/\\|?*\x00-\x1f]+)?|playlist_artwork_[0-9]+|custom_bg_[0-9]+)\.(?:jpg|jpeg|png|webp|gif)$',
  caseSensitive: false,
);

bool _allowed(String name) =>
    name.length <= 240 &&
    !name.contains('..') &&
    (_jsonFiles.contains(name) ||
        _mediaName.hasMatch(name) ||
        _imageName.hasMatch(name));
bool _audioVideo(String name) => name.endsWith('.mp3') || name.endsWith('.mp4');
Future<String> _hash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();
File _file(String root, String name) =>
    File('$root${Platform.pathSeparator}$name');

Future<void> _regularTarget(File file) async {
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type != FileSystemEntityType.notFound &&
      type != FileSystemEntityType.file) {
    throw const FormatException(
      'Import destination contains a link or directory',
    );
  }
}

/// Streaming ZIP (STORE): MP3/MP4 are already compressed. No large media buffer
/// crosses the UI isolate, and imports cannot contain compressed ZIP bombs.
Future<String> exportLibraryArchive({
  required Directory directory,
  required String destination,
  required bool includeMedia,
  Uint8List? statistics,
}) => compute(_export, {
  'root': directory.path,
  'destination': destination,
  'media': includeMedia,
  'statistics': statistics,
});

Future<String> _export(Map<String, Object?> job) async {
  final root = job['root'] as String;
  final output = File(job['destination'] as String);
  await _regularTarget(output);
  if (await output.exists()) {
    throw const FormatException('Export file already exists');
  }
  final encoder = ZipFileEncoder()..create(output.path, level: 0);
  final inventory = <String, Map<String, Object>>{};
  var total = 0;
  Future<void> addBytes(String name, List<int> bytes) async {
    if (bytes.length > _jsonLimit) {
      throw const FormatException('Backup entry too large');
    }
    final entry = ArchiveFile(name, bytes.length, bytes)
      ..compression = CompressionType.none;
    encoder.addArchiveFile(entry);
    inventory[name] = {
      'size': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    };
  }

  Future<void> addFile(String name, File file) async {
    if (inventory.containsKey(name)) return;
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return;
    }
    final before = await file.stat();
    total += before.size;
    if (total > _totalLimit ||
        before.size >
            (_audioVideo(name) ? 8 * 1024 * 1024 * 1024 : _jsonLimit)) {
      throw const FormatException('Backup exceeds size limit');
    }
    final digest = await _hash(file);
    final stream = InputFileStream(file.path);
    try {
      encoder.addArchiveFile(
        ArchiveFile.stream(name, stream)..compression = CompressionType.none,
      );
    } finally {
      await stream.close();
    }
    final after = await file.stat();
    if (before.size != after.size ||
        before.modified != after.modified ||
        digest != await _hash(file)) {
      throw const FileSystemException('File changed during export; retry');
    }
    inventory[name] = {'size': after.size, 'sha256': digest};
  }

  try {
    final playlistFile = _file(root, 'my_playlists.json');
    if (await playlistFile.exists()) {
      final playlists = await _readJson(playlistFile) as List;
      for (final raw in playlists) {
        final item = raw as Map;
        final image = item['image'];
        if (image is String &&
            image.isNotEmpty &&
            !isPortablePlaylistArtwork(image)) {
          final source = File(image);
          final ext = image.split('.').last.toLowerCase();
          final name = 'playlist_artwork_${item['id']}.$ext';
          if (_imageName.hasMatch(name) && await source.exists()) {
            await addFile(name, source);
            item['image'] = name;
          } else {
            item['image'] = null;
          }
        }
      }
      _validateJson('my_playlists.json', playlists);
      await addBytes('my_playlists.json', utf8.encode(jsonEncode(playlists)));
    }
    await for (final entity in Directory(root).list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!_allowed(name) ||
          name == 'my_playlists.json' ||
          name == 'listening_statistics.json' ||
          (job['media'] != true && _audioVideo(name))) {
        continue;
      }
      if (_jsonFiles.contains(name)) {
        _validateJson(name, await _readJson(entity));
      }
      await addFile(name, entity);
    }
    final statistics = job['statistics'] as Uint8List?;
    if (statistics != null) {
      await addBytes('listening_statistics.json', statistics);
    }
    final manifest = utf8.encode(
      jsonEncode({
        'format': 'shiki-library',
        'version': 1,
        'media': job['media'],
        'files': inventory,
      }),
    );
    encoder.addArchiveFile(
      ArchiveFile(_manifest, manifest.length, manifest)
        ..compression = CompressionType.none,
    );
    await encoder.close();
    return output.path;
  } catch (_) {
    try {
      await encoder.close();
    } catch (_) {}
    // Only this newly-created, incomplete export is removed.
    if (await output.exists()) await output.delete();
    rethrow;
  }
}

Future<dynamic> _readJson(File file) async {
  if (await file.length() > _jsonLimit) {
    throw const FormatException('JSON too large');
  }
  return jsonDecode(await file.readAsString());
}

void _validateJson(String name, dynamic value) {
  bool id(dynamic v) => v is int && v > 0;
  bool ids(dynamic v) => v is List && v.length <= 100000 && v.every(id);
  bool rows(dynamic v) =>
      v is List &&
      v.length <= 100000 &&
      v.every((dynamic row) => row is Map && id(row['id']));
  var valid = true;
  switch (name) {
    case 'liked_tracks.json':
      valid = ids(value);
    case 'my_playlists.json':
      valid =
          rows(value) &&
          (value as List).every(
            (dynamic row) =>
                row['name'] is String &&
                (row['name'] as String).length <= 1000 &&
                ids(row['tracks']) &&
                (row['image'] == null ||
                    row['image'] == '' ||
                    (row['image'] is String &&
                        isPortablePlaylistArtwork(row['image']))),
          );
    case 'offline_tracks.json':
      valid =
          rows(value) &&
          (value as List).every(
            (dynamic row) =>
                row['title'] is String &&
                row['album'] is Map &&
                id(row['album']['id']) &&
                row['album']['artist'] is Map &&
                id(row['album']['artist']['id']) &&
                row['album']['artist']['name'] is String &&
                (row['artists'] == null || rows(row['artists'])),
          );
    case 'offline_artists.json':
      valid =
          rows(value) &&
          (value as List).every((dynamic row) => row['name'] is String);
    case 'track_versions.json':
      valid =
          value is Map &&
          value.length <= 100000 &&
          value.entries.every(
            (entry) =>
                int.tryParse(entry.key.toString()) != null &&
                entry.value is Map &&
                ['audio', 'lyrics', 'video'].every(
                  (key) =>
                      entry.value[key] == null ||
                      (entry.value[key] is String &&
                          _mediaName.hasMatch(entry.value[key])),
                ),
          );
    case 'shiki_settings.json':
      valid =
          value is Map &&
          (value['customBackground'] == null ||
              (value['customBackground'] is String &&
                  _imageName.hasMatch(value['customBackground']))) &&
          (value['serverBaseUrl'] == null ||
              (value['serverBaseUrl'] is String &&
                  isValidServerBaseUrl(value['serverBaseUrl']))) &&
          [
            'vinylRotation',
            'playVideoClip',
            'discordShowGitHubButton',
            'discordLyricsStatus',
          ].every((key) => value[key] == null || value[key] is bool) &&
          (value['accentColor'] == null || value['accentColor'] is int) &&
          (value['themeColor'] == null || value['themeColor'] is String) &&
          (value['language'] == null || value['language'] is String);
  }
  if (!valid) throw FormatException('Invalid backup data: $name');
}

Future<void> prepareLibraryImport({
  required Directory directory,
  required String archive,
  bool restoreSettings = false,
}) => compute(_prepare, {
  'root': directory.path,
  'archive': archive,
  'settings': restoreSettings,
});

Future<void> _prepare(Map<String, Object?> job) async {
  final root = job['root'] as String;
  if (await _file(root, _pending).exists()) {
    throw const FormatException(
      'An import is already pending. Restart the player first.',
    );
  }
  final input = InputFileStream(job['archive'] as String);
  final stageName = 'transfer_stage_${DateTime.now().microsecondsSinceEpoch}';
  final stage = Directory('$root/$stageName');
  var accepted = false;
  try {
    if (input.length > _totalLimit) {
      throw const FormatException('Archive too large');
    }
    final directory = ZipDirectory()..read(input);
    if (directory.fileHeaders.length > 100000) {
      throw const FormatException('Too many files');
    }
    final names = <String>{};
    var total = 0;
    for (final header in directory.fileHeaders) {
      final name = header.filename;
      total += header.uncompressedSize;
      if ((!_allowed(name) && name != _manifest) ||
          !names.add(name.toLowerCase()) ||
          header.compressionMethod != 0 ||
          header.compressedSize != header.uncompressedSize ||
          header.file?.filename != name ||
          header.file?.compressionMethod != CompressionType.none ||
          header.file?.uncompressedSize != header.uncompressedSize ||
          header.file?.length != header.uncompressedSize ||
          header.generalPurposeBitFlag & 1 != 0 ||
          ((header.externalFileAttributes >> 16) & 0xf000) == 0xa000 ||
          header.uncompressedSize >
              (_audioVideo(name) ? 8 * 1024 * 1024 * 1024 : _jsonLimit) ||
          total > _totalLimit) {
        throw const FormatException('Unsupported or unsafe archive entry');
      }
    }
    input.setPosition(0);
    final archive = ZipDecoder().decodeStream(input);
    final manifestFile = archive.find(_manifest);
    if (manifestFile == null || manifestFile.size > _jsonLimit) {
      throw const FormatException('Not a Shiki archive');
    }
    final manifestBytes = manifestFile.readBytes()!;
    final manifest = jsonDecode(utf8.decode(manifestBytes));
    if (manifest is! Map ||
        manifest['format'] != 'shiki-library' ||
        manifest['version'] != 1 ||
        manifest['files'] is! Map) {
      throw const FormatException('Unsupported Shiki archive version');
    }
    final inventory = manifest['files'] as Map;
    if (inventory.length != archive.length - 1 ||
        inventory.keys.any((name) => name is! String || !_allowed(name))) {
      throw const FormatException('Archive inventory mismatch');
    }
    await stage.create();
    for (final entry in archive) {
      if (entry.name == _manifest) continue;
      final expected = inventory[entry.name];
      if (!entry.isFile ||
          entry.isSymbolicLink ||
          expected is! Map ||
          expected['size'] != entry.size ||
          expected['sha256'] is! String) {
        throw const FormatException('Invalid archive entry');
      }
      final destination = _file(stage.path, entry.name);
      final output = OutputFileStream(destination.path);
      try {
        entry.writeContent(output);
      } finally {
        await output.close();
      }
      if (await destination.length() != expected['size'] ||
          await _hash(destination) != expected['sha256']) {
        throw const FormatException('Archive checksum mismatch');
      }
      if (_jsonFiles.contains(entry.name)) {
        _validateJson(entry.name, await _readJson(destination));
      }
    }
    final stats = _file(stage.path, 'listening_statistics.json');
    if (await stats.exists()) {
      await StatisticsStore('').validateFile(stats.path);
    }
    await atomicFileStore.writeString(
      _file(root, _pending),
      jsonEncode({
        'stage': stageName,
        'id': sha256.convert(manifestBytes).toString(),
        'settings': job['settings'],
        'files': inventory,
      }),
    );
    accepted = true;
  } finally {
    await input.close();
    if (!accepted && await stage.exists()) {
      // stage is a freshly-created direct child, never a user-selected path.
      await stage.delete(recursive: true);
    }
  }
}

Future<bool> applyPendingLibraryImport(Directory directory) async {
  if (!await _file(directory.path, _pending).exists()) return false;
  return compute(_apply, directory.path);
}

Future<bool> _apply(String root) async {
  final pending = await _readJson(_file(root, _pending));
  if (pending is! Map ||
      pending['stage'] is! String ||
      !RegExp(r'^transfer_stage_[0-9]+$').hasMatch(pending['stage']) ||
      pending['id'] is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(pending['id']) ||
      pending['files'] is! Map) {
    throw const FormatException('Invalid pending import');
  }
  final stage = '$root/${pending['stage']}';
  if (await FileSystemEntity.type(stage, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const FormatException('Missing import staging directory');
  }
  final inventory = pending['files'] as Map;
  for (final item in inventory.entries) {
    if (item.key is! String || !_allowed(item.key) || item.value is! Map) {
      throw const FormatException('Invalid staged entry');
    }
    final file = _file(stage, item.key);
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() != item.value['size'] ||
        await _hash(file) != item.value['sha256']) {
      throw const FormatException('Staged archive changed');
    }
    await _regularTarget(_file(root, item.key));
  }
  Future<dynamic> read(String path, String name, dynamic fallback) async {
    final file = _file(path, name);
    if (!await file.exists()) return fallback;
    final value = await _readJson(file);
    _validateJson(name, value);
    return value;
  }

  final localTracks = await read(root, 'offline_tracks.json', []) as List;
  final importedTracks = await read(stage, 'offline_tracks.json', []) as List;
  final localArtists = await read(root, 'offline_artists.json', []) as List;
  final importedArtists = await read(stage, 'offline_artists.json', []) as List;
  void compatibleEntities(
    Iterable<dynamic> local,
    Iterable<dynamic> incoming,
    String nameKey,
  ) {
    final known = {for (final row in local.whereType<Map>()) row['id']: row};
    for (final row in incoming.whereType<Map>()) {
      final old = known[row['id']];
      if (old == null) continue;
      final oldIds = old['catalog_ids'] is Map
          ? old['catalog_ids'] as Map
          : const {};
      final newIds = row['catalog_ids'] is Map
          ? row['catalog_ids'] as Map
          : const {};
      final conflicts = oldIds.keys.any(
        (key) =>
            newIds.containsKey(key) && '${oldIds[key]}' != '${newIds[key]}',
      );
      final sameId = oldIds.keys.any(
        (key) => newIds[key] != null && '${oldIds[key]}' == '${newIds[key]}',
      );
      if (conflicts ||
          (!sameId &&
              '${old[nameKey]}'.trim().toLowerCase() !=
                  '${row[nameKey]}'.trim().toLowerCase())) {
        throw const FormatException(
          'Artist or album IDs belong to different libraries',
        );
      }
    }
  }

  Iterable<dynamic> artistsIn(List tracks) sync* {
    for (final track in tracks) {
      yield track['album']['artist'];
      yield* track['artists'] as List? ?? const [];
    }
  }

  compatibleEntities(
    [...localArtists, ...artistsIn(localTracks)],
    [...importedArtists, ...artistsIn(importedTracks)],
    'name',
  );
  compatibleEntities(
    localTracks.map((t) => t['album']),
    importedTracks.map((t) => t['album']),
    'title',
  );
  final byId = {for (final track in localTracks) track['id']: track};
  for (final track in importedTracks) {
    final old = byId[track['id']];
    if (old != null) {
      final sameSource =
          old['source_id'] != null && old['source_id'] == track['source_id'];
      final differentSource =
          old['source_id'] != null && track['source_id'] != null && !sameSource;
      if (differentSource ||
          (!sameSource &&
              (old['title'] != track['title'] ||
                  old['album']?['artist']?['name'] !=
                      track['album']?['artist']?['name']))) {
        throw const FormatException(
          'Track IDs belong to different libraries; existing tracks were not replaced',
        );
      }
    } else {
      byId[track['id']] = track;
    }
  }
  final changes = <String, dynamic>{
    'offline_tracks.json': byId.values.toList(),
  };
  final favorites = await read(root, 'liked_tracks.json', []) as List;
  changes['liked_tracks.json'] = {
    ...favorites,
    ...await read(stage, 'liked_tracks.json', []) as List,
  }.toList();
  final playlists = await read(root, 'my_playlists.json', []) as List;
  final incoming = await read(stage, 'my_playlists.json', []) as List;
  var nextId = DateTime.now().millisecondsSinceEpoch;
  final usedIds = {for (final playlist in playlists) playlist['id']};
  for (final raw in incoming) {
    final playlist = Map<String, dynamic>.from(raw as Map);
    final origin = '${pending['id']}:${playlist['id']}';
    if (playlists.any((dynamic p) => p['_backupOrigin'] == origin)) continue;
    final same = playlists
        .where(
          (dynamic p) =>
              p['id'] == playlist['id'] && p['name'] == playlist['name'],
        )
        .firstOrNull;
    if (same != null) {
      same['tracks'] = {
        ...same['tracks'] as List,
        ...playlist['tracks'] as List,
      }.toList();
      continue;
    }
    if (usedIds.contains(playlist['id'])) {
      while (usedIds.contains(nextId)) {
        nextId++;
      }
      playlist['id'] = nextId++;
    }
    usedIds.add(playlist['id']);
    playlist['_backupOrigin'] = origin;
    // A same-name image never overwrites an existing playlist's artwork.
    final image = playlist['image'];
    if (image is String && image.isNotEmpty && inventory.containsKey(image)) {
      final suffix = image.split('.').last;
      final stableId = int.parse(
        (inventory[image]['sha256'] as String).substring(0, 12),
        radix: 16,
      );
      final renamed = 'playlist_artwork_$stableId.$suffix';
      await _copyMissing(_file(stage, image), _file(root, renamed));
      playlist['image'] = renamed;
    }
    playlists.add(playlist);
  }
  changes['my_playlists.json'] = playlists;
  final artists = {for (final artist in localArtists) artist['id']: artist};
  for (final artist in importedArtists) {
    artists.putIfAbsent(artist['id'], () => artist);
  }
  changes['offline_artists.json'] = artists.values.toList();
  final versions = Map<String, dynamic>.from(
    await read(root, 'track_versions.json', {}) as Map,
  );
  final importedVersions = await read(stage, 'track_versions.json', {}) as Map;
  for (final entry in importedVersions.entries) {
    if (versions.containsKey(entry.key)) continue;
    // Never switch an existing downloaded MP3 to a version from the archive.
    if (await _file(root, 'track_${entry.key}.mp3').exists()) continue;
    final record = Map<String, dynamic>.from(entry.value as Map);
    var conflict = false;
    for (final field in ['audio', 'lyrics', 'video']) {
      final name = record[field];
      if (name is! String || !inventory.containsKey(name)) continue;
      final existing = _file(root, name);
      if (await existing.exists() &&
          await _hash(existing) != inventory[name]['sha256']) {
        conflict = true;
      }
    }
    if (conflict) continue;
    final audioName = record['audio'];
    record['has_audio'] =
        audioName is String &&
        (inventory.containsKey(audioName) ||
            await _file(root, audioName).exists());
    versions[entry.key as String] = record;
  }
  changes['track_versions.json'] = versions;
  if (pending['settings'] == true &&
      inventory.containsKey('shiki_settings.json')) {
    changes['shiki_settings.json'] = await read(
      stage,
      'shiki_settings.json',
      {},
    );
  }
  // Validate everything before replacing metadata. Media copies only fill holes.
  for (final item in changes.entries) {
    _validateJson(item.key, item.value);
  }
  final stats = _file(stage, 'listening_statistics.json');
  if (await stats.exists()) await StatisticsStore('').validateFile(stats.path);
  for (final name in inventory.keys.cast<String>()) {
    if (!_jsonFiles.contains(name)) {
      await _copyMissing(_file(stage, name), _file(root, name));
    }
  }
  final backup = Directory('$root/transfer_restore_${pending['id']}');
  final backupType = await FileSystemEntity.type(
    backup.path,
    followLinks: false,
  );
  if (backupType != FileSystemEntityType.notFound &&
      backupType != FileSystemEntityType.directory) {
    throw const FormatException('Backup destination is not a directory');
  }
  await backup.create();
  final originals = <String, String?>{};
  for (final name in changes.keys) {
    final file = _file(root, name);
    await _regularTarget(file);
    originals[name] = await file.exists() ? await file.readAsString() : null;
    if (originals[name] != null && !await _file(backup.path, name).exists()) {
      await atomicFileStore.writeString(
        _file(backup.path, name),
        originals[name]!,
      );
    }
  }
  try {
    for (final entry in changes.entries) {
      await atomicFileStore.writeString(
        _file(root, entry.key),
        jsonEncode(entry.value),
      );
    }
    if (await stats.exists()) {
      await StatisticsStore(
        '$root/listening_statistics.sqlite',
      ).importFile(stats.path);
    }
    await _file(root, _pending).delete();
  } catch (_) {
    for (final entry in originals.entries) {
      final file = _file(root, entry.key);
      if (entry.value != null) {
        await atomicFileStore.writeString(file, entry.value!);
      } else if (await file.exists()) {
        await file.delete();
      }
    }
    rethrow;
  }
  // Only extracted temporary copies; the user's ZIP and library remain intact.
  try {
    await Directory(stage).delete(recursive: true);
  } catch (_) {}
  return true;
}

Future<void> cancelPendingLibraryImport(Directory directory) async {
  final marker = _file(directory.path, _pending);
  await _regularTarget(marker);
  if (!await marker.exists()) return;
  final pending = await _readJson(marker);
  if (pending is! Map ||
      pending['stage'] is! String ||
      !RegExp(r'^transfer_stage_[0-9]+$').hasMatch(pending['stage'])) {
    throw const FormatException('Invalid pending import');
  }
  final stage = Directory('${directory.path}/${pending['stage']}');
  await marker.delete();
  if (await FileSystemEntity.type(stage.path, followLinks: false) ==
      FileSystemEntityType.directory) {
    await stage.delete(recursive: true);
  }
}

Future<void> _copyMissing(File source, File destination) async {
  await _regularTarget(destination);
  if (await destination.exists()) return;
  final temporary = File('${destination.path}.transfer.tmp');
  await _regularTarget(temporary);
  await source.copy(temporary.path);
  if (await destination.exists()) {
    await temporary.delete();
    return;
  }
  await temporary.rename(destination.path);
}
