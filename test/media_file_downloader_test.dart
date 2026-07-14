import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shiki/media_file_downloader.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shiki-download-test-');
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('streams chunks into a part file, then promotes exact bytes', () async {
    final stream = StreamController<List<int>>();
    final client = _StreamingClient((_) async {
      return http.StreamedResponse(stream.stream, HttpStatus.ok);
    });
    final downloader = MediaFileDownloader(client: client);
    addTearDown(downloader.close);
    final destination = File('${directory.path}/track.mp3');

    final resultFuture = downloader.download(
      source: Uri.parse('http://fixture/track.mp3'),
      destination: destination,
    );
    await client.sent;
    stream.add(<int>[1, 2, 3]);
    await _waitUntil(() => _partFilesFor(destination).isNotEmpty);

    expect(await destination.exists(), isFalse);
    expect(_partFilesFor(destination), hasLength(1));

    stream
      ..add(<int>[4, 5])
      ..close();
    final result = await resultFuture;

    expect(result.path, destination.path);
    expect(await destination.readAsBytes(), <int>[1, 2, 3, 4, 5]);
    expect(_partFilesFor(destination), isEmpty);
  });

  test('HTTP error creates neither final nor part file', () async {
    final client = _StreamingClient((_) async {
      return http.StreamedResponse(
        Stream<List<int>>.value(<int>[1, 2]),
        HttpStatus.internalServerError,
      );
    });
    final downloader = MediaFileDownloader(client: client);
    addTearDown(downloader.close);
    final destination = File('${directory.path}/video.mp4');

    await expectLater(
      downloader.download(
        source: Uri.parse('http://fixture/video.mp4'),
        destination: destination,
      ),
      throwsA(isA<HttpException>()),
    );

    expect(await destination.exists(), isFalse);
    expect(_partFilesFor(destination), isEmpty);
  });

  test('empty response creates neither final nor part file', () async {
    final client = _StreamingClient((_) async {
      return http.StreamedResponse(const Stream<List<int>>.empty(), 200);
    });
    final downloader = MediaFileDownloader(client: client);
    addTearDown(downloader.close);
    final destination = File('${directory.path}/empty.mp4');

    await expectLater(
      downloader.download(
        source: Uri.parse('http://fixture/empty.mp4'),
        destination: destination,
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(await destination.exists(), isFalse);
    expect(_partFilesFor(destination), isEmpty);
  });

  test('content-length mismatch creates neither final nor part file', () async {
    final client = _StreamingClient((_) async {
      return http.StreamedResponse(
        Stream<List<int>>.value(<int>[1, 2]),
        200,
        contentLength: 3,
      );
    });
    final downloader = MediaFileDownloader(client: client);
    addTearDown(downloader.close);
    final destination = File('${directory.path}/truncated.mp4');

    await expectLater(
      downloader.download(
        source: Uri.parse('http://fixture/truncated.mp4'),
        destination: destination,
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(await destination.exists(), isFalse);
    expect(_partFilesFor(destination), isEmpty);
  });

  test('removes only stale well-formed part files before download', () async {
    final destination = File('${directory.path}/orphaned.mp4');
    final now = DateTime.now();
    final old = now.subtract(const Duration(hours: 3));
    final oldPart = File(
      '${destination.path}.part.987654.${old.microsecondsSinceEpoch}.4',
    );
    final freshPart = File(
      '${destination.path}.part.987655.${now.microsecondsSinceEpoch}.5',
    );
    final recentlyTouchedPart = File(
      '${destination.path}.part.987656.${old.microsecondsSinceEpoch}.6',
    );
    final malformedPart = File('${destination.path}.part.orphan');
    for (final file in <File>[
      oldPart,
      freshPart,
      recentlyTouchedPart,
      malformedPart,
    ]) {
      await file.writeAsBytes(<int>[9]);
    }
    await oldPart.setLastModified(old);
    await freshPart.setLastModified(old);
    await malformedPart.setLastModified(old);

    final client = _StreamingClient((_) async {
      return http.StreamedResponse(
        Stream<List<int>>.value(<int>[1, 2, 3]),
        200,
      );
    });
    final downloader = MediaFileDownloader(
      client: client,
      stalePartialAge: const Duration(hours: 1),
    );
    addTearDown(downloader.close);

    await downloader.download(
      source: Uri.parse('http://fixture/orphaned.mp4'),
      destination: destination,
    );

    expect(await oldPart.exists(), isFalse);
    expect(await freshPart.exists(), isTrue);
    expect(await recentlyTouchedPart.exists(), isTrue);
    expect(await malformedPart.exists(), isTrue);
    expect(await destination.readAsBytes(), <int>[1, 2, 3]);
  });

  test('existing final file is preserved without HTTP request', () async {
    final destination = File('${directory.path}/existing.mp3');
    await destination.writeAsBytes(<int>[9, 8, 7]);
    final client = _StreamingClient((_) async {
      fail('HTTP request must not run for an existing final file.');
    });
    final downloader = MediaFileDownloader(client: client);
    addTearDown(downloader.close);

    await downloader.download(
      source: Uri.parse('http://fixture/existing.mp3'),
      destination: destination,
    );

    expect(await destination.readAsBytes(), <int>[9, 8, 7]);
    expect(client.sendCount, 0);
  });

  test('replaces an empty final only after complete download', () async {
    final destination = File('${directory.path}/empty-final.mp3');
    await destination.writeAsBytes(const <int>[]);
    final stream = StreamController<List<int>>();
    final client = _StreamingClient((_) async {
      return http.StreamedResponse(stream.stream, 200, contentLength: 3);
    });
    final downloader = MediaFileDownloader(client: client);
    addTearDown(downloader.close);

    final resultFuture = downloader.download(
      source: Uri.parse('http://fixture/empty-final.mp3'),
      destination: destination,
    );
    await client.sent;
    stream.add(<int>[1, 2]);
    await _waitUntil(() => _partFilesFor(destination).isNotEmpty);
    expect(await destination.length(), 0);

    stream
      ..add(<int>[3])
      ..close();
    await resultFuture;

    expect(await destination.readAsBytes(), <int>[1, 2, 3]);
    expect(_partFilesFor(destination), isEmpty);
  });

  test('deduplicates concurrent requests for the same destination', () async {
    final stream = StreamController<List<int>>();
    final client = _StreamingClient((_) async {
      return http.StreamedResponse(stream.stream, 200);
    });
    final downloader = MediaFileDownloader(client: client);
    addTearDown(downloader.close);
    final destination = File('${directory.path}/same.mp4');

    final first = downloader.download(
      source: Uri.parse('http://fixture/same.mp4'),
      destination: destination,
    );
    final second = downloader.download(
      source: Uri.parse('http://fixture/same.mp4'),
      destination: destination,
    );
    await client.sent;
    stream
      ..add(<int>[1, 2, 3])
      ..close();

    await Future.wait(<Future<File>>[first, second]);
    expect(client.sendCount, 1);
    expect(await destination.readAsBytes(), <int>[1, 2, 3]);
  });

  test(
    'foreground-first cancellation detaches while manual subscriber continues',
    () async {
      final stream = StreamController<List<int>>();
      var requestAborted = false;
      final foregroundClient = _StreamingClient((request) async {
        final abortable = request as http.AbortableRequest;
        unawaited(
          abortable.abortTrigger!.then<void>((_) {
            requestAborted = true;
          }),
        );
        return http.StreamedResponse(stream.stream, 200);
      });
      final manualClient = _StreamingClient((_) async {
        fail('Manual subscriber must reuse foreground transfer.');
      });
      final foregroundDownloader = MediaFileDownloader(
        client: foregroundClient,
      );
      final manualDownloader = MediaFileDownloader(client: manualClient);
      addTearDown(foregroundDownloader.close);
      addTearDown(manualDownloader.close);
      final destination = File('${directory.path}/foreground-first.mp4');
      final foregroundAbort = Completer<void>();

      final foreground = foregroundDownloader.download(
        source: Uri.parse('http://fixture/foreground-first.mp4'),
        destination: destination,
        abortTrigger: foregroundAbort.future,
      );
      await foregroundClient.sent;
      stream.add(<int>[1]);
      await _waitUntil(() => _partFilesFor(destination).isNotEmpty);
      final manual = manualDownloader.download(
        source: Uri.parse('http://fixture/foreground-first.mp4'),
        destination: destination,
      );
      final cancellationExpectation = expectLater(
        foreground,
        throwsA(isA<MediaDownloadCancelledException>()),
      );

      foregroundAbort.complete();
      await cancellationExpectation.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);
      expect(requestAborted, isFalse);

      stream
        ..add(<int>[2, 3])
        ..close();
      await manual;

      expect(foregroundClient.sendCount, 1);
      expect(manualClient.sendCount, 0);
      expect(requestAborted, isFalse);
      expect(await destination.readAsBytes(), <int>[1, 2, 3]);
      expect(_partFilesFor(destination), isEmpty);
    },
  );

  test(
    'manual-first transfer survives foreground subscriber cancellation',
    () async {
      final stream = StreamController<List<int>>();
      var requestAborted = false;
      final manualClient = _StreamingClient((request) async {
        final abortable = request as http.AbortableRequest;
        unawaited(
          abortable.abortTrigger!.then<void>((_) {
            requestAborted = true;
          }),
        );
        return http.StreamedResponse(stream.stream, 200);
      });
      final foregroundClient = _StreamingClient((_) async {
        fail('Foreground subscriber must reuse manual transfer.');
      });
      final manualDownloader = MediaFileDownloader(client: manualClient);
      final foregroundDownloader = MediaFileDownloader(
        client: foregroundClient,
      );
      addTearDown(manualDownloader.close);
      addTearDown(foregroundDownloader.close);
      final destination = File('${directory.path}/manual-first.mp4');

      final manual = manualDownloader.download(
        source: Uri.parse('http://fixture/manual-first.mp4'),
        destination: destination,
      );
      await manualClient.sent;
      stream.add(<int>[4]);
      await _waitUntil(() => _partFilesFor(destination).isNotEmpty);
      final foregroundAbort = Completer<void>();
      final foreground = foregroundDownloader.download(
        source: Uri.parse('http://fixture/manual-first.mp4'),
        destination: destination,
        abortTrigger: foregroundAbort.future,
      );
      final cancellationExpectation = expectLater(
        foreground,
        throwsA(isA<MediaDownloadCancelledException>()),
      );

      foregroundAbort.complete();
      await cancellationExpectation.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);
      expect(requestAborted, isFalse);

      stream
        ..add(<int>[5, 6])
        ..close();
      await manual;

      expect(manualClient.sendCount, 1);
      expect(foregroundClient.sendCount, 0);
      expect(requestAborted, isFalse);
      expect(await destination.readAsBytes(), <int>[4, 5, 6]);
      expect(_partFilesFor(destination), isEmpty);
    },
  );

  test('new caller starts fresh after last subscriber cancels', () async {
    final streams = <StreamController<List<int>>>[];
    final firstRequestAborted = Completer<void>();
    final client = _StreamingClient((request) async {
      final stream = StreamController<List<int>>();
      streams.add(stream);
      if (streams.length == 1) {
        final abortable = request as http.AbortableRequest;
        unawaited(
          abortable.abortTrigger!.then<void>((_) async {
            if (!firstRequestAborted.isCompleted) {
              firstRequestAborted.complete();
            }
            if (!stream.isClosed) {
              stream.addError(StateError('aborted'));
              await stream.close();
            }
          }),
        );
      }
      return http.StreamedResponse(stream.stream, 200);
    });
    final downloader = MediaFileDownloader(client: client);
    addTearDown(downloader.close);
    final destination = File('${directory.path}/retry-after-cancel.mp4');
    final abort = Completer<void>();
    final cancelled = downloader.download(
      source: Uri.parse('http://fixture/retry-after-cancel.mp4'),
      destination: destination,
      abortTrigger: abort.future,
    );
    await client.sent;
    streams.single.add(<int>[1]);
    await _waitUntil(() => _partFilesFor(destination).isNotEmpty);
    final cancellationExpectation = expectLater(
      cancelled,
      throwsA(isA<MediaDownloadCancelledException>()),
    );

    abort.complete();
    await cancellationExpectation.timeout(const Duration(seconds: 1));
    final retry = downloader.download(
      source: Uri.parse('http://fixture/retry-after-cancel.mp4'),
      destination: destination,
    );
    await firstRequestAborted.future.timeout(const Duration(seconds: 1));
    await _waitUntil(() => client.sendCount == 2);
    streams.last
      ..add(<int>[2, 3])
      ..close();
    await retry.timeout(const Duration(seconds: 1));

    expect(client.sendCount, 2);
    expect(await destination.readAsBytes(), <int>[2, 3]);
    expect(_partFilesFor(destination), isEmpty);
  });

  test(
    'coalesces separate downloader instances before destination lock',
    () async {
      final firstStream = StreamController<List<int>>();
      final firstClient = _StreamingClient((_) async {
        return http.StreamedResponse(firstStream.stream, 200);
      });
      final secondClient = _StreamingClient((_) async {
        return http.StreamedResponse(Stream<List<int>>.value(<int>[9]), 200);
      });
      final firstDownloader = MediaFileDownloader(client: firstClient);
      final secondDownloader = MediaFileDownloader(client: secondClient);
      addTearDown(firstDownloader.close);
      addTearDown(secondDownloader.close);
      final destination = File('${directory.path}/locked.mp4');

      final first = firstDownloader.download(
        source: Uri.parse('http://fixture/first.mp4'),
        destination: destination,
      );
      await firstClient.sent;
      final second = secondDownloader.download(
        source: Uri.parse('http://fixture/second.mp4'),
        destination: destination,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(secondClient.sendCount, 0);

      firstStream
        ..add(<int>[1, 2, 3])
        ..close();
      await Future.wait(<Future<File>>[first, second]);

      expect(secondClient.sendCount, 0);
      expect(await destination.readAsBytes(), <int>[1, 2, 3]);
    },
  );

  test('destination lock serializes downloads across isolates', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final firstResponse = Completer<HttpResponse>();
    var requestCount = 0;
    server.listen((request) async {
      requestCount += 1;
      if (requestCount == 1) {
        request.response.contentLength = 3;
        request.response.add(<int>[1]);
        await request.response.flush();
        firstResponse.complete(request.response);
        return;
      }
      request.response.add(<int>[9]);
      await request.response.close();
    });

    final source =
        'http://${server.address.address}:${server.port}/isolate-lock.mp4';
    final destination = File('${directory.path}/isolate-lock.mp4');
    final downloader = MediaFileDownloader();
    addTearDown(downloader.close);
    final first = downloader.download(
      source: Uri.parse(source),
      destination: destination,
      idleTimeout: const Duration(minutes: 1),
    );
    final response = await firstResponse.future.timeout(
      const Duration(seconds: 2),
    );
    await _waitUntil(() => _partFilesFor(destination).isNotEmpty);

    final ready = ReceivePort();
    final readyPort = ready.sendPort;
    final isolatedResult = ReceivePort();
    await Isolate.spawn<_IsolatedDownloadMessage>(_runIsolatedDownload, (
      source: source,
      destination: destination.path,
      readyPort: readyPort,
      resultPort: isolatedResult.sendPort,
    ));
    final second = isolatedResult.first
        .then<List<int>>((message) {
          final result = message as _IsolatedDownloadResult;
          final error = result.error;
          if (error != null) throw StateError(error);
          return result.bytes!;
        })
        .whenComplete(isolatedResult.close);
    await ready.first.timeout(const Duration(seconds: 2));
    ready.close();
    var secondCompleted = false;
    unawaited(
      second.then<void>(
        (_) => secondCompleted = true,
        onError: (Object _, StackTrace _) => secondCompleted = true,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final requestsWhileLocked = requestCount;
    final completedWhileLocked = secondCompleted;

    response
      ..add(<int>[2, 3])
      ..close();
    await first.timeout(const Duration(seconds: 2));
    final isolatedBytes = await second.timeout(const Duration(seconds: 2));

    expect(requestsWhileLocked, 1);
    expect(completedWhileLocked, isFalse);
    expect(requestCount, 1);
    expect(isolatedBytes, <int>[1, 2, 3]);
    expect(await destination.readAsBytes(), <int>[1, 2, 3]);
  });

  test('limits active downloads without changing caller queueing', () async {
    final streams = <StreamController<List<int>>>[];
    final client = _StreamingClient((_) async {
      final stream = StreamController<List<int>>();
      streams.add(stream);
      return http.StreamedResponse(stream.stream, 200);
    });
    final downloader = MediaFileDownloader(client: client, maxConcurrent: 2);
    addTearDown(downloader.close);

    final downloads = <Future<File>>[
      for (var index = 0; index < 3; index += 1)
        downloader.download(
          source: Uri.parse('http://fixture/$index.mp3'),
          destination: File('${directory.path}/$index.mp3'),
        ),
    ];
    await _waitUntil(() => client.sendCount == 2);
    expect(client.sendCount, 2);

    streams.first
      ..add(<int>[1])
      ..close();
    await _waitUntil(() => client.sendCount == 3);
    expect(client.sendCount, 3);

    for (final stream in streams.skip(1)) {
      stream
        ..add(<int>[1])
        ..close();
    }
    await Future.wait(downloads);
  });

  test(
    'connection timeout triggers request abortion and removes temp',
    () async {
      final aborted = Completer<void>();
      final neverCompletes = Completer<http.StreamedResponse>();
      final client = _StreamingClient((request) {
        final abortable = request as http.AbortableRequest;
        abortable.abortTrigger!.then((_) {
          if (!aborted.isCompleted) aborted.complete();
        });
        return neverCompletes.future;
      });
      final downloader = MediaFileDownloader(client: client);
      addTearDown(downloader.close);
      final destination = File('${directory.path}/connection-timeout.mp3');

      await expectLater(
        downloader.download(
          source: Uri.parse('http://fixture/connection-timeout.mp3'),
          destination: destination,
          connectionTimeout: const Duration(milliseconds: 30),
        ),
        throwsA(isA<TimeoutException>()),
      );
      await aborted.future.timeout(const Duration(seconds: 1));

      expect(await destination.exists(), isFalse);
      expect(_partFilesFor(destination), isEmpty);
    },
  );

  test('idle timeout aborts stalled response and removes temp', () async {
    final stream = StreamController<List<int>>();
    final aborted = Completer<void>();
    final client = _StreamingClient((request) async {
      final abortable = request as http.AbortableRequest;
      abortable.abortTrigger!.then((_) {
        if (!aborted.isCompleted) aborted.complete();
      });
      return http.StreamedResponse(stream.stream, 200);
    });
    final downloader = MediaFileDownloader(client: client);
    addTearDown(downloader.close);
    final destination = File('${directory.path}/idle-timeout.mp4');

    await expectLater(
      downloader.download(
        source: Uri.parse('http://fixture/idle-timeout.mp4'),
        destination: destination,
        idleTimeout: const Duration(milliseconds: 30),
      ),
      throwsA(isA<TimeoutException>()),
    );
    await aborted.future.timeout(const Duration(seconds: 1));

    expect(await destination.exists(), isFalse);
    expect(_partFilesFor(destination), isEmpty);
    await stream.close();
  });

  test('caller aborts stalled download and removes only temp', () async {
    final stream = StreamController<List<int>>();
    final requestAborted = Completer<void>();
    final callerAbort = Completer<void>();
    final client = _StreamingClient((request) async {
      final abortable = request as http.AbortableRequest;
      abortable.abortTrigger!.then((_) async {
        if (!requestAborted.isCompleted) requestAborted.complete();
        if (!stream.isClosed) {
          stream.addError(StateError('aborted'));
          await stream.close();
        }
      });
      return http.StreamedResponse(stream.stream, 200);
    });
    final downloader = MediaFileDownloader(client: client);
    addTearDown(downloader.close);
    final destination = File('${directory.path}/caller-abort.mp4');

    final result = downloader.download(
      source: Uri.parse('http://fixture/caller-abort.mp4'),
      destination: destination,
      idleTimeout: const Duration(minutes: 1),
      abortTrigger: callerAbort.future,
    );
    await client.sent;
    stream.add(<int>[1, 2, 3]);
    await _waitUntil(() => _partFilesFor(destination).isNotEmpty);

    callerAbort.complete();

    await expectLater(
      result,
      throwsA(isA<MediaDownloadCancelledException>()),
    ).timeout(const Duration(seconds: 1));
    await requestAborted.future.timeout(const Duration(seconds: 1));
    expect(await destination.exists(), isFalse);
    await _waitUntil(() => _partFilesFor(destination).isEmpty);
    expect(_partFilesFor(destination), isEmpty);
  });

  test('caller abort removes queued work without consuming a slot', () async {
    final streams = <StreamController<List<int>>>[];
    final client = _StreamingClient((_) async {
      final stream = StreamController<List<int>>();
      streams.add(stream);
      return http.StreamedResponse(stream.stream, 200);
    });
    final downloader = MediaFileDownloader(client: client, maxConcurrent: 1);
    addTearDown(downloader.close);

    final active = downloader.download(
      source: Uri.parse('http://fixture/active-slot.mp3'),
      destination: File('${directory.path}/active-slot.mp3'),
    );
    await client.sent;

    final callerAbort = Completer<void>();
    final queued = downloader.download(
      source: Uri.parse('http://fixture/cancelled-queued.mp3'),
      destination: File('${directory.path}/cancelled-queued.mp3'),
      abortTrigger: callerAbort.future,
    );
    callerAbort.complete();

    await expectLater(
      queued,
      throwsA(isA<MediaDownloadCancelledException>()),
    ).timeout(const Duration(seconds: 1));
    expect(client.sendCount, 1);

    streams.single
      ..add(<int>[1])
      ..close();
    await active;

    final afterCancellation = downloader.download(
      source: Uri.parse('http://fixture/after-cancel.mp3'),
      destination: File('${directory.path}/after-cancel.mp3'),
    );
    await _waitUntil(() => client.sendCount == 2);
    streams.last
      ..add(<int>[2])
      ..close();
    await afterCancellation;

    expect(client.sendCount, 2);
  });

  test('close aborts active work, rejects queued and future work', () async {
    final stream = StreamController<List<int>>();
    final client = _StreamingClient((request) async {
      final abortable = request as http.AbortableRequest;
      abortable.abortTrigger!.then((_) async {
        if (!stream.isClosed) {
          stream.addError(StateError('aborted'));
          await stream.close();
        }
      });
      return http.StreamedResponse(stream.stream, 200);
    });
    final downloader = MediaFileDownloader(client: client, maxConcurrent: 1);
    final active = downloader.download(
      source: Uri.parse('http://fixture/active.mp3'),
      destination: File('${directory.path}/active.mp3'),
    );
    await client.sent;
    final queued = downloader.download(
      source: Uri.parse('http://fixture/queued.mp3'),
      destination: File('${directory.path}/queued.mp3'),
    );

    final activeExpectation = expectLater(active, throwsA(isA<StateError>()));
    final queuedExpectation = expectLater(queued, throwsA(isA<StateError>()));
    await downloader.close();

    await activeExpectation;
    await queuedExpectation;
    expect(
      () => downloader.download(
        source: Uri.parse('http://fixture/future.mp3'),
        destination: File('${directory.path}/future.mp3'),
      ),
      throwsA(isA<StateError>()),
    );
  });
}

typedef _IsolatedDownloadMessage = ({
  String source,
  String destination,
  SendPort readyPort,
  SendPort resultPort,
});
typedef _IsolatedDownloadResult = ({List<int>? bytes, String? error});

Future<void> _runIsolatedDownload(_IsolatedDownloadMessage message) async {
  message.readyPort.send(null);
  final downloader = MediaFileDownloader();
  _IsolatedDownloadResult result;
  try {
    final file = await downloader.download(
      source: Uri.parse(message.source),
      destination: File(message.destination),
      idleTimeout: const Duration(minutes: 1),
    );
    result = (bytes: await file.readAsBytes(), error: null);
  } catch (error, stackTrace) {
    result = (bytes: null, error: '$error\n$stackTrace');
  } finally {
    await downloader.close();
  }
  message.resultPort.send(result);
}

List<File> _partFilesFor(File destination) {
  String normalize(String path) {
    final absolute = File(path).absolute.path.replaceAll('/', '\\');
    return Platform.isWindows ? absolute.toLowerCase() : absolute;
  }

  final prefix = '${normalize(destination.path)}.part.';
  return destination.parent
      .listSync()
      .whereType<File>()
      .where((file) => normalize(file.path).startsWith(prefix))
      .toList(growable: false);
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

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this._handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  _handler;
  final Completer<void> _sent = Completer<void>();
  int sendCount = 0;

  Future<void> get sent => _sent.future;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sendCount += 1;
    if (!_sent.isCompleted) {
      _sent.complete();
    }
    return _handler(request);
  }
}
