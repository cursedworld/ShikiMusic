import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/localization.dart';
import 'package:shiki/screens/settings_screen.dart';
import 'package:shiki/track_transition_mode.dart';

import 'fixtures/animated_background.dart';

class _WallpaperPicker extends FilePicker {
  File? selected;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    expect(type, FileType.custom);
    expect(allowedExtensions, containsAll(['gif', 'mp4', 'png']));
    expect(withData, isFalse);
    final file = selected;
    if (file == null) return null;
    return FilePickerResult([
      PlatformFile(
        name: file.uri.pathSegments.last,
        path: file.path,
        size: file.lengthSync(),
      ),
    ]);
  }
}

void main() {
  late Directory directory;
  late Color oldAccent;
  late String oldLanguage;
  late String? oldBackground;
  late bool oldVinyl, oldVideo, oldGitHub, oldLyrics, oldReplayGain;
  late TrackTransitionMode oldMode;
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
    oldMode = trackTransitionModeNotifier.value;
    oldReplayGain = replayGainEnabledNotifier.value;
    accentColorNotifier.value = themeColors['color_purple']!;
    languageNotifier.value = 'ru';
    customBackgroundNotifier.value = null;
    vinylRotationNotifier.value = false;
    playVideoClipNotifier.value = true;
    discordShowGitHubButtonNotifier.value = false;
    discordLyricsStatusNotifier.value = true;
    trackTransitionModeNotifier.value = TrackTransitionMode.off;
    replayGainEnabledNotifier.value = false;
  });
  tearDown(() async {
    accentColorNotifier.value = oldAccent;
    languageNotifier.value = oldLanguage;
    customBackgroundNotifier.value = oldBackground;
    vinylRotationNotifier.value = oldVinyl;
    playVideoClipNotifier.value = oldVideo;
    discordShowGitHubButtonNotifier.value = oldGitHub;
    discordLyricsStatusNotifier.value = oldLyrics;
    trackTransitionModeNotifier.value = oldMode;
    replayGainEnabledNotifier.value = oldReplayGain;
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

  testWidgets('chooses a GIF intact and keeps it if a replacement is invalid', (
    tester,
  ) async {
    final picker = _WallpaperPicker();
    FilePicker.platform = picker;
    addTearDown(() => picker.selected = null);
    final gif = testGif();
    final original = File('${directory.path}/picked.GIF')
      ..writeAsBytesSync(gif);
    picker.selected = original;

    await show(tester, width: 375);
    await drive(tester, () => editable(tester));
    final row = find.byKey(const ValueKey('settings_background'));
    Future<void> pick() async {
      final onTap = tester
          .widget<InkWell>(
            find.descendant(of: row, matching: find.byType(InkWell)).first,
          )
          .onTap!;
      // The shared persistence queue must not outlive a test's fake clock.
      await tester.runAsync(() async => onTap());
    }

    await pick();
    await drive(
      tester,
      () =>
          customBackgroundNotifier.value != null &&
          find.text(tr('settings_background_preparing')).evaluate().isEmpty,
    );
    final saved = customBackgroundNotifier.value!;
    expect(saved, endsWith('.gif'));
    expect(File('${directory.path}/$saved').readAsBytesSync(), gif);
    expect(original.readAsBytesSync(), gif);
    final settings = File('${directory.path}/shiki_settings.json');
    expect(
      (jsonDecode(settings.readAsStringSync()) as Map)['customBackground'],
      saved,
    );

    picker.selected = File('${directory.path}/bad.mp4')
      ..writeAsStringSync('not MP4');
    await pick();
    await drive(
      tester,
      () => find.text(tr('settings_background_invalid')).evaluate().isNotEmpty,
    );
    expect(customBackgroundNotifier.value, saved);
    expect(
      (jsonDecode(settings.readAsStringSync()) as Map)['customBackground'],
      saved,
    );
    expect(File('${directory.path}/$saved').existsSync(), isTrue);
  });

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets('video setting availability on $platform', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await show(tester);
        await drive(tester, () => editable(tester));
        final fade = find.byKey(const ValueKey('track_transition_setting'));
        await tester.scrollUntilVisible(
          fade,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(
          find.descendant(of: fade, matching: find.text('Выкл.')),
          findsOneWidget,
        );
        if (platform != TargetPlatform.android) {
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('vinyl_rotation_switch')),
            200,
            scrollable: find.byType(Scrollable).first,
          );
        }
        expect(
          find.byKey(const ValueKey('vinyl_rotation_switch')),
          platform == TargetPlatform.android ? findsNothing : findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('video_clip_switch')),
          platform == TargetPlatform.android ? findsNothing : findsOneWidget,
        );
        expect(playVideoClipNotifier.value, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('ReplayGain is off in old settings and saves a live change', (
    tester,
  ) async {
    final file = File('${directory.path}/shiki_settings.json');
    file.writeAsStringSync(jsonEncode({'trackTransitionMode': 'crossfade'}));
    final row = find.byKey(const ValueKey('replay_gain_switch'));
    final toggle = find.descendant(of: row, matching: find.byType(Switch));

    Future<void> reveal() async {
      await show(tester, width: 320);
      await drive(tester, () => editable(tester));
      await tester.scrollUntilVisible(
        row,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
    }

    await reveal();
    expect(tester.widget<Switch>(toggle).value, isFalse);
    await tester.runAsync(() async {
      tester.widget<Switch>(toggle).onChanged!(true);
    });
    expect(replayGainEnabledNotifier.value, isTrue);
    await drive(tester, () {
      try {
        return jsonDecode(file.readAsStringSync())['replayGainEnabled'] == true;
      } on FileSystemException catch (error) {
        if (error.osError?.errorCode == 32) return false;
        rethrow;
      }
    });
    expect(
      jsonDecode(file.readAsStringSync())['trackTransitionMode'],
      'crossfade',
    );
    await tester.pumpWidget(const SizedBox());
    replayGainEnabledNotifier.value = false;
    await reveal();
    expect(tester.widget<Switch>(toggle).value, isTrue);
    expect(replayGainEnabledNotifier.value, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('legacy fade migrates; crossfade and off save and reload', (
    tester,
  ) async {
    final file = File('${directory.path}/shiki_settings.json');
    file.writeAsStringSync(
      jsonEncode({'playVideoClip': true, 'smoothTrackTransitions': true}),
    );
    final fade = find.byKey(const ValueKey('track_transition_setting'));

    Future<void> open() async {
      await show(tester, width: 320);
      await drive(tester, () => editable(tester));
      await tester.scrollUntilVisible(
        fade,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(fade);
      await tester.pumpAndSettle();
    }

    bool saved(TrackTransitionMode value) {
      try {
        final data =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        return data['trackTransitionMode'] == value.name &&
            data['smoothTrackTransitions'] ==
                (value != TrackTransitionMode.off) &&
            data['playVideoClip'] == true;
      } on FileSystemException catch (error) {
        if (error.osError?.errorCode == 32) return false;
        rethrow;
      }
    }

    Future<void> selectMode(TrackTransitionMode value) async {
      // Keep the static settings write queue on the real IO zone so it
      // can also be used after this widget test's fake clock is gone.
      final row = tester.widget<InkWell>(
        find.descendant(of: fade, matching: find.byType(InkWell)),
      );
      await tester.runAsync(() async {
        row.onTap!();
      });
      await tester.pumpAndSettle();
      for (final option in TrackTransitionMode.values) {
        expect(
          find.byKey(ValueKey('track_transition_option_${option.name}')),
          findsOneWidget,
        );
      }
      await tester.tap(
        find.byKey(ValueKey('track_transition_option_${value.name}')),
      );
      await tester.pumpAndSettle();
      await drive(tester, () => saved(value));
    }

    await open();
    expect(trackTransitionModeNotifier.value, TrackTransitionMode.fade);
    await selectMode(TrackTransitionMode.crossfade);
    expect(trackTransitionModeNotifier.value, TrackTransitionMode.crossfade);

    await tester.pumpWidget(const SizedBox());
    trackTransitionModeNotifier.value = TrackTransitionMode.off;
    await open();
    expect(trackTransitionModeNotifier.value, TrackTransitionMode.crossfade);
    expect(find.text('Кроссфейд · 0,6 с'), findsOneWidget);

    await selectMode(TrackTransitionMode.off);
    expect(trackTransitionModeNotifier.value, TrackTransitionMode.off);
  });

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
          'smoothTrackTransitions': true,
          'trackTransitionMode': 'crossfade',
          'discordShowGitHubButton': false,
          'discordLyricsStatus': true,
          'serverBaseUrl': 'http://localhost:8000',
        }),
      );
      await show(tester);
      await drive(tester, () => editable(tester));
      await tester.tap(swatch('blue'));
      late Map<String, dynamic> saved;
      await drive(tester, () {
        try {
          final current =
              jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
          if (current['themeColor'] != 'color_blue') return false;
          saved = current;
          return true;
        } on FileSystemException catch (error) {
          // Windows may briefly lock the atomic replacement during this poll.
          if (error.osError?.errorCode == 32) return false;
          rethrow;
        }
      });
      expect(saved['language'], 'en');
      expect(saved['playVideoClip'], isTrue);
      expect(saved['smoothTrackTransitions'], isTrue);
      expect(saved['trackTransitionMode'], 'crossfade');
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
