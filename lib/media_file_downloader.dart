import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:http/http.dart' as http;

class MediaDownloadCancelledException implements Exception {
  const MediaDownloadCancelledException();

  @override
  String toString() => 'Media download cancelled.';
}

class MediaFileDownloader {
  MediaFileDownloader({
    http.Client? client,
    int maxConcurrent = 2,
    Duration stalePartialAge = const Duration(hours: 24),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _maxConcurrent = maxConcurrent,
       _stalePartialAge = stalePartialAge {
    if (maxConcurrent < 1) {
      throw ArgumentError.value(
        maxConcurrent,
        'maxConcurrent',
        'must be positive',
      );
    }
    if (stalePartialAge < Duration.zero) {
      throw ArgumentError.value(
        stalePartialAge,
        'stalePartialAge',
        'must not be negative',
      );
    }
  }

  final http.Client _client;
  final bool _ownsClient;
  final int _maxConcurrent;
  final Duration _stalePartialAge;
  static final Map<String, _SharedMediaDownload> _inFlight =
      <String, _SharedMediaDownload>{};
  static final Set<String> _activeTemporaryPaths = <String>{};
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  final Set<_MediaDownloadSubscription> _subscriptions =
      <_MediaDownloadSubscription>{};
  int _activeDownloads = 0;
  int _ownedTransfers = 0;
  bool _closed = false;
  bool _clientClosed = false;
  final Completer<void> _closeCompleter = Completer<void>();

  static int _temporaryFileSequence = 0;

  Future<File> download({
    required Uri source,
    required File destination,
    Duration connectionTimeout = const Duration(seconds: 15),
    Duration idleTimeout = const Duration(seconds: 30),
    Future<void>? abortTrigger,
  }) {
    _throwIfClosed();
    _validateTimeout(connectionTimeout, 'connectionTimeout');
    _validateTimeout(idleTimeout, 'idleTimeout');

    final absolutePath = destination.absolute.path;
    final destinationPath = Platform.isWindows
        ? absolutePath.toLowerCase()
        : absolutePath;
    final existing = _inFlight[destinationPath];
    if (existing != null) {
      return _subscribe(existing, abortTrigger: abortTrigger);
    }

    late final _SharedMediaDownload shared;
    shared = _SharedMediaDownload(
      onAbandoned: () {
        if (identical(_inFlight[destinationPath], shared)) {
          _inFlight.remove(destinationPath);
        }
      },
    );
    _inFlight[destinationPath] = shared;
    final subscription = _subscribe(shared, abortTrigger: abortTrigger);
    _ownedTransfers += 1;
    shared.start(
      (cancellation) => _downloadAndRelease(
        source: source,
        destination: destination,
        connectionTimeout: connectionTimeout,
        idleTimeout: idleTimeout,
        cancellation: cancellation,
      ),
      onFinished: () {
        if (identical(_inFlight[destinationPath], shared)) {
          _inFlight.remove(destinationPath);
        }
        _ownedTransfers -= 1;
        _finishCloseIfIdle();
      },
    );
    return subscription;
  }

  Future<void> close() {
    if (_closed) return _closeCompleter.future;
    _closed = true;

    final error = StateError('MediaFileDownloader is closed.');
    final stackTrace = StackTrace.current;
    for (final subscription in _subscriptions.toList(growable: false)) {
      subscription.cancel(error, stackTrace);
    }
    _finishCloseIfIdle();
    return _closeCompleter.future;
  }

  Future<File> _subscribe(
    _SharedMediaDownload shared, {
    required Future<void>? abortTrigger,
  }) {
    final subscription = _MediaDownloadSubscription(
      owner: this,
      shared: shared,
    );
    _subscriptions.add(subscription);
    shared.add(subscription);
    subscription.watch(abortTrigger);
    return subscription.future;
  }

  void _finishCloseIfIdle() {
    if (!_closed || _ownedTransfers != 0) {
      return;
    }
    if (_ownsClient && !_clientClosed) {
      _clientClosed = true;
      _client.close();
    }
    if (!_closeCompleter.isCompleted) {
      _closeCompleter.complete();
    }
  }

  Future<File> _downloadAndRelease({
    required Uri source,
    required File destination,
    required Duration connectionTimeout,
    required Duration idleTimeout,
    required _TransferCancellation cancellation,
  }) async {
    var acquiredSlot = false;
    try {
      await _acquireSlot(cancellation: cancellation);
      acquiredSlot = true;
      return await _download(
        source: source,
        destination: destination,
        connectionTimeout: connectionTimeout,
        idleTimeout: idleTimeout,
        cancellation: cancellation,
      );
    } finally {
      if (acquiredSlot) {
        _releaseSlot();
      }
    }
  }

  Future<void> _acquireSlot({
    required _TransferCancellation cancellation,
  }) async {
    cancellation.throwIfCancelled();
    if (_activeDownloads < _maxConcurrent) {
      _activeDownloads += 1;
      return;
    }
    final waiter = Completer<void>();
    _waiters.addLast(waiter);
    void cancelWaiter() {
      if (waiter.isCompleted) return;
      if (_waiters.remove(waiter)) {
        waiter.completeError(
          const MediaDownloadCancelledException(),
          StackTrace.current,
        );
      }
    }

    unawaited(cancellation.future.then<void>((_) => cancelWaiter()));
    await waiter.future;
  }

  void _releaseSlot() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
      return;
    }
    _activeDownloads -= 1;
  }

