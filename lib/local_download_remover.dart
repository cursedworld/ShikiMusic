import 'dart:convert';
import 'dart:io';

import 'atomic_file_store.dart';

/// Reversible deletion of this app's local media, never catalog/user data.
/// The durable manifest precedes every rename. Until "committed", startup
/// recovery restores both the files and this track's previous version record.
class LocalDownloadRemover {
  LocalDownloadRemover(
    this.directory, {
    Future<void> Function(File source, File target)? moveFile,
  }) : _moveFile = moveFile ?? _rename;

  final Directory directory;
  final Future<void> Function(File, File) _moveFile;
  Directory get _root => Directory('${directory.path}/.download_removals');
  File get _index => File('${directory.path}/track_versions.json');

  static Future<void> _rename(File source, File target) async {
    await source.rename(target.path);
  }

  static bool _ownedName(int id, String name) => RegExp(
    '^(?:track_$id(?:_[a-f0-9]{64})?\\.(?:mp3|lrc)|'
    'video_$id(?:_[a-f0-9]{64})?\\.mp4|'
    'cover_$id(?:_[a-zA-Z0-9_-]+)?\\.(?:jpg|jpeg|png|webp|gif))\$',
    caseSensitive: false,
  ).hasMatch(name);

  Future<void> _safeDirectory(Directory value) async {
    final type = await FileSystemEntity.type(value.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await value.create();
    } else if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Removal directory is not a regular directory',
        value.path,
      );
    }
  }

  Future<Map<String, dynamic>> _readIndex() async {
    if (!await _index.exists()) return {};
    final data = jsonDecode(await _index.readAsString());
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Invalid download index');
    }
    return data;
  }

  /// Returns true if committed files await a later disk-cleanup retry.
  Future<bool> remove(
    int id, {
    required Future<void> Function() commitIndex,
  }) async {
    if (id <= 0) throw ArgumentError.value(id, 'id');
    await _safeDirectory(_root);
    final transaction = Directory('${_root.path}/track_$id');
    if (await transaction.exists()) {
      throw StateError('Download removal needs recovery first');
    }
    final old = (await _readIndex())['$id'];
    final names = <String>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && _ownedName(id, entity.uri.pathSegments.last)) {
        names.add(entity.uri.pathSegments.last);
      }
    }
    await _safeDirectory(transaction);
    final journal = <String, dynamic>{
      'version': 1,
      'id': id,
      'files': names,
      'oldRecord': old,
      'phase': 'staging',
    };
    final manifest = File('${transaction.path}/journal.json');
    await atomicFileStore.writeString(manifest, jsonEncode(journal));
    try {
      for (final name in names) {
        final source = File('${directory.path}/$name');
        if (await FileSystemEntity.type(source.path, followLinks: false) !=
            FileSystemEntityType.file) {
          throw FileSystemException(
            'Local media changed during removal',
            source.path,
          );
        }
        await _moveFile(source, File('${transaction.path}/$name'));
      }
      await commitIndex();
      journal['phase'] = 'committed';
      await atomicFileStore.writeString(manifest, jsonEncode(journal));
    } catch (_) {
      await _rollback(transaction, journal);
      rethrow;
    }
    try {
      await _cleanup(transaction, journal);
      return false;
    } on FileSystemException {
      // Journal remains committed: retry cleanup at next startup, not rollback.
      return true;
    }
  }

  Future<void> recover() async {
    if (!await _root.exists()) return;
    await _safeDirectory(_root);
    await for (final entity in _root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!RegExp(r'^track_[1-9][0-9]*$').hasMatch(name)) continue;
      final manifest = File('${entity.path}/journal.json');
      if (!await manifest.exists()) {
        continue; // No renamed files before journal.
      }
      final data = jsonDecode(await manifest.readAsString());
      if (data is! Map<String, dynamic> ||
          data['version'] != 1 ||
          data['id'] is! int ||
          name != 'track_${data['id']}' ||
          data['files'] is! List ||
          (data['files'] as List).any(
            (file) => file is! String || !_ownedName(data['id'] as int, file),
          ) ||
          (data['oldRecord'] != null && data['oldRecord'] is! Map) ||
          !['staging', 'committed'].contains(data['phase'])) {
        throw const FormatException('Invalid download removal journal');
      }
      if (data['phase'] == 'committed') {
        try {
          await _cleanup(entity, data);
        } on FileSystemException {
          // Already absent from downloads. Busy trash must not block startup.
        }
      } else {
        await _rollback(entity, data);
      }
    }
  }

  Future<void> _rollback(
    Directory transaction,
    Map<String, dynamic> journal,
  ) async {
    for (final name in journal['files'] as List) {
      final staged = File('${transaction.path}/$name');
      if (!await staged.exists()) continue;
      final original = File('${directory.path}/$name');
      if (await FileSystemEntity.type(original.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw FileSystemException(
          'Cannot restore over existing local media',
          original.path,
        );
      }
      await staged.rename(original.path);
    }
    // Merge just this record, preserving any independent track changes.
    final index = await _readIndex();
    final id = '${journal['id']}';
    if (journal['oldRecord'] == null) {
      index.remove(id);
    } else {
      index[id] = journal['oldRecord'];
    }
    await atomicFileStore.writeString(_index, jsonEncode(index));
    await _cleanup(transaction, journal);
  }

  Future<void> _cleanup(
    Directory transaction,
    Map<String, dynamic> journal,
  ) async {
    for (final name in journal['files'] as List) {
      final file = File('${transaction.path}/$name');
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.file) {
        await file.delete();
      }
    }
    final manifest = File('${transaction.path}/journal.json');
    if (await manifest.exists()) await manifest.delete();
    // Non-recursive: an unexpected file/link must never be removed.
    await transaction.delete();
  }
}
