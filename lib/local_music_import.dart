import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'atomic_file_store.dart';
import 'local_music_catalog.dart';
import 'mp3_metadata.dart';

typedef LocalMusicFile = ({String name, String? path});
typedef LocalMusicProgress =
    void Function(int index, int total, String name, double? fraction);

enum LocalImportProblem {
  unsupported,
  invalidAudio,
  cannotRead,
  unpairedLyrics,
}

class LocalImportCancel {
  bool requested = false;
  void cancel() => requested = true;
}

class LocalMusicImportResult {
  const LocalMusicImportResult({
    required this.entries,
    required this.added,
    required this.alreadyPresent,
    required this.restored,
    required this.problems,
    required this.cancelled,
    this.newEntries = const [],
    this.matchEntries = const [],
  });
  final List<LocalMusicEntry> entries;
  final List<LocalMusicEntry> newEntries;
  final List<LocalMusicEntry> matchEntries;
  final int added, alreadyPresent, restored;
  final List<({String name, LocalImportProblem problem})> problems;
  final bool cancelled;
}

/// All assets are written before the catalog is published. Cancellation keeps
/// completed tracks, not the file currently being copied. One file at a time:
/// buffer size doesn't depend on the number or length of selected songs.
Future<LocalMusicImportResult> importLocalMusic({
  required Directory directory,
  required List<LocalMusicFile> files,
  required LocalImportCancel cancel,
  bool lookForAdjacentLyrics = false,
  LocalMusicProgress? onProgress,
}) async {
  final problems = <({String name, LocalImportProblem problem})>[];
  final tracks = <LocalMusicFile>[];
  final lyrics = <String, List<LocalMusicFile>>{};
  final stemCounts = <String, int>{};
  for (final file in files) {
    final name = file.name.toLowerCase();
    if (name.endsWith('.mp3')) {
      tracks.add(file);
      stemCounts.update(_stem(name), (count) => count + 1, ifAbsent: () => 1);
    } else if (name.endsWith('.lrc')) {
      (lyrics[_stem(name)] ??= []).add(file);
    } else {
      problems.add((name: file.name, problem: LocalImportProblem.unsupported));
    }
  }
  for (final group in lyrics.entries) {
    if (stemCounts.containsKey(group.key)) continue;
    for (final file in group.value) {
      problems.add((
        name: file.name,
        problem: LocalImportProblem.unpairedLyrics,
      ));
    }
  }

  var added = 0;
  var restored = 0;
  var alreadyPresent = 0;
  var entries = <LocalMusicEntry>[];
  final newEntries = <LocalMusicEntry>[];
  final matching = <String>{};
  if (tracks.isNotEmpty && !cancel.requested) {
    final staging = await directory.createTemp('.local_import_');
    try {
      // Serializes read/merge/write on this catalog, including concurrent
      // imports. No changes become visible before the atomic JSON write.
      await atomicFileStore.writeStringLazy(
        File('${directory.path}/$localMusicCatalogName'),
        () async {
          final current = await readLocalMusicCatalog(directory);
          final byDigest = {for (final entry in current) entry.digest: entry};
          final used = {for (final entry in current) entry.id};
          for (var i = 0; i < tracks.length && !cancel.requested; i++) {
            final file = tracks[i];
            final output = File('${staging.path}/$i.mp3.part');
            void progress(double? fraction) =>
                onProgress?.call(i + 1, tracks.length, file.name, fraction);
            progress(null);
            if (cancel.requested) break;
            try {
              if (file.path == null) {
                throw const FileSystemException('No file path');
              }
              final source = File(file.path!);
              final digest = await _copyAndHash(
                source,
                output,
                cancel,
                progress,
              );
              if (digest == null || cancel.requested) break;
              final old = byDigest[digest];
              final audioName = localAudioName(digest);
              final coverName = localCoverName(digest);
              final audioFile = resolveLocalMusicAsset(directory, audioName);
              final coverFile = resolveLocalMusicAsset(directory, coverName);
              final audioReady = await _regularAsset(audioFile);
              final coverReady = await _regularAsset(coverFile);
              // Never associate arbitrary bytes with an existing digest, even
              // if someone modified the copy outside the player.
              final audioMatches =
                  audioReady && await fileSha256(audioFile) == digest;
              final Mp3Metadata? info;
              if (old == null || !audioMatches || !coverReady) {
                info = await _readCopiedMetadata(output.path);
              } else {
                info = null;
              }
              if (cancel.requested) break;
              final key = _stem(file.name.toLowerCase());
              final choices = lyrics[key] ?? const <LocalMusicFile>[];
              final explicit = lookForAdjacentLyrics
                  ? choices
                        .where(
                          (lyric) =>
                              lyric.path != null &&
                              File(lyric.path!).parent.path ==
                                  source.parent.path,
                        )
                        .firstOrNull
                  : null;
              final lrc = (old != null && old.lyrics.isNotEmpty)
                  ? old.lyrics
                  : await _readLyrics(
                      explicit?.path ??
                          (choices.length == 1 && stemCounts[key] == 1
                              ? choices.first.path
                              : null) ??
                          (lookForAdjacentLyrics
                              ? '${source.path.substring(0, source.path.length - 4)}.lrc'
                              : null),
                    );
              if (cancel.requested) break;
              if (!audioMatches) {
                await output.rename(localMusicAsset(directory, audioName).path);
              }
              final cover = info?.coverJpeg;
              if (!coverReady && cover != null) {
                // Optional cover failure doesn't hide a playable song.
                try {
                  await atomicFileStore.writeBytes(
                    localMusicAsset(directory, coverName),
                    cover,
                  );
                } on FileSystemException {
                  // Keep the usual no-cover placeholder.
                }
              }
              if (old == null) {
                final tags = info!;
                byDigest[digest] = LocalMusicEntry(
                  id: allocateLocalTrackId(digest, used),
                  digest: digest,
                  title: tags.title.isEmpty
                      ? _fallbackTitle(file.name)
                      : tags.title,
                  artist: tags.artist,
                  album: tags.album,
                  trackNumber: tags.trackNumber,
                  discNumber: tags.discNumber,
                  duration: tags.duration,
                  lyrics: lrc,
                );
                newEntries.add(byDigest[digest]!);
                added++;
              } else {
                if (old.lyrics != lrc) {
                  byDigest[digest] = old.withIdAndLyrics(old.id, lrc);
                }
                if (audioMatches) {
                  alreadyPresent++;
                } else {
                  newEntries.add(byDigest[digest]!);
                  restored++;
                }
              }
              if (byDigest[digest]!.metadata == null) matching.add(digest);
              progress(1);
            } on FormatException {
              problems.add((
                name: file.name,
                problem: LocalImportProblem.invalidAudio,
              ));
            } on FileSystemException {
              problems.add((
                name: file.name,
                problem: LocalImportProblem.cannotRead,
              ));
            } finally {
              if (await output.exists()) {
                try {
                  await output.delete();
                } on FileSystemException {
                  // Not indexed, and never confused with a published file.
                }
              }
            }
          }
          entries = byDigest.values.toList();
          return encodeLocalMusicCatalogText(entries);
        },
      );
    } finally {
      // Fresh temp child of the library created by this call only.
      try {
        await staging.delete(recursive: true);
      } on FileSystemException {
        // A failed cleanup must not undo successfully published tracks.
      }
    }
  } else {
    entries = await readLocalMusicCatalog(directory);
  }
  return LocalMusicImportResult(
    entries: entries,
    added: added,
    alreadyPresent: alreadyPresent,
    restored: restored,
    problems: problems,
    cancelled: cancel.requested,
    newEntries: List.unmodifiable(newEntries),
    matchEntries: [
      for (final entry in entries)
        if (matching.contains(entry.digest)) entry,
    ],
  );
}