  Future<File> _download({
    required Uri source,
    required File destination,
    required Duration connectionTimeout,
    required Duration idleTimeout,
    required _TransferCancellation cancellation,
  }) async {
    cancellation.throwIfCancelled();
    if (await _isUsable(destination)) {
      return destination;
    }

    await destination.parent.create(recursive: true);
    final lockFile = File('${destination.path}.lock');
    RandomAccessFile? lockHandle;
    var lockAcquired = false;
    File? partial;
    String? normalizedPartialPath;
    RandomAccessFile? output;
    Completer<void>? requestAbortTrigger;
    try {
      lockHandle = await lockFile.open(mode: FileMode.append);
      await lockHandle.lock(FileLock.blockingExclusive);
      lockAcquired = true;
      cancellation.throwIfCancelled();

      if (await _isUsable(destination)) {
        return destination;
      }
      await _deleteStalePartialFiles(destination);
      cancellation.throwIfCancelled();

      partial = File(_temporaryPathFor(destination));
      normalizedPartialPath = _normalizedAbsolutePath(partial.path);
      _activeTemporaryPaths.add(normalizedPartialPath);
      requestAbortTrigger = Completer<void>();
      unawaited(
        cancellation.future.then<void>(
          (_) => _completeAbort(requestAbortTrigger!),
        ),
      );
      await Future<void>.value();
      cancellation.throwIfCancelled();
      final request = http.AbortableRequest(
        'GET',
        source,
        abortTrigger: requestAbortTrigger.future,
      );
      final response = await _client
          .send(request)
          .timeout(
            connectionTimeout,
            onTimeout: () {
              _completeAbort(requestAbortTrigger!);
              throw TimeoutException(
                'Connection timed out after $connectionTimeout.',
              );
            },
          );
      if (response.statusCode != HttpStatus.ok) {
        _completeAbort(requestAbortTrigger);
        throw HttpException(
          'Download failed with HTTP ${response.statusCode}.',
          uri: source,
        );
      }

      final fileHandle = await partial.open(mode: FileMode.write);
      output = fileHandle;
      var writtenBytes = 0;
      await for (final chunk in _withIdleTimeout(
        response.stream,
        idleTimeout,
        requestAbortTrigger,
      )) {
        if (chunk.isEmpty) continue;
        await fileHandle.writeFrom(chunk);
        writtenBytes += chunk.length;
      }
      await fileHandle.flush();
      await fileHandle.close();
      output = null;

      if (writtenBytes == 0) {
        throw const FileSystemException('Downloaded file is empty.');
      }
      final expectedBytes = response.contentLength;
      if (expectedBytes != null && writtenBytes != expectedBytes) {
        throw FileSystemException(
          'Downloaded $writtenBytes bytes; expected $expectedBytes.',
          partial.path,
        );
      }

      cancellation.throwIfCancelled();
      return await partial.rename(destination.path);
    } catch (error, stackTrace) {
      if (cancellation.isCancelled &&
          error is! MediaDownloadCancelledException) {
        Error.throwWithStackTrace(
          const MediaDownloadCancelledException(),
          stackTrace,
        );
      }
      rethrow;
    } finally {
      if (output != null) {
        try {
          await output.close();
        } catch (_) {}
      }
      if (partial != null && await partial.exists()) {
        try {
          await partial.delete();
        } catch (_) {}
      }
      if (normalizedPartialPath != null) {
        _activeTemporaryPaths.remove(normalizedPartialPath);
      }
      if (lockHandle != null) {
        if (lockAcquired) {
          try {
            await lockHandle.unlock();
          } catch (_) {}
        }
        try {
          await lockHandle.close();
        } catch (_) {}
      }
    }
  }

  Stream<List<int>> _withIdleTimeout(
    Stream<List<int>> stream,
    Duration timeout,
    Completer<void> abortTrigger,
  ) {
    return stream.timeout(
      timeout,
      onTimeout: (sink) {
        _completeAbort(abortTrigger);
        sink
          ..addError(TimeoutException('Download stalled for $timeout.'))
          ..close();
      },
    );
  }

