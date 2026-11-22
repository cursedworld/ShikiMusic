import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/track_fade.dart';

const _track = Duration(seconds: 120);
const _step = Duration(milliseconds: 32);

class _Playback {
  _Playback({bool enabled = true}) {
    fade = TrackFade(
      readPosition: () async {
        reads++;
        final read = readOverride;
        return read != null ? await read() : position;
      },
      writeVolume: (value) async {
        writes.add(value);
        await writeOverride?.call(value);
      },
      volume: 0.8,
      enabled: enabled,
      onError: errors.add,
    );
  }

  final writes = <double>[];
  final errors = <Object>[];
  int reads = 0;
  Duration position = Duration.zero;
  Future<Duration?> Function()? readOverride;
  Future<void> Function(double)? writeOverride;
  late final TrackFade fade;

  Future<void> report(
    int milliseconds, {
    Duration duration = _track,
    bool playing = true,
  }) {
    position = Duration(milliseconds: milliseconds);
    return fade.updatePosition(position, duration, playing: playing);
  }

  Future<void> sample(WidgetTester tester, int milliseconds) async {
    position = Duration(milliseconds: milliseconds);
    await tester.pump(_step);
  }
}

void main() {
  testWidgets('disabled player never reads position or writes fade gain', (
    tester,
  ) async {
    final playback = _Playback(enabled: false);
    addTearDown(playback.fade.dispose);
    await playback.fade.setVolume(0.8);
    await playback.report(0);
    await tester.pump(const Duration(seconds: 3));
    await playback.report(119200);
    await tester.pump(const Duration(seconds: 2));
    expect(playback.writes, [0.8]);
    expect(playback.reads, 0);
    expect(playback.errors, isEmpty);
  });

  testWidgets('fades at track edges with no timer or writes in the middle', (
    tester,
  ) async {
    final playback = _Playback();
    addTearDown(playback.fade.dispose);
    await playback.report(0, playing: false);
    await tester.pump(const Duration(seconds: 2));
    expect(playback.writes, [0.0]);
    expect(playback.reads, 0);

    await playback.report(0);
    await playback.sample(tester, 150);
    await playback.sample(tester, 300);
    await playback.sample(tester, 600);
    expect(playback.writes, [0.0, 0.125, 0.4, 0.8]);
    expect(playback.reads, 3);

    for (var i = 1; i <= 300; i++) {
      await playback.report(600 + i * 200);
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(playback.reads, 3);
    expect(playback.writes, hasLength(4));

    await playback.report(118900); // the regular poll wakes the tail ramp
    await playback.sample(tester, 119100);
    expect(playback.writes, hasLength(4));
    await playback.sample(tester, 119550);
    await playback.sample(tester, 119775);
    await playback.sample(tester, 120000);
    expect(playback.writes.skip(4), [0.4, 0.125, 0.0]);
    expect(playback.reads, 7);
    await tester.pump(const Duration(seconds: 2));
    expect(playback.reads, 7);
    expect(playback.errors, isEmpty);
  });

  testWidgets('paused and stalled playback do not keep fast polling', (
    tester,
  ) async {
    final playback = _Playback();
    addTearDown(playback.fade.dispose);
    await playback.report(300);
    await tester.pump(_step);
    await tester.pump(const Duration(seconds: 4));
    expect(playback.reads, 1);
    expect(playback.writes, [0.4]);

    playback.fade.hold();
    await playback.report(300, playing: false);
    await tester.pump(const Duration(seconds: 4));
    expect(playback.reads, 1);
    expect(playback.writes, [0.4]);

    await playback.report(300);
    await playback.sample(tester, 600);
    expect(playback.writes, [0.4, 0.8]);
  });

  testWidgets('seek and source change invalidate an old sample', (
    tester,
  ) async {
    final playback = _Playback();
    addTearDown(playback.fade.dispose);
    final slowSample = Completer<Duration?>();
    playback.readOverride = () => slowSample.future;
    await playback.report(119550);
    await tester.pump(_step);
    expect(playback.reads, 1);

    playback.fade.hold();
    await playback.report(4000); // seek out of the quiet tail
    expect(playback.writes, [0.4, 0.8]);
    playback.fade.hold();
    await playback.report(0, playing: false); // fast skip / repeat
    slowSample.complete(const Duration(milliseconds: 119775));
    await tester.pump(const Duration(seconds: 1));
    expect(playback.writes, [0.4, 0.8, 0.0]);
    expect(playback.reads, 1);
  });

  testWidgets('mute and user volume compose with the fade', (tester) async {
    final playback = _Playback();
    addTearDown(playback.fade.dispose);
    await playback.report(300);
    await playback.fade.setVolume(0.6);
    await playback.fade.setVolume(0);
    expect(playback.writes, [0.4, 0.3, 0.0]);
    await tester.pump(const Duration(seconds: 1));
    expect(playback.reads, 0);
    await playback.report(1000);
    await playback.fade.setVolume(0.6);
    expect(playback.writes, [0.4, 0.3, 0.0, 0.6]);
  });

  testWidgets('disabling during a pending write restores latest user volume', (
    tester,
  ) async {
    final playback = _Playback();
    addTearDown(playback.fade.dispose);
    final writeGate = Completer<void>();
    playback.writeOverride = (_) => writeGate.future;
    final fading = playback.report(119550);
    await tester.pump();
    expect(playback.writes, [0.4]);

    final disabled = playback.fade.setEnabled(false);
    final changed = playback.fade.setVolume(0.7);
    await tester.pump(const Duration(seconds: 2));
    expect(playback.writes, [0.4]);
    expect(playback.reads, 0);

    writeGate.complete();
    await Future.wait([fading, disabled, changed]);
    expect(playback.writes, [0.4, 0.7]);
    expect(playback.errors, isEmpty);
  });

  testWidgets('unknown duration and short tracks have a usable envelope', (
    tester,
  ) async {
    final playback = _Playback();
    addTearDown(playback.fade.dispose);
    await playback.report(5000, duration: Duration.zero);
    expect(playback.writes, [0.8]);
    expect(playback.reads, 0);
    playback.fade.hold();
    const short = Duration(milliseconds: 400);
    await playback.report(0, duration: short);
    await playback.sample(tester, 100);
    await playback.sample(tester, 200);
    await playback.sample(tester, 300);
    await playback.sample(tester, 400);
    expect(playback.writes, [0.8, 0.0, 0.4, 0.8, 0.4, 0.0]);
  });

  testWidgets('a failed fade write falls back to the normal volume', (
    tester,
  ) async {
    final playback = _Playback();
    addTearDown(playback.fade.dispose);
    playback.writeOverride = (volume) async {
      if (volume < 0.8) throw StateError('gain unavailable');
    };
    await playback.report(0);
    await tester.pump(const Duration(seconds: 2));
    expect(playback.writes, [0.0, 0.8]);
    expect(playback.reads, 0);
    expect(playback.errors, hasLength(1));
  });

  testWidgets('disposal prevents a pending sample from changing the gain', (
    tester,
  ) async {
    final playback = _Playback();
    final slowSample = Completer<Duration?>();
    playback.readOverride = () => slowSample.future;
    await playback.report(0);
    await tester.pump(_step);
    playback.fade.dispose();
    slowSample.complete(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 2));
    expect(playback.reads, 1);
    expect(playback.writes, [0.0]);
  });
}
