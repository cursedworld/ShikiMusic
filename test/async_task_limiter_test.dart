import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/async_task_limiter.dart';

void main() {
  test('runs no more than configured task count', () async {
    final limiter = AsyncTaskLimiter(2);
    final blockers = <Completer<void>>[
      for (var index = 0; index < 3; index += 1) Completer<void>(),
    ];
    var active = 0;
    var peak = 0;

    final tasks = <Future<void>>[
      for (var index = 0; index < blockers.length; index += 1)
        limiter.run(() async {
          active += 1;
          if (active > peak) peak = active;
          await blockers[index].future;
          active -= 1;
        }),
    ];
    await _waitUntil(() => active == 2);
    expect(peak, 2);

    blockers[0].complete();
    await _waitUntil(() => blockers[2].isCompleted || active == 2);
    blockers[1].complete();
    blockers[2].complete();
    await Future.wait(tasks);

    expect(peak, 2);
    expect(active, 0);
  });

  test('releases slot after task failure', () async {
    final limiter = AsyncTaskLimiter(1);

    await expectLater(
      limiter.run<void>(() async => throw StateError('failed')),
      throwsStateError,
    );
    final value = await limiter.run<int>(() async => 42);

    expect(value, 42);
  });

  test('abort removes queued task without starting it', () async {
    final limiter = AsyncTaskLimiter(1);
    final releaseActive = Completer<void>();
    final abortQueued = Completer<void>();
    var activeStarted = false;
    var queuedStarted = false;

    final active = limiter.run(() async {
      activeStarted = true;
      await releaseActive.future;
    });
    await _waitUntil(() => activeStarted);

    final queued = limiter.run(() async {
      queuedStarted = true;
    }, abortTrigger: abortQueued.future);
    final queuedExpectation = expectLater(
      queued,
      throwsA(isA<AsyncTaskCancelledException>()),
    );
    abortQueued.complete();
    await queuedExpectation;

    releaseActive.complete();
    await active;
    expect(queuedStarted, isFalse);
    expect(await limiter.run(() async => 42), 42);
  });

  test(
    'close lets active task finish but rejects queued and new tasks',
    () async {
      final limiter = AsyncTaskLimiter(1);
      final releaseActive = Completer<void>();
      var activeStarted = false;
      var queuedStarted = false;

      final active = limiter.run(() async {
        activeStarted = true;
        await releaseActive.future;
        return 1;
      });
      await _waitUntil(() => activeStarted);
      final queued = limiter.run(() async {
        queuedStarted = true;
        return 2;
      });
      final queuedExpectation = expectLater(queued, throwsStateError);

      limiter.close();
      limiter.close();
      releaseActive.complete();

      expect(await active, 1);
      await queuedExpectation;
      expect(queuedStarted, isFalse);
      await expectLater(limiter.run(() async => 3), throwsStateError);
    },
  );
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for test condition.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
