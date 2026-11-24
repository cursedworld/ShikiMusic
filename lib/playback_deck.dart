import 'dart:io';

import 'package:audioplayers/audioplayers.dart';

import 'lyric_timing.dart';
import 'mp3_metadata.dart';
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
    bool replayGainEnabled = false,
    AudioPlayer? player,
    Future<double> Function(String) trackGainReader = readMp3TrackGain,
  }) : player = player ?? AudioPlayer(),
       _replayGainEnabled = replayGainEnabled,
       _trackGainReader = trackGainReader {
    this.player.positionUpdater = null;
    fade = TrackFade(
      readPosition: this.player.getCurrentPosition,
      writeVolume: this.player.setVolume,
      onError: (error) {
        _lastVolumeError = error;
        onError(error);
      },
      volume: volume,
      enabled: fadeEnabled,
    );
    if (context != null) {
      contextReady = this.player.setAudioContext(context);
      // The owner still observes setup failure when preparing the source.
      // This handler covers players canceled before ever being prepared.
      contextReady!.ignore();
    }
  }

  final AudioPlayer player;
  late final TrackFade fade;
  final Future<double> Function(String) _trackGainReader;
  bool _replayGainEnabled, _disposed = false;
  int _sourceRevision = 0;
  Future<double>? _loadedFileGain;
  Future<void>? contextReady;
  Object? _lastVolumeError;
  LyricAudioFile? localAudio;

  Future<void> setTrackSource(
    Source source, {
    LyricAudioFile? localAudio,
  }) async {
    final revision = ++_sourceRevision;
    this.localAudio = null;
    _loadedFileGain = null;
    // A backend may automatically start a new source if the deck is still
    // playing. Keep it paused until the new recording's gain is known.
    if (playing &&
        (_replayGainEnabled && localAudio != null || fade.trackGain != 1)) {
      await player.pause();
    }
    await player.setSource(source);
    if (_disposed || revision != _sourceRevision) return;
    this.localAudio = localAudio;
    if (_replayGainEnabled || fade.trackGain != 1) await _applyReplayGain();
  }

  Future<void> setReplayGainEnabled(bool enabled) async {
    if (_disposed || enabled == _replayGainEnabled) return;
    _replayGainEnabled = enabled;
    await _applyReplayGain();
  }

  Future<void> _applyReplayGain() async {
    final file = localAudio;
    final revision = _sourceRevision;
    final gain = _replayGainEnabled && file != null
        ? await (_loadedFileGain ??= _trackGainReader(file.path))
        : 1.0;
    if (_disposed ||
        revision != _sourceRevision ||
        !identical(file, localAudio)) {
      return;
    }
    await fade.setTrackGain(_replayGainEnabled ? gain : 1);
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
    _disposed = true;
    fade.dispose();
    try {
      await contextReady;
    } finally {
      await player.dispose();
    }
  }
}
