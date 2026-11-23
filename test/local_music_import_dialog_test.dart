import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/local_music_import.dart';
import 'package:shiki/widgets/local_music_import_dialog.dart';

import 'fixtures/local_mp3.dart';

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

  testWidgets('dialog imports an outside MP3 with real progress and storage', (
    tester,
  ) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('shiki-import-dialog-'),
    ))!;
    addTearDown(() => root.delete(recursive: true));
    final bytes = fixtureMp3();
    final (source, library) = (await tester.runAsync(
      () async => (
        await File('${root.path}/Песня (1).MP3').writeAsBytes(bytes),
        await Directory('${root.path}/library').create(),
      ),
    ))!;
    final finished = Completer<LocalMusicImportResult>();
    late Future<LocalMusicImportResult> Function() importSelection;
    await mount(
      tester,
      LocalMusicImportDialog(
        desktop: true,
        chooseFiles: () async => [(name: 'Песня (1).MP3', path: source.path)],
        onImport: (selected, cancel, progress) {
          importSelection = () => importLocalMusic(
            directory: library,
            files: selected,
            cancel: cancel,
            onProgress: progress,
          );
          return finished.future;
        },
      ),
      width: 1200,
    );
    await tester.tap(find.byKey(const ValueKey('pick_local_music')));
    await tester.pump();
    final actual = await tester.runAsync(importSelection);
    expect(actual, isNotNull);
    finished.complete(actual!);
    await tester.pumpAndSettle();
    expect(find.textContaining('Добавлено: 1.'), findsOneWidget);
    expect(find.textContaining('Не удалось'), findsNothing);
    await tester.runAsync(() async {
      final copies = await library
          .list()
          .where((item) => item.path.endsWith('.mp3'))
          .toList();
      expect(copies, hasLength(1));
      expect(await File(copies.single.path).readAsBytes(), bytes);
      expect(await source.readAsBytes(), bytes);
    });
  });

  testWidgets('selection and storage failures give distinct retry messages', (
    tester,
  ) async {
    var picks = 0;
    var imports = 0;
    await mount(
      tester,
      LocalMusicImportDialog(
        desktop: true,
        chooseFiles: () async {
          if (++picks == 1) throw StateError('picker unavailable');
          return files;
        },
        onImport: (_, _, _) async {
          imports++;
          throw const FileSystemException('write failed');
        },
      ),
      width: 320,
    );
    final pick = find.byKey(const ValueKey('pick_local_music'));
    await tester.tap(pick);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Не удалось получить выбранные файлы'),
      findsOneWidget,
    );
    expect(imports, 0);
    await tester.tap(pick);
    await tester.pumpAndSettle();
    expect(find.textContaining('Не удалось сохранить копии'), findsOneWidget);
    expect(
      find.textContaining('Не удалось получить выбранные файлы'),
      findsNothing,
    );
    expect(imports, 1);
    expect(tester.takeException(), isNull);
  });
}
