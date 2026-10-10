import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/widgets/artist_library_view.dart';

void main() {
  const names = [
    'Кишлак',
    '707',
    'Автостопом по фазе сна',
    'ЗоХа',
    'Исполнитель с очень длинным именем',
    'Артист',
    'Ещё один исполнитель',
    'Демо',
  ];
  final catalog = [
    for (var i = 0; i < names.length; i++)
      {
        'id': i + 1,
        'name': names[i],
        'tracks_count': 12 + i,
        'albums_count': 2,
      },
  ];
  late String oldLanguage, oldPath;
  const capture = bool.fromEnvironment('SHIKI_ARTISTS_SCREENSHOT');
  const fontPath = String.fromEnvironment('SHIKI_TEST_FONT');
  const iconsPath = String.fromEnvironment('SHIKI_TEST_ICONS');
  setUpAll(() async {
    if (!capture) return;
    for (final entry in {
      'ArtistsTest': fontPath,
      'MaterialIcons': iconsPath,
    }.entries) {
      if (entry.value.isEmpty) continue;
      final loader = FontLoader(entry.key);
      loader.addFont(
        Future.value(
          ByteData.sublistView(await File(entry.value).readAsBytes()),
        ),
      );
      await loader.load();
    }
  });
  setUp(() {
    oldLanguage = languageNotifier.value;
    oldPath = globalLocalPath;
    languageNotifier.value = 'ru';
    globalLocalPath = '';
  });
  tearDown(() {
    languageNotifier.value = oldLanguage;
    globalLocalPath = oldPath;
  });

  Future<void> show(
    WidgetTester tester, {
    double width = 1024,
    double scale = 1,
    String query = '',
    List<dynamic>? artists,
    void Function(int, String)? onOpen,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('artists_screenshot'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: capture && fontPath.isNotEmpty ? 'ArtistsTest' : null,
            ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            backgroundColor: const Color(0xFF161416),
            appBar: AppBar(
              backgroundColor: const Color(0xFF161416),
              title: const Text('Исполнители'),
            ),
            body: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ArtistLibraryView(
                catalog: artists ?? catalog,
                tracks: const [],
                query: query,
                onOpen: onOpen ?? (_, _) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test(
    'catalog metadata includes photo version and deduplicates collaborators',
    () {
      final primary = {'id': 7, 'name': 'Artist'};
      final guest = {'id': 8, 'name': 'Guest'};
      final tracks = [
        {
          'id': 10,
          'artists': [primary, guest],
          'album': {'id': 9, 'artist': primary},
        },
        {
          'id': 11,
          'artists': [guest],
          'album': {'id': 9, 'artist': primary},
        },
      ];
      final result = artistLibraryEntries(
        [
          {
            ...primary,
            'photo': 'photo.jpg',
            'photo_version': 'revision',
            'tracks_count': 15,
            'albums_count': 3,
          },
        ],
        tracks,
        '',
      );
      expect(result.map((e) => e['name']), ['Artist', 'Guest']);
      expect(result.first['photo_version'], 'revision');
      expect(result.first['tracks_count'], 15);
      expect(result.first['albums_count'], 3);
      expect(result.last['tracks_count'], 2);
      expect(result.last['albums_count'], 1);
      expect(
        artistLibraryEntries([], tracks, 'guest').single['tracks_count'],
        2,
      );
      expect(
        artistLibraryEntries([], tracks, '  ARTIST  ').single['tracks_count'],
        2,
      );
    },
  );

  test('offline performer photo and version remain paired', () {
    final artist = {
      'id': 7,
      'name': 'Artist',
      'photo': 'fresh.jpg',
      'photo_version': 'fresh',
    };
    final result = artistLibraryEntries(
      [
        {'id': 7, 'name': 'Artist'},
      ],
      [
        {
          'id': 1,
          'artists': [artist],
          'album': {'id': 1},
        },
      ],
      '',
    );
    expect(result.single['photo'], 'fresh.jpg');
    expect(result.single['photo_version'], 'fresh');
    expect(result.single['tracks_count'], 1);
  });

  for (final width in [320.0, 375.0, 600.0, 800.0, 1440.0]) {
    testWidgets('consistent artist portraits and text at width $width', (
      tester,
    ) async {
      await show(tester, width: width);
      expect(tester.takeException(), isNull);
      final first = tester.getSize(
        find.byKey(const ValueKey('artist_photo_0')),
      );
      final second = tester.getSize(
        find.byKey(const ValueKey('artist_photo_1')),
      );
      expect(first, second);
      expect(first.width, first.height);
      expect(first.width, 56);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('artist_photo_1'))).dy,
        greaterThan(
          tester
              .getBottomRight(find.byKey(const ValueKey('artist_photo_0')))
              .dy,
        ),
      );
      if (capture && (width == 375 || width == 1440)) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('artists_screenshot')),
          );
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            await Directory('build').create(recursive: true);
            await File(
              'build/artists_${width.toInt()}.png',
            ).writeAsBytes(png!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }
      await tester.scrollUntilVisible(
        find.text('Демо'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('large text remains readable without tile overflow', (
    tester,
  ) async {
    await show(tester, width: 320, scale: 2);
    await tester.scrollUntilVisible(
      find.text(names[4]),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('filter and activation preserve the artist identity', (
    tester,
  ) async {
    int? selectedId;
    String? selectedName;
    await show(
      tester,
      query: '707',
      onOpen: (id, name) {
        selectedId = id;
        selectedName = name;
      },
    );
    expect(find.text('Кишлак'), findsNothing);
    await tester.tap(find.text('707'));
    expect(selectedId, 2);
    expect(selectedName, '707');
  });

  testWidgets('empty library differs from an unmatched search', (tester) async {
    await show(tester, artists: []);
    expect(find.textContaining('Здесь появятся'), findsOneWidget);
    await show(tester, query: 'missing');
    expect(find.textContaining('Исполнители не найдены'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tiles support keyboard activation', (tester) async {
    var opened = false;
    await show(tester, query: '707', onOpen: (_, _) => opened = true);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(opened, isTrue);
  });
}
