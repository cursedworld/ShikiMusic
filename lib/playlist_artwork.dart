import 'dart:io';

import 'safe_file_migration.dart';

bool isPortablePlaylistArtwork(String value) => RegExp(
  r'^playlist_artwork_[0-9]+\.(?:jpg|jpeg|png|webp|gif)$',
  caseSensitive: false,
).hasMatch(value);

File resolvePlaylistArtwork(Directory dataDirectory, String value) =>
    isPortablePlaylistArtwork(value)
    ? File('${dataDirectory.path}/$value')
    : File(value);

Future<String> copyPlaylistArtwork(
  Directory dataDirectory,
  String sourcePath,
  int playlistId,
) async {
  final source = File(sourcePath);
  final extension = source.uri.pathSegments.last.split('.').last.toLowerCase();
  if (!['jpg', 'jpeg', 'png', 'webp', 'gif'].contains(extension)) {
    throw const FormatException('Unsupported playlist image');
  }
  final name = 'playlist_artwork_$playlistId.$extension';
  await safeFileMigration.migrate(
    source: source,
    destination: File('${dataDirectory.path}/$name'),
  );
  return name;
}
