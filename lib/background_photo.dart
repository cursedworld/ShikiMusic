import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

const _maxPhotoFileBytes = 64 * 1024 * 1024;
const _maxPhotoPixels = 40 * 1000 * 1000;
const _maxPhotoSide = 20 * 1000;

const playlistPhotoExtensions = ['jpg', 'jpeg', 'png', 'webp'];
const playlistBackgroundMaxBytes = 16 * 1024 * 1024;

final _playlistBackgroundName = RegExp(r'^playlist_bg_[0-9a-f]{32}\.jpg$');

bool isPlaylistBackgroundName(Object? value) =>
    value is String && _playlistBackgroundName.hasMatch(value);

String newPlaylistBackgroundName() {
  final random = math.Random.secure();
  final suffix = List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  return 'playlist_bg_$suffix.jpg';
}

/// Retains the existing static image path for the global background.
Uint8List? processCustomBackgroundImage(String sourcePath) =>
    _processBackgroundImage(sourcePath, photoOnly: false);

/// Only still JPEG, PNG and WebP are accepted for a playlist background.
/// Run as a compute callback; the original file is never written to.
Uint8List? processPlaylistBackgroundPhoto(String sourcePath) {
  try {
    return _processBackgroundImage(sourcePath, photoOnly: true);
  } on FileSystemException {
    rethrow;
  } catch (_) {
    return null;
  }
}

Uint8List? _processBackgroundImage(
  String sourcePath, {
  required bool photoOnly,
}) {
  final file = File(sourcePath);
  // A system picker may return a temporary path without the original suffix.
  // The detected format below, not that path, determines what we accept.
  final length = file.lengthSync();
  if (length <= 0 || length > _maxPhotoFileBytes) return null;
  final bytes = file.readAsBytesSync();
  if (bytes.isEmpty || bytes.length > _maxPhotoFileBytes) return null;

  final decoder = img.findDecoderForData(bytes);
  if (decoder == null ||
      (photoOnly &&
          decoder is! img.JpegDecoder &&
          decoder is! img.PngDecoder &&
          decoder is! img.WebPDecoder)) {
    return null;
  }
  final info = decoder.startDecode(bytes);
  if (info == null || !_safePhotoSize(info.width, info.height)) return null;

  // image reports the number of ANMF frames for WebP. A normal VP8/VP8L
  // still image has no ANMF frames but is decoded by decodeFrame(0).
  final animatedWebP =
      info is img.WebPInfo &&
      (info.hasAnimation || info.format == img.WebPFormat.animated);
  final numFrames = info is img.WebPInfo && !animatedWebP ? 1 : info.numFrames;
  if (numFrames < 1 || (photoOnly && (animatedWebP || numFrames != 1))) {
    return null;
  }
  final image = decoder.decodeFrame(0);
  if (image == null || !_safePhotoSize(image.width, image.height)) return null;

  if (photoOnly) {
    final oriented =
        image.exif.imageIfd.hasOrientation &&
            image.exif.imageIfd.orientation != 1
        ? img.bakeOrientation(image)
        : image;
    final landscape = oriented.width >= oriented.height;
    final scale = math.min(
      1.0,
      math.min(
        (landscape ? 1920 : 1080) / oriented.width,
        (landscape ? 1080 : 1920) / oriented.height,
      ),
    );
    final fitted = scale == 1.0
        ? oriented
        : img.copyResize(
            oriented,
            width: math.max(1, (oriented.width * scale).round()),
            height: math.max(1, (oriented.height * scale).round()),
            interpolation: img.Interpolation.average,
          );
    return img.encodeJpg(fitted, quality: 92);
  }

  img.Image processedImage = image;
  if (image.width > 1920 || image.height > 1080) {
    final aspectRatio = image.width / image.height;
    final int newWidth;
    final int newHeight;
    if (image.width > image.height) {
      newWidth = 1920;
      newHeight = (1920 / aspectRatio).round();
    } else {
      newHeight = 1080;
      newWidth = (1080 * aspectRatio).round();
    }
    processedImage = img.copyResize(image, width: newWidth, height: newHeight);
  }
  return img.encodeJpg(processedImage, quality: 85);
}

bool _safePhotoSize(int width, int height) =>
    width > 0 &&
    height > 0 &&
    width <= _maxPhotoSide &&
    height <= _maxPhotoSide &&
    width * height <= _maxPhotoPixels;

bool isStoredPlaylistPhoto(File file) {
  try {
    final length = file.lengthSync();
    if (length <= 0 || length > playlistBackgroundMaxBytes) return false;
    final info = img.JpegDecoder().startDecode(file.readAsBytesSync());
    return info != null &&
        info.width > 0 &&
        info.height > 0 &&
        math.max(info.width, info.height) <= 1920 &&
        math.min(info.width, info.height) <= 1080;
  } catch (_) {
    return false;
  }
}
