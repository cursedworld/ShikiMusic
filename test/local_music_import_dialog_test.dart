import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/local_music_import.dart';
import 'package:shiki/widgets/local_music_import_dialog.dart';

void main() {
  const files = [(name: 'An MP3 with a very long name.mp3', path: null)];
  Future<void> mount(
    WidgetTester tester,
    LocalMusicImportDialog dialog, {
    required double width,
  }) async {
    tester.view.physicalSize = Size(width, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showDialog<void>(context: context, builder: (_) => dialog),
              child: const Text('Open import'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open import'));
    await tester.pumpAndSettle();
  }

  for (final width in [320.0, 1200.0]) {
    testWidgets('copy notice, progress, cancellation and report at $width', (
      tester,
    ) async {
      final finish = Completer<LocalMusicImportResult>();
      LocalImportCancel? token;
      await mount(
        tester,
        LocalMusicImportDialog(
          desktop: width >= 800,
          chooseFiles: () async => files,
          onImport: (selected, cancel, progress) {
            expect(selected, files);
            token = cancel;
            progress(1, 1, files.first.name, .4);
            return finish.future;
          },
        ),
        width: width,
      );
      expect(find.textContaining('Копии займут место'), findsOneWidget);
      expect(
        find.textContaining(width < 800 ? 'вместе с MP3' : 'из папки'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('pick_local_music')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .4,
      );
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(token!.requested, isTrue);
      finish.complete(
        const LocalMusicImportResult(
          entries: [],
          added: 1,
          alreadyPresent: 2,
          restored: 1,
          problems: [
            (name: 'unreadable.mp3', problem: LocalImportProblem.invalidAudio),
          ],
          cancelled: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Уже в библиотеке: 2'), findsOneWidget);
      expect(find.textContaining('unreadable.mp3'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  }
}
