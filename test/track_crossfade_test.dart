import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/globals.dart' show LoopMode;
import 'package:shiki/playback_order.dart';
import 'package:shiki/track_crossfade.dart';
import 'package:shiki/track_transition_mode.dart';

const _duration = Duration(seconds: 12);
const _source = (slot: 1, trackId: 8, path: 'track_8.mp3');
Future<void> _flush() => Future<void>.delayed(Duration.zero);

class _Deck implements CrossfadeDeck {
  final volume = <double>[];
  final paths = <String>[];
  Completer<Duration?>? prepareGate;
  Completer<void>? resumeGate;
  int starts = 0;
  int disposals = 0;
  bool prepareError = false;

  @override
  bool playing = false;

  @override
  Future<Duration?> prepare(String path) async {
    paths.add(path);
    if (prepareError) throw StateError('bad file');
    return prepareGate != null ? await prepareGate!.future : _duration;
  }

  @override
  Future<void> resume() async {
    starts++;
    await resumeGate?.future;
    playing = true;
  }

  @override
  Future<void> setPrerollVolume(double value) async => volume.add(value);

  @override
  Future<void> dispose() async {
    disposals++;
    playing = false;
  }
}

class _Playback {
  _Playback() {
    crossfade = TrackCrossfade<_Deck>(
      fileReady: (_) async {
        fileProbes++;
        return downloaded;
      },
      createDeck: () {
        created++;
        return deck;
      },
      nextSource: () => next,
      onError: errors.add,
      onReleased: () => released++,
    );
  }

  final deck = _Deck();
  CrossfadeSource? next = _source;
  int fileProbes = 0, created = 0, released = 0;
  bool downloaded = true;
  final errors = <Object>[];
  late final TrackCrossfade<_Deck> crossfade;

  void remaining(int ms, {double volume = 0.8}) =>
      crossfade.update(Duration(milliseconds: ms), volume);
}

