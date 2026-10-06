import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shiki/globals.dart';
import 'package:shiki/screens/artist_screen.dart';

void main() {
  late Directory directory;
  late String previousLocalPath;
  late dynamic previousTrack;
  late bool previousPlaying;
  late ChangeNotifier libraryChanges;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shiki_artist_test_');
    previousLocalPath = globalLocalPath;
    previousTrack = activeTrackNotifier.value;
    previousPlaying = isPlayingNotifier.value;
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
  }) => MaterialApp(
    home: ArtistScreen(
      artistId: 7,
      artistName: 'Artist',
      getAllTracks: getTracks,
      onPlayTrack: (_, _) {},
      onToggleFavorite: (_) {},
      onDownloadTrack: (_) {},
      onDownloadAlbum: onDownloadAlbum,
      onDeleteDownloadedTrack: (_) {},
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
}
