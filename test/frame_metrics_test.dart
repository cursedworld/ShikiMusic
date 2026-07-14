import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/perf/frame_metrics.dart';

void main() {
  test('counts missed and hidden frames', () {
    final metrics = FrameMetricsAccumulator(frameBudgetMicros: 16667)
      ..recordFrame(totalSpanMicros: 10000, hidden: false, nowMicros: 10000)
      ..recordFrame(totalSpanMicros: 20000, hidden: true, nowMicros: 20000);

    expect(metrics.totalFrames, 2);
    expect(metrics.missedFrames, 1);
    expect(metrics.hiddenFlutterFrames, 1);
    expect(metrics.toJson()['missedFrameRatioPercent'], 50.0);
  });

  test('counts only hidden frames after video release for idle gate', () {
    final metrics = FrameMetricsAccumulator(frameBudgetMicros: 16667)
      ..recordFrame(totalSpanMicros: 10000, hidden: true, nowMicros: 10000)
      ..recordFrame(totalSpanMicros: 10000, hidden: true, nowMicros: 20000)
      ..markVideoControllerReleased()
      ..recordFrame(totalSpanMicros: 10000, hidden: true, nowMicros: 30000)
      ..recordFrame(totalSpanMicros: 10000, hidden: false, nowMicros: 40000);

    expect(metrics.hiddenFlutterFrames, 3);
    expect(metrics.hiddenFlutterFramesAfterRelease, 1);
    expect(metrics.toJson()['hiddenFlutterFramesAfterRelease'], 1);
  });

  test('counts from capture start when video was already released', () {
    final metrics = FrameMetricsAccumulator(
      frameBudgetMicros: 16667,
      videoControllerAlreadyReleased: true,
    )..recordFrame(totalSpanMicros: 10000, hidden: true, nowMicros: 10000);

    expect(metrics.hiddenFlutterFramesAfterRelease, 1);
    expect(metrics.toJson()['hiddenFlutterFramesAfterRelease'], 1);
  });

  test('reports null missed-frame ratio when no frames were captured', () {
    final metrics = FrameMetricsAccumulator(frameBudgetMicros: 16667);

    expect(metrics.totalFrames, 0);
    expect(metrics.toJson()['missedFrameRatioPercent'], isNull);
  });

  test('accepts first restore video frame once and only after visible', () {
    final metrics = FrameMetricsAccumulator(frameBudgetMicros: 16667)
      ..requestRestore(100000);

    expect(metrics.canAcceptVideoFrame, isFalse);
    expect(metrics.recordVideoFrame(120000), isFalse);

    metrics
      ..markLifecycleHidden()
      ..markLifecycleVisible();

    expect(metrics.canAcceptVideoFrame, isTrue);
    expect(metrics.recordVideoFrame(145000), isTrue);
    expect(metrics.recordVideoFrame(180000), isFalse);
    expect(metrics.firstFrameAfterRestoreMicros, 45000);
    expect(metrics.toJson()['firstFrameAfterRestoreMs'], 45.0);
    expect(metrics.canAcceptVideoFrame, isFalse);
  });
}
