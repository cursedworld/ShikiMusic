import 'dart:io';

import 'package:audioplayers/audioplayers.dart';

import 'lyric_timing.dart';
import 'track_crossfade.dart';
import 'track_fade.dart';

/// One native decoder and its volume writer. Only the foreground deck gets a
/// UI position updater; the preroll deck never requests Flutter frames.
class PlaybackDeck implements CrossfadeDeck {
  PlaybackDeck({
    required double volume,
    required bool fadeEnabled,
    required void Function(Object) onError,
    AudioContext? context,
  }) {
    player.positionUpdater = null;
    fade = TrackFade(
      readPosition: player.getCurrentPosition,
      writeVolume: player.setVolume,
      onError: (error) {
        _lastVolumeError = error;
        onError(error);
      },
      volume: volume,
      enabled: fadeEnabled,
    );
    if (context != null) {
      contextReady = player.setAudioContext(context);
      // The owner still observes setup failure when preparing the source.
      // This handler covers players canceled before ever being prepared.
      contextReady!.ignore();
    }
  }

  final player = AudioPlayer();
  late final TrackFade fade;
  Future<void>? contextReady;
  Object? _lastVolumeError;
  LyricAudioFile? localAudio;

  Future<void> setTrackSource(
    Source source, {
    LyricAudioFile? localAudio,
  }) async {
    this.localAudio = null;
    await player.setSource(source);
    this.localAudio = localAudio;
  }

  @override
  bool get playing => player.state == PlayerState.playing;

  @override
  Future<Duration?> prepare(String path) async {
    await contextReady;
    await setTrackSource(
      DeviceFileSource(path),
      localAudio: await LyricAudioFile.inspect(File(path)),
    );
    return player.getDuration();
  }

  @override
  Future<void> resume() => player.resume();

  @override
  Future<void> setPrerollVolume(double volume) async {
    await fade.setVolume(volume);
    if (_lastVolumeError case final Object error) throw error;
  }

  @override
  Future<void> dispose() async {
    fade.dispose();
    try {
      await contextReady;
    } finally {
      await player.dispose();
    }
  }
}
