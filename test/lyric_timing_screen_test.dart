import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/localization.dart';
import 'package:shiki/lrc_parser.dart';
import 'package:shiki/lyric_timing.dart';
import 'package:shiki/lyric_timing_proposals.dart';
import 'package:shiki/screens/lyrics_screen.dart';
import 'package:shiki/widgets/lyric_timing_controls.dart';
import 'package:shiki/widgets/synced_lyrics_view.dart';

class _RecordedOffsets extends LyricTimingStore {
  _RecordedOffsets() : super(Directory.systemTemp);

  bool fail = false;
  int? lastSaved;

  @override
  Future<void> save(
    int trackId, {
    required String audio,
    required String text,
    required int advanceMilliseconds,
  }) async {
    if (fail) throw const FileSystemException('Test failure');
    lastSaved = advanceMilliseconds;
  }
}

void main() {
  const rawLrc = '[00:01]Первая строка\n[00:05]Вторая строка';
  const toggle = ValueKey('lyric_timing_toggle');
  const captureKey = ValueKey('lyric_timing_capture');
  const capture = bool.fromEnvironment('SHIKI_LYRIC_TIMING_CAPTURE');

  setUpAll(() async {
    if (!capture) return;
    final regular = File('C:/Windows/Fonts/segoeui.ttf');
    final flutter =
        Platform.environment['FLUTTER_ROOT'] ?? 'E:/Develop/flutter';
    final icons = File(
      '$flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    for (final font in [
      (regular, 'LyricTimingCapture'),
      (icons, 'MaterialIcons'),
    ]) {
      if (await font.$1.exists()) {
        final loader = FontLoader(font.$2)
          ..addFont(
            Future.value(ByteData.sublistView(await font.$1.readAsBytes())),
          );
        await loader.load();
      }
    }
  });

  Future<
    ({
      _RecordedOffsets store,
      ValueNotifier<LyricTimingSession?> timing,
      Duration? Function() sought,
    })
  >
  show(
    WidgetTester tester, {
    double width = 375,
    double scale = 1,
    String language = 'ru',
    bool eligible = true,
    LyricTimingProposalClient? proposals,
  }) async {
    final previousTrack = activeTrackNotifier.value;
    final previousLyrics = globalLyrics;
    final previousPlain = noLrcData;
    final previousLine = currentLine;
    final previousLoading = lrcLoading;
    final previousLanguage = languageNotifier.value;
    final store = _RecordedOffsets();
    final timing = ValueNotifier<LyricTimingSession?>(null);
    var active = true;
    Duration? seek;

    void showAtPausedPosition(List<LyricLine> lines) {
      globalLyrics = lines;
      currentLine = lyricLineIndexAt(lines, const Duration(milliseconds: 960));
      uiSignal.value++;
    }

    activeTrackNotifier.value = {
      'id': 1791,
      'title': 'Трек с длинным названием для узкого экрана',
      'artists': [
        {'name': 'Исполнитель'},
      ],
    };
    languageNotifier.value = language;
    lrcLoading = false;
    noLrcData = eligible ? '' : 'Текст без меток времени';
    showAtPausedPosition(eligible ? parseLrcString(rawLrc) : []);
    if (eligible) {
      timing.value = LyricTimingSession(
        store: store,
        trackId: 1791,
        contents: rawLrc,
        fingerprintAudio: () async => 'a' * 64,
        isCurrent: () => active && activeTrackNotifier.value?['id'] == 1791,
        onTimeline: showAtPausedPosition,
      );
    }

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 812);
    addTearDown(() {
      active = false;
      activeTrackNotifier.value = previousTrack;
      globalLyrics = previousLyrics;
      noLrcData = previousPlain;
      currentLine = previousLine;
      lrcLoading = previousLoading;
      languageNotifier.value = previousLanguage;
      timing.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final theme = ThemeData.dark();
    await tester.pumpWidget(
      MaterialApp(
        theme: capture
            ? theme.copyWith(
                textTheme: theme.textTheme.apply(
                  fontFamily: 'LyricTimingCapture',
                ),
              )
            : theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: RepaintBoundary(
          key: captureKey,
          child: PresentationOverlay(
            timing: timing,
            proposals: proposals,
            onSeekRequested: (position) => seek = position,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (store: store, timing: timing, sought: () => seek);
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!capture) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(captureKey),
      );
      final image = await boundary.toImage();
      try {
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        final output = await Directory(
          '.omx/lyric-timing-qa',
        ).create(recursive: true);
        await File(
          '${output.path}/$name.png',
        ).writeAsBytes(bytes.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  testWidgets(
    'preview updates the paused highlight and cue seek; cancel restores both',
    (tester) async {
      final fixture = await show(tester);
      expect(find.byTooltip(tr('lyric_timing')), findsOneWidget);
      expect(currentLine, -1);
      await screenshot(tester, 'mobile-closed');
      await tester.tap(find.byKey(toggle));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr('lyric_timing_earlier')));
      await tester.pumpAndSettle();
      expect(currentLine, 0);
      expect(find.text('На 0,1 с раньше'), findsOneWidget);
      await screenshot(tester, 'mobile-edit');
      await tester.tap(find.byKey(const ValueKey('lyric_cue_0')));
      expect(fixture.sought(), const Duration(milliseconds: 900));
      await tester.tap(find.text(tr('cancel')));
      await tester.pumpAndSettle();
      expect(currentLine, -1);
      expect(globalLyrics.first.time, const Duration(seconds: 1));
      expect(fixture.store.lastSaved, isNull);
      expect(find.byType(LyricTimingControls), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'save failure keeps the preview; retry commits and reset clears it',
    (tester) async {
      final fixture = await show(tester);
      fixture.store.fail = true;
      await tester.tap(find.byKey(toggle));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr('lyric_timing_later')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr('lyric_timing_done')));
      await tester.pumpAndSettle();
      expect(find.text(tr('lyric_timing_save_error')), findsOneWidget);
      expect(globalLyrics.first.time, const Duration(milliseconds: 1100));

      fixture.store.fail = false;
      await tester.tap(find.text(tr('lyric_timing_done')));
      await tester.pumpAndSettle();
      expect(fixture.store.lastSaved, -100);
      expect(find.byType(LyricTimingControls), findsNothing);
      await tester.tap(find.byKey(toggle));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr('lyric_timing_reset')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr('lyric_timing_done')));
      await tester.pumpAndSettle();
      expect(fixture.store.lastSaved, 0);
      expect(globalLyrics.first.time, const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('removing the lyrics route discards an unsaved draft', (
    tester,
  ) async {
    final fixture = await show(tester);
    await tester.tap(find.byKey(toggle));
    await tester.pumpAndSettle();
    await tester.tap(find.text(tr('lyric_timing_earlier')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(fixture.timing.value!.hasPreview, isFalse);
    expect(globalLyrics.first.time, const Duration(seconds: 1));
  });

  testWidgets('track switch closes its editor without applying the old draft', (
    tester,
  ) async {
    final fixture = await show(tester);
    await tester.tap(find.byKey(toggle));
    await tester.pumpAndSettle();
    await tester.tap(find.text(tr('lyric_timing_earlier')));
    await tester.pumpAndSettle();
    activeTrackNotifier.value = {'id': 1792, 'title': 'Другая запись'};
    globalLyrics = parseLrcString('[00:03]Новая строка');
    currentLine = -1;
    fixture.timing.value = null;
    uiSignal.value++;
    await tester.pumpAndSettle();
    expect(find.byType(LyricTimingControls), findsNothing);
    expect(find.byKey(toggle), findsNothing);
    expect(globalLyrics.single.time, const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('plain lyrics have no edit button', (tester) async {
    await show(tester, eligible: false);
    expect(find.byKey(toggle), findsNothing);
    expect(find.text('Текст без меток времени'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  LyricTimingProposalClient mockProposals(
    Future<http.Response> Function(http.Request) handler,
  ) {
    final client = LyricTimingProposalClient(client: MockClient(handler));
    addTearDown(client.close);
    return client;
  }

  testWidgets('explicit proposal writes locally first and sends just once', (
    tester,
  ) async {
    var gets = 0;
    var posts = 0;
    _RecordedOffsets? store;
    final proposals = mockProposals((request) async {
      if (request.method == 'GET') {
        gets++;
        return http.Response('{"lyric_timing_proposals":1}', 200);
      }
      posts++;
      expect(store?.lastSaved, 100, reason: 'Local save precedes POST');
      expect(jsonDecode(request.body)['advance_ms'], 100);
      return http.Response('{"status":"pending"}', 201);
    });
    final fixture = await show(tester, proposals: proposals);
    store = fixture.store;
    expect(gets, 0);
    await tester.tap(find.byKey(toggle));
    await tester.pumpAndSettle();
    expect(gets, 1);
    expect(find.text(tr('lyric_timing_propose')), findsNothing);
    await tester.tap(find.text(tr('lyric_timing_earlier')));
    await tester.pumpAndSettle();
    final action = find.text(tr('lyric_timing_propose'));
    expect(posts, 0);
    await screenshot(tester, 'mobile-proposal');
    fixture.store.fail = true;
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(posts, 0);
    expect(find.text(tr('lyric_timing_save_error')), findsOneWidget);
    fixture.store.fail = false;
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(posts, 1);
    expect(find.text(tr('lyric_timing_proposal_pending')), findsOneWidget);
    expect(action, findsNothing);
    expect(fixture.timing.value?.hasPreview, isFalse);
    await tester.tap(find.text(tr('lyric_timing_done')));
    await tester.pumpAndSettle();
    expect(posts, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unsupported server leaves Done as a local action', (
    tester,
  ) async {
    final requests = <String>[];
    final proposals = mockProposals((request) async {
      requests.add(request.method);
      return http.Response('Not found', 404);
    });
    final fixture = await show(tester, proposals: proposals);
    await tester.tap(find.byKey(toggle));
    await tester.pumpAndSettle();
    await tester.tap(find.text(tr('lyric_timing_earlier')));
    await tester.pumpAndSettle();
    expect(find.text(tr('lyric_timing_propose')), findsNothing);
    await tester.tap(find.text(tr('lyric_timing_done')));
    await tester.pumpAndSettle();
    expect(fixture.store.lastSaved, 100);
    expect(requests, ['GET']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a version conflict does not roll back the local timing', (
    tester,
  ) async {
    final proposals = mockProposals(
      (request) async => request.method == 'GET'
          ? http.Response('{"lyric_timing_proposals":1}', 200)
          : http.Response('{"error":"version_conflict"}', 409),
    );
    final fixture = await show(
      tester,
      width: 320,
      scale: 1.5,
      proposals: proposals,
    );
    await tester.tap(find.byKey(toggle));
    await tester.pumpAndSettle();
    await tester.tap(find.text(tr('lyric_timing_later')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(tr('lyric_timing_propose')));
    await tester.pumpAndSettle();
    expect(find.text(tr('lyric_timing_proposal_conflict')), findsOneWidget);
    expect(fixture.store.lastSaved, -100);
    expect(globalLyrics.first.time, const Duration(milliseconds: 1100));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('late capability from an earlier editor cannot enable sending', (
    tester,
  ) async {
    final first = Completer<http.Response>();
    var probes = 0;
    final proposals = mockProposals(
      (_) async =>
          ++probes == 1 ? first.future : http.Response('Not found', 404),
    );
    await show(tester, proposals: proposals);
    await tester.tap(find.byKey(toggle));
    await tester.pump();
    await tester.tap(find.text(tr('cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(toggle));
    await tester.pumpAndSettle();
    first.complete(http.Response('{"lyric_timing_proposals":1}', 200));
    await tester.pumpAndSettle();
    await tester.tap(find.text(tr('lyric_timing_later')));
    await tester.pumpAndSettle();
    expect(probes, 2);
    expect(find.text(tr('lyric_timing_propose')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final (width, scale, language) in [
    (320.0, 2.0, 'ru'),
    (360.0, 1.5, 'ja'),
    (1024.0, 1.0, 'en'),
  ]) {
    testWidgets('editor fits $width at scale $scale in $language', (
      tester,
    ) async {
      await show(tester, width: width, scale: scale, language: language);
      await tester.tap(find.byKey(toggle));
      await tester.pumpAndSettle();
      final editor = tester.getRect(find.byType(LyricTimingControls));
      final lyrics = tester.getRect(find.byType(SyncedLyricsView));
      expect(editor.width, lessThanOrEqualTo(392));
      expect(editor.right, lessThanOrEqualTo(width - 20));
      expect(editor.bottom, lessThan(lyrics.top));
      expect(lyrics.height, greaterThan(200));
      expect(tester.takeException(), isNull);
      if (width == 1024) await screenshot(tester, 'desktop-edit');
      await tester.pumpWidget(const SizedBox());
    });
  }
}
