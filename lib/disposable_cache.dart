import 'dart:io';

import 'local_music_catalog.dart';
import 'playlist_artwork.dart';

final RegExp _trackArtwork = RegExp(
  r'^cover_(\d+)(?:_.*)?\.(?:jpg|jpeg|png|webp)$',
  caseSensitive: false,
);
final RegExp _artistArtwork = RegExp(
  r'^artist_(\d+)(?:_.*)?\.(?:jpg|jpeg|png|webp)$',
  caseSensitive: false,
);
final RegExp _artworkTemporary = RegExp(
  r'^(?:cover_\d+(?:_.*?)?|artist_\d+(?:_.*?)?)\.(?:jpg|jpeg|png|webp)\.tmp\.\d+\.\d+\.\d+$',
  caseSensitive: false,
);

final _serverAudio = RegExp(r'^track_\d+(?:_[a-f0-9]{64})?\.mp3$');
final _serverClip = RegExp(r'^video_\d+(?:_[a-f0-9]{64})?\.mp4$');
final _localClip = RegExp(r'^local_video_[a-f0-9]{64}\.mp4$');
final _clipPreview = RegExp(r'^clip_preview_[a-f0-9]{64}\.mp4$');

class StorageUsage {
  const StorageUsage({
    this.audioBytes = 0,
    this.clipBytes = 0,
    this.artworkBytes = 0,
    this.reclaimableBytes = 0,
    this.hasReclaimableArtwork = false,
  });

  final int audioBytes, clipBytes, artworkBytes, reclaimableBytes;
  final bool hasReclaimableArtwork;
}

class ArtworkCleanupResult {
  const ArtworkCleanupResult({
    this.removedBytes = 0,
    this.removedFiles = 0,
    this.failed = false,
    this.busy = false,
  });

  final int removedBytes, removedFiles;
  final bool failed, busy;
}

enum _ArtworkCandidate { orphan, temporary }

_ArtworkCandidate? _artworkCandidate(
  String name,
  Set<int> protectedTracks,
  Set<int> protectedArtists,
) {
  final track = _trackArtwork.firstMatch(name);
  final artist = track == null ? _artistArtwork.firstMatch(name) : null;
  final id = int.tryParse(track?[1] ?? artist?[1] ?? '');
  if (id != null &&
      !(track != null ? protectedTracks : protectedArtists).contains(id)) {
    return _ArtworkCandidate.orphan;
  }
  return _artworkTemporary.hasMatch(name) ? _ArtworkCandidate.temporary : null;
}

bool _canRemove(_ArtworkCandidate? candidate, FileStat stat, DateTime cutoff) =>
    stat.type == FileSystemEntityType.file &&
    (candidate == _ArtworkCandidate.orphan ||
        (candidate == _ArtworkCandidate.temporary &&
            stat.modified.isBefore(cutoff)));

Stream<File> _regularFiles(Directory directory) async* {
  // Directory.list reports links separately with followLinks disabled.
  // https://api.dart.dev/dart-io/Directory/list.html
  await for (final entry in directory.list(followLinks: false)) {
    if (entry is File) yield entry;
  }
}

/// Logical sizes of managed media, not the allocation of the entire profile.
Future<StorageUsage> readStorageUsage(
  Directory directory, {
  required Set<int> protectedTrackIds,
  required Set<int> protectedArtistIds,
  DateTime? now,
}) async {
  final root = Directory(await directory.resolveSymbolicLinks());
  final cutoff = (now ?? DateTime.now()).subtract(const Duration(days: 1));
  final legacy = Directory('${root.path}/local_music');
  var audio = 0, clips = 0, artwork = 0, reclaimable = 0;
  var hasReclaimable = false;

  Future<void> count(Directory source, {required bool legacy}) async {
    await for (final file in _regularFiles(source)) {
      final name = file.uri.pathSegments.last;
      final local = localAssetDigest(name) != null;
      final isAudio =
          (local && name.endsWith('.mp3')) ||
          (!legacy && _serverAudio.hasMatch(name));
      final isClip =
          !legacy &&
          (_serverClip.hasMatch(name) ||
              _localClip.hasMatch(name) ||
              _clipPreview.hasMatch(name));
      final isArtwork =
          (local && name.endsWith('.jpg')) ||
          (!legacy &&
              (_trackArtwork.hasMatch(name) ||
                  _artistArtwork.hasMatch(name) ||
                  _artworkTemporary.hasMatch(name) ||
                  isPortablePlaylistArtwork(name)));
      if (!isAudio && !isClip && !isArtwork) continue;
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) continue;
      if (isAudio) {
        audio += stat.size;
      } else if (isClip) {
        clips += stat.size;
      } else {
        artwork += stat.size;
        if (!legacy &&
            _canRemove(
              _artworkCandidate(name, protectedTrackIds, protectedArtistIds),
              stat,
              cutoff,
            )) {
          reclaimable += stat.size;
          hasReclaimable = true;
        }
      }
    }
  }

  await count(root, legacy: false);
  if (await FileSystemEntity.type(legacy.path, followLinks: false) ==
      FileSystemEntityType.directory) {
    await count(legacy, legacy: true);
  }
  return StorageUsage(
    audioBytes: audio,
    clipBytes: clips,
    artworkBytes: artwork,
    reclaimableBytes: reclaimable,
    hasReclaimableArtwork: hasReclaimable,
  );
}

/// Removes only orphan artwork and old artwork temporary files.
/// Audio, video, lyrics, JSON snapshots, playlists, backgrounds and links stay.
Future<ArtworkCleanupResult> clearDisposableArtwork(
  Directory directory, {
  required Set<int> protectedTrackIds,
  required Set<int> protectedArtistIds,
  DateTime? now,
  bool Function()? isBusy,
}) async {
  if (isBusy?.call() == true) return const ArtworkCleanupResult(busy: true);
  final cutoff = (now ?? DateTime.now()).subtract(const Duration(days: 1));
  var bytes = 0, files = 0;
  var failed = false, busy = false;
  try {
    final root = Directory(await directory.resolveSymbolicLinks());
    await for (final file in _regularFiles(root)) {
      final candidate = _artworkCandidate(
        file.uri.pathSegments.last,
        protectedTrackIds,
        protectedArtistIds,
      );
      if (candidate == null) continue;
      try {
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
          continue;
        }
        // The only managed deletion targets are direct children of the
        // resolved profile root with an eligible cache filename.
        // https://api.dart.dev/dart-io/FileSystemEntity/resolveSymbolicLinks.html
        final resolved = await file.resolveSymbolicLinks();
        if (Platform.isWindows
            ? resolved.toLowerCase() != file.path.toLowerCase()
            : resolved != file.path) {
          failed = true;
          continue;
        }
        final stat = await file.stat();
        if (!_canRemove(candidate, stat, cutoff)) continue;
        if (isBusy?.call() == true) {
          busy = true;
          break;
        }
        // Non-recursive delete never follows a newly substituted file link.
        await File(resolved).delete();
        bytes += stat.size;
        files++;
      } on FileSystemException {
        failed = true;
      }
    }
  } on FileSystemException {
    failed = true;
  }
  return ArtworkCleanupResult(
    removedBytes: bytes,
    removedFiles: files,
    failed: failed,
    busy: busy,
  );
}
