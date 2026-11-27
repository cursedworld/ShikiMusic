import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiki/track_updates.dart';

void main() {
  test(
    'manual pause skips startup and foreground polling, then checks once',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'shiki-poll-test-',
      );
      var requests = 0;
      final checked = Completer<void>();
      final client = MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      });
      final monitor = TrackUpdateMonitor(
        directory: directory,
        tracks: () => [],
        client: client,
        onCheckSucceeded: checked.complete,
        interval: const Duration(minutes: 5),
      );
      addTearDown(() async {
        monitor.dispose();
        client.close();
        await directory.delete(recursive: true);
      });

      monitor.setNetworkPaused(true);
      monitor.start();
      monitor.setActivity(visible: false, playing: true);
      monitor.setActivity(visible: true, playing: true);
      await monitor.checkNow();
      expect(requests, 0);

      monitor.setNetworkPaused(false);
      await checked.future;
      expect(requests, 1);
    },
  );

  test('late catalog response is ignored after pause and resume', () async {
    final directory = await Directory.systemTemp.createTemp('shiki-poll-test-');
    final pending = Completer<http.Response>();
    final sent = Completer<void>();
    final checked = Completer<void>();
    final requestedEtags = <String?>[];
    var refreshes = 0;
    final client = MockClient((request) async {
      requestedEtags.add(request.headers['if-none-match']);
      if (sent.isCompleted) {
        return http.Response('{}', 200, headers: {'etag': 'new'});
      }
      sent.complete();
      return pending.future;
    });
    final monitor = TrackUpdateMonitor(
      directory: directory,
      tracks: () => [],
      client: client,
      onCatalogChanged: () async => refreshes++,
      onCheckSucceeded: checked.complete,
      interval: const Duration(minutes: 5),
    );
    addTearDown(() async {
      monitor.dispose();
      client.close();
      await directory.delete(recursive: true);
    });

    monitor.start();
    await sent.future;
    monitor.setNetworkPaused(true);
    monitor.setNetworkPaused(false);
    pending.complete(http.Response('{}', 200, headers: {'etag': 'old'}));
    await checked.future;
    expect(requestedEtags, [null, null]);
    expect(refreshes, 1);
  });

  test(
    'background pause stops catalog polls; foreground resumes immediately',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'shiki-poll-test-',
      );
      var calls = 0;
      var successes = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response('{}', 200, headers: {'etag': 'fixed'});
      });
      final monitor = TrackUpdateMonitor(
        directory: directory,
        tracks: () => [],
        client: client,
        interval: const Duration(milliseconds: 25),
        onCheckSucceeded: () => successes++,
      );
      addTearDown(() async {
        monitor.dispose();
        client.close();
        await directory.delete(recursive: true);
      });
      Future<void> waitFor(bool Function() ready) async {
        final end = DateTime.now().add(const Duration(seconds: 3));
        while (!ready() && DateTime.now().isBefore(end)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(ready(), isTrue);
      }

      monitor.start();
      monitor.start();
      await waitFor(() => successes > 0);
      final visibleCalls = calls;
      for (var i = 0; i < 6; i++) {
        monitor.setActivity(visible: true, playing: i.isEven);
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
      expect(
        calls,
        greaterThan(visibleCalls + 1),
        reason: 'visible play/pause must not postpone the catalog timer',
      );
      monitor.setActivity(visible: false, playing: false);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final pausedCalls = calls;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(calls, pausedCalls);
      monitor.setActivity(visible: false, playing: true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        calls,
        pausedCalls,
        reason: 'background music polls once a minute, not 25ms',
      );
      monitor.setActivity(visible: true, playing: true);
      await waitFor(() => calls > pausedCalls);
      monitor.setActivity(visible: false, playing: false);
    },
  );

  test(
    'offline monitor reports failure without discarding pending offers',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'shiki-poll-test-',
      );
      final errors = <Object>[];
      final client = MockClient(
        (_) async => throw const SocketException('offline'),
      );
      final monitor = TrackUpdateMonitor(
        directory: directory,
        tracks: () => [],
        client: client,
        onCheckFailed: errors.add,
      );
      addTearDown(() async {
        monitor.dispose();
        client.close();
        await directory.delete(recursive: true);
      });
      await monitor.checkNow();
      expect(errors, hasLength(1));
      expect(errors.single, isA<SocketException>());
      expect(monitor.offers.value, isEmpty);
    },
  );
}
