import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiki/downloaded_only.dart';

void main() {
  final catalog = Uri.parse('http://127.0.0.1:65534/api/tracks/');

  test(
    'live loopback transfer is aborted without waiting for its server body',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final mode = DownloadedOnlyMode();
      final client = mode.client();
      addTearDown(() async {
        client.close();
        mode.dispose();
        await server.close(force: true);
      });
      var calls = 0;
      final started = Completer<void>();
      server.listen((request) async {
        calls++;
        final response = request.response;
        response.done.ignore();
        response.bufferOutput = false;
        response.write('body in progress');
        await response.flush();
        started.complete();
      });
      final url = catalog.replace(port: server.port);
      final response = await client.send(http.Request('GET', url));
      final bytes = StreamIterator(response.stream);
      await started.future;
      expect(await bytes.moveNext(), isTrue);

      mode.value = true;
      await expectLater(
        bytes.moveNext().timeout(const Duration(seconds: 3)),
        throwsA(isA<http.RequestAbortedException>()),
      );
      await expectLater(
        client.get(url),
        throwsA(isA<http.RequestAbortedException>()),
      );
      expect(calls, 1);
      await bytes.cancel();
    },
  );

  test(
    'old profiles keep Django enabled and only a boolean enables the mode',
    () {
      expect(downloadedOnlyFromSettings({}), isFalse);
      expect(downloadedOnlyFromSettings({'downloadedOnly': 'true'}), isFalse);
      expect(downloadedOnlyFromSettings({'downloadedOnly': true}), isTrue);
    },
  );

  test(
    'only downloaded blocks network before creating an HTTP request',
    () async {
      final mode = DownloadedOnlyMode()..value = true;
      final delegate = MockClient(
        (_) async => fail('Unexpected Django request'),
      );
      final client = mode.client(delegate: delegate);
      addTearDown(mode.dispose);
      addTearDown(client.close);
      addTearDown(delegate.close);

      await expectLater(
        client.get(catalog),
        throwsA(isA<http.RequestAbortedException>()),
      );
    },
  );

  test(
    'response from before a quick off/on cycle cannot reach the app',
    () async {
      final mode = DownloadedOnlyMode();
      final late = Completer<http.Response>();
      final sent = Completer<void>();
      final delegate = MockClient((request) async {
        if (sent.isCompleted) return http.Response('current', 200);
        sent.complete();
        return late.future;
      });
      final client = mode.client(delegate: delegate);
      addTearDown(mode.dispose);
      addTearDown(client.close);
      addTearDown(delegate.close);

      final first = expectLater(
        client.get(catalog),
        throwsA(isA<http.RequestAbortedException>()),
      );
      await sent.future;
      mode.value = true;
      mode.value = false;
      expect((await client.get(catalog)).body, 'current');
      late.complete(http.Response('obsolete', 200));
      await first;
    },
  );

  test(
    'streamed response is aborted after its first chunk when mode changes',
    () async {
      final mode = DownloadedOnlyMode();
      final body = StreamController<List<int>>();
      final delegate = MockClient.streaming((_, _) async {
        return http.StreamedResponse(body.stream, 200);
      });
      final client = mode.client(delegate: delegate);
      addTearDown(mode.dispose);
      addTearDown(client.close);
      addTearDown(delegate.close);

      final response = await client.send(http.Request('GET', catalog));
      final bytes = StreamIterator(response.stream);
      final first = bytes.moveNext();
      body.add(utf8.encode('before'));
      expect(await first, isTrue);
      expect(utf8.decode(bytes.current), 'before');

      mode.value = true;
      final rest = expectLater(
        bytes.moveNext(),
        throwsA(isA<http.RequestAbortedException>()),
      );
      body.add(utf8.encode('obsolete'));
      await rest;
      await bytes.cancel();
      await body.close();
    },
  );
}