// Keep the parser closure out of the import scope. On Dart VM it could
// otherwise capture the progress callback, including unsendable UI state.
Future<Mp3Metadata> _readCopiedMetadata(String path) =>
    Isolate.run(() => readMp3Metadata(path));

Future<bool> _regularAsset(File file) async {
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return false;
  if (type != FileSystemEntityType.file) {
    throw const FileSystemException('Local music asset is not a regular file');
  }
  return true;
}

Future<String> fileSha256(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

class _DigestSink implements Sink<Digest> {
  Digest? result;
  @override
  void add(Digest data) => result = data;
  @override
  void close() {}
}

Future<String?> _copyAndHash(
  File source,
  File output,
  LocalImportCancel cancel,
  void Function(double?) progress,
) async {
  final before = await source.stat();
  if (before.type != FileSystemEntityType.file) {
    throw const FileSystemException('Cannot read selected file');
  }
  if (before.size < 4 || before.size > localMusicMaxBytes) {
    throw const FormatException('Unsupported MP3 size');
  }
  final result = _DigestSink();
  final hash = sha256.startChunkedConversion(result);
  final destination = await output.open(mode: FileMode.write);
  final clock = Stopwatch()..start();
  var done = 0;
  try {
    await for (final bytes in source.openRead()) {
      if (cancel.requested) return null;
      done += bytes.length;
      if (done > before.size) {
        throw const FileSystemException('File changed while importing');
      }
      hash.add(bytes);
      await destination.writeFrom(bytes);
      if (clock.elapsedMilliseconds >= 120) {
        clock.reset();
        progress(done / before.size);
      }
    }
    final after = await source.stat();
    if (done != before.size ||
        before.modified != after.modified ||
        before.changed != after.changed ||
        before.size != after.size) {
      throw const FileSystemException('File changed while importing');
    }
    await destination.flush();
    hash.close();
    return result.result.toString();
  } finally {
    await destination.close();
  }
}

String _stem(String name) => name.substring(0, name.length - 4);

String _fallbackTitle(String name) {
  final title = String.fromCharCodes(_stem(name).trim().runes.take(512)).trim();
  return title.isEmpty ? 'MP3' : title;
}

Future<String> _readLyrics(String? path) async {
  if (path == null) return '';
  RandomAccessFile? input;
  try {
    input = await File(path).open();
    final bytes = await input.read(localLyricMaxBytes + 1);
    if (bytes.length > localLyricMaxBytes) return '';
    final utf16 =
        bytes.length >= 2 &&
        ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
            (bytes[0] == 0xfe && bytes[1] == 0xff));
    final bom =
        bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf;
    final text = utf16
        ? decodeLocalUtf16(bytes, start: 0, little: false)
        : utf8.decode(Uint8List.sublistView(bytes, bom ? 3 : 0));
    return text.contains('\u0000') ||
            utf8.encode(text).length > localLyricMaxBytes
        ? ''
        : text.trim();
  } on FormatException {
    return '';
  } on FileSystemException {
    return '';
  } finally {
    await input?.close();
  }
}
