import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:audio_service/audio_service.dart';

/// Bridges [AudioPlayer] with the Android system media session via
/// [audio_service]. Exposes callbacks so the UI can react to notification
/// controls (play / pause / next / prev).
///
/// IMPORTANT: This handler does NOT create its own AudioPlayer.
/// It accepts an external AudioPlayer instance so that state changes
/// from the actual player are synced to the Android media session.
class AudioPlayerHandler extends BaseAudioHandler with SeekHandler {
  late final AudioPlayer player;

  VoidCallback? onNext;
  VoidCallback? onPrev;
  VoidCallback? onPauseCustom;
  VoidCallback? onPlayCustom;
  VoidCallback? onStopCustom;

  AudioPlayerHandler() {
    // Player will be attached via attachPlayer() after construction
    _setIdleState();
  }

  /// Attach the actual AudioPlayer instance used by the app.
  /// This must be called once after construction.
  void attachPlayer(AudioPlayer externalPlayer) {
    player = externalPlayer;

    // Sync player state → media session
    player.onPlayerStateChanged.listen((state) {
      _updatePlaybackState(
        playing: state == PlayerState.playing,
        processingState: state == PlayerState.completed
            ? AudioProcessingState.completed
            : AudioProcessingState.ready,
      );
    });

    player.onPositionChanged.listen((pos) {
      playbackState.add(playbackState.value.copyWith(updatePosition: pos));
    });

    player.onDurationChanged.listen((duration) {
      final item = mediaItem.value;
      if (item != null) {
        mediaItem.add(item.copyWith(duration: duration));
      }
    });
  }

  void _setIdleState() {
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.play,
          MediaAction.pause,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
          MediaAction.stop,
        },
        processingState: AudioProcessingState.idle,
        playing: false,
      ),
    );
  }

  void _updatePlaybackState({
    required bool playing,
    required AudioProcessingState processingState,
  }) {
    playbackState.add(
      playbackState.value.copyWith(
        playing: playing,
        processingState: processingState,
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.play,
          MediaAction.pause,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
          MediaAction.stop,
        },
      ),
    );
  }

  @override
  Future<void> play() async {
    await player.resume();
    if (onPlayCustom != null) onPlayCustom!();
  }

  @override
  Future<void> pause() async {
    await player.pause();
    if (onPauseCustom != null) onPauseCustom!();
  }

  @override
  Future<void> stop() async {
    await player.stop();
    _updatePlaybackState(
      playing: false,
      processingState: AudioProcessingState.idle,
    );
    if (onStopCustom != null) onStopCustom!();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> skipToNext() async {
    if (onNext != null) onNext!();
  }

  @override
  Future<void> skipToPrevious() async {
    if (onPrev != null) onPrev!();
  }

  /// Keep the service alive when the user removes the app from recent tasks.
  /// This matches Spotify-like behaviour on Android.
  @override
  Future<void> onTaskRemoved() async {
    // Do NOT stop playback; just let the service continue in the background.
    // If you want to stop when the last track finishes, handle that elsewhere.
    // For now we do nothing so music keeps playing.
  }
}
