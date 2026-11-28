import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/listening_statistics.dart';
import 'package:shiki/localization.dart';
import 'package:shiki/screens/settings_screen.dart';
import 'package:shiki/screens/statistics_screen.dart';
import 'package:shiki/statistics_store.dart';

class _ScreenStore extends StatisticsStore {
  _ScreenStore() : super('unused');
  bool empty = false, fail = false;
  int trackCount = 3;
  final orders = <(String?, bool), List<int>>{};
  String? requestedFrom;
  bool requestedByPlays = false;
  Completer<void>? pendingRead;

  @override
  Future<void> write(List<Map<String, Object?>> rows) async {}

  @override
  Future<Map<String, Object?>> summary({
    String? from,
    String? to,
    bool byPlays = false,
  }) async {
    await pendingRead?.future;
    if (fail) throw StateError('unavailable');
    requestedFrom = from;
    requestedByPlays = byPlays;
    final now = DateTime.now();
    final first = DateTime(now.year, now.month, now.day - 20);
    return {
      'listening_ms': empty ? 0 : 125 * 60000,
      'app_ms': 20 * 60000,
      'plays': empty ? 0 : 42,
      'tracks': empty ? 0 : 12,
      'artists': empty ? 0 : 7,
      'first_day': statisticsDay(first),
      'days': [
        if (!empty)
          for (var i = 0; i < 21; i++)
            {
              'day': statisticsDay(
                DateTime(first.year, first.month, first.day + i),
              ),
              'ms': (i % 5 + 1) * 60000,
            },
      ],
      'top_tracks': [
        if (!empty)
          for (final id
              in orders[(from, byPlays)] ??
                  List.generate(trackCount, (index) => index + 1))
            {
              'key': 'track:$id',
              'name': id == 1
                  ? 'Без ответа'
                  : id == 2
                  ? 'Уличная жизнь'
                  : 'Трек $id',
              'detail': id == 1 ? 'Кишлак, 707' : 'Исполнитель',
              'ms': 600000 - id * 1000,
              'plays': 4,
            },
      ],
      'top_artists': [
        if (!empty)
          {
            'key': 'artist:7',
            'name': 'Кишлак',
            'detail': '',
            'ms': 2400000,
            'plays': 12,
          },
      ],
    };
  }
}

class _ScreenStatistics extends ListeningStatistics {
  _ScreenStatistics(_ScreenStore super.store);
  StatisticsSummary? readySummary;

  @override
  StatisticsSummary? cachedSummary({
    String? from,
    String? to,
    bool byPlays = false,
  }) =>
      readySummary ?? super.cachedSummary(from: from, to: to, byPlays: byPlays);

  @override
  Future<StatisticsSummary> summary({
    String? from,
    String? to,
    bool byPlays = false,
  }) async => StatisticsSummary.fromMap(
    await store.summary(from: from, to: to, byPlays: byPlays),
  );
}

