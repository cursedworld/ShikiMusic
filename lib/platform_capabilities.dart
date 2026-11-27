import 'package:flutter/foundation.dart';

/// Clips are desktop-only until the mobile playback path is supported.
bool videoClipsSupportedOn(TargetPlatform platform) => switch (platform) {
  TargetPlatform.windows ||
  TargetPlatform.linux ||
  TargetPlatform.macOS => true,
  _ => false,
};

bool get supportsVideoClips => videoClipsSupportedOn(defaultTargetPlatform);

bool get supportsDiscordPresence => switch (defaultTargetPlatform) {
  TargetPlatform.windows ||
  TargetPlatform.linux ||
  TargetPlatform.macOS => true,
  _ => false,
};

bool vinylRotationSupportedOn(TargetPlatform platform) => switch (platform) {
  TargetPlatform.windows ||
  TargetPlatform.linux ||
  TargetPlatform.macOS => true,
  _ => false,
};

bool get supportsVinylRotation =>
    vinylRotationSupportedOn(defaultTargetPlatform);

bool get isMobilePlatform => !supportsVideoClips;

bool get supportsCompactTrackList =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux;
