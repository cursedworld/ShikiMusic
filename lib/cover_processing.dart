import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

const _maxCoverBytes = 64 * 1024 * 1024;
const _maxCoverPixels = 40 * 1000 * 1000;
const _maxCoverSide = 20000;

img.Image? _decodeCover(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > _maxCoverBytes) return null;
  try {
    final decoder = img.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (decoder == null ||
        info == null ||
        !_safeSize(info.width, info.height)) {
      return null;
    }
    final image = decoder.decodeFrame(0);
    return image != null && _safeSize(image.width, image.height) ? image : null;
  } catch (_) {
    // Optional artwork can be corrupt; it must not break media playback.
    return null;
  }
}

bool _safeSize(int width, int height) =>
    width > 0 &&
    height > 0 &&
    width <= _maxCoverSide &&
    height <= _maxCoverSide &&
    width * height <= _maxCoverPixels;

/// Top-level compute callback; keeps cover decoding off the UI isolate.
bool isSquareCoverFile(String path) {
  try {
    final file = File(path);
    if (!file.existsSync() || file.lengthSync() > _maxCoverBytes) return false;
    final image = _decodeCover(file.readAsBytesSync());
    return image != null && image.width == image.height;
  } on FileSystemException {
    return false;
  }
}

/// Keeps the existing 600×600 notification artwork format and encoding quality.
Uint8List? cropCoverBytes(Uint8List bytes) {
  final image = _decodeCover(bytes);
  if (image == null) return null;
  final size = image.width < image.height ? image.width : image.height;
  final cropped = img.copyCrop(
    image,
    x: (image.width - size) ~/ 2,
    y: (image.height - size) ~/ 2,
    width: size,
    height: size,
  );
  final resized = img.copyResize(cropped, width: 600, height: 600);
  return img.encodeJpg(resized);
}

/// Decode thumbnails at their physical display size, not full artwork size.
/// The original provider remains available for fullscreen and system artwork.
ImageProvider coverThumbnail(
  BuildContext context,
  ImageProvider provider,
  double logicalSize,
) {
  final pixels = (logicalSize * MediaQuery.devicePixelRatioOf(context)).ceil();
  return CoverThumbnailProvider(provider, pixelSize: pixels);
}

/// Preserves the pixels needed for BoxFit.cover, including rectangular artwork.
/// Fitting inside a square would undersample its shorter dimension and blur it.
ui.TargetImageSize coverThumbnailTargetSize(
  int width,
  int height,
  int pixelSize,
) {
  final shorterSide = width < height ? width : height;
  if (shorterSide <= pixelSize || shorterSide <= 0) {
    return ui.TargetImageSize(width: width, height: height);
  }
  final scale = pixelSize / shorterSide;
  return ui.TargetImageSize(
    width: (width * scale).ceil(),
    height: (height * scale).ceil(),
  );
}

@immutable
class CoverThumbnailKey {
  const CoverThumbnailKey(this.providerKey, this.pixelSize);
  final Object providerKey;
  final int pixelSize;

  @override
  bool operator ==(Object other) =>
      other is CoverThumbnailKey &&
      other.providerKey == providerKey &&
      other.pixelSize == pixelSize;

  @override
  int get hashCode => Object.hash(providerKey, pixelSize);
}

class CoverThumbnailProvider extends ImageProvider<CoverThumbnailKey> {
  const CoverThumbnailProvider(this.imageProvider, {required this.pixelSize});
  final ImageProvider imageProvider;
  final int pixelSize;

  @override
  Future<CoverThumbnailKey> obtainKey(ImageConfiguration configuration) async =>
      CoverThumbnailKey(
        await imageProvider.obtainKey(configuration),
        pixelSize,
      );

  @override
  ImageStreamCompleter loadImage(
    CoverThumbnailKey key,
    ImageDecoderCallback decode,
  ) {
    final completer = imageProvider.loadImage(key.providerKey, (
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) {
      return decode(
        buffer,
        getTargetSize: (width, height) =>
            coverThumbnailTargetSize(width, height, key.pixelSize),
      );
    });
    completer.addEphemeralErrorListener((Object error, StackTrace? stackTrace) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
    });
    return completer;
  }
}
