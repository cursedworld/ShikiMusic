import 'dart:async';
import 'dart:math' as math;

import 'playback_position.dart';

/// Applies a short gain envelope to the existing audio player. The regular
/// position stream wakes it near an edge; fine-grained samples are local to
/// the fade, never published to UI, lyrics, statistics or media sessions.
class TrackFade {
  TrackFade({
    required Future<Duration?> Function() readPosition,
    required Future<void> Function(double) writeVolume,
    required void Function(Object) onError,
    required double volume,
    bool enabled = false,
  }) : _readPosition = readPosition,
       _writeVolume = writeVolume,
       _onError = onError,
       _volume = volume,
       _enabled = enabled;

  static const fadeIn = Duration(milliseconds: 600);
  static const fadeOut = Duration(milliseconds: 900);
  static const _step = Duration(milliseconds: 32);
  final _done = Future<void>.value();

  final Future<Duration?> Function() _readPosition;
  final Future<void> Function(double) _writeVolume;
  final void Function(Object) _onError;
  void Function(Duration remaining, double volume)? onNearEnd;
  Duration nearEndLead = Duration.zero;
  bool _fadeHead = true;

  bool _enabled;
  bool get enabled => _enabled && !_disposed;

  bool _disposed = false;
  bool _playing = false;
  bool _sampling = false;
  bool _volumeFailed = false;
  int _epoch = 0;
  Duration? _position;
  Duration _duration = Duration.zero;
  Timer? _timer;

  double _volume;
  double _gain = 1;
  double? _appliedVolume;
  Future<void>? _volumeWrite;
  double get _effectiveVolume => _volume * _gain;

  Future<void> setEnabled(bool value) {
    if (_disposed || _enabled == value) return _done;
    _enabled = value;
    return reset();
  }

  Future<void> setVolume(double value) {
    if (_disposed) return _done;
    _volume = value;
    _schedule();
    return _flushVolume();
  }

  /// Stop sampling immediately on pause, seek or source change. Keep the
  /// current gain until the new position is known, to avoid a volume spike.
  void hold() {
    _epoch++;
    _playing = false;
    _position = null;
    _timer?.cancel();
    _timer = null;
  }

  void beginTrack({bool fadeIn = true}) {
    hold();
    _fadeHead = fadeIn;
    _volumeFailed = false;
  }

  /// Restore user volume on disable, stop or an abandoned source load.
  Future<void> reset() {
    hold();
    _gain = 1;
    _volumeFailed = false;
    return _flushVolume();
  }

  /// Can also be called before resuming a prepared source, so its first
  /// audible samples already start at the right gain.
  Future<void> updatePosition(
    Duration position,
    Duration duration, {
    required bool playing,
  }) {
    if (!enabled || _volumeFailed) return _done;
    if (!playing && _playing) hold();
    final previous = _position;
    // The regular 200 ms poll can finish just after a more recent fade sample.
    // Actual backwards seeks call hold() first.
    if (playing && _playing && previous != null && position < previous) {
      return _done;
    }
    _playing = playing;
    _position = position;
    _duration = duration;
    final write = _updateGain(position);
    _schedule();
    return write;
  }

  int _edgeMicros(Duration edge) => _duration > Duration.zero
      ? math.min(edge.inMicroseconds, _duration.inMicroseconds ~/ 2)
      : edge.inMicroseconds;

  Future<void> _updateGain(Duration position) {
    final head = _fadeHead ? _edgeMicros(fadeIn) : 0;
    final tail = _edgeMicros(fadeOut);
    final elapsed = position.inMicroseconds;
    final remaining = _duration.inMicroseconds - elapsed;
    final double progress;
    if (head > 0 && elapsed < head) {
      progress = math.max(0, elapsed) / head;
    } else if (_duration > Duration.zero && tail > 0 && remaining < tail) {
      progress = math.max(0, remaining) / tail;
    } else {
      progress = 1;
    }
    // Smoothstep keeps both ends of the envelope gentle.
    _gain = progress * progress * (3 - 2 * progress);
    final callback = onNearEnd;
    if (callback != null &&
        _playing &&
        _duration > Duration.zero &&
        remaining > 0 &&
        remaining <= nearEndLead.inMicroseconds) {
      callback(Duration(microseconds: remaining), _volume);
    }
    return _flushVolume();
  }

  bool get _nearEdge {
    final elapsed = _position?.inMicroseconds;
    if (elapsed == null) return false;
    final remaining = _duration.inMicroseconds - elapsed;
    return (_fadeHead && elapsed < _edgeMicros(fadeIn)) ||
        (remaining > 0 &&
            remaining <=
                _edgeMicros(fadeOut) + playbackPositionInterval.inMicroseconds);
  }

  void _schedule() {
    if (!enabled || !_playing || _volumeFailed || _volume == 0 || !_nearEdge) {
      _timer?.cancel();
      _timer = null;
    } else if (!_sampling) {
      _timer ??= Timer(_step, _sample);
    }
  }

  Future<void> _sample() async {
    _timer = null;
    _sampling = true;
    final epoch = _epoch;
    var advanced = false;
    try {
      final position = await _readPosition();
      final previous = _position;
      if (epoch != _epoch ||
          !_playing ||
          position == null ||
          previous == null) {
        return;
      }
      // If the native clock stalls, let the ordinary position stream wake
      // the fade again. Don't run a fast poll while buffering.
      if (position <= previous) return;
      advanced = true;
      _position = position;
      unawaited(_updateGain(position));
    } catch (error) {
      if (epoch == _epoch && enabled) _onError(error);
    } finally {
      _sampling = false;
      if (advanced || epoch != _epoch) _schedule();
    }
  }

  Future<void> _flushVolume() {
    if (_disposed) return _done;
    final pending = _volumeWrite;
    if (pending != null) return pending;
    if (_appliedVolume == _effectiveVolume) return _done;
    return _volumeWrite = _startVolumeWrite();
  }

  Future<void> _startVolumeWrite() => Future<void>.microtask(() async {
    // At most one native volume call in flight. New samples and user input
    // coalesce to the latest value instead of building a queue of old gains.
    try {
      while (!_disposed && _appliedVolume != _effectiveVolume) {
        final target = _effectiveVolume;
        try {
          await _writeVolume(target);
          _appliedVolume = target;
        } catch (error) {
          if (_disposed) break;
          _onError(error);
          _appliedVolume = null;
          if (_gain == 1) break;
          hold();
          _volumeFailed = true;
          _gain = 1; // Try restoring normal volume once.
        }
      }
    } finally {
      _volumeWrite = null;
    }
  });

  void dispose() {
    _disposed = true;
    hold();
  }
}
