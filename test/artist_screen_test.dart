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
import 'package:image/image.dart' as img;
import 'package:shiki/globals.dart';
import 'package:shiki/screens/artist_screen.dart';

Future<void> settleImages(WidgetTester tester) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
    if (PaintingBinding.instance.imageCache.pendingImageCount == 0) return;
  }
  fail('Local images did not finish loading.');
}

void main() {
  setUpAll(() async {
    // Optional local fonts make generated previews readable; CI needs no fonts.
    for (final font in [
      ('Roboto', const String.fromEnvironment('SHIKI_UI_FONT')),
      ('MaterialIcons', const String.fromEnvironment('SHIKI_UI_ICON_FONT')),
    ]) {
      if (font.$2.isEmpty) continue;
      final loader = FontLoader(font.$1)
        ..addFont(
          File(
            font.$2,
          ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await loader.load();
    }
  });
  late Directory directory;
  late String previousLocalPath;
  late dynamic previousTrack;
  late bool previousPlaying;
  late String? previousBackground;
  late ChangeNotifier libraryChanges;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shiki_artist_test_');
    previousLocalPath = globalLocalPath;
    previousTrack = activeTrackNotifier.value;
    previousPlaying = isPlayingNotifier.value;
    previousBackground = customBackgroundNotifier.value;
    customBackgroundNotifier.value = null;
    globalLocalPath = directory.path;
    activeTrackNotifier.value = null;
    isPlayingNotifier.value = false;
    libraryChanges = ChangeNotifier();
    clearCoverCache();
    final cover = img.encodePng(img.Image(width: 16, height: 16));
    for (final id in [1001, 1002]) {
      File('${directory.path}/cover_$id.jpg').writeAsBytesSync(cover);
    }
  });

  tearDown(() async {
    libraryChanges.dispose();
    clearCoverCache();
    globalLocalPath = previousLocalPath;
    activeTrackNotifier.value = previousTrack;
    isPlayingNotifier.value = previousPlaying;
    customBackgroundNotifier.value = previousBackground;
    final path = directory.absolute.path;
    final prefix =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}shiki_artist_test_';
    if (!path.startsWith(prefix)) throw StateError('Unexpected test directory');
    // FileImage can briefly retain a Windows file handle after widget disposal.
    for (var attempt = 0; ; attempt++) {
      try {
        await directory.delete(recursive: true);
        break;
      } on FileSystemException {
        if (attempt == 9) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  });

  Map<String, dynamic> track(int id, String title) => {
    'id': id,
    'title': title,
    'artists': [],
    'album': <String, dynamic>{
      'id': 10,
      'title': 'Album',
      'cover': 'http://localhost/covers/cover.jpg',
      'artist': {'id': 7, 'name': 'Artist'},
    },
  };

  Widget screen({
    required http.Client client,
    required List<dynamic> Function() getTracks,
    bool Function(dynamic)? isDownloaded,
    bool Function(int)? isDownloading,
    bool Function(int)? isFavorited,
    Future<void> Function(List<dynamic>)? onDownloadAlbum,
    Future<void> Function(List<int>)? onToggleFavorites,
    Future<bool> Function(int, List<int>)? onAddToPlaylist,
    Future<bool> Function(List<int>)? onCreatePlaylist,
    void Function(List<dynamic>, int)? onPlayTrack,
    void Function(dynamic)? onDeleteDownloadedTrack,
    Map<String, dynamic>? initialArtistData,
  }) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: ArtistScreen(
      artistId: 7,
      artistName: 'Artist',
      initialArtistData: initialArtistData,
      getAllTracks: getTracks,
      onPlayTrack: onPlayTrack ?? (_, _) {},
      onToggleFavorite: (_) {},
      onToggleFavorites: onToggleFavorites,
      getPlaylists: () => {42: 'Target playlist'},
      onAddToPlaylist: onAddToPlaylist,
      onCreatePlaylist: onCreatePlaylist,
      onDownloadTrack: (_) {},
      onDownloadAlbum: onDownloadAlbum,
      onDeleteDownloadedTrack: onDeleteDownloadedTrack ?? (_) {},
      isTrackDownloaded: isDownloaded ?? (_) => false,
      isTrackFavorited: isFavorited ?? (_) => false,
      isDownloading: isDownloading ?? (_) => false,
      libraryChanges: libraryChanges,
      httpClient: client,
    ),
  );

  void largeViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  for (final width in [375.0, 1440.0]) {
    testWidgets(
      'artist row selection batches likes and downloads at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final tracks = [track(1001, 'First'), track(1002, 'Second')];
        final favorites = <int>{1002};
        final favoriteBatches = <List<int>>[];
        final downloads = <int>[];
        final played = <int>[];
        final added = <int>[];
        final created = <int>[];
        var deletes = 0;
        final client = MockClient((_) async => http.Response('{}', 404));
        addTearDown(client.close);
        await tester.pumpWidget(
          screen(
            client: client,
            getTracks: () => tracks,
            initialArtistData: {'id': 7, 'name': 'Artist', 'bio': ''},
            isFavorited: favorites.contains,
            isDownloaded: (_) => true,
            onToggleFavorites: (ids) async {
              favoriteBatches.add(List<int>.of(ids));
              if (ids.every(favorites.contains)) {
                favorites.removeAll(ids);
              } else {
                favorites.addAll(ids);
              }
            },
            onAddToPlaylist: (id, ids) async {
              expect(id, 42);
              added.addAll(ids);
              return true;
            },
            onCreatePlaylist: (ids) async {
              created.addAll(ids);
              return true;
            },
            onDownloadAlbum: (selected) async =>
                downloads.addAll(selected.map((t) => t['id'] as int)),
            onPlayTrack: (selected, _) =>
                played.addAll(selected.map((t) => t['id'] as int)),
            onDeleteDownloadedTrack: (_) => deletes++,
          ),
        );
        await tester.pumpAndSettle();
        await settleImages(tester);
        if (width < 800) {
          await tester.longPress(find.text('First'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Second'));
        } else {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.tap(find.text('First'));
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pumpAndSettle();
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.tap(find.text('Second'));
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        }
        await tester.pumpAndSettle();
        expect(find.text('Выбрано: 2'), findsOneWidget);
        expect(played, isEmpty);
        final row = tester.widget<Container>(
          find.byKey(const ValueKey('artist_track_1001')),
        );
        expect(
          (row.decoration as BoxDecoration).color,
          Colors.black.withValues(alpha: 0.16),
        );
        await tester.tap(find.byKey(const ValueKey('artist_favorite_1002')));
        await tester.pumpAndSettle();
        expect(favoriteBatches, [
          [1001, 1002],
        ]);
        expect(favorites, {1001, 1002});
        await tester.tap(find.byKey(const ValueKey('selection_playlist')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Target playlist'));
        await tester.pumpAndSettle();
        expect(added, [1001, 1002]);
        await tester.tap(
          find.byKey(const ValueKey('create_playlist_from_selection')),
        );
        await tester.pumpAndSettle();
        expect(created, [1001, 1002]);
        expect(find.text('Выбрано: 2'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('artist_download_1001')));
        await tester.pumpAndSettle();
        expect(downloads, [1001, 1002]);
        expect(deletes, 0);
        await tester.tap(find.byKey(const ValueKey('play_track_selection')));
        await tester.pumpAndSettle();
        expect(played, [1001, 1002]);
        expect(find.text('Выбрано: 2'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await settleImages(tester);
      },
    );
  }

  Future<void> driveUntil(WidgetTester tester, Completer<void> signal) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
      if (signal.isCompleted) return;
    }
    fail('Expected HTTP request was not made.');
  }

  testWidgets('playback and library changes update the open artist screen', (
    tester,
  ) async {
    largeViewport(tester);
    final requested = Completer<void>();
    final client = MockClient((_) async {
      requested.complete();
      return http.Response('', 503);
    });
    var tracks = <dynamic>[track(1001, 'First song')];
    var downloaded = false;
    var downloading = false;
    var favorited = false;

    addTearDown(client.close);
    await tester.pumpWidget(
      screen(
        client: client,
        getTracks: () => tracks,
        isDownloaded: (_) => downloaded,
        isDownloading: (_) => downloading,
        isFavorited: (_) => favorited,
      ),
    );
    await driveUntil(tester, requested);
    await tester.pump();
    expect(find.text('First song'), findsOneWidget);
    expect(find.byIcon(Icons.graphic_eq), findsNothing);

    activeTrackNotifier.value = tracks.first;
    isPlayingNotifier.value = true;
    await tester.pump();
    expect(find.byIcon(Icons.graphic_eq), findsOneWidget);

    isPlayingNotifier.value = false;
    downloading = true;
    favorited = true;
    libraryChanges.notifyListeners();
    await tester.pump();
    expect(find.byIcon(Icons.graphic_eq), findsNothing);
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(find.byIcon(Icons.download), findsNothing);

    downloading = false;
    downloaded = true;
    libraryChanges.notifyListeners();
    await tester.pump();
    expect(find.byIcon(Icons.download_done), findsOneWidget);

    tracks = [track(1002, 'Replacement song')];
    libraryChanges.notifyListeners();
    await tester.pump();
    expect(find.text('Replacement song'), findsOneWidget);
    expect(find.text('First song'), findsNothing);

    await settleImages(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('fresh metadata appears without waiting for the artist photo', (
    tester,
  ) async {
    largeViewport(tester);
    final cache = File('${directory.path}/artist_details_7.json');
    cache.writeAsStringSync(jsonEncode({'id': 7, 'bio': 'Old biography'}));
    final fresh = {
      'id': 7,
      'name': 'Artist',
      'bio': 'Fresh biography',
      'photo': 'http://localhost/artists/new.jpg',
      'albums': [],
      'tracks': [],
    };
    final photoRequested = Completer<void>();
    final photoResponse = Completer<http.Response>();
    final client = MockClient((request) async {
      if (request.url.path.contains('/artists/new.jpg')) {
        photoRequested.complete();
        return photoResponse.future;
      }
      return http.Response(jsonEncode(fresh), 200);
    });

    addTearDown(client.close);
    // Seed the image cache: HTTP metadata is mocked separately from NetworkImage.
    final frame = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(
        File('${directory.path}/cover_1001.jpg').readAsBytesSync(),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame;
    });
    PaintingBinding.instance.imageCache.putIfAbsent(
      const NetworkImage('http://localhost/artists/new.jpg'),
      () => OneFrameImageStreamCompleter(
        Future.value(ImageInfo(image: frame!.image)),
      ),
    );
    addTearDown(PaintingBinding.instance.imageCache.clear);
    await tester.pumpWidget(screen(client: client, getTracks: () => []));
    await driveUntil(tester, photoRequested);
    await tester.pump();
    expect(find.text('Fresh biography'), findsOneWidget);
    expect(find.text('Old biography'), findsNothing);
    expect(photoResponse.isCompleted, isFalse);
    expect(jsonDecode(cache.readAsStringSync()), fresh);

    await tester.pumpWidget(const SizedBox.shrink());
    photoResponse.complete(http.Response('', 503));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'fresh catalog replaces server snapshots and matches artist IDs only',
    (tester) async {
      largeViewport(tester);
      final requested = Completer<void>();
      final oldTrack = track(1001, 'Old snapshot song');
      final client = MockClient((_) async {
        if (!requested.isCompleted) requested.complete();
        return http.Response(
          jsonEncode({
            'id': 7,
            'name': 'Old name',
            'bio': 'Biography stays',
            'tracks': [oldTrack],
            'albums': [oldTrack['album']],
          }),
          200,
        );
      });
      addTearDown(client.close);
      var tracks = <dynamic>[track(1002, 'Fresh catalog song')];
      (tracks.first['album']['artist'] as Map)['name'] = 'Renamed artist';
      final unrelated = track(1003, 'Artist tribute song');
      (unrelated['album']['artist'] as Map)['id'] = 70;
      (unrelated['album']['artist'] as Map)['name'] = 'Artist tribute';
      tracks.add(unrelated);
      await tester.pumpWidget(screen(client: client, getTracks: () => tracks));
      await driveUntil(tester, requested);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(find.text('Fresh catalog song'), findsOneWidget);
      expect(find.text('Old snapshot song'), findsNothing);
      expect(find.text('Artist tribute song'), findsNothing);
      expect(find.text('Renamed artist'), findsOneWidget);
      expect(find.text('Biography stays'), findsOneWidget);

      tracks = [unrelated];
      libraryChanges.notifyListeners();
      await tester.pump();
      expect(find.text('Fresh catalog song'), findsNothing);
      expect(find.text('Old snapshot song'), findsNothing);
      expect(find.text('Biography stays'), findsOneWidget);
      await settleImages(tester);
      final state = tester.state(find.byType(ArtistScreen)) as dynamic;
      final metadataIdle = Completer<void>();
      unawaited(
        (state.metadataIdle as Future<void>).then(
          (_) => metadataIdle.complete(),
        ),
      );
      await driveUntil(tester, metadataIdle);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('artist selection download receives current album tracks', (
    tester,
  ) async {
    largeViewport(tester);
    final requested = Completer<void>();
    final client = MockClient((_) async {
      requested.complete();
      return http.Response('', 503);
    });
    addTearDown(client.close);
    final first = track(1001, 'First album song');
    final second = track(1002, 'Second album song');
    (second['album'] as Map)['id'] = 20;
    (second['album'] as Map)['title'] = 'Other album';
    List<dynamic>? downloaded;
    await tester.pumpWidget(
      screen(
        client: client,
        getTracks: () => [first, second],
        onDownloadAlbum: (tracks) async {
          downloaded = tracks;
        },
      ),
    );
    await driveUntil(tester, requested);
    await tester.pump();
    await tester.tap(find.text('Other album').first);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('download_artist_selection')));
    await tester.pump();
    expect(downloaded!.map((track) => track['id']), [1002]);
    await settleImages(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late server response is ignored after leaving the screen', (
    tester,
  ) async {
    final requested = Completer<void>();
    final response = Completer<http.Response>();
    final client = MockClient((_) {
      requested.complete();
      return response.future;
    });

    addTearDown(client.close);
    await tester.pumpWidget(screen(client: client, getTracks: () => []));
    await driveUntil(tester, requested);
    await tester.pumpWidget(const SizedBox.shrink());
    response.complete(http.Response('{"id":7,"bio":"Late"}', 200));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    libraryChanges.notifyListeners();
    activeTrackNotifier.value = {'id': 1001};
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      File('${directory.path}/artist_details_7.json').existsSync(),
      isFalse,
    );
  });

  testWidgets(
    'featured artist album download includes other performers songs',
    (tester) async {
      largeViewport(tester);
      final requested = Completer<void>();
      final client = MockClient((_) async {
        if (!requested.isCompleted) requested.complete();
        return http.Response('', 503);
      });
      addTearDown(client.close);
      final collaboration = track(1001, 'Collaboration');
      (collaboration['album']['artist'] as Map)['id'] = 70;
      collaboration['artists'] = [
        {'id': 7, 'name': 'Artist'},
      ];
      final solo = track(1002, 'Other performer solo');
      (solo['album']['artist'] as Map)['id'] = 70;
      List<dynamic>? downloaded;
      await tester.pumpWidget(
        screen(
          client: client,
          getTracks: () => [collaboration, solo],
          onDownloadAlbum: (tracks) async => downloaded = tracks,
        ),
      );
      await driveUntil(tester, requested);
      await tester.pump();
      await tester.tap(find.text('Album').first);
      await tester.pump();
      expect(find.text('Other performer solo'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('download_artist_selection')));
      await tester.pump();
      expect(downloaded!.map((track) => track['id']), [1001, 1002]);
      await settleImages(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'late artist GET cannot replace newer live metadata or disk snapshot',
    (tester) async {
      largeViewport(tester);
      final requested = Completer<void>();
      final response = Completer<http.Response>();
      final client = MockClient((_) {
        if (!requested.isCompleted) requested.complete();
        return response.future;
      });
      addTearDown(client.close);
      final snapshot = File('${directory.path}/artist_details_7.json');
      await tester.runAsync(
        () => snapshot.writeAsString(
          jsonEncode({'id': 7, 'name': 'Artist', 'bio': 'Initial bio'}),
        ),
      );
      await tester.pumpWidget(
        screen(client: client, getTracks: () => [track(1001, 'Song')]),
      );
      await driveUntil(tester, requested);
      await tester.runAsync(
        () => snapshot.writeAsString(
          jsonEncode({'id': 7, 'name': 'Artist', 'bio': 'Fresh manual bio'}),
        ),
      );
      libraryChanges.notifyListeners();
      final state = tester.state(find.byType(ArtistScreen)) as dynamic;
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      expect(find.text('Fresh manual bio'), findsOneWidget);
      response.complete(
        http.Response(
          jsonEncode({
            'id': 7,
            'name': 'Old name',
            'bio': 'Stale response',
            'tracks': [],
            'albums': [],
          }),
          200,
        ),
      );
      final idle = Completer<void>();
      unawaited(
        (state.metadataIdle as Future<void>).then((_) => idle.complete()),
      );
      await driveUntil(tester, idle);
      expect(find.text('Fresh manual bio'), findsOneWidget);
      expect(find.text('Stale response'), findsNothing);
      final saved = await tester.runAsync(() => snapshot.readAsString());
      expect(jsonDecode(saved!)['bio'], 'Fresh manual bio');
      await settleImages(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('an album with no optional cover keeps its fallback icon', (
    tester,
  ) async {
    largeViewport(tester);
    final requested = Completer<void>();
    final client = MockClient((_) async {
      requested.complete();
      return http.Response('', 503);
    });
    addTearDown(client.close);
    final song = track(1003, 'No artwork song');
    (song['album'] as Map)['cover'] = null;
    await tester.pumpWidget(screen(client: client, getTracks: () => [song]));
    await driveUntil(tester, requested);
    await settleImages(tester);
    expect(find.text('No artwork song'), findsOneWidget);
    expect(find.byIcon(Icons.album), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'selected album remains downloadable from initial detail fallback',
    (tester) async {
      largeViewport(tester);
      final requested = Completer<void>();
      final first = track(1001, 'Fallback collaboration');
      (first['album']['artist'] as Map)['id'] = 70;
      first['artists'] = [
        {'id': 7, 'name': 'Artist'},
      ];
      final second = track(1002, 'Fallback solo');
      (second['album']['artist'] as Map)['id'] = 70;
      final client = MockClient((_) async {
        if (!requested.isCompleted) requested.complete();
        return http.Response(
          jsonEncode({
            'id': 7,
            'name': 'Artist',
            'tracks': [first],
            'albums': [
              {
                ...first['album'] as Map,
                'tracks': [first, second],
              },
            ],
          }),
          200,
        );
      });
      addTearDown(client.close);
      List<dynamic>? downloaded;
      await tester.pumpWidget(
        screen(
          client: client,
          getTracks: () => [],
          onDownloadAlbum: (tracks) async => downloaded = tracks,
        ),
      );
      await driveUntil(tester, requested);
      final state = tester.state(find.byType(ArtistScreen)) as dynamic;
      final idle = Completer<void>();
      unawaited(
        (state.metadataIdle as Future<void>).then((_) => idle.complete()),
      );
      await driveUntil(tester, idle);
      await tester.tap(find.text('Album').first);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('download_artist_selection')));
      await tester.pump();
      expect(downloaded!.map((track) => track['id']), [1001, 1002]);
      libraryChanges.notifyListeners();
      await tester.pump();
      expect(find.text('Fallback collaboration'), findsNothing);
      final latestIdle = Completer<void>();
      unawaited(
        (state.metadataIdle as Future<void>).then((_) => latestIdle.complete()),
      );
      await driveUntil(tester, latestIdle);
      await settleImages(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final width in [375.0, 1440.0]) {
    testWidgets(
      'artist layout keeps background and cached biography at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final background = img.Image(width: 32, height: 32)
          ..clear(img.ColorRgb8(60, 78, 98));
        File(
          '${directory.path}/background.png',
        ).writeAsBytesSync(img.encodePng(background));
        customBackgroundNotifier.value = 'background.png';
        final biography =
            'Биография из локального каталога. '
            'Исполнитель, альбомы и совместные записи доступны без подключения к серверу. '
            'Музыка и сохранённые данные остаются на устройстве.';
        File(
          '${directory.path}/artist_details_7.json',
        ).writeAsStringSync(jsonEncode({'id': 7, 'bio': 'Stale detail cache'}));
        final requested = Completer<void>();
        final client = MockClient((_) async {
          requested.complete();
          return http.Response('', 503);
        });
        addTearDown(client.close);
        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('artist_preview'),
            child: screen(
              client: client,
              getTracks: () => [track(1001, 'Трек из библиотеки')],
              initialArtistData: {'id': 7, 'name': 'Кишлак', 'bio': biography},
            ),
          ),
        );
        expect(find.text(biography), findsOneWidget);
        await driveUntil(tester, requested);
        await settleImages(tester);
        await tester.pumpAndSettle();
        expect(find.text(biography), findsOneWidget);
        expect(find.text('Stale detail cache'), findsNothing);
        expect(find.byKey(const ValueKey('artist_background')), findsOneWidget);
        final portrait = tester.widget<Container>(
          find.byKey(const ValueKey('artist_portrait')),
        );
        final decoration = portrait.decoration! as BoxDecoration;
        expect(decoration.boxShadow, isNull);
        expect(decoration.gradient, isNull);
        expect(
          tester.getSize(find.text(biography)).width,
          lessThanOrEqualTo(780),
        );
        expect(tester.takeException(), isNull);
        const previewDirectory = String.fromEnvironment('SHIKI_UI_PREVIEW_DIR');
        if (previewDirectory.isNotEmpty) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('artist_preview')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            try {
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final target = File(
                '$previewDirectory/artist_${width.toInt()}.png',
              );
              await target.parent.create(recursive: true);
              await target.writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
        if (width == 375) {
          final expand = find.byKey(const ValueKey('artist_bio_expand'));
          expect(expand, findsOneWidget);
          await tester.tap(expand);
          await tester.pump();
          expect(tester.widget<Text>(find.text(biography)).maxLines, isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
