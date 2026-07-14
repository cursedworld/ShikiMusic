import 'dart:async';
import 'dart:collection';

class AsyncTaskCancelledException implements Exception {
  const AsyncTaskCancelledException();
}

class AsyncTaskLimiter {
  AsyncTaskLimiter(this.maxConcurrent) {
    if (maxConcurrent < 1) {
      throw ArgumentError.value(
        maxConcurrent,
        'maxConcurrent',
        'must be positive',
      );
    }
  }

  final int maxConcurrent;
  final Queue<_TaskWaiter> _waiters = Queue<_TaskWaiter>();
  int _activeTasks = 0;
  bool _closed = false;

  Future<T> run<T>(
    Future<T> Function() task, {
    Future<void>? abortTrigger,
    Object cancellationError = const AsyncTaskCancelledException(),
  }) async {
    var acquired = false;
    try {
      await _acquire(
        abortTrigger: abortTrigger,
        cancellationError: cancellationError,
      );
      acquired = true;
      _throwIfClosed();
      return await task();
    } finally {
      if (acquired) {
        _release();
      }
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final error = StateError('AsyncTaskLimiter is closed.');
    final stackTrace = StackTrace.current;
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().cancel(error, stackTrace);
    }
  }

  Future<void> _acquire({
    required Future<void>? abortTrigger,
    required Object cancellationError,
  }) async {
    _throwIfClosed();
    if (_activeTasks < maxConcurrent) {
      _activeTasks += 1;
      return;
    }
    final waiter = _TaskWaiter();
    _waiters.addLast(waiter);
    if (abortTrigger != null) {
      unawaited(
        abortTrigger.then<void>(
          (_) => _cancelWaiter(waiter, cancellationError, StackTrace.current),
          onError: (Object _, StackTrace stackTrace) =>
              _cancelWaiter(waiter, cancellationError, stackTrace),
        ),
      );
    }
    await waiter.future;
  }

  void _release() {
    while (_waiters.isNotEmpty) {
      if (_waiters.removeFirst().acquire()) return;
    }
    _activeTasks -= 1;
  }

  void _cancelWaiter(_TaskWaiter waiter, Object error, StackTrace stackTrace) {
    if (!_waiters.remove(waiter)) return;
    waiter.cancel(error, stackTrace);
  }

  void _throwIfClosed() {
    if (_closed) {
      throw StateError('AsyncTaskLimiter is closed.');
    }
  }
}

class _TaskWaiter {
  final Completer<void> _completer = Completer<void>();
  bool _queued = true;

  Future<void> get future => _completer.future;

  bool acquire() {
    if (!_queued) return false;
    _queued = false;
    _completer.complete();
    return true;
  }

  void cancel(Object error, StackTrace stackTrace) {
    if (!_queued) return;
    _queued = false;
    _completer.completeError(error, stackTrace);
  }
}
