import 'dart:io';

import 'package:video_player/video_player.dart';

import 'custom_background.dart';
import 'local_video_backend.dart';

Future<VideoPlayerController> openBackgroundVideo(File file) async {
  await checkMotionBackgroundHeader(file, BackgroundKind.video);
  ensureLocalVideoBackend();
  final controller = VideoPlayerController.file(
    file,
    videoPlayerOptions: VideoPlayerOptions(
      // A decorative video must never compete with music for audio focus.
      mixWithOthers: true,
      // Visibility is owned by the backdrop, not the plugin's auto-resume.
      allowBackgroundPlayback: true,
    ),
  );
  try {
    await controller.setVolume(0);
    await controller.setLooping(true);
    await controller.initialize().timeout(const Duration(seconds: 5));
    final value = controller.value;
    if (!value.isInitialized ||
        value.size.isEmpty ||
        value.duration <= Duration.zero) {
      throw BackgroundProblem.invalid;
    }
    if (!isMotionBackgroundSizeAllowed(value.size.width, value.size.height) ||
        value.duration > backgroundVideoMaxDuration) {
      throw BackgroundProblem.tooLarge;
    }
    await controller.setVolume(0).timeout(const Duration(seconds: 3));
    await controller.setLooping(true).timeout(const Duration(seconds: 3));
    return controller;
  } catch (error) {
    await closeBackgroundVideo(controller);
    if (error is BackgroundProblem) rethrow;
    throw BackgroundProblem.invalid;
  }
}

Future<void> closeBackgroundVideo(VideoPlayerController controller) async {
  try {
    // If creation is still pending, dispose will release it when it arrives.
    // A platform failure must not lock the rest of the UI waiting for it.
    await controller.dispose().timeout(const Duration(seconds: 3));
  } catch (_) {}
}
