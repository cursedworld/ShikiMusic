import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/playback_position.dart';

void main() {
  testWidgets('polls five times a second without continuous frame requests', (
    tester,
  ) async {
    var calls = 0;
    final values = <Duration>[];
    final updater = playbackPositionUpdater(
      () async => Duration(milliseconds: ++calls * 200),
    );
    final subscription = updater.positionStream.listen(values.add);
    updater.start();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(calls, 5);
    expect(values.last, const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
    updater.stop();
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 5);
    await tester.runAsync(() async {
      await subscription.cancel();
      await updater.dispose();
    });
  });

  testWidgets(
    'seek and pause positions update immediately; resume does not duplicate timers',
    (tester) async {
      var position = const Duration(seconds: 10);
      final values = <Duration>[];
      final updater = playbackPositionUpdater(() async => position);
      final subscription = updater.positionStream.listen(values.add);
      updater.start();
      await tester.pump(const Duration(milliseconds: 200));
      position = const Duration(seconds: 50);
      await updater.update();
      await tester.pump();
      expect(values.last, position);
      position = const Duration(milliseconds: 50125);
      await updater.stopAndUpdate();
      await tester.pump();
      expect(values.last, position);
      final pausedCount = values.length;
      await tester.pump(const Duration(seconds: 2));
      expect(values.length, pausedCount);
      updater.start();
      updater.start();
      await tester.pump(const Duration(milliseconds: 200));
      expect(values.length, pausedCount + 1);
      await tester.runAsync(() async {
        await subscription.cancel();
        await updater.dispose();
      });
    },
  );
}
