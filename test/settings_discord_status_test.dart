import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/discord_status.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/screens/settings_screen.dart';

void main() {
  late Directory directory;
  late bool previousLyricsMode;
  late bool previousGitHub;
  late DiscordPrivacy previousPrivacy;
  late bool previousVideo;
  late bool previousVinyl;
  late Color previousAccent;
  late String previousLanguage;
  late String? previousBackground;
  const switchKey = ValueKey('discord_lyrics_status_switch');
  const presenceKey = ValueKey('discord_presence_switch');
  const pauseKey = ValueKey('discord_hide_on_pause_switch');

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'shiki_settings_rpc_test_',
    );
    previousLyricsMode = discordLyricsStatusNotifier.value;
    previousGitHub = discordShowGitHubButtonNotifier.value;
    previousPrivacy = discordPrivacyNotifier.value;
    previousVideo = playVideoClipNotifier.value;
    previousVinyl = vinylRotationNotifier.value;
    previousAccent = accentColorNotifier.value;
    previousLanguage = languageNotifier.value;
    previousBackground = customBackgroundNotifier.value;
    discordLyricsStatusNotifier.value = false;
    discordShowGitHubButtonNotifier.value = true;
    discordPrivacyNotifier.value = defaultDiscordPrivacy;
    languageNotifier.value = 'ru';
    customBackgroundNotifier.value = null;
  });

  tearDown(() async {
    discordLyricsStatusNotifier.value = previousLyricsMode;
    discordShowGitHubButtonNotifier.value = previousGitHub;
    discordPrivacyNotifier.value = previousPrivacy;
    playVideoClipNotifier.value = previousVideo;
    vinylRotationNotifier.value = previousVinyl;
    accentColorNotifier.value = previousAccent;
    languageNotifier.value = previousLanguage;
    customBackgroundNotifier.value = previousBackground;
    final prefix =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}shiki_settings_rpc_test_';
    if (!directory.absolute.path.startsWith(prefix)) {
      throw StateError('Unexpected test directory');
    }
    await directory.delete(recursive: true);
  });

  Widget screen({Key? key, double textScale = 1}) => MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: SettingsScreen(
      key: key,
      dataDirectoryProvider: () async => directory,
    ),
  );

  Future<void> driveUntil(WidgetTester tester, bool Function() done) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
      if (done()) return;
    }
    fail('Settings I/O did not complete.');
  }

  Future<void> showSwitch(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.byKey(switchKey),
      250,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 20,
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapSavingSwitch(WidgetTester tester, Finder finder) async {
    // The settings write queue is shared across screens and must not retain
    // callbacks scheduled on an earlier widget test's fake clock.
    await tester.runAsync(() async => tester.tap(finder));
    await tester.pumpAndSettle();
  }

  bool savedLyricsModeIs(File file, bool value) {
    try {
      return jsonDecode(file.readAsStringSync())['discordLyricsStatus'] ==
          value;
    } on FileSystemException {
      return false;
    }
  }

  testWidgets('the switch updates shared state, persists, and restores', (
    tester,
  ) async {
    final file = File('${directory.path}/shiki_settings.json');
    file.writeAsStringSync(
      jsonEncode({
        'language': 'ru',
        'themeColor': 'color_red',
        'discordShowGitHubButton': false,
        'discordLyricsStatus': false,
      }),
    );
    await tester.pumpWidget(screen());
    await driveUntil(tester, () => !discordShowGitHubButtonNotifier.value);
    await showSwitch(tester);
    expect(tester.widget<SwitchListTile>(find.byKey(switchKey)).value, isFalse);

    await tapSavingSwitch(tester, find.byKey(switchKey));
    expect(discordLyricsStatusNotifier.value, isTrue);
    await driveUntil(tester, () => savedLyricsModeIs(file, true));
    final saved = jsonDecode(file.readAsStringSync()) as Map;
    expect(saved['discordShowGitHubButton'], isFalse);
    expect(saved['language'], 'ru');

    await tester.pumpWidget(const SizedBox.shrink());
    discordLyricsStatusNotifier.value = false;
    await tester.pumpWidget(screen(key: const ValueKey('restored')));
    await driveUntil(tester, () => discordLyricsStatusNotifier.value);
    await showSwitch(tester);
    expect(tester.widget<SwitchListTile>(find.byKey(switchKey)).value, isTrue);

    await tapSavingSwitch(tester, find.byKey(switchKey));
    await driveUntil(tester, () => savedLyricsModeIs(file, false));
    expect(discordLyricsStatusNotifier.value, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy settings retain track-and-artist status by default', (
    tester,
  ) async {
    final file = File('${directory.path}/shiki_settings.json');
    file.writeAsStringSync(
      jsonEncode({'language': 'ru', 'discordShowGitHubButton': false}),
    );
    discordLyricsStatusNotifier.value = true;
    await tester.pumpWidget(screen());
    await driveUntil(tester, () => !discordLyricsStatusNotifier.value);
    await showSwitch(tester);
    expect(tester.widget<SwitchListTile>(find.byKey(switchKey)).value, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('Discord privacy choices persist and restore as one preference', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final file = File('${directory.path}/shiki_settings.json')
        ..writeAsStringSync(
          jsonEncode({'language': 'ru', 'discordShowGitHubButton': false}),
        );
      final presence = find.byKey(presenceKey);
      final pause = find.byKey(pauseKey);
      SwitchListTile tile(Finder finder) =>
          tester.widget<SwitchListTile>(finder);

      Future<void> open() async {
        await tester.pumpWidget(screen());
        await tester.scrollUntilVisible(
          presence,
          230,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
      }

      await open();
      await driveUntil(tester, () => tile(presence).onChanged != null);
      expect(tile(presence).value, isTrue);
      expect(tile(pause).value, isFalse);
      await tester.ensureVisible(pause);
      await tester.pumpAndSettle();
      await tapSavingSwitch(tester, pause);
      await tester.ensureVisible(presence);
      await tester.pumpAndSettle();
      await tapSavingSwitch(tester, presence);
      final hidden = (enabled: false, hideOnPause: true);
      expect(discordPrivacyNotifier.value, hidden);
      expect(tile(pause).onChanged, isNull);
      Map? saved;
      await driveUntil(tester, () {
        try {
          saved = jsonDecode(file.readAsStringSync()) as Map;
          return discordPrivacyFromSettings(saved!) == hidden;
        } on FileSystemException {
          return false;
        }
      });
      expect(saved!['discordShowGitHubButton'], isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      discordPrivacyNotifier.value = discordPrivacyFromSettings(saved!);
      await open();
      expect(tile(presence).value, isFalse);
      expect(tile(pause).value, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the new Discord privacy controls are absent on Android', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(screen());
      await tester.scrollUntilVisible(
        find.text('Discord'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(presenceKey), findsNothing);
      expect(find.byKey(pauseKey), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  for (final (language, presenceText, pauseText) in [
    ('ru', 'Показывать, что я слушаю', 'Скрывать трек на паузе'),
    ('en', 'Show what I’m listening to', 'Hide track when paused'),
    ('ja', '聴いている曲を表示', '一時停止中は曲を非表示'),
  ]) {
    testWidgets(
      'Discord privacy controls fit at 320 px with 200% text in $language',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        try {
          languageNotifier.value = language;
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(320, 812);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          await tester.pumpWidget(screen(textScale: 2));
          for (final (key, label) in [
            (presenceKey, presenceText),
            (pauseKey, pauseText),
          ]) {
            final row = find.byKey(key);
            await tester.scrollUntilVisible(
              row,
              170,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
            expect(
              find.descendant(of: row, matching: find.text(label)),
              findsOneWidget,
            );
            final rect = tester.getRect(row);
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(320));
            expect(rect.height, greaterThanOrEqualTo(44));
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }

  for (final width in [375.0, 768.0, 1024.0, 1440.0]) {
    testWidgets(
      'Discord switch fits at width $width with an accessible target',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(screen());
        await showSwitch(tester);
        final rect = tester.getRect(find.byKey(switchKey));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(width));
        expect(rect.height, greaterThanOrEqualTo(44));
        final semantics = tester.ensureSemantics();
        final node = tester.getSemantics(find.byKey(switchKey));
        expect(node.label, contains('Текст песни в статусе Discord'));
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }
}
