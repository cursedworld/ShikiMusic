import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shiki/widgets/player_backdrop.dart';
import 'package:video_player/video_player.dart';

class _TestVideo extends VideoPlayerController {
  _TestVideo(super.file) : super.file() {
    value = value.copyWith(isInitialized: true, size: const Size(1920, 1080));
  }

  int starts = 0;
  int closes = 0;

  @override
  Future<void> play() async => starts++;

  @override
  Future<void> dispose() async {
    closes++;
    await super.dispose();
  }
}

Future<void> _mount(
  WidgetTester tester,
  BackgroundVideoOpener open, {
  bool routeVisible = true,
  bool allowMotion = true,
  bool reduceMotion = false,
  String? name = 'custom_bg_1.mp4',
  String? playlistPhoto,
  String directory = 'test-profile',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reduceMotion),
          child: TickerMode(
            enabled: routeVisible,
            child: Scaffold(
              body: PlayerBackdrop(
                directory: directory,
                name: name,
                playlistPhoto: playlistPhoto,
                gradient: const LinearGradient(
                  colors: [Colors.black, Colors.blueGrey],
                ),
                allowMotion: allowMotion,
                openVideo: open,
                child: const Text('Music controls'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'a playlist photo replaces the global animation without mounting a second player',
    (tester) async {
      const photo = 'playlist_bg_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.jpg';
      final directory = (await tester.runAsync(() async {
        final path = await Directory.systemTemp.createTemp(
          'shiki_photo_backdrop_',
        );
        await File(
          '${path.path}/$photo',
        ).writeAsBytes(img.encodeJpg(img.Image(width: 32, height: 16)));
        return path;
      }))!;
      addTearDown(() => directory.delete(recursive: true));
      final controllers = <_TestVideo>[];
      Future<VideoPlayerController> open(File file) async {
        final next = _TestVideo(file);
        controllers.add(next);
        return next;
      }

      await _mount(tester, open, directory: directory.path);
      expect(controllers.single.starts, 1);
      final controls = tester.element(find.text('Music controls'));
      await _mount(
        tester,
        open,
        directory: directory.path,
        playlistPhoto: photo,
      );
      expect(find.byType(VideoPlayer), findsNothing);
      expect(find.byType(Image), findsOneWidget);
      expect(controllers.single.closes, 1);
      expect(tester.element(find.text('Music controls')), same(controls));
      await _mount(tester, open, directory: directory.path);
      expect(controllers.length, 2);
      expect(controllers.last.starts, 1);
    },
  );

  testWidgets('default and GIF backgrounds never open a video decoder', (
    tester,
  ) async {
    var opens = 0;
    Future<VideoPlayerController> open(File file) async {
      opens++;
      return _TestVideo(file);
    }

    await _mount(tester, open, name: null);
    final controls = tester.element(find.text('Music controls'));
    await _mount(tester, open, name: 'custom_bg_5.gif');
    expect(tester.element(find.text('Music controls')), same(controls));
    expect(find.byType(Image), findsOneWidget);
    await _mount(tester, open, name: 'custom_bg_5.gif', reduceMotion: true);
    expect(find.byType(Image), findsNothing);
    expect(opens, 0);
  });

  testWidgets(
    'video releases on hiding even before another frame is rendered',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final controllers = <_TestVideo>[];
      Future<VideoPlayerController> open(File file) async {
        final controller = _TestVideo(file);
        controllers.add(controller);
        return controller;
      }

      await _mount(tester, open);
      expect(controllers.single.starts, 1);
      expect(find.byType(VideoPlayer), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.idle();
      expect(controllers.single.closes, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(controllers.length, 2);
      expect(controllers.last.starts, 1);
      await _mount(tester, open, routeVisible: false);
      expect(controllers.last.closes, 1);
      expect(find.byType(VideoPlayer), findsNothing);
      await _mount(tester, open, allowMotion: false);
      await _mount(tester, open, reduceMotion: true);
      expect(controllers.length, 2);
    },
  );

  testWidgets('late initialization cannot play after the backdrop was hidden', (
    tester,
  ) async {
    final pending = Completer<VideoPlayerController>();
    Future<VideoPlayerController> open(File file) => pending.future;
    await _mount(tester, open);
    await _mount(tester, open, routeVisible: false);
    final video = _TestVideo(File('late.mp4'));
    pending.complete(video);
    await tester.pump();
    expect(video.starts, 0);
    expect(video.closes, 1);
    expect(find.byType(VideoPlayer), findsNothing);
  });
}
