import 'package:flutter/foundation.dart';

/// Clips are desktop-only until the mobile playback path is supported.
bool videoClipsSupportedOn(TargetPlatform platform) => switch (platform) {
  TargetPlatform.windows ||
  TargetPlatform.linux ||
  TargetPlatform.macOS => true,
  _ => false,
};

bool get supportsVideoClips => videoClipsSupportedOn(defaultTargetPlatform);

bool get isMobilePlatform => !supportsVideoClips;
