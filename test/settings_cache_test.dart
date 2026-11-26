import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/disposable_cache.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/localization.dart';
import 'package:shiki/screens/settings_screen.dart';
import 'package:shiki/screens/storage_screen.dart';

const _usage = StorageUsage(
  audioBytes: 1000,
  clipBytes: 1500000,
  artworkBytes: 620,
  reclaimableBytes: 400,
  hasReclaimableArtwork: true,
);
const _clear = ValueKey('storage_clear');
const _confirm = ValueKey('storage_confirm_clear');

void main() {
  late Directory directory;
  late String oldLanguage;
  late String? oldBackground;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'shiki_settings_cache_test_',
    );
    oldLanguage = languageNotifier.value;
    oldBackground = customBackgroundNotifier.value;
    languageNotifier.value = 'ru';
    customBackgroundNotifier.value = null;
  });
  tearDown(() async {
    languageNotifier.value = oldLanguage;
    customBackgroundNotifier.value = oldBackground;
    final prefix =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}shiki_settings_cache_test_';
    if (!directory.absolute.path.startsWith(prefix)) {
      throw StateError('Unexpected test directory');
    }
    await directory.delete(recursive: true);
  });

  Future<void> confirmClear(WidgetTester tester) async {
    final clear = find.byKey(_clear);
    await tester.scrollUntilVisible(
      clear,
      160,
      scrollable: find
          .descendant(
            of: find.byType(StorageScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(clear);
    await tester.pumpAndSettle();
  }

  testWidgets('opens storage on demand and previews the removable bytes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var reads = 0;
    var clears = 0;
    final initial = Completer<StorageUsage>();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: SettingsScreen(
          dataDirectoryProvider: () async => directory,
          storageBuilder: (_) => StorageScreen(
            loadUsage: () {
              reads++;
              return initial.future;
            },
            clearCache: () async {
              clears++;
              return const ArtworkCleanupResult();
            },
          ),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.text(tr('storage')),
      280,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(reads, 0);
    await tester.tap(find.text(tr('storage')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(reads, 1);
    expect(find.text(tr('storage_calculating')), findsOneWidget);
    initial.complete(_usage);
    await tester.pumpAndSettle();

    expect(find.text('1 КБ'), findsOneWidget);
    expect(find.text('1,5 МБ'), findsOneWidget);
    expect(find.text('620 Б'), findsOneWidget);
    expect(find.text('400 Б'), findsOneWidget);
    await confirmClear(tester);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining(
          tr('storage_estimated').replaceAll('{size}', '400 Б'),
        ),
      ),
      findsOneWidget,
    );
    expect(find.byKey(_confirm), findsOneWidget);
    expect(clears, 0);
    await tester.tap(find.text(tr('cancel')));
    await tester.pumpAndSettle();
    expect(clears, 0);
    expect(reads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reports only removed bytes, then refreshes the counts', (
    tester,
  ) async {
    var reads = 0;
    final completed = Completer<ArtworkCleanupResult>();
    await tester.pumpWidget(
      MaterialApp(
        home: StorageScreen(
          loadUsage: () async {
            reads++;
            return reads == 1 ? _usage : const StorageUsage(artworkBytes: 384);
          },
          clearCache: () => completed.future,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await confirmClear(tester);
    await tester.tap(find.byKey(_confirm));
    await tester.pump();

    expect(reads, 1);
    expect(find.text(tr('storage_cleaning')), findsOneWidget);
    expect(find.textContaining('236 Б'), findsNothing);
    completed.complete(
      const ArtworkCleanupResult(removedBytes: 236, removedFiles: 1),
    );
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(
      find.text(tr('storage_freed').replaceAll('{size}', '236 Б')),
      findsOneWidget,
    );
    expect(find.text('384 Б'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byKey(_clear)).onPressed, isNull);
  });

  for (final (result, label) in [
    (const ArtworkCleanupResult(busy: true), 'wait_for_downloads'),
    (
      const ArtworkCleanupResult(
        removedBytes: 100,
        removedFiles: 1,
        failed: true,
      ),
      'cache_clear_failed',
    ),
  ]) {
    testWidgets('shows $label without inventing a freed size', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: StorageScreen(
            loadUsage: () async => _usage,
            clearCache: () async => result,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await confirmClear(tester);
      await tester.tap(find.byKey(_confirm));
      await tester.pumpAndSettle();

      expect(find.textContaining(tr(label)), findsOneWidget);
      final freed = find.textContaining('100 Б');
      expect(freed, result.removedFiles > 0 ? findsOneWidget : findsNothing);
    });
  }

  testWidgets(
    'offers retry on a read error and cannot clear an empty profile',
    (tester) async {
      var reads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: StorageScreen(
            loadUsage: () async {
              if (++reads == 1) throw const FileSystemException('test');
              return const StorageUsage();
            },
            clearCache: () async => throw StateError('Should not clear'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(tr('storage_read_error')), findsOneWidget);
      expect(find.byKey(_clear), findsNothing);
      await tester.tap(find.text(tr('stats_retry')));
      await tester.pumpAndSettle();
      expect(find.text('0 Б'), findsNWidgets(4));
      expect(
        tester.widget<OutlinedButton>(find.byKey(_clear)).onPressed,
        isNull,
      );
    },
  );

  testWidgets('late cleanup completion after leaving the screen is safe', (
    tester,
  ) async {
    var reads = 0;
    final completed = Completer<ArtworkCleanupResult>();
    await tester.pumpWidget(
      MaterialApp(
        home: StorageScreen(
          loadUsage: () async {
            reads++;
            return _usage;
          },
          clearCache: () => completed.future,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await confirmClear(tester);
    await tester.tap(find.byKey(_confirm));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    completed.complete(const ArtworkCleanupResult());
    await tester.pump();
    expect(reads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop confirmation opens in each language with safe focus', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var clears = 0;
    for (final (width, language) in [
      (768.0, 'ru'),
      (1024.0, 'en'),
      (1440.0, 'ja'),
    ]) {
      tester.view.physicalSize = Size(width, 720);
      languageNotifier.value = language;
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey(language),
          theme: ThemeData.dark(),
          home: StorageScreen(
            loadUsage: () async => _usage,
            clearCache: () async {
              clears++;
              return const ArtworkCleanupResult();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(tr('storage_artwork')), findsOneWidget);
      expect(find.text(language == 'ru' ? '1,5 МБ' : '1.5 MB'), findsOneWidget);
      await confirmClear(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(clears, 0);
      expect(tester.takeException(), isNull);
    }
  });
}
