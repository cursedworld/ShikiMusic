import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'atomic_file_store.dart';
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

class PlaylistArtworkPreview {
  const PlaylistArtworkPreview(this.bytes, this.width, this.height);
  final Uint8List bytes;
  final int width;
  final int height;
}

class PlaylistCropSelection {
  const PlaylistCropSelection({
    required this.sourcePath,
    required this.left,
    required this.top,
    required this.side,
  });
  final String sourcePath;

  /// Position relative to the oriented source width/height.
  final double left;
  final double top;

  /// Square side relative to the source's shorter dimension.
  final double side;
}

class CroppedPlaylistArtwork {
  const CroppedPlaylistArtwork(this.bytes, {this.animated = false});
  final Uint8List bytes;
  final bool animated;
}

img.Image _readPlaylistImage(String path, {required bool allFrames}) {
  try {
    return _decodePlaylistImage(path, allFrames: allFrames);
  } on FileSystemException {
    rethrow;
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('Invalid playlist image');
  }
}

img.Image _decodePlaylistImage(String path, {required bool allFrames}) {
  final file = File(path);
  final length = file.lengthSync();
  if (length <= 0 || length > 64 * 1024 * 1024) {
    throw const FormatException('Playlist image is too large or empty');
  }
  final bytes = file.readAsBytesSync();
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (decoder == null ||
      info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width > 20000 ||
      info.height > 20000 ||
      info.numFrames > 200 ||
      info.width * info.height * math.max(1, info.numFrames) > 40000000) {
    throw const FormatException('Unsupported or oversized playlist image');
  }
  final image = allFrames ? decoder.decode(bytes) : decoder.decodeFrame(0);
  if (image == null) throw const FormatException('Invalid playlist image');
  return image.exif.imageIfd.hasOrientation &&
          image.exif.imageIfd.orientation != 1
      ? img.bakeOrientation(image)
      : image;
}

/// Top-level compute callback: only the small preview crosses to the UI isolate.
PlaylistArtworkPreview loadPlaylistArtworkPreview(String sourcePath) {
  final image = _readPlaylistImage(sourcePath, allFrames: false);
  final preview = math.max(image.width, image.height) <= 1024
      ? image
      : img.copyResize(
          image,
          width: image.width >= image.height ? 1024 : null,
          height: image.height > image.width ? 1024 : null,
          interpolation: img.Interpolation.average,
        );
  return PlaylistArtworkPreview(
    img.encodePng(preview),
    image.width,
    image.height,
  );
}

/// The stored square is clipped to a circle by the existing sidebar avatar.
CroppedPlaylistArtwork cropPlaylistArtwork(PlaylistCropSelection selection) {
  if (![
        selection.left,
        selection.top,
        selection.side,
      ].every((v) => v.isFinite) ||
      selection.left < 0 ||
      selection.top < 0 ||
      selection.side <= 0 ||
      selection.side > 1) {
    throw const FormatException('Invalid playlist crop');
  }
  final image = _readPlaylistImage(selection.sourcePath, allFrames: true);
  final side = (selection.side * math.min(image.width, image.height))
      .round()
      .clamp(1, math.min(image.width, image.height))
      .toInt();
  final x = (selection.left * image.width).round();
  final y = (selection.top * image.height).round();
  // Allow a one-pixel rounding difference at the right/bottom edge only.
  if (x > image.width - side + 1 || y > image.height - side + 1) {
    throw const FormatException('Playlist crop lies outside image');
  }
  final cropped = img.copyCrop(
    image,
    x: x.clamp(0, image.width - side).toInt(),
    y: y.clamp(0, image.height - side).toInt(),
    width: side,
    height: side,
  );
  final output = side <= 512
      ? cropped
      : img.copyResize(
          cropped,
          width: 512,
          height: 512,
          interpolation: img.Interpolation.average,
        );
  // copyCrop's additional frames inherit first-frame metadata; restore timing.
  output.loopCount = image.loopCount;
  for (var i = 0; i < output.numFrames; i++) {
    output.frames[i].frameDuration = image.frames[i].frameDuration;
  }
  return output.numFrames > 1
      ? CroppedPlaylistArtwork(img.encodeGif(output), animated: true)
      : CroppedPlaylistArtwork(img.encodePng(output));
}

Future<String> saveCroppedPlaylistArtwork(
  Directory dataDirectory,
  CroppedPlaylistArtwork artwork,
  int playlistId,
) async {
  final name =
      'playlist_artwork_$playlistId.${artwork.animated ? 'gif' : 'png'}';
  await atomicFileStore.writeBytes(
    File('${dataDirectory.path}/$name'),
    artwork.bytes,
  );
  return name;
}
