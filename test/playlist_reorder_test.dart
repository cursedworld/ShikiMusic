import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/atomic_file_store.dart';
import 'package:shiki/screens/home_screen.dart';
import 'package:shiki/widgets/playlist_track_list.dart';

class _PlaylistState extends MainAppScreenState {
  BuildContext? testContext;
  VoidCallback? rebuild;
  bool memoryOnly = false;

  @override
  bool get mounted => testContext != null;

  @override
  Future<bool> savePlaylists() =>
      memoryOnly ? Future.value(true) : super.savePlaylists();

  @override
  BuildContext get context => testContext!;

  @override
  void setState(VoidCallback fn) {
    fn();
    rebuild?.call();
  }
}

void main() {
  setUpAll(() async {
    final font = File('C:/Windows/Fonts/segoeui.ttf');
    if (await font.exists()) {
      final loader = FontLoader('PlaylistTest');
      loader.addFont(
        Future.value(ByteData.sublistView(await font.readAsBytes())),
      );
      await loader.load();
    }
    final icons = File(
      'E:/Develop/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (await icons.exists()) {
      final loader = FontLoader('MaterialIcons');
      loader.addFont(
        Future.value(ByteData.sublistView(await icons.readAsBytes())),
      );
      await loader.load();
    }
  });
  final tracks = [
    for (var id = 1; id <= 4; id++)
      {
        'id': id,
        'title': 'Track $id',
        'artists': [
          {'id': 7, 'name': 'Artist'},
        ],
        'album': {'title': 'Album', 'cover': ''},
      },
  ];

  _PlaylistState createFixture(Directory directory) {
    final state = _PlaylistState()
      ..localPath = directory.path
      ..isLoading = false
      ..cachedTracks = List.from(tracks)
      ..myPlaylists = [
        {
          'id': 42,
          'name': 'Playlist',
          'image': '',
          'tracks': [1, 2, 3, 4],
        },
        {
          'id': 43,
          'name': 'Other',
          'image': '',
          'tracks': [4, 2],
        },
      ]
      ..navId = 3;
    addTearDown(() async {
      await atomicFileStore.writeStringLazy(
        File('${directory.path}/app_state.json'),
        () => '{}',
      );
      state.catalogSyncStatus.dispose();
      state.searchInput.dispose();
      state.searchFocusNode.dispose();
      state.currentPositionNotifier.dispose();
      state.fullDurationNotifier.dispose();
      await directory.delete(recursive: true);
    });
    return state;
  }

  Future<_PlaylistState> fixture() async =>
      createFixture(await Directory.systemTemp.createTemp('shiki_reorder_'));

  Future<Directory> widgetDirectory(WidgetTester tester) async => (await tester
      .runAsync(() => Directory.systemTemp.createTemp('shiki_reorder_ui_')))!;

  List<int> queueIds(_PlaylistState state) => [
    for (final track in state.playingQueue) track['id'] as int,
  ];

  test(
    'reorder persists and updates playing playlist without changing position',
    () async {
      final state = await fixture();
      state
        ..playingPlaylistId = 42
        ..playingQueue = List.from(tracks)
        ..playingIndex = 1
        ..isPlaying = true;
      state.currentPositionNotifier.value = const Duration(seconds: 77);
      expect(await state.reorderPlaylist(42, [1, 2, 3, 4], 1, 4), isTrue);
      expect(queueIds(state), [1, 3, 4, 2]);
      expect(state.playingIndex, 3);
      expect(state.playingQueue[state.playingIndex], same(tracks[1]));
      expect(state.currentPositionNotifier.value, const Duration(seconds: 77));
      expect(state.isPlaying, isTrue);
      final saved =
          jsonDecode(
                await File(
                  '${state.localPath}/my_playlists.json',
                ).readAsString(),
              )
              as List;
      expect(saved.first['tracks'], [1, 3, 4, 2]);
      expect(saved.last['tracks'], [4, 2]);
      final appState = jsonDecode(
        await File('${state.localPath}/app_state.json').readAsString(),
      );
      expect(appState['playingPlaylistId'], 42);
      expect(appState['playingIndex'], 3);
      expect(appState['position'], 77000);
      state.myPlaylists = [];
      await state.readPlaylists();
      expect(state.myPlaylists.first['tracks'], [1, 3, 4, 2]);
    },
  );

  test(
    'editing a different playlist does not change the current queue',
    () async {
      final state = await fixture();
      state
        ..playingPlaylistId = 43
        ..playingQueue = [tracks[3], tracks[1]];
      expect(await state.reorderPlaylist(42, [1, 2, 3, 4], 0, 4), isTrue);
      expect(queueIds(state), [4, 2]);
      expect(state.playingIndex, 0);
    },
  );

  test(
    'shuffle stays unchanged until disabled, then uses the new playlist order',
    () async {
      final state = await fixture();
      final oldShuffle = isShuffledNotifier.value;
      addTearDown(() => isShuffledNotifier.value = oldShuffle);
      state
        ..playingPlaylistId = 42
        ..playingQueue = List.from(tracks)
        ..playingIndex = 1;
      state.toggleShuffle();
      final shuffled = queueIds(state);
      await state.reorderPlaylist(42, [1, 2, 3, 4], 3, 0);
      expect(queueIds(state), shuffled);
      expect(state.isShuffled, isTrue);
      state.toggleShuffle();
      expect(queueIds(state), [4, 1, 2, 3]);
      expect(state.playingQueue[state.playingIndex]['id'], 2);
    },
  );

  test('save failure rolls back order and leaves playback untouched', () async {
    final state = await fixture();
    await Directory('${state.localPath}/my_playlists.json').create();
    state
      ..playingPlaylistId = 42
      ..playingQueue = List.from(tracks)
      ..playingIndex = 2;
    expect(await state.reorderPlaylist(42, [1, 2, 3, 4], 0, 4), isFalse);
    expect(state.myPlaylists.first['tracks'], [1, 2, 3, 4]);
    expect(queueIds(state), [1, 2, 3, 4]);
    expect(state.playingIndex, 2);
  });

  test('rapid drags persist in order and preserve the active track', () async {
    final state = await fixture();
    state
      ..playingPlaylistId = 42
      ..playingQueue = List.from(tracks)
      ..playingIndex = 2;
    final first = state.reorderPlaylist(42, [1, 2, 3, 4], 0, 4);
    final second = state.reorderPlaylist(42, [2, 3, 4, 1], 1, 0);
    expect(await Future.wait([first, second]), [true, true]);
    expect(state.myPlaylists.first['tracks'], [3, 2, 4, 1]);
    expect(queueIds(state), [3, 2, 4, 1]);
    expect(state.playingIndex, 0);
    expect(state.playingQueue.first, same(tracks[2]));
    final saved = jsonDecode(
      await File('${state.localPath}/my_playlists.json').readAsString(),
    );
    expect(saved.first['tracks'], [3, 2, 4, 1]);
  });

  test('filtered playlist changes only existing queue members', () async {
    final state = await fixture();
    state
      ..playingPlaylistId = 42
      ..playingQueue = [tracks[0], tracks[3]];
    await state.reorderPlaylist(42, [1, 4], 0, 2);
    expect(state.myPlaylists.first['tracks'], [4, 2, 3, 1]);
    expect(queueIds(state), [4, 1]);
    expect(state.playingIndex, 1);
  });

  for (final width in [320.0, 375.0, 768.0, 1440.0]) {
    testWidgets('actual playlist drag works at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = await widgetDirectory(tester);
      final state = createFixture(directory)
        ..memoryOnly = true
        ..localPath = '';
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: 'PlaylistTest',
            ),
          ),
          home: StatefulBuilder(
            builder: (context, setState) {
              state.testContext = context;
              state.rebuild = () => setState(() {});
              return RepaintBoundary(
                key: const ValueKey('playlist_capture'),
                child: state.build(context),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final first = find.byKey(const ValueKey('playlist_drag_1'));
      expect(tester.getSize(first).width, 50);
      final target = Offset(
        tester.getCenter(first).dx,
        tester.getBottomLeft(find.byType(ReorderableListView)).dy - 30,
      );
      final gesture = await tester.startGesture(tester.getCenter(first));
      if (width < 800) await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
      await gesture.moveTo(target);
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.moveBy(const Offset(0, 1));
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).color ==
                  Colors.black.withValues(alpha: 0.16),
        ),
        findsOneWidget,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(state.myPlaylists.first['tracks'], [2, 3, 4, 1]);
      expect(
        tester.getRect(find.text('Track 2')).left -
            tester.getRect(find.byKey(const ValueKey('playlist_drag_2'))).right,
        closeTo(16, 0.1),
      );
      expect(tester.takeException(), isNull);
      expect(tester.binding.hasScheduledFrame, isFalse);
      if (const bool.fromEnvironment('SHIKI_PLAYLIST_CAPTURE')) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('playlist_capture')),
          );
          final image = await boundary.toImage();
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final output = Directory('.omx/playlist-qa');
            await output.create(recursive: true);
            await File(
              '${output.path}/reorder-${width.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }
      state.rebuild = null;
      state.testContext = null;
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('desktop handle uses the cover area and only reveals on hover', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PlaylistTrackDragHandle(
              key: const ValueKey('compact_handle'),
              index: 0,
              itemCount: 2,
              onReorder: (_, _) {},
              artwork: const ColoredBox(color: Color(0xFF345E75)),
            ),
          ),
        ),
      ),
    );
    final handle = find.byKey(const ValueKey('compact_handle'));
    expect(tester.getSize(handle), const Size(50, 50));
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(handle));
    await tester.pumpAndSettle();
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );
    expect(tester.binding.hasScheduledFrame, isFalse);
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  testWidgets('drag decoration is translucent with no flat surface or shadow', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaylistTrackList(
            itemCount: 2,
            itemBuilder: (_, index) =>
                SizedBox(key: ValueKey(index), height: 80),
            onReorder: (_, _) {},
          ),
        ),
      ),
    );
    final list = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    final proxy = list.proxyDecorator!(
      const SizedBox(),
      0,
      const AlwaysStoppedAnimation(1),
    );
    final material = proxy as Material;
    expect(material.type, MaterialType.transparency);
    expect(material.elevation, 0);
    final decoration =
        (material.child! as DecoratedBox).decoration as BoxDecoration;
    expect(decoration.color, Colors.black.withValues(alpha: 0.16));
    expect(decoration.boxShadow, isNull);
  });

  testWidgets('keyboard reorders without triggering playback', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = await widgetDirectory(tester);
    final state = createFixture(directory)
      ..memoryOnly = true
      ..localPath = '';
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: StatefulBuilder(
          builder: (context, setState) {
            state.testContext = context;
            state.rebuild = () => setState(() {});
            return state.build(context);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final handle = find
        .descendant(
          of: find.byKey(const ValueKey('playlist_drag_2')),
          matching: find.byType(ReorderableDragStartListener),
        )
        .first;
    Focus.of(tester.element(handle)).requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(state.myPlaylists.first['tracks'], [2, 1, 3, 4]);
    expect(state.playingQueue, isEmpty);
    expect(tester.takeException(), isNull);
    state.rebuild = null;
    state.testContext = null;
    await tester.pumpWidget(const SizedBox());
  });
}
