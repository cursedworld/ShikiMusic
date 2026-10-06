import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/localization.dart';
import 'package:shiki/screens/settings_screen.dart';

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

  Future<void> showClearDialog(
    WidgetTester tester,
    FutureOr<bool?> Function() callback,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          onClearCache: callback,
          dataDirectoryProvider: () async => directory,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text(tr('clear_cache')),
      300,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 20,
    );
    await tester.tap(find.text(tr('clear_cache')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(tr('clear')));
    await tester.pump();
  }

  testWidgets('reports success only after asynchronous cleanup completed', (
    tester,
  ) async {
    final completed = Completer<bool?>();
    await showClearDialog(tester, () => completed.future);
    expect(find.text(tr('cache_cleared')), findsNothing);
    completed.complete(true);
    await tester.pump();
    expect(find.text(tr('cache_cleared')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('does not report success for skipped cleanup', (tester) async {
    await showClearDialog(tester, () async => false);
    await tester.pump();
    expect(find.text(tr('cache_cleared')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reports failure without success on file errors', (tester) async {
    await showClearDialog(
      tester,
      () async => throw const FileSystemException('test'),
    );
    await tester.pump();
    expect(find.text(tr('cache_cleared')), findsNothing);
    expect(find.text(tr('cache_clear_failed')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('late cleanup completion after leaving screen is safe', (
    tester,
  ) async {
    final completed = Completer<bool?>();
    await showClearDialog(tester, () => completed.future);
    await tester.pumpWidget(const SizedBox.shrink());
    completed.complete(true);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