void main() {
  test('legacy boolean stays sequential; explicit modes take precedence', () {
    expect(
      TrackTransitionMode.fromSettings(null, null),
      TrackTransitionMode.off,
    );
    expect(
      TrackTransitionMode.fromSettings(null, true),
      TrackTransitionMode.fade,
    );
    expect(
      TrackTransitionMode.fromSettings('off', true),
      TrackTransitionMode.off,
    );
    expect(
      TrackTransitionMode.fromSettings('crossfade', false),
      TrackTransitionMode.crossfade,
    );
  });

  test(
    'one muted preroll, overlap at 600 ms, one start and EOF handoff',
    () async {
      final playback = _Playback();
      playback.remaining(5000);
      expect(playback.fileProbes, 0);
      playback.remaining(1400);
      await _flush();
      expect(playback.created, 1);
      expect(playback.deck.paths, [_source.path]);
      expect(playback.deck.volume, [0.0]);
      playback.remaining(601);
      await _flush();
      expect(playback.deck.starts, 0);
      playback.remaining(600);
      await _flush();
      expect(playback.deck.starts, 1);
      playback.remaining(300);
      expect(playback.deck.volume.last, closeTo(0.4, 0.001));
      playback.crossfade.setVolume(0);
      expect(playback.deck.volume.last, 0);
      playback.crossfade.setVolume(0.6);
      expect(playback.deck.volume.last, closeTo(0.3, 0.001));
      final handoff = playback.crossfade.takeAtEnd();
      expect(handoff?.deck, same(playback.deck));
      expect(handoff?.source, _source);
      expect(handoff?.duration, _duration);
      expect(playback.deck.starts, 1);
      expect(playback.deck.disposals, 0);
      expect(playback.crossfade.takeAtEnd(), isNull);
    },
  );

  test(
    'streaming next track does not allocate a deck or recheck every sample',
    () async {
      final playback = _Playback()..downloaded = false;
      playback.remaining(1380);
      await _flush();
      for (var ms = 1100; ms >= 0; ms -= 32) {
        playback.remaining(ms);
      }
      expect(playback.fileProbes, 1);
      expect(playback.created, 0);
      expect(playback.crossfade.takeAtEnd(), isNull);
    },
  );

  test('busy preparation cannot delay skip or leak another decoder', () async {
    final playback = _Playback();
    final gate = playback.deck.prepareGate = Completer<Duration?>();
    playback.remaining(1300);
    await _flush();
    playback.crossfade.cancel(allowRetry: true);
    expect(playback.crossfade.holdsTrack(_source.trackId), isTrue);
    playback.remaining(1200);
    expect(playback.created, 1);
    expect(playback.deck.disposals, 0);
    gate.complete(_duration);
    await _flush();
    expect(playback.deck.disposals, 1);
    expect(playback.deck.starts, 0);
    expect(playback.released, 1);
    expect(playback.crossfade.holdsTrack(_source.trackId), isFalse);
    expect(playback.crossfade.takeAtEnd(), isNull);
  });

  test('pause or seek during mix silences and disposes the new deck', () async {
    final playback = _Playback();
    playback.remaining(1200);
    await _flush();
    playback.remaining(600);
    await _flush();
    playback.remaining(400);
    expect(playback.deck.volume.last, greaterThan(0));
    playback.crossfade.cancel();
    await _flush();
    expect(playback.deck.disposals, 1);
    expect(playback.deck.volume.last, 0);
    expect(playback.crossfade.takeAtEnd(), isNull);
  });

  test('late preparation falls back to ordinary end without overlap', () async {
    final playback = _Playback();
    final gate = playback.deck.prepareGate = Completer<Duration?>();
    playback.remaining(1400);
    await _flush();
    playback.remaining(350);
    gate.complete(_duration);
    await _flush();
    expect(playback.deck.starts, 0);
    expect(playback.deck.disposals, 1);
    expect(playback.crossfade.takeAtEnd(), isNull);
  });

  test('resume still pending at EOF does not delay the normal path', () async {
    final playback = _Playback();
    final gate = playback.deck.resumeGate = Completer<void>();
    playback.remaining(1400);
    await _flush();
    playback.remaining(590);
    expect(playback.crossfade.takeAtEnd(), isNull);
    gate.complete();
    await _flush();
    expect(playback.deck.starts, 1);
    expect(playback.deck.volume.every((value) => value == 0), isTrue);
    expect(playback.deck.disposals, 1);
  });

  test('changing the next track rejects a stale handoff', () async {
    final playback = _Playback();
    playback.remaining(1400);
    await _flush();
    playback.remaining(600);
    await _flush();
    playback.next = (slot: 2, trackId: 9, path: 'track_9.mp3');
    expect(playback.crossfade.takeAtEnd(), isNull);
    await _flush();
    expect(playback.deck.disposals, 1);
  });

  test(
    'another occurrence of the same file invalidates a silent deck',
    () async {
      final playback = _Playback();
      playback.remaining(1300);
      await _flush();
      expect(playback.deck.paths, [_source.path]);
      expect(playback.crossfade.audibleSource, isNull);

      playback.next = (slot: 2, trackId: _source.trackId, path: _source.path);
      playback.crossfade.reconcileNextSource();
      await _flush();
      expect(playback.deck.disposals, 1);
      expect(playback.deck.starts, 0);
      expect(playback.crossfade.takeAtEnd(), isNull);
    },
  );

  test('an audible base handoff stays ahead of newly queued tracks', () async {
    final order = PlaybackOrder()
      ..reset([
        {'id': 1},
        {'id': 2},
        {'id': 3},
      ], 0);
    final deck = _Deck();
    late final TrackCrossfade<_Deck> crossfade;
    CrossfadeSource? nextSource() {
      final entry = order
          .next(
            LoopMode.off,
            automatic: true,
            alreadyStarting: crossfade.audibleSource?.slot,
          )
          ?.entry;
      if (entry == null) return null;
      return (
        slot: entry.slot,
        trackId: entry.trackId,
        path: 'track_${entry.trackId}.mp3',
      );
    }

    crossfade = TrackCrossfade(
      createDeck: () => deck,
      fileReady: (_) async => true,
      nextSource: nextSource,
      onError: (error) => fail('$error'),
      onReleased: () {},
    );
    crossfade.update(const Duration(milliseconds: 1400), 0.8);
    await _flush();
    crossfade.update(const Duration(milliseconds: 600), 0.8);
    await _flush();
    crossfade.update(const Duration(milliseconds: 430), 0.8);
    final slot = crossfade.audibleSource!.slot;
    order.insertNext([
      {'id': 4},
      {'id': 5},
    ], alreadyStarting: slot);
    crossfade.reconcileNextSource();
    final handoff = crossfade.takeAtEnd()!;
    expect(handoff.source, (slot: slot, trackId: 2, path: 'track_2.mp3'));
    expect(deck.starts, 1);
    expect(deck.disposals, 0);
    order.take(
      order.next(
        LoopMode.off,
        automatic: true,
        alreadyStarting: handoff.source.slot,
      )!,
    );
    expect(order.current!.trackId, 2);
    for (final id in [4, 5, 3]) {
      final move = order.next(LoopMode.off, automatic: true)!;
      order.take(move);
      expect(order.current!.trackId, id);
    }
  });

  test(
    'bad local media releases preroll without affecting normal playback',
    () async {
      final playback = _Playback();
      playback.deck.prepareError = true;
      playback.remaining(1300);
      await _flush();
      expect(playback.deck.starts, 0);
      expect(playback.deck.disposals, 1);
      expect(playback.errors, hasLength(1));
    },
  );

  testWidgets('stalled playback cannot keep the second decoder alive', (
    tester,
  ) async {
    final playback = _Playback();
    playback.remaining(1400);
    await tester.pump();
    playback.remaining(600);
    await tester.pump();
    playback.remaining(350);
    expect(playback.deck.volume.last, greaterThan(0));
    await tester.pump(const Duration(seconds: 3));
    expect(playback.deck.volume.last, 0.0);
    expect(playback.deck.disposals, 1);
    expect(playback.crossfade.takeAtEnd(), isNull);
  });
}