void main() {
  late _ScreenStore store;
  late ListeningStatistics statistics;
  late String previousLanguage;
  const screenshot = bool.fromEnvironment('SHIKI_STATS_SCREENSHOT');
  const fontPath = String.fromEnvironment('SHIKI_TEST_FONT');
  const iconsPath = String.fromEnvironment('SHIKI_TEST_ICONS');
  setUpAll(() async {
    if (screenshot && fontPath.isNotEmpty) {
      final loader = FontLoader('StatisticsTest');
      loader.addFont(
        Future.value(ByteData.sublistView(await File(fontPath).readAsBytes())),
      );
      await loader.load();
      if (iconsPath.isNotEmpty) {
        final icons = FontLoader('MaterialIcons');
        icons.addFont(
          Future.value(
            ByteData.sublistView(await File(iconsPath).readAsBytes()),
          ),
        );
        await icons.load();
      }
    }
  });
  setUp(() {
    previousLanguage = languageNotifier.value;
    languageNotifier.value = 'ru';
    store = _ScreenStore();
    statistics = _ScreenStatistics(store);
  });
  tearDown(() async {
    await statistics.close();
    languageNotifier.value = previousLanguage;
  });

  Future<void> show(
    WidgetTester tester, {
    double width = 1024,
    double scale = 1,
    bool settle = true,
    List<dynamic> Function()? currentTracks,
    Future<bool> Function(String, List<int>)? onCreatePlaylist,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('statistics_screenshot'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: Locale(languageNotifier.value),
          supportedLocales: appSupportedLocales,
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: screenshot && fontPath.isNotEmpty
                  ? 'StatisticsTest'
                  : null,
            ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: StatisticsScreen(
            statistics: statistics,
            currentTracks: currentTracks,
            onCreatePlaylist: onCreatePlaylist,
          ),
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  testWidgets('initial read hides the incomplete statistics page', (
    tester,
  ) async {
    final pending = store.pendingRead = Completer<void>();
    await show(tester, settle: false);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('stats_initial_loading')), findsOneWidget);
    expect(find.byKey(const ValueKey('stats_period')), findsNothing);
    expect(find.text('Экспорт'), findsNothing);
    expect(find.text('Импорт'), findsNothing);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stats_initial_loading')), findsNothing);
    expect(find.text('Без ответа'), findsOneWidget);
    expect(find.text('2 ч 5 мин'), findsOneWidget);
    expect(find.text('Экспорт'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh retains the loaded statistics while reading', (
    tester,
  ) async {
    await show(tester);
    final pending = store.pendingRead = Completer<void>();
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('stats_initial_loading')), findsNothing);
    expect(find.text('Без ответа'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'prepared statistics appear without a loading frame or another read',
    (tester) async {
      (statistics as _ScreenStatistics).readySummary = await statistics
          .summary();
      store.pendingRead = Completer<void>();
      await show(tester, settle: false);
      await tester.pump();
      expect(find.text('2 ч 5 мин'), findsOneWidget);
      expect(find.byKey(const ValueKey('stats_initial_loading')), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(store.pendingRead!.isCompleted, isFalse);
    },
  );

  for (final language in ['ru', 'en', 'ja']) {
    testWidgets('statistics fits narrow layout in $language', (tester) async {
      languageNotifier.value = language;
      await show(tester, width: 375, onCreatePlaylist: (_, _) async => true);
      expect(find.text(tr('create_playlist')), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text(tr('stats_import')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [320.0, 375.0, 768.0, 1024.0, 1440.0]) {
    testWidgets('statistics layout fits width $width', (tester) async {
      await show(tester, width: width);
      expect(find.text('Моя музыка'), findsOneWidget);
      expect(find.text(tr('stats_favorite_artist')), findsOneWidget);
      expect(find.text('Без ответа'), findsOneWidget);
      expect(find.text('2 ч 5 мин'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (screenshot && (width == 375 || width == 1440)) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('statistics_screenshot')),
          );
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            await Directory('build').create(recursive: true);
            await File(
              'build/statistics_${width.toInt()}.png',
            ).writeAsBytes(png!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }
      await tester.scrollUntilVisible(
        find.text('Импорт'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('narrow layout supports larger text', (tester) async {
    await show(tester, width: 375, scale: 1.5);
    await tester.scrollUntilVisible(
      find.text('Импорт'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('date periods and ranking sort reach the database query', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('stats_period')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('7 дней'));
    await tester.pumpAndSettle();
    final now = DateTime.now();
    expect(
      store.requestedFrom,
      statisticsDay(DateTime(now.year, now.month, now.day - 6)),
    );
    await tester.tap(find.byKey(const ValueKey('stats_period')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Всё время'));
    await tester.pumpAndSettle();
    expect(store.requestedFrom, isNull);
    await tester.ensureVisible(find.byKey(const ValueKey('stats_sort')));
    await tester.tap(find.byKey(const ValueKey('stats_sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('По прослушиваниям').last);
    await tester.pumpAndSettle();
    expect(store.requestedByPlays, isTrue);
  });

  testWidgets('sort menu opens below the button for either selection', (
    tester,
  ) async {
    await show(tester);
    final button = find.byKey(const ValueKey('stats_sort'));
    for (final value in [true, false]) {
      await tester.ensureVisible(button);
      final bottom = tester.getBottomLeft(button).dy;
      await tester.tap(button);
      await tester.pumpAndSettle();
      final items = find.byType(PopupMenuItem<bool>);
      expect(items, findsNWidgets(2));
      expect(tester.getTopLeft(items.first).dy, greaterThanOrEqualTo(bottom));
      await tester.tap(
        find.widgetWithText(
          PopupMenuItem<bool>,
          value ? 'По прослушиваниям' : 'По времени',
        ),
      );
      await tester.pumpAndSettle();
      expect(store.requestedByPlays, value);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('rankings expand and artist tab preserves the compact default', (
    tester,
  ) async {
    store.trackCount = 8;
    await show(tester);
    expect(find.text('Трек 6'), findsNothing);
    await tester.ensureVisible(
      find.byKey(const ValueKey('stats_expand_ranking')),
    );
    await tester.tap(find.byKey(const ValueKey('stats_expand_ranking')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Трек 8'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Трек 8'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('stats_rank_artists')),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('stats_rank_artists')));
    await tester.pumpAndSettle();
    expect(find.text('Без ответа'), findsNothing);
    expect(find.byKey(const ValueKey('stats_expand_ranking')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('double text size and English labels do not overflow', (
    tester,
  ) async {
    languageNotifier.value = 'en';
    await show(
      tester,
      width: 320,
      scale: 2,
      onCreatePlaylist: (_, _) async => true,
    );
    await tester.scrollUntilVisible(
      find.text('Import'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
  });

  final create = find.byKey(const ValueKey('stats_create_playlist'));

  testWidgets('empty history reports no listening for the selected period', (
    tester,
  ) async {
    store.empty = true;
    await show(tester, onCreatePlaylist: (_, _) async => true);
    expect(find.text('За выбранный период нет прослушиваний.'), findsOneWidget);
    expect(tester.widget<TextButton>(create).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  Future<void> openPlaylistDialog(WidgetTester tester) async {
    await tester.ensureVisible(create);
    await tester.pumpAndSettle();
    await tester.tap(create);
    await tester.pumpAndSettle();
  }

  Future<void> confirmPlaylist(WidgetTester tester) async {
    final submit = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text(tr('create')),
    );
    await tester.tap(submit);
    await tester.pumpAndSettle();
  }

  testWidgets('creates the full monthly top even when collapsed at 320px', (
    tester,
  ) async {
    store.trackCount = 8;
    var library = [
      for (var id = 7; id > 0; id--) {'id': id},
    ];
    final saved = <(String, List<int>)>[];
    await show(
      tester,
      width: 320,
      scale: 1.5,
      currentTracks: () => library,
      onCreatePlaylist: (name, ids) async {
        saved.add((name, ids));
        return true;
      },
    );
    expect(find.text('Трек 6'), findsNothing);
    await openPlaylistDialog(tester);
    final name = find.byType(TextField);
    expect(
      tester.widget<TextField>(name).controller!.text,
      contains('30 дней'),
    );
    expect(
      find.textContaining(
        tr('stats_playlist_missing').replaceAll('{count}', '1'),
      ),
      findsOneWidget,
    );
    // Re-resolve at confirmation instead of saving stale library references.
    library = library.where((track) => track['id'] != 3).toList();
    await tester.enterText(name, 'Мой ноябрь');
    await confirmPlaylist(tester);
    expect(saved.single.$1, 'Мой ноябрь');
    expect(saved.single.$2, [1, 2, 4, 5, 6, 7]);
    expect(
      find.textContaining(
        tr('stats_playlist_missing').replaceAll('{count}', '2'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('disables creation during a period change and uses latest sort', (
    tester,
  ) async {
    final now = DateTime.now();
    final week = statisticsDay(DateTime(now.year, now.month, now.day - 6));
    store.orders[(week, false)] = [2, 1];
    store.orders[(week, true)] = [3, 2];
    final saved = <List<int>>[];
    await show(
      tester,
      currentTracks: () => [
        for (var id = 1; id <= 3; id++) {'id': id},
      ],
      onCreatePlaylist: (_, ids) async {
        saved.add(ids);
        return true;
      },
    );
    await tester.tap(find.byKey(const ValueKey('stats_period')));
    await tester.pumpAndSettle();
    final pending = store.pendingRead = Completer<void>();
    await tester.tap(find.text(tr('stats_period_week')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<TextButton>(create).onPressed, isNull);
    expect(saved, isEmpty);

    store.pendingRead = null;
    final sort = find.byKey(const ValueKey('stats_sort'));
    await tester.ensureVisible(sort);
    await tester.tap(sort);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(
      find.widgetWithText(PopupMenuItem<bool>, tr('stats_sort_plays')),
    );
    await tester.pumpAndSettle();
    pending.complete();
    await tester.pumpAndSettle();
    await openPlaylistDialog(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      contains('7 дней'),
    );
    await confirmPlaylist(tester);
    expect(saved, [
      [3, 2],
    ]);
  });

  testWidgets('uses the custom range and refuses a top with no matching IDs', (
    tester,
  ) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day - 10);
    final range = DateTimeRange(
      start: start,
      end: start.add(const Duration(days: 2)),
    );
    store.orders[(statisticsDay(start), false)] = [44, 55];
    var library = [
      {'id': 1},
    ];
    final saved = <List<int>>[];
    await show(
      tester,
      currentTracks: () => library,
      onCreatePlaylist: (_, ids) async {
        saved.add(ids);
        return true;
      },
    );
    final formatDate = MaterialLocalizations.of(
      tester.element(find.byType(StatisticsScreen)),
    ).formatCompactDate;
    await tester.tap(find.byKey(const ValueKey('stats_period')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(PopupMenuItem<String>, tr('stats_period_custom')),
    );
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(DateRangePickerDialog))).pop(range);
    await tester.pumpAndSettle();
    expect(store.requestedFrom, statisticsDay(start));
    await openPlaylistDialog(tester);
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining(tr('stats_playlist_empty')), findsOneWidget);
    expect(
      find.textContaining(
        tr('stats_playlist_missing').replaceAll('{count}', '2'),
      ),
      findsOneWidget,
    );
    expect(saved, isEmpty);

    library = [
      {'id': 55},
      {'id': 44},
    ];
    await openPlaylistDialog(tester);
    final name = tester
        .widget<TextField>(find.byType(TextField))
        .controller!
        .text;
    expect(name, contains(formatDate(range.start)));
    expect(name, contains(formatDate(range.end)));
    await confirmPlaylist(tester);
    expect(saved, [
      [44, 55],
    ]);
  });

  testWidgets('read failure offers retry and then recovers', (tester) async {
    store.fail = true;
    await show(tester);
    expect(find.textContaining('Не удалось прочитать'), findsOneWidget);
    store.fail = false;
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(find.text('2 ч 5 мин'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings opens the statistics screen', (tester) async {
    final pending = store.pendingRead = Completer<void>();
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('shiki-statistics-settings-'),
    ))!;
    addTearDown(() async {
      final prefix =
          '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}shiki-statistics-settings-';
      if (!directory.absolute.path.startsWith(prefix)) {
        throw StateError('Unexpected test directory');
      }
      await directory.delete(recursive: true);
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: SettingsScreen(
          dataDirectoryProvider: () async => directory,
          statistics: statistics,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(pending.isCompleted, isFalse);
    pending.complete();
    store.pendingRead = null;
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('open_statistics')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('open_statistics')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open_statistics')));
    await tester.pumpAndSettle();
    expect(find.byType(StatisticsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
