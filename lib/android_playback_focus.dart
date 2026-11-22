import 'dart:async';

import 'package:audio_session/audio_session.dart';

/// One Android audio focus request for both decks. Used only once a source
/// is opened in crossfade mode, so enabling it never restarts playing audio.
class AndroidPlaybackFocus {
  AndroidPlaybackFocus(this.onInterruption);

  final void Function(AudioInterruptionEvent) onInterruption;
  AudioSession? _session;
  StreamSubscription<AudioInterruptionEvent>? _events;
  bool _held = false;
  bool _interrupted = false;
  bool _disposed = false;

  bool get available => _held && !_interrupted && !_disposed;

  Future<bool> acquire() async {
    if (_disposed || _interrupted) return false;
    if (_held) return true;
    final session = _session ??= await AudioSession.instance;
    if (_disposed) return false;
    _events ??= session.interruptionEventStream.listen((event) {
      if (_disposed || !_held || event.type == AudioInterruptionType.duck) {
        return;
      }
      if (event.begin && event.type == AudioInterruptionType.unknown) {
        _held = false;
        _interrupted = false;
      } else {
        _interrupted = event.begin;
      }
      onInterruption(event);
    });
    _held = await session.setActive(true);
    if (_disposed) await release();
    return available;
  }

  Future<void> release() async {
    _interrupted = false;
    if (!_held) return;
    _held = false;
    await _session?.setActive(false);
  }

  Future<void> dispose() async {
    _disposed = true;
    await _events?.cancel();
    await release();
  }
}
