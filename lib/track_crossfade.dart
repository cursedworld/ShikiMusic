import 'dart:async';

abstract interface class CrossfadeDeck {
  bool get playing;
  Future<Duration?> prepare(String path);
  Future<void> resume();
  Future<void> setPrerollVolume(double volume);
  Future<void> dispose();
}

typedef CrossfadeSource = ({int trackId, String path});
typedef CrossfadeHandoff<T> = ({
  T deck,
  Duration duration,
  Duration position,
  CrossfadeSource source,
});

/// Owns the second deck only near an automatic transition. The current deck's
/// existing fade samples drive both preparation and mixing; no extra polling.
class TrackCrossfade<T extends CrossfadeDeck> {
  TrackCrossfade({
    required T Function() createDeck,
    required Future<bool> Function(String) fileReady,
    required CrossfadeSource? Function() nextSource,
    required void Function(Object) onError,
    required void Function() onReleased,
  }) : _createDeck = createDeck,
       _fileReady = fileReady,
       _nextSource = nextSource,
       _onError = onError,
       _onReleased = onReleased;

  static const overlap = Duration(milliseconds: 600);
  static const prepareWithin = Duration(milliseconds: 1400);
  static const minimumTrackDuration = Duration(seconds: 2);
  static const _latestStart = Duration(milliseconds: 400);

  final T Function() _createDeck;
  final Future<bool> Function(String) _fileReady;
  final CrossfadeSource? Function() _nextSource;
  final void Function(Object) _onError;
  final void Function() _onReleased;

  _CrossfadeAttempt<T>? _attempt;
  _CrossfadeAttempt<T>? _retiring;
  bool _tried = false;
  Duration _remaining = Duration.zero;
  double _volume = 0;

  bool holdsTrack(int id) =>
      _attempt?.source.trackId == id || _retiring?.source.trackId == id;

  void update(Duration remaining, double volume) {
    _remaining = remaining;
    _volume = volume;
    final attempt = _attempt;
    if (attempt != null) {
      if (attempt.started != null) {
        _mix(attempt);
      } else {
        _startIfReady(attempt);
      }
    } else if (!_tried &&
        _retiring == null &&
        remaining <= prepareWithin &&
        remaining >= _latestStart &&
        volume > 0) {
      _tried = true;
      final source = _nextSource();
      if (source == null) return;
      final pending = _CrossfadeAttempt<T>(source);
      _attempt = pending;
      // Don't leave an idle or audible preroll alive if the old clock stalls.
      pending.deadline = Timer(
        prepareWithin + const Duration(seconds: 1),
        () => _cancelAttempt(pending),
      );
      pending.work = _prepare(pending);
    }
  }

  void setVolume(double volume) {
    _volume = volume;
    final attempt = _attempt;
    if (attempt != null && attempt.started != null) _mix(attempt);
  }

  bool _canUse(_CrossfadeAttempt<T> attempt) =>
      identical(_attempt, attempt) && _nextSource() == attempt.source;

  Future<void> _prepare(_CrossfadeAttempt<T> attempt) async {
    try {
      if (!await _fileReady(attempt.source.path) ||
          !_canUse(attempt) ||
          _remaining < _latestStart) {
        _cancelAttempt(attempt);
        return;
      }
      final deck = attempt.deck = _createDeck();
      await deck.setPrerollVolume(0);
      if (!_canUse(attempt)) {
        _cancelAttempt(attempt);
        return;
      }
      final duration = await deck.prepare(attempt.source.path);
      if (!_canUse(attempt) ||
          duration == null ||
          duration < minimumTrackDuration ||
          _remaining < _latestStart) {
        _cancelAttempt(attempt);
        return;
      }
      attempt.duration = duration;
      _startIfReady(attempt);
    } catch (error) {
      _fail(attempt, error);
    }
  }

  void _startIfReady(_CrossfadeAttempt<T> attempt) {
    if (attempt.duration == null || attempt.starting || _remaining > overlap) {
      return;
    }
    if (_remaining < _latestStart || !_canUse(attempt)) {
      _cancelAttempt(attempt);
      return;
    }
    attempt.starting = true;
    // Silence until the backend acknowledges resume. Start from the current
    // gain at that time rather than jumping ahead on a slow launch.
    attempt.work = _start(attempt);
  }

  Future<void> _start(_CrossfadeAttempt<T> attempt) async {
    final clock = Stopwatch()..start();
    try {
      await attempt.deck!.resume();
      if (!_canUse(attempt) || !attempt.deck!.playing) {
        _cancelAttempt(attempt);
        return;
      }
      attempt.started = clock;
      attempt.startRemaining = _remaining;
    } catch (error) {
      _fail(attempt, error);
    }
  }

  void _mix(_CrossfadeAttempt<T> attempt) {
    final total = attempt.startRemaining.inMicroseconds;
    if (total <= 0) return;
    final t = (1 - _remaining.inMicroseconds / total).clamp(0.0, 1.0);
    final volume = _volume * t * t * (3 - 2 * t);
    if (volume == attempt.lastVolume) return;
    attempt.lastVolume = volume;
    unawaited(
      attempt.deck!.setPrerollVolume(volume).catchError((Object error) {
        _fail(attempt, error);
      }),
    );
  }

  /// Transfers the already playing deck at the old track's natural EOF.
  /// No seek, resume or new source load on the incoming track.
  CrossfadeHandoff<T>? takeAtEnd() {
    final attempt = _attempt;
    final started = attempt?.started;
    if (attempt == null ||
        started == null ||
        !_canUse(attempt) ||
        !attempt.deck!.playing) {
      cancel();
      return null;
    }
    _attempt = null;
    attempt.deadline?.cancel();
    _tried = false;
    final position = started.elapsed;
    return (
      deck: attempt.deck!,
      duration: attempt.duration!,
      position: position > overlap ? overlap : position,
      source: attempt.source,
    );
  }

  void cancel({bool allowRetry = false}) {
    if (allowRetry) _tried = false;
    final attempt = _attempt;
    if (attempt != null) _cancelAttempt(attempt);
  }

  void _fail(_CrossfadeAttempt<T> attempt, Object error) {
    if (!identical(_attempt, attempt)) return;
    _onError(error);
    _cancelAttempt(attempt);
  }

  void _cancelAttempt(_CrossfadeAttempt<T> attempt) {
    if (!identical(_attempt, attempt)) return;
    _attempt = null;
    attempt.deadline?.cancel();
    _retiring = attempt;
    unawaited(_retire(attempt));
  }

  Future<void> _retire(_CrossfadeAttempt<T> attempt) async {
    try {
      // A canceled prepare must settle before disposal (some native backends
      // still reference the player). Do not queue foreground transport here.
      await attempt.work;
      final deck = attempt.deck;
      if (deck != null) {
        try {
          await deck.setPrerollVolume(0);
        } finally {
          await deck.dispose();
        }
      }
    } catch (error) {
      _onError(error);
    } finally {
      _retiring = null;
      _onReleased();
    }
  }
}

class _CrossfadeAttempt<T extends CrossfadeDeck> {
  _CrossfadeAttempt(this.source);

  final CrossfadeSource source;
  T? deck;
  Duration? duration;
  Future<void>? work;
  Timer? deadline;
  bool starting = false;
  Stopwatch? started;
  Duration startRemaining = Duration.zero;
  double lastVolume = 0;
}
