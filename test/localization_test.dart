import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/localization.dart';

void main() {
  test(
    'every interface message has all three translations and matching placeholders',
    () {
      final previous = languageNotifier.value;
      addTearDown(() => languageNotifier.value = previous);
      for (final entry in translationCatalog.entries) {
        expect(
          entry.value.keys,
          containsAll(['ru', 'en', 'ja']),
          reason: entry.key,
        );
        final placeholders = RegExp(
          r'\{\w+\}',
        ).allMatches(entry.value['en']!).map((match) => match.group(0)).toSet();
        for (final language in ['ru', 'en', 'ja']) {
          languageNotifier.value = language;
          expect(
            tr(entry.key).trim(),
            isNotEmpty,
            reason: '${entry.key}: $language',
          );
          expect(
            RegExp(
              r'\{\w+\}',
            ).allMatches(tr(entry.key)).map((match) => match.group(0)).toSet(),
            placeholders,
            reason: '${entry.key}: $language',
          );
        }
      }
    },
  );

  test('literal translation keys used by the app exist', () {
    final pattern = RegExp("\\btr\\(\\s*['\"]([a-z0-9_]+)['\"]\\s*\\)");
    for (final file in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      for (final match in pattern.allMatches(file.readAsStringSync())) {
        expect(translationCatalog, contains(match.group(1)), reason: file.path);
      }
    }
  });

  for (final locale in appSupportedLocales) {
    testWidgets('standard buttons follow ${locale.languageCode}', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          supportedLocales: appSupportedLocales,
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(appBar: AppBar(leading: const BackButton())),
        ),
      );
      await tester.pumpAndSettle();
      final expected = switch (locale.languageCode) {
        'ru' => 'Назад',
        'ja' => '戻る',
        _ => 'Back',
      };
      expect(find.byTooltip(expected), findsOneWidget);
      final context = tester.element(find.byType(BackButton));
      final strings = MaterialLocalizations.of(context);
      if (locale.languageCode != 'en') {
        expect(strings.cancelButtonLabel, isNot('CANCEL'));
        expect(strings.selectAllButtonLabel, isNot('Select all'));
      }
    });
  }
}
