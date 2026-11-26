import 'dart:collection';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/lyrics_text_size.dart';
import 'package:shiki/screens/lyrics_screen.dart';
import 'package:shiki/widgets/synced_lyrics_view.dart';

class _MeasuredLyrics extends ListBase<LyricLine> {
  _MeasuredLyrics(this.cues);

  final List<LyricLine> cues;
  int passes = 0;

  @override
  int get length => cues.length;
  @override
  set length(int value) => throw UnsupportedError('Read-only cues');
  @override
  LyricLine operator [](int index) => cues[index];
  @override
  void operator []=(int index, LyricLine value) =>
      throw UnsupportedError('Read-only cues');
  @override
  Iterator<LyricLine> get iterator {
    passes++;
    return cues.iterator;
  }
}

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
    List<LyricLine>? cues,
    LyricsTextSize textSize = LyricsTextSize.normal,
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
              lines: cues ?? lines,
              activeIndex: active,
              onSeek: onSeek ?? (_) {},
              textSize: textSize,
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
    final cues = _MeasuredLyrics(lines);
    await show(tester, active: 3, cues: cues);
    expect(cues.passes, 1);
    final scroll = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    final before = scroll.pixels;
    await show(tester, active: 4, settle: false, cues: cues);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(scroll.pixels, greaterThan(before));
    await tester.pumpAndSettle();
    final row = tester.getRect(find.byKey(const ValueKey('lyric_cue_4')));
    final viewport = tester.getRect(
      find.byKey(const ValueKey('mobile_synced_lyrics')),
    );
    expect((row.center.dy - viewport.center.dy).abs(), lessThan(1));
    expect(
      cues.passes,
      1,
      reason: 'Changing the active cue must not remeasure',
    );
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

  testWidgets('resize remeasures once and keeps the same active cue and seek', (
    tester,
  ) async {
    final cues = _MeasuredLyrics(lines);
    final text = find.text(cues[4].txt);
    final cue = find.byKey(const ValueKey('lyric_cue_4'));
    final viewport = find.byKey(const ValueKey('mobile_synced_lyrics'));
    Duration? sought;
    final heights = <double>[];
    for (final (size, fontSize) in [
      (LyricsTextSize.normal, 32.0),
      (LyricsTextSize.large, 40.0),
      (LyricsTextSize.small, 28.0),
    ]) {
      await show(
        tester,
        width: 320,
        scale: 2,
        cues: cues,
        textSize: size,
        onSeek: (value) => sought = value,
      );
      final paragraph = tester.renderObject<RenderParagraph>(text);
      final row = tester.getRect(cue);
      final body = tester.getRect(text);
      expect(paragraph.text.style?.fontSize, fontSize);
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(body.top, greaterThanOrEqualTo(row.top + 11));
      expect(body.bottom, lessThanOrEqualTo(row.bottom - 11));
      expect(row.center.dy, closeTo(tester.getCenter(viewport).dy, 1));
      heights.add(row.height);
      expect(cues.passes, heights.length);
      await tester.tap(cue);
      expect(sought, cues[4].time);
    }
    expect(heights[1], greaterThan(heights[0]));
    expect(heights[2], lessThan(heights[0]));
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone and desktop overlays use complete responsive lyrics', (
    tester,
  ) async {
    final oldLines = globalLyrics,
        oldLine = currentLine,
        oldTrack = activeTrackNotifier.value;
    final oldLoading = lrcLoading;
    final oldPlainLyrics = noLrcData;
    final oldSize = lyricsTextSizeNotifier.value;
    addTearDown(() {
      globalLyrics = oldLines;
      currentLine = oldLine;
      activeTrackNotifier.value = oldTrack;
      lrcLoading = oldLoading;
      noLrcData = oldPlainLyrics;
      lyricsTextSizeNotifier.value = oldSize;
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    globalLyrics = List.of(lines);
    currentLine = 4;
    lrcLoading = false;
    activeTrackNotifier.value = {'id': 1, 'title': 'Track', 'artists': []};
    const plain = 'Слова песни без меток времени';
    final syncedView = find.byType(SyncedLyricsView);
    double? fontSize(String text) => tester
        .renderObject<RenderParagraph>(find.text(text))
        .text
        .style
        ?.fontSize;

    Future<void> checkPlainLyrics() async {
      globalLyrics = [];
      noLrcData = plain;
      uiSignal.value++;
      await tester.pumpAndSettle();
      expect(syncedView, findsNothing);
      expect(fontSize(plain), 30);
      lyricsTextSizeNotifier.value = LyricsTextSize.small;
      await tester.pumpAndSettle();
      expect(fontSize(plain), 21);
      expect(fontSize('Track'), 24);
      expect(tester.takeException(), isNull);
    }

    lyricsTextSizeNotifier.value = LyricsTextSize.large;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 812);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(
      MaterialApp(home: PresentationOverlay(onSeekRequested: (_) {})),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<SyncedLyricsView>(syncedView).textSize,
      LyricsTextSize.large,
    );
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
    expect(fontSize(replacement[4].txt), 40);
    await checkPlainLyrics();
    await tester.pumpWidget(const SizedBox());
    globalLyrics = replacement;
    lyricsTextSizeNotifier.value = LyricsTextSize.large;
    tester.view.physicalSize = const Size(1200, 812);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.pumpWidget(
      MaterialApp(home: PresentationOverlay(onSeekRequested: (_) {})),
    );
    await tester.pumpAndSettle();
    expect(fontSize(replacement[4].txt), 40);
    await checkPlainLyrics();
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}
