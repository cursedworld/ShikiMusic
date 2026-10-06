import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/download_batch.dart';

TrackDownloadResult result(int id, {bool failedVideo = false}) =>
    TrackDownloadResult(
      id: id,
      title: 'Track $id',
      audioReady: true,
      videoReady: !failedVideo,
      errors: failedVideo ? {DownloadComponent.video: 'HTTP 500'} : {},
    );

void main() {
  test('batch deduplicates IDs and waits for every bounded worker', () async {
    var active = 0;
    var peak = 0;
    final started = <int>[];
    final gates = <int, Completer<void>>{};
    final batch = runDownloadBatch<int>(
      tracks: [1, 2, 2, 3, 4],
      trackId: (id) => id,
      download: (id) async {
        started.add(id);
        active++;
        if (active > peak) peak = active;
        final gate = gates[id] = Completer<void>();
        await gate.future;
        active--;
        return result(id);
      },
    );
    var completed = false;
    unawaited(batch.then((_) => completed = true));
    await Future<void>.delayed(Duration.zero);
    expect(started, [1, 2]);
    expect(completed, isFalse);
    gates[2]!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(started, [1, 2, 3]);
    gates[3]!.complete();
    await Future<void>.delayed(Duration.zero);
    gates[4]!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    gates[1]!.complete();
    final summary = await batch;
    expect(peak, 2);
    expect(summary.results.map((item) => item.id), [1, 2, 3, 4]);
    expect(summary.complete, 4);
  });

  test(
    'audio stays successful when video fails and later songs still finish',
    () async {
      final summary = await runDownloadBatch<int>(
        tracks: [1, 2, 3],
        trackId: (id) => id,
        download: (id) async => result(id, failedVideo: id == 2),
      );
      expect(summary.audioReady, 3);
      expect(summary.videoReady, 2);
      expect(summary.retry.single.id, 2);
      expect(summary.retry.single.errors[DownloadComponent.video], 'HTTP 500');
    },
  );

  test(
    'cancellation stops allocating new songs, waits active transfers',
    () async {
      var cancelled = false;
      final started = <int>[];
      final gate = Completer<void>();
      final batch = runDownloadBatch<int>(
        tracks: [1, 2, 3, 4],
        trackId: (id) => id,
        isCancelled: () => cancelled,
        download: (id) async {
          started.add(id);
          await gate.future;
          return result(id);
        },
      );
      await Future<void>.delayed(Duration.zero);
      cancelled = true;
      gate.complete();
      final summary = await batch;
      expect(started, [1, 2]);
      expect(summary.results.length, 2);
    },
  );

  test('empty batch completes without workers', () async {
    final summary = await runDownloadBatch<int>(
      tracks: [],
      trackId: (id) => id,
      download: (id) async => result(id),
    );
    expect(summary.results, isEmpty);
  });

  test('confirmed missing clip is visible, not an automatic retry failure', () {
    final summary = DownloadBatchResult(
      results: [
        TrackDownloadResult(
          id: 1,
          title: 'Audio only',
          audioReady: true,
          videoReady: false,
          videoUnavailable: true,
        ),
      ],
    );
    expect(summary.retry, isEmpty);
    expect(summary.complete, 0);
    expect(summary.incomplete.single.videoUnavailable, isTrue);
    expect(summary.audioReady, 1);
    expect(summary.videoUnavailable, 1);
  });

  test(
    'unexpected failure is recorded and does not stop the remaining batch',
    () async {
      final summary = await runDownloadBatch<int>(
        tracks: [1, 2, 3],
        trackId: (id) => id,
        title: (id) => 'Song $id',
        maxConcurrent: 1,
        download: (id) async {
          if (id == 2) throw const FormatException('Invalid track');
          return result(id);
        },
      );
      expect(summary.results.map((item) => item.id), [1, 2, 3]);
      expect(summary.audioReady, 2);
      expect(summary.retry.single.title, 'Song 2');
      expect(
        summary.retry.single.errors[DownloadComponent.library],
        contains('Invalid track'),
      );
    },
  );
}
