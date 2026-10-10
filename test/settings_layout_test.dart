import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/screens/settings_screen.dart';

void main() {
  late Directory directory;
  late Color oldAccent;
  late String oldLanguage;
  late String? oldBackground;
  late bool oldVinyl, oldVideo, oldGitHub, oldLyrics;
  const capture = bool.fromEnvironment('SHIKI_SETTINGS_SCREENSHOT');
  const fontPath = String.fromEnvironment('SHIKI_TEST_FONT');
  const iconsPath = String.fromEnvironment('SHIKI_TEST_ICONS');

  setUpAll(() async {
    if (!capture) return;
    for (final entry in {
      'SettingsTest': fontPath,
      'MaterialIcons': iconsPath,
    }.entries) {
      if (entry.value.isEmpty) continue;
      final font = FontLoader(entry.key);
      font.addFont(
        Future.value(
          ByteData.sublistView(await File(entry.value).readAsBytes()),
        ),
      );
      await font.load();
    }
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shiki-settings-layout-');
    oldAccent = accentColorNotifier.value;
    oldLanguage = languageNotifier.value;
    oldBackground = customBackgroundNotifier.value;
    oldVinyl = vinylRotationNotifier.value;
    oldVideo = playVideoClipNotifier.value;
    oldGitHub = discordShowGitHubButtonNotifier.value;
    oldLyrics = discordLyricsStatusNotifier.value;
    accentColorNotifier.value = themeColors['color_purple']!;
    languageNotifier.value = 'ru';
    customBackgroundNotifier.value = null;
    vinylRotationNotifier.value = false;
    playVideoClipNotifier.value = true;
    discordShowGitHubButtonNotifier.value = false;
    discordLyricsStatusNotifier.value = true;
  });
  tearDown(() async {
    accentColorNotifier.value = oldAccent;
    languageNotifier.value = oldLanguage;
    customBackgroundNotifier.value = oldBackground;
    vinylRotationNotifier.value = oldVinyl;
    playVideoClipNotifier.value = oldVideo;
    discordShowGitHubButtonNotifier.value = oldGitHub;
    discordLyricsStatusNotifier.value = oldLyrics;
    final prefix =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}shiki-settings-layout-';
    if (!directory.absolute.path.startsWith(prefix)) {
      throw StateError('Unexpected test directory');
    }
    await directory.delete(recursive: true);
  });

  Finder swatch(String color) => find.byKey(ValueKey('theme_color_$color'));
  bool selected(WidgetTester tester, String color) =>
      tester.widget<Semantics>(swatch(color)).properties.selected == true;
  bool editable(WidgetTester tester) =>
      tester
          .widget<InkResponse>(
            find.descendant(
              of: swatch('purple'),
              matching: find.byType(InkResponse),
            ),
          )
          .onTap !=
      null;

  Future<void> drive(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
      if (done()) return;
    }
    fail('Settings operation did not finish');
  }

  Future<void> show(
    WidgetTester tester, {
    double width = 1024,
    double scale = 1,
    Future<Directory> Function()? provider,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('settings_screenshot'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: capture && fontPath.isNotEmpty
                  ? 'SettingsTest'
                  : null,
            ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: SettingsScreen(
            onClearCache: () => true,
            dataDirectoryProvider: provider ?? () async => directory,
          ),
        ),
      ),
    );
  }

  testWidgets('first frame shows the current purple selection, not red', (
    tester,
  ) async {
    final pending = Completer<Directory>();
    await show(tester, provider: () => pending.future);
    expect(selected(tester, 'purple'), isTrue);
    expect(selected(tester, 'red'), isFalse);
    expect(editable(tester), isFalse);
    await tester.tap(swatch('red'));
    expect(accentColorNotifier.value, themeColors['color_purple']);
    pending.complete(directory);
    await drive(tester, () => editable(tester));
    expect(selected(tester, 'purple'), isTrue);
    expect(File('${directory.path}/shiki_settings.json').existsSync(), isFalse);
  });

  testWidgets('custom accent is not temporarily shown as a preset', (
    tester,
  ) async {
    accentColorNotifier.value = const Color(0xFF8765AB);
    final pending = Completer<Directory>();
    await show(tester, provider: () => pending.future);
    expect(find.text('Свой цвет'), findsOneWidget);
    for (final name in [
      'red',
      'blue',
      'purple',
      'green',
      'orange',
      'pink',
      'teal',
      'black',
    ]) {
      expect(selected(tester, name), isFalse);
    }
    pending.complete(directory);
    await drive(tester, () => editable(tester));
  });

  testWidgets(
    'palette persists a new color without resetting other loaded settings',
    (tester) async {
      final file = File('${directory.path}/shiki_settings.json');
      file.writeAsStringSync(
        jsonEncode({
          'themeColor': 'color_purple',
          'language': 'en',
          'vinylRotation': false,
          'playVideoClip': true,
          'discordShowGitHubButton': false,
          'discordLyricsStatus': true,
          'serverBaseUrl': 'http://localhost:8000',
        }),
      );
      await show(tester);
      await drive(tester, () => editable(tester));
      await tester.tap(swatch('blue'));
      await drive(
        tester,
        () => jsonDecode(file.readAsStringSync())['themeColor'] == 'color_blue',
      );
      final saved = jsonDecode(file.readAsStringSync());
      expect(saved['language'], 'en');
      expect(saved['playVideoClip'], isTrue);
      expect(saved['vinylRotation'], isFalse);
      expect(saved['discordShowGitHubButton'], isFalse);
      expect(saved['discordLyricsStatus'], isTrue);
      expect(selected(tester, 'blue'), isTrue);
      expect(accentColorNotifier.value, themeColors['color_blue']);
    },
  );

  testWidgets('unreadable settings stay protected until a successful retry', (
    tester,
  ) async {
    final file = File('${directory.path}/shiki_settings.json')
      ..writeAsStringSync('{broken');
    await show(tester);
    await drive(
      tester,
      () => find
          .textContaining('Не удалось прочитать настройки')
          .evaluate()
          .isNotEmpty,
    );
    expect(editable(tester), isFalse);
    await tester.tap(swatch('red'));
    expect(file.readAsStringSync(), '{broken');
    file.writeAsStringSync(jsonEncode({'themeColor': 'color_purple'}));
    await tester.tap(find.text('Повторить'));
    await drive(tester, () => editable(tester));
    expect(selected(tester, 'purple'), isTrue);
  });

  for (final width in [320.0, 375.0, 768.0, 1440.0]) {
    testWidgets('unified settings fits width $width', (tester) async {
      await show(tester, width: width);
      await drive(tester, () => editable(tester));
      expect(tester.takeException(), isNull);
      if (capture && (width == 375 || width == 1440)) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('settings_screenshot')),
          );
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            await Directory('build').create(recursive: true);
            await File(
              'build/settings_${width.toInt()}.png',
            ).writeAsBytes(png!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }
      await tester.scrollUntilVisible(
        find.text('О приложении'),
        220,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('large text, language picker and server editor remain usable', (
    tester,
  ) async {
    await show(tester, width: 320, scale: 2);
    await drive(tester, () => editable(tester));
    await tester.ensureVisible(find.byKey(const ValueKey('settings_language')));
    await tester.tap(find.byKey(const ValueKey('settings_language')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(languageNotifier.value, 'en');
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings_server')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('settings_server')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings_server')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('server_address')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  });
}
