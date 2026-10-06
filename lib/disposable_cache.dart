import 'dart:io';

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

/// Removes only orphan artwork and old artwork temporary files.
/// Audio, video, lyrics, JSON snapshots, playlists, backgrounds and links stay.
Future<void> clearDisposableArtwork(
  Directory directory, {
  required Set<int> protectedTrackIds,
  required Set<int> protectedArtistIds,
  DateTime? now,
}) async {
  if (!await directory.exists()) return;
  final cutoff = (now ?? DateTime.now()).subtract(const Duration(days: 1));
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = entity.uri.pathSegments.last;
    final track = _trackArtwork.firstMatch(name);
    final artist = _artistArtwork.firstMatch(name);
    var remove =
        (track != null &&
            !protectedTrackIds.contains(int.parse(track.group(1)!))) ||
        (artist != null &&
            !protectedArtistIds.contains(int.parse(artist.group(1)!)));
    if (!remove && _artworkTemporary.hasMatch(name)) {
      // Never race a recent atomic write, including another player process.
      remove = (await entity.stat()).modified.isBefore(cutoff);
    }
    if (remove) await entity.delete();
  }
}
