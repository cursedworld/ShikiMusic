import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/localization.dart';
import 'package:shiki/track_updates.dart';
import 'package:shiki/widgets/track_updates_dialog.dart';

void main() {
  const versions = TrackContentVersions(
    audio: null,
    lyrics: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    metadata:
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  );
  const offer = TrackUpdateOffer(
    id: 1,
    title: 'Track with updated lyrics',
    versions: versions,
  );

  for (final width in [375.0, 768.0, 1024.0, 1440.0]) {
    testWidgets('update dialog fits width $width and shows retry state', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final monitor = TrackUpdateMonitor(
        directory: Directory.systemTemp,
        tracks: () => [],
      );
      addTearDown(monitor.dispose);
      monitor.offers.value = [offer];
      final operation = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => TrackUpdatesDialog(
                    monitor: monitor,
                    onUpdate: (_) => operation.future,
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(tr('track_updates_hint')), findsOneWidget);
      await tester.tap(find.text(tr('update_track')));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      operation.completeError(const HttpException('offline'));
      await tester.pumpAndSettle();
      expect(find.text(tr('track_update_failed')), findsOneWidget);
      expect(find.text(tr('update_track')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(tr('update_later')));
      await tester.pumpAndSettle();
      expect(find.byType(TrackUpdatesDialog), findsNothing);
    });
  }
}
