import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/screens/lyrics_screen.dart';
import 'package:shiki/widgets/synced_lyrics_view.dart';

void main() {
  final lines = [
    for (var i = 0; i < 12; i++)
      LyricLine(
        Duration(seconds: i * 5),
        '',
        i == 4
            ? 'Это длинная строка, которая должна полностью помещаться на экране телефона, даже когда она выделена'
            : 'Строка номер ${i + 1}',
      ),
  ];
  const capture = bool.fromEnvironment('SHIKI_MOBILE_CAPTURE');
  setUpAll(() async {
    final font = File('C:/Windows/Fonts/segoeui.ttf');
    if (!await font.exists()) return;
    final loader = FontLoader('MobileLyricsTest');
    loader.addFont(
      Future.value(ByteData.sublistView(await font.readAsBytes())),
    );
    await loader.load();
  });

  Future<void> show(
    WidgetTester tester, {
    double width = 375,
    double scale = 1,
    int active = 4,
    bool reducedMotion = false,
    bool settle = true,
    ValueChanged<Duration>? onSeek,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 812);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          textTheme: ThemeData.dark().textTheme.apply(
            fontFamily: 'MobileLyricsTest',
          ),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: reducedMotion,
          ),
          child: child!,
        ),
        home: RepaintBoundary(
          key: const ValueKey('mobile_lyrics_capture'),
          child: Scaffold(
            appBar: AppBar(title: const Text('Текст песни')),
            body: SyncedLyricsView(
              lines: lines,
              activeIndex: active,
              onSeek: onSeek ?? (_) {},
            ),
          ),
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  for (final width in [320.0, 375.0, 768.0, 800.0, 1024.0, 1440.0]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('long active cue fits $width at text scale $scale', (
        tester,
      ) async {
        await show(tester, width: width, scale: scale);
        final text = find.text(lines[4].txt);
        final paragraph = tester.renderObject<RenderParagraph>(text);
        final row = tester.getRect(find.byKey(const ValueKey('lyric_cue_4')));
        final rect = tester.getRect(text);
        expect(paragraph.didExceedMaxLines, isFalse);
        expect(paragraph.maxLines, isNull);
        expect(rect.left, greaterThanOrEqualTo(20));
        expect(rect.right, lessThanOrEqualTo(width - 20));
        expect(rect.top, greaterThanOrEqualTo(row.top + 11));
        expect(rect.bottom, lessThanOrEqualTo(row.bottom - 11));
        final viewport = tester.getRect(
          find.byKey(const ValueKey('mobile_synced_lyrics')),
        );
        expect((row.center.dy - viewport.center.dy).abs(), lessThan(1));
        expect(tester.takeException(), isNull);
        if (capture && width == 375 && scale == 1) {
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('mobile_lyrics_capture')),
            );
            final image = await boundary.toImage();
            try {
              final png = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final directory = Directory('.omx/mobile-qa');
              await directory.create(recursive: true);
              await File(
                '${directory.path}/lyrics-375.png',
              ).writeAsBytes(png!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
      });
    }
  }

  testWidgets('highlight scrolls smoothly to the real variable-height cue', (
    tester,
  ) async {
    await show(tester, active: 3);
    final scroll = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    final before = scroll.pixels;
    await show(tester, active: 4, settle: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(scroll.pixels, greaterThan(before));
    await tester.pumpAndSettle();
    final row = tester.getRect(find.byKey(const ValueKey('lyric_cue_4')));
    final viewport = tester.getRect(
      find.byKey(const ValueKey('mobile_synced_lyrics')),
    );
    expect((row.center.dy - viewport.center.dy).abs(), lessThan(1));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('cue tap seeks and reduced motion has no lingering animation', (
    tester,
  ) async {
    Duration? requested;
    await show(
      tester,
      reducedMotion: true,
      onSeek: (value) => requested = value,
    );
    await tester.tap(find.text(lines[4].txt));
    expect(requested, lines[4].time);
    final styles = tester.widgetList<AnimatedDefaultTextStyle>(
      find.descendant(
        of: find.byType(SyncedLyricsView),
        matching: find.byType(AnimatedDefaultTextStyle),
      ),
    );
    expect(styles.every((style) => style.duration == Duration.zero), isTrue);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('phone and desktop overlays use complete responsive lyrics', (
    tester,
  ) async {
    final oldLines = globalLyrics,
        oldLine = currentLine,
        oldTrack = activeTrackNotifier.value;
    final oldLoading = lrcLoading;
    addTearDown(() {
      globalLyrics = oldLines;
      currentLine = oldLine;
      activeTrackNotifier.value = oldTrack;
      lrcLoading = oldLoading;
      debugDefaultTargetPlatformOverride = null;
    });
    globalLyrics = lines;
    currentLine = 4;
    lrcLoading = false;
    activeTrackNotifier.value = {'id': 1, 'title': 'Track', 'artists': []};
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(
      MaterialApp(home: PresentationOverlay(onSeekRequested: (_) {})),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SyncedLyricsView), findsOneWidget);
    final replacement = [
      for (var i = 0; i < 15; i++)
        LyricLine(
          Duration(seconds: i * 3),
          '',
          i == 4
              ? 'Совершенно новый длинный текст другого трека, которому нужна новая высота строки'
              : 'Другой трек, строка $i',
        ),
    ];
    globalLyrics
      ..clear()
      ..addAll(replacement);
    uiSignal.value++;
    await tester.pumpAndSettle();
    expect(find.text(replacement[4].txt), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.pumpWidget(
      MaterialApp(home: PresentationOverlay(onSeekRequested: (_) {})),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SyncedLyricsView), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}
