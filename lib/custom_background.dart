import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

enum BackgroundKind { image, gif, video }

enum BackgroundProblem implements Exception { invalid, tooLarge }

const backgroundPickerExtensions = [
  'jpg',
  'jpeg',
  'png',
  'webp',
  'bmp',
  'tif',
  'tiff',
  'ico',
  'gif',
  'mp4',
];
const backgroundGifMaxBytes = 24 * 1024 * 1024;
const backgroundVideoMaxBytes = 64 * 1024 * 1024;
const backgroundVideoMaxDuration = Duration(seconds: 30);

final _savedBackgroundName = RegExp(
  r'^custom_bg_[0-9]+\.(jpg|jpeg|png|webp|gif|mp4)$',
  caseSensitive: false,
);

BackgroundKind? savedBackgroundKind(Object? name) {
  if (name is! String) return null;
  return switch (_savedBackgroundName.firstMatch(name)?[1]?.toLowerCase()) {
    'gif' => BackgroundKind.gif,
    'mp4' => BackgroundKind.video,
    null => null,
    _ => BackgroundKind.image,
  };
}

bool isMotionBackgroundSizeAllowed(num width, num height) =>
    width > 0 &&
    height > 0 &&
    width <= 1920 &&
    height <= 1920 &&
    width * height <= 1920 * 1080;

int? motionBackgroundByteLimit(BackgroundKind? kind) => switch (kind) {
  BackgroundKind.gif => backgroundGifMaxBytes,
  BackgroundKind.video => backgroundVideoMaxBytes,
  _ => null,
};

Future<String?> availableCustomBackground(
  Directory directory,
  Object? name,
) async {
  final kind = savedBackgroundKind(name);
  if (kind == null) return null;
  final path = '${directory.path}/$name';
  if (await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.file) {
    return null;
  }
  final limit = motionBackgroundByteLimit(kind);
  if (limit != null) {
    final bytes = await File(path).length();
    if (bytes <= 0 || bytes > limit) return null;
  }
  return name as String;
}

/// Check the container before handing it to an image or native video decoder.
Future<void> checkMotionBackgroundHeader(File file, BackgroundKind kind) async {
  final limit = motionBackgroundByteLimit(kind)!;
  final length = await file.length();
  if (length > limit) throw BackgroundProblem.tooLarge;
  final input = await file.open();
  try {
    final header = await input.read(16);
    if (kind == BackgroundKind.gif) {
      if (header.length < 13) throw BackgroundProblem.invalid;
      final magic = String.fromCharCodes(header.take(6));
      if (magic != 'GIF87a' && magic != 'GIF89a') {
        throw BackgroundProblem.invalid;
      }
      final width = header[6] | (header[7] << 8);
      final height = header[8] | (header[9] << 8);
      if (width == 0 || height == 0) throw BackgroundProblem.invalid;
      if (!isMotionBackgroundSizeAllowed(width, height)) {
        throw BackgroundProblem.tooLarge;
      }
    } else {
      if (header.length < 16 ||
          String.fromCharCodes(header.skip(4).take(4)) != 'ftyp') {
        throw BackgroundProblem.invalid;
      }
    }
  } finally {
    await input.close();
  }
}

BackgroundProblem? _checkGifFrames(String path) {
  try {
    final decoder = img.GifDecoder();
    final info = decoder.startDecode(File(path).readAsBytesSync());
    if (info == null || info.numFrames == 0) return BackgroundProblem.invalid;
    if (info.frames.any(
      (frame) => !isMotionBackgroundSizeAllowed(frame.width, frame.height),
    )) {
      return BackgroundProblem.tooLarge;
    }
    return decoder.decodeFrame(0) == null ? BackgroundProblem.invalid : null;
  } catch (_) {
    return BackgroundProblem.invalid;
  }
}

/// Copy the chosen GIF/MP4 without transcoding. The final name only appears
/// after the bounded copy and container check succeed.
Future<void> copyMotionBackground(File source, File destination) async {
  final kind = savedBackgroundKind(destination.uri.pathSegments.last);
  final limit = motionBackgroundByteLimit(kind);
  if (kind == null || limit == null) throw BackgroundProblem.invalid;
  await checkMotionBackgroundHeader(source, kind);
  if (await FileSystemEntity.type(destination.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw const FileSystemException('Background destination already exists');
  }
  final temporary = File('${destination.path}.part');
  RandomAccessFile? output;
  var ownsTemporary = false;
  var written = 0;
  try {
    await temporary.create(exclusive: true);
    ownsTemporary = true;
    output = await temporary.open(mode: FileMode.writeOnly);
    await for (final chunk in source.openRead()) {
      written += chunk.length;
      if (written > limit) throw BackgroundProblem.tooLarge;
      await output.writeFrom(chunk);
    }
    await output.flush();
    await output.close();
    output = null;
    await checkMotionBackgroundHeader(temporary, kind);
    if (kind == BackgroundKind.gif) {
      final problem = await compute(_checkGifFrames, temporary.path);
      if (problem != null) throw problem;
    }
    await temporary.rename(destination.path);
    ownsTemporary = false;
  } finally {
    try {
      await output?.close();
    } on FileSystemException {
      // Preserve the original copy error.
    }
    if (ownsTemporary) {
      try {
        if (await temporary.exists()) await temporary.delete();
      } on FileSystemException {
        // Leave only the staging file if the filesystem won't remove it.
      }
    }
  }
}
