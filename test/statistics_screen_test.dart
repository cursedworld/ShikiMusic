import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/listening_statistics.dart';
import 'package:shiki/screens/settings_screen.dart';
import 'package:shiki/screens/statistics_screen.dart';
import 'package:shiki/statistics_store.dart';

class _ScreenStore extends StatisticsStore {
  _ScreenStore() : super('unused');
  bool empty = false, fail = false;
  int trackCount = 3;
  String? requestedFrom;
  bool requestedByPlays = false;

  @override
  Future<void> write(List<Map<String, Object?>> rows) async {}

  @override
  Future<Map<String, Object?>> summary({
    String? from,
    String? to,
    bool byPlays = false,
  }) async {
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
          for (var i = 0; i < trackCount; i++)
            {
              'key': 'track:${i + 1}',
              'name': i == 0
                  ? 'Без ответа'
                  : i == 1
                  ? 'Уличная жизнь'
                  : 'Трек ${i + 1}',
              'detail': i == 0 ? 'Кишлак, 707' : 'Исполнитель',
              'ms': 600000 - i * 1000,
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
          home: StatisticsScreen(statistics: statistics),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final width in [320.0, 375.0, 768.0, 1024.0, 1440.0]) {
    testWidgets('statistics layout fits width $width', (tester) async {
      await show(tester, width: width);
      expect(find.text('Моя музыка'), findsOneWidget);
      expect(find.text('Чаще всего слушал'), findsOneWidget);
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
    await tester.ensureVisible(find.byType(DropdownButton<bool>));
    await tester.tap(find.byType(DropdownButton<bool>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('По прослушиваниям').last);
    await tester.pumpAndSettle();
    expect(store.requestedByPlays, isTrue);
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
    await show(tester, width: 320, scale: 2);
    await tester.scrollUntilVisible(
      find.text('Import'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty history explains how to start collecting statistics', (
    tester,
  ) async {
    store.empty = true;
    await show(tester);
    expect(find.textContaining('Включи трек'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
          onClearCache: () => true,
          dataDirectoryProvider: () async => directory,
          statistics: statistics,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('open_statistics')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('open_statistics')));
    await tester.pumpAndSettle();
    expect(find.byType(StatisticsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