  Future<bool> _isUsable(File file) async {
    try {
      return await file.exists() && await file.length() > 0;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> _deleteStalePartialFiles(File destination) async {
    final destinationName = destination.uri.pathSegments.last;
    final pattern = RegExp(
      '^${RegExp.escape(destinationName)}\\.part\\.(\\d+)\\.(\\d+)\\.(\\d+)\$',
      caseSensitive: !Platform.isWindows,
    );
    final cutoff = DateTime.now().subtract(_stalePartialAge);

    try {
      await for (final entity in destination.parent.list(followLinks: false)) {
        if (entity is! File) continue;
        final match = pattern.firstMatch(entity.uri.pathSegments.last);
        if (match == null) continue;

        final ownerPid = int.tryParse(match.group(1)!);
        final createdMicros = int.tryParse(match.group(2)!);
        final sequence = int.tryParse(match.group(3)!);
        if (ownerPid == null ||
            ownerPid <= 0 ||
            createdMicros == null ||
            createdMicros <= 0 ||
            sequence == null ||
            sequence < 0) {
          continue;
        }

        final normalizedPath = _normalizedAbsolutePath(entity.path);
        if (_activeTemporaryPaths.contains(normalizedPath)) continue;

        final encodedCreation = DateTime.fromMicrosecondsSinceEpoch(
          createdMicros,
        );
        if (encodedCreation.isAfter(cutoff)) continue;

        final stat = await entity.stat();
        if (stat.type != FileSystemEntityType.file ||
            stat.modified.isAfter(cutoff)) {
          continue;
        }

        // Destination lock excludes active downloads from other processes.
        // Recheck local registry directly before deletion to close async races.
        if (_activeTemporaryPaths.contains(normalizedPath)) continue;
        try {
          await entity.delete();
        } on FileSystemException {
          // Cleanup is best-effort; inability to delete must not block playback.
        }
      }
    } on FileSystemException {
      // Directory enumeration/stat races are harmless and retried next download.
    }
  }

  String _temporaryPathFor(File destination) {
    final sequence = _temporaryFileSequence++;
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    return '${destination.path}.part.$pid.$timestamp.$sequence';
  }

  static String _normalizedAbsolutePath(String path) {
    final absolutePath = File(path).absolute.path;
    return Platform.isWindows ? absolutePath.toLowerCase() : absolutePath;
  }

  void _completeAbort(Completer<void> abortTrigger) {
    if (!abortTrigger.isCompleted) {
      abortTrigger.complete();
    }
  }

  void _throwIfClosed() {
    if (_closed) {
      throw StateError('MediaFileDownloader is closed.');
    }
  }

  void _validateTimeout(Duration timeout, String name) {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, name, 'must be positive');
    }
  }
}

class _SharedMediaDownload {
  _SharedMediaDownload({required void Function() onAbandoned})
    : _onAbandoned = onAbandoned;

  final void Function() _onAbandoned;
  final _TransferCancellation _cancellation = _TransferCancellation();
  final Set<_MediaDownloadSubscription> _subscribers =
      <_MediaDownloadSubscription>{};
  bool _started = false;
  bool _completed = false;

  void add(_MediaDownloadSubscription subscription) {
    if (_completed) {
      throw StateError('Cannot subscribe to a completed media download.');
    }
    _subscribers.add(subscription);
  }

  void start(
    Future<File> Function(_TransferCancellation cancellation) operation, {
    required void Function() onFinished,
  }) {
    if (_started) {
      throw StateError('Media download already started.');
    }
    _started = true;
    unawaited(
      Future<File>.sync(() => operation(_cancellation)).then<void>(
        (file) {
          _completed = true;
          onFinished();
          for (final subscription in _subscribers.toList(growable: false)) {
            subscription.complete(file);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          _completed = true;
          onFinished();
          for (final subscription in _subscribers.toList(growable: false)) {
            subscription.completeError(error, stackTrace);
          }
        },
      ),
    );
  }

  void remove(_MediaDownloadSubscription subscription) {
    if (!_subscribers.remove(subscription)) return;
    if (!_completed && _subscribers.isEmpty) {
      _onAbandoned();
      _cancellation.cancel();
    }
  }
}

class _MediaDownloadSubscription {
  _MediaDownloadSubscription({required this.owner, required this.shared});

  final MediaFileDownloader owner;
  final _SharedMediaDownload shared;
  final Completer<File> _completer = Completer<File>();
  bool _active = true;

  Future<File> get future => _completer.future;

  void watch(Future<void>? abortTrigger) {
    if (abortTrigger == null) return;
    unawaited(
      abortTrigger.then<void>(
        (_) =>
            cancel(const MediaDownloadCancelledException(), StackTrace.current),
        onError: (Object _, StackTrace stackTrace) =>
            cancel(const MediaDownloadCancelledException(), stackTrace),
      ),
    );
  }

  void complete(File file) {
    if (!_detach()) return;
    _completer.complete(file);
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (!_detach()) return;
    _completer.completeError(error, stackTrace);
  }

  void cancel(Object error, StackTrace stackTrace) {
    if (!_detach()) return;
    _completer.completeError(error, stackTrace);
  }

  bool _detach() {
    if (!_active) return false;
    _active = false;
    owner._subscriptions.remove(this);
    shared.remove(this);
    return true;
  }
}

class _TransferCancellation {
  final Completer<void> _completer = Completer<void>();
  bool isCancelled = false;

  Future<void> get future => _completer.future;

  void cancel() {
    if (isCancelled) return;
    isCancelled = true;
    _completer.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) {
      throw const MediaDownloadCancelledException();
    }
  }
}
