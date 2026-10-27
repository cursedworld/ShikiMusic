import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/catalog_sync.dart';
import 'package:shiki/widgets/catalog_sync_button.dart';

void main() {
  test('validates whole catalog before replacing cached tracks', () {
    final cache = [
      for (var i = 1; i <= 129; i++) {'id': i, 'title': 'Track $i'},
    ];
    final fresh = [
      for (var i = 1; i <= 132; i++) {'id': i, 'title': 'Track $i'},
    ];
    expect(decodeTrackCatalog(utf8.encode(jsonEncode(fresh))).length, 132);
    for (final invalid in [
      [],
      {'detail': 'error'},
      [
        ...cache,
        {'id': 130, 'title': 'broken', 'artists': 'not a list'},
      ],
      [...cache, cache.first],
      [null],
    ]) {
      expect(
        () => decodeTrackCatalog(
          utf8.encode(jsonEncode(invalid)),
          hasCachedTracks: true,
        ),
        throwsFormatException,
      );
      expect(cache.length, 129);
    }
    expect(decodeTrackCatalog(utf8.encode('[]')), isEmpty);
    expect(
      () => decodeTrackCatalog(utf8.encode('{bad')),
      throwsFormatException,
    );
  });

  test(
    'failures never advance last successful check; repeated errors are quiet',
    () {
      final status = CatalogSyncStatus();
      addTearDown(status.dispose);
      final checked = DateTime(2026, 10, 26, 12);
      status.succeeded(at: checked);
      status.checking();
      status.failed(TimeoutException('offline'));
      expect(status.phase, CatalogSyncPhase.offline);
      expect(status.lastSuccess, checked);
      var changes = 0;
      status.addListener(() => changes++);
      status.failed(const SocketException('offline'));
      expect(changes, 0);
      status.failed(const FormatException('bad JSON'));
      expect(status.phase, CatalogSyncPhase.error);
      expect(changes, 1);
      expect(status.lastSuccess, checked);
      status.succeeded(at: checked.add(const Duration(seconds: 12)));
      expect(status.phase, CatalogSyncPhase.synced);
    },
  );

  testWidgets(
    'offline status remains actionable without animation or snackbar',
    (tester) async {
      final status = CatalogSyncStatus()
        ..failed(const SocketException('offline'));
      addTearDown(status.dispose);
      var refreshes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CatalogSyncButton(
              status: status,
              onRefresh: () => refreshes++,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('catalog_sync')));
      await tester.pumpAndSettle();
      expect(refreshes, 1);
      expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.binding.hasScheduledFrame, isFalse);
      status.checking();
      await tester.pump();
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNull,
      );
    },
  );
}
