import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/screens/settings_screen.dart';

void main() {
  late Directory directory;
  late bool previousLyricsMode;
  late bool previousGitHub;
  late bool previousVideo;
  late bool previousVinyl;
  late Color previousAccent;
  late String previousLanguage;
  late String? previousBackground;
  const switchKey = ValueKey('discord_lyrics_status_switch');

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'shiki_settings_rpc_test_',
    );
    previousLyricsMode = discordLyricsStatusNotifier.value;
    previousGitHub = discordShowGitHubButtonNotifier.value;
    previousVideo = playVideoClipNotifier.value;
    previousVinyl = vinylRotationNotifier.value;
    previousAccent = accentColorNotifier.value;
    previousLanguage = languageNotifier.value;
    previousBackground = customBackgroundNotifier.value;
    discordLyricsStatusNotifier.value = false;
    discordShowGitHubButtonNotifier.value = true;
    languageNotifier.value = 'ru';
    customBackgroundNotifier.value = null;
  });

  tearDown(() async {
    discordLyricsStatusNotifier.value = previousLyricsMode;
    discordShowGitHubButtonNotifier.value = previousGitHub;
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

  Widget screen({Key? key}) => MaterialApp(
    home: SettingsScreen(
      key: key,
      onClearCache: () => true,
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

    await tester.tap(find.byKey(switchKey));
    await tester.pump();
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

    await tester.tap(find.byKey(switchKey));
    await tester.pump();
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
