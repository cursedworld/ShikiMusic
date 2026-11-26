import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shiki/globals.dart';
import 'package:shiki/screens/settings_screen.dart';
import 'package:shiki/widgets/player_backdrop.dart';
import 'package:video_player/video_player.dart';

import 'fixtures/animated_background.dart';

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
  ValueNotifier<int>? dimming,
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
                dimming: dimming ?? const AlwaysStoppedAnimation(65),
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

  testWidgets('live dimming covers photo, GIF and playlist photo', (
    tester,
  ) async {
    const playlistPhoto = 'playlist_bg_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.jpg';
    const globalPhoto = 'custom_bg_2.jpg';
    const gif = 'custom_bg_3.gif';
    final jpeg = img.encodeJpg(img.Image(width: 32, height: 16));
    final gifBytes = testGif();
    final directory = (await tester.runAsync(() async {
      final tmp = await Directory.systemTemp.createTemp('shiki_dimming_');
      for (final name in [playlistPhoto, globalPhoto]) {
        await File('${tmp.path}/$name').writeAsBytes(jpeg);
      }
      await File('${tmp.path}/$gif').writeAsBytes(gifBytes);
      return tmp;
    }))!;
    addTearDown(() => directory.delete(recursive: true));
    final dimming = ValueNotifier(65);
    addTearDown(dimming.dispose);
    Future<VideoPlayerController> open(File file) async {
      fail('A still image or GIF must not open a video decoder.');
    }

    Finder photoDecoration() => find.byWidgetPredicate(
      (widget) =>
          widget is DecoratedBox &&
          (widget.decoration as BoxDecoration).image != null,
    );
    ColorFilter? filter() =>
        (tester.widget<DecoratedBox>(photoDecoration()).decoration
                as BoxDecoration)
            .image!
            .colorFilter;
    await _mount(
      tester,
      open,
      directory: directory.path,
      name: globalPhoto,
      dimming: dimming,
    );
    final controls = tester.element(find.text('Music controls'));
    expect(
      filter(),
      const ColorFilter.mode(Color(0xA6000000), BlendMode.srcOver),
    );
    dimming.value = 20;
    await tester.pump();
    expect(
      filter(),
      const ColorFilter.mode(Color(0x33000000), BlendMode.srcOver),
    );

    await _mount(
      tester,
      open,
      directory: directory.path,
      name: gif,
      dimming: dimming,
    );
    final provider = tester.widget<Image>(find.byType(Image)).image;
    dimming.value = 80;
    await tester.pump();
    final gifImage = tester.widget<Image>(find.byType(Image));
    expect(gifImage.image, same(provider));
    expect(gifImage.color, const Color(0xCC000000));

    await _mount(
      tester,
      open,
      directory: directory.path,
      name: gif,
      playlistPhoto: playlistPhoto,
      dimming: dimming,
    );
    dimming.value = 40;
    await tester.pump();
    expect(
      tester.widget<Image>(find.byType(Image)).color,
      const Color(0x66000000),
    );
    expect(tester.element(find.text('Music controls')), same(controls));
    await tester.pumpWidget(const SizedBox());
    expect(File('${directory.path}/$playlistPhoto').readAsBytesSync(), jpeg);
    expect(File('${directory.path}/$globalPhoto').readAsBytesSync(), jpeg);
    expect(File('${directory.path}/$gif').readAsBytesSync(), gifBytes);
  });

  testWidgets(
    'the settings preview reuses the live player video while dragging',
    (tester) async {
      const name = 'custom_bg_4.mp4';
      const bytes = [0, 1, 2, 3];
      final directory = (await tester.runAsync(() async {
        final tmp = await Directory.systemTemp.createTemp(
          'shiki_dimming_route_',
        );
        await File('${tmp.path}/$name').writeAsBytes(bytes);
        await File(
          '${tmp.path}/shiki_settings.json',
        ).writeAsString('{"customBackground":"$name"}');
        return tmp;
      }))!;
      addTearDown(() => directory.delete(recursive: true));
      final previousDimming = backgroundDimmingNotifier.value;
      final previousBackground = customBackgroundNotifier.value;
      backgroundDimmingNotifier.value = 65;
      addTearDown(() {
        backgroundDimmingNotifier.value = previousDimming;
        customBackgroundNotifier.value = previousBackground;
      });
      final videos = <_TestVideo>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: PlayerBackdrop(
                directory: directory.path,
                name: name,
                dimming: backgroundDimmingNotifier,
                gradient: const LinearGradient(
                  colors: [Colors.black, Colors.blueGrey],
                ),
                allowMotion: true,
                openVideo: (file) async {
                  final video = _TestVideo(file);
                  videos.add(video);
                  return video;
                },
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    SettingsRoute(
                      builder: (_) => SettingsScreen(
                        dataDirectoryProvider: () async => directory,
                      ),
                    ),
                  ),
                  child: const Text('Open settings fixture'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(videos.single.starts, 1);
      await tester.tap(find.text('Open settings fixture'));
      await tester.pumpAndSettle();
      expect(videos.single.closes, 1);

      final row = find.byKey(const ValueKey('settings_background_dimming'));
      await tester.scrollUntilVisible(
        row,
        100,
        scrollable: find.byType(Scrollable).first,
      );
      final toggle = find.descendant(of: row, matching: find.byType(InkWell));
      for (
        var attempt = 0;
        attempt < 80 && tester.widget<InkWell>(toggle).onTap == null;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      expect(tester.widget<InkWell>(toggle).onTap, isNotNull);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(row, findsNothing);
      expect(videos, hasLength(2));
      final preview = videos.last;
      expect(
        tester.widget<VideoPlayer>(find.byType(VideoPlayer)).controller,
        same(preview),
      );
      final slider = find.byKey(const ValueKey('background_dimming_slider'));
      await tester.drag(slider, const Offset(70, 0));
      await tester.pumpAndSettle();
      final percent = tester.widget<Slider>(slider).value.round();
      expect(percent, isNot(65));
      expect(backgroundDimmingNotifier.value, percent);
      expect(
        find.descendant(
          of: find.byType(PlayerBackdrop),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is ColoredBox &&
                widget.color ==
                    Color.fromARGB((percent * 255 / 100).round(), 0, 0, 0),
          ),
        ),
        findsOneWidget,
      );
      expect(videos, hasLength(2));
      expect(preview.starts, 1);
      expect(preview.closes, 0);
      await tester.tap(find.byKey(const ValueKey('background_dimming_cancel')));
      await tester.pumpAndSettle();
      expect(row, findsOneWidget);
      expect(preview.closes, 1);
      expect(backgroundDimmingNotifier.value, 65);
      await tester.pumpWidget(const SizedBox());
      expect(File('${directory.path}/$name').readAsBytesSync(), bytes);
    },
  );

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
