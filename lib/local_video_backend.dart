import 'dart:io';

import 'package:video_player_media_kit/video_player_media_kit.dart';

bool _linuxVideoBackendInitialized = false;

void ensureLocalVideoBackend() {
  if (!Platform.isLinux || _linuxVideoBackendInitialized) return;
  VideoPlayerMediaKit.ensureInitialized(linux: true);
  _linuxVideoBackendInitialized = true;
}
