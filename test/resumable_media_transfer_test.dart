import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shiki/media_file_downloader.dart';

class _Client extends http.BaseClient {
  _Client(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

void main() {
  late Directory directory;
  late File destination;
  final data = utf8.encode('complete immutable media fixture');
  final source = Uri.parse('http://fixture/media.mp3');
  String digest(List<int> bytes) => sha256.convert(bytes).toString();
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shiki-resume-test-');
    destination = File('${directory.path}/track_1.mp3');
  });
  tearDown(() => directory.delete(recursive: true));

  Future<void> interrupt({List<int>? payload, int? count}) async {
    final body = payload ?? data;
    Stream<List<int>> interrupted() async* {
      yield body.take(count ?? 10).toList();
      throw const SocketException('Connection lost');
    }

    final client = _Client(
      (_) async => http.StreamedResponse(
        interrupted(),
        200,
        contentLength: body.length,
        headers: {'etag': '"v1"'},
      ),
    );
    final downloader = MediaFileDownloader(client: client);
    try {
      await expectLater(
        downloader.download(
          source: source,
          destination: destination,
          expectedSha256: digest(body),
        ),
        throwsA(isA<SocketException>()),
      );
    } finally {
      await downloader.close();
      client.close();
    }
    expect(await destination.exists(), isFalse);
    expect(await File('${destination.path}.part.resume').length(), count ?? 10);
  }

  test(
    'new downloader resumes immutable bytes after connection loss',
    () async {
      await interrupt();
      final client = _Client((request) async {
        expect(request.headers['Range'], 'bytes=10-');
        expect(request.headers['If-Range'], '"v1"');
        return http.StreamedResponse(
          Stream.value(data.sublist(10)),
          206,
          contentLength: data.length - 10,
          headers: {
            'content-range': 'bytes 10-${data.length - 1}/${data.length}',
            'etag': '"v1"',
          },
        );
      });
      final downloader = MediaFileDownloader(client: client);
      addTearDown(downloader.close);
      await downloader.download(
        source: source,
        destination: destination,
        expectedSha256: digest(data),
      );
      expect(await destination.readAsBytes(), data);
      expect(await File('${destination.path}.part.resume').exists(), isFalse);
      expect(await File('${destination.path}.resume.json').exists(), isFalse);
    },
  );

  test('server ignoring Range safely restarts only the partial', () async {
    await interrupt();
    final client = _Client((request) async {
      expect(request.headers['Range'], 'bytes=10-');
      return http.StreamedResponse(
        Stream.value(data),
        200,
        contentLength: data.length,
      );
    });
    final downloader = MediaFileDownloader(client: client);
    addTearDown(downloader.close);
    await downloader.download(
      source: source,
      destination: destination,
      expectedSha256: digest(data),
    );
    expect(await destination.readAsBytes(), data);
  });

  test(
    'bad Content-Range is rejected, never concatenated or promoted',
    () async {
      await interrupt();
      final client = _Client(
        (_) async => http.StreamedResponse(
          Stream.value(data.sublist(10)),
          206,
          contentLength: data.length - 10,
          headers: {
            'content-range': 'bytes 0-${data.length - 11}/${data.length}',
          },
        ),
      );
      final downloader = MediaFileDownloader(client: client);
      addTearDown(downloader.close);
      await expectLater(
        downloader.download(
          source: source,
          destination: destination,
          expectedSha256: digest(data),
        ),
        throwsFormatException,
      );
      expect(await destination.exists(), isFalse);
      expect(await File('${destination.path}.part.resume').exists(), isFalse);
    },
  );

  test(
    '416 can finish a complete interrupted file only after SHA-256 verification',
    () async {
      await interrupt(count: data.length);
      final client = _Client((request) async {
        expect(request.headers['Range'], 'bytes=${data.length}-');
        return http.StreamedResponse(
          const Stream.empty(),
          416,
          headers: {'content-range': 'bytes */${data.length}'},
        );
      });
      final downloader = MediaFileDownloader(client: client);
      addTearDown(downloader.close);
      await downloader.download(
        source: source,
        destination: destination,
        expectedSha256: digest(data),
      );
      expect(await destination.readAsBytes(), data);
    },
  );

  test('changed version never reuses bytes from an old version', () async {
    await interrupt();
    final newer = utf8.encode('new recording version');
    final client = _Client((request) async {
      expect(request.headers.containsKey('Range'), isFalse);
      return http.StreamedResponse(
        Stream.value(newer),
        200,
        contentLength: newer.length,
      );
    });
    final downloader = MediaFileDownloader(client: client);
    addTearDown(downloader.close);
    await downloader.download(
      source: source,
      destination: destination,
      expectedSha256: digest(newer),
    );
    expect(await destination.readAsBytes(), newer);
  });

  test(
    'changed response body is not promoted even with a plausible range',
    () async {
      await interrupt();
      final wrong = List<int>.filled(data.length - 10, 33);
      final client = _Client(
        (_) async => http.StreamedResponse(
          Stream.value(wrong),
          206,
          contentLength: wrong.length,
          headers: {
            'content-range': 'bytes 10-${data.length - 1}/${data.length}',
          },
        ),
      );
      final downloader = MediaFileDownloader(client: client);
      addTearDown(downloader.close);
      await expectLater(
        downloader.download(
          source: source,
          destination: destination,
          expectedSha256: digest(data),
        ),
        throwsFormatException,
      );
      expect(await destination.exists(), isFalse);
      expect(await File('${destination.path}.part.resume').exists(), isFalse);
    },
  );

  test(
    'cancelled subscriber does not cancel shared verified download',
    () async {
      final body = StreamController<List<int>>();
      final sent = Completer<void>();
      var requests = 0;
      final client = _Client((_) async {
        requests++;
        sent.complete();
        return http.StreamedResponse(
          body.stream,
          200,
          contentLength: data.length,
        );
      });
      final downloader = MediaFileDownloader(client: client);
      addTearDown(downloader.close);
      final cancel = Completer<void>();
      final first = downloader.download(
        source: source,
        destination: destination,
        expectedSha256: digest(data),
        abortTrigger: cancel.future,
      );
      final failed = expectLater(
        first,
        throwsA(isA<MediaDownloadCancelledException>()),
      );
      final second = downloader.download(
        source: source,
        destination: destination,
        expectedSha256: digest(data),
      );
      await sent.future;
      cancel.complete();
      await failed;
      body.add(data);
      await body.close();
      expect(await (await second).readAsBytes(), data);
      expect(requests, 1);
    },
  );

  test('HTTP failure preserves usable partial for next retry', () async {
    await interrupt();
    final client = _Client(
      (_) async => http.StreamedResponse(const Stream.empty(), 500),
    );
    final downloader = MediaFileDownloader(client: client);
    addTearDown(downloader.close);
    await expectLater(
      downloader.download(
        source: source,
        destination: destination,
        expectedSha256: digest(data),
      ),
      throwsA(isA<HttpException>()),
    );
    expect(await File('${destination.path}.part.resume').length(), 10);
  });

  test(
    'existing good destination is never replaced by a failed transfer',
    () async {
      await destination.writeAsBytes(data);
      final client = _Client((_) async => throw StateError('must not request'));
      final downloader = MediaFileDownloader(client: client);
      addTearDown(downloader.close);
      await downloader.download(
        source: source,
        destination: destination,
        expectedSha256: digest(data),
      );
      expect(await destination.readAsBytes(), data);
    },
  );
}
