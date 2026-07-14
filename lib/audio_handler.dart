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
  AudioPlayer? _player;

  VoidCallback? onNext;
  VoidCallback? onPrev;
  VoidCallback? onPauseCustom;
  VoidCallback? onPlayCustom;
  VoidCallback? onStopCustom;

  bool _isAttached = false;
  Duration _lastPosition = Duration.zero;
  DateTime? _lastPositionBroadcast;

  AudioPlayerHandler() {
    // Start with idle state so the notification system knows we exist
    _broadcastState(playing: false, processingState: AudioProcessingState.idle);
  }

  /// Attach the actual AudioPlayer instance used by the app.
  /// This must be called once after construction.
  void attachPlayer(AudioPlayer externalPlayer) {
    _player = externalPlayer;
    _isAttached = true;

    // Sync player state → media session
    _player!.onPlayerStateChanged.listen((state) {
      _broadcastState(
        playing: state == PlayerState.playing,
        processingState: state == PlayerState.completed
            ? AudioProcessingState.completed
            : AudioProcessingState.ready,
      );
    });

    _player!.onPositionChanged.listen((pos) {
      _lastPosition = pos;
      final now = DateTime.now();
      final previous = _lastPositionBroadcast;
      if (previous != null &&
          now.difference(previous) < const Duration(seconds: 1)) {
        return;
      }
      _lastPositionBroadcast = now;
      playbackState.add(playbackState.value.copyWith(updatePosition: pos));
    });

    _player!.onDurationChanged.listen((duration) {
      final item = mediaItem.value;
      if (item != null) {
        mediaItem.add(item.copyWith(duration: duration));
      }
    });
  }

  void _broadcastState({
    required bool playing,
    required AudioProcessingState processingState,
  }) {
    playbackState.add(
      PlaybackState(
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
        androidCompactActionIndices: const [0, 1, 2],
        processingState: processingState,
        playing: playing,
        updatePosition: _isAttached ? _lastPosition : Duration.zero,
      ),
    );
  }

  @override
  Future<void> play() async {
    if (!_isAttached) return;
    await _player!.resume();
    if (onPlayCustom != null) onPlayCustom!();
  }

  @override
  Future<void> pause() async {
    if (!_isAttached) return;
    await _player!.pause();
    if (onPauseCustom != null) onPauseCustom!();
  }

  @override
  Future<void> stop() async {
    if (!_isAttached) return;
    await _player!.stop();
    _lastPosition = Duration.zero;
    _lastPositionBroadcast = null;
    _broadcastState(playing: false, processingState: AudioProcessingState.idle);
    if (onStopCustom != null) onStopCustom!();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    if (!_isAttached) return;
    await _player!.seek(position);
    _lastPosition = position;
    _lastPositionBroadcast = DateTime.now();
    playbackState.add(playbackState.value.copyWith(updatePosition: position));
  }

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
    // Do NOT stop playback; let the foreground service continue.
    // The notification will keep the service alive.
  }

  /// Called when notification is swiped away.
  /// We also keep playing — user must explicitly stop.
  @override
  Future<void> onNotificationDeleted() async {
    // Do nothing — keep playing like Spotify does.
  }
}
