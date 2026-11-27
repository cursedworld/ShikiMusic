import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/localization.dart';
import 'package:shiki/widgets/clip_preview.dart';
import 'package:video_player/video_player.dart';

const _cover = ColoredBox(color: Colors.brown);
const _frame = ValueKey('expanded_clip_frame');

VideoPlayerController _clip([Size size = const Size(1280, 720)]) {
  final controller = VideoPlayerController.asset('unused-test-clip.mp4')
    ..value = VideoPlayerValue(
      duration: const Duration(minutes: 3),
      position: const Duration(seconds: 46),
      isInitialized: true,
      isPlaying: true,
      volume: 0,
      size: size,
    );
  addTearDown(controller.dispose);
  return controller;
}

Future<ValueNotifier<VideoPlayerController?>> _showPreview(
  WidgetTester tester,
  VideoPlayerController controller,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 720);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final source = ValueNotifier<VideoPlayerController?>(controller);
  addTearDown(source.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Center(
          child: SizedBox.square(
            dimension: 240,
            child: ClipOval(
              child: ValueListenableBuilder(
                valueListenable: source,
                builder: (context, clip, child) => clip == null
                    ? child!
                    : ClipPreview(controller: clip, cover: child!),
                child: _cover,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return source;
}

void main() {
  final video = find.byType(VideoPlayer, skipOffstage: false);
  final frame = find.byKey(_frame);

  testWidgets(
    'hovering the clip leaves it clear but keeps its accessible name',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await _showPreview(tester, _clip());
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(4, 4));
        addTearDown(mouse.removePointer);

        await mouse.moveTo(tester.getCenter(find.byType(ClipPreview)));
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();

        expect(find.text(tr('expand_clip')), findsNothing);
        expect(find.byTooltip(tr('expand_clip')), findsNothing);
        expect(find.bySemanticsLabel(tr('expand_clip')), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('a click moves the same playing clip into a dialog and back', (
    tester,
  ) async {
    final controller = _clip();
    final playback = controller.value;
    await _showPreview(tester, controller);

    await tester.tap(find.byType(ClipPreview));
    await tester.pumpAndSettle();

    expect(frame, findsOneWidget);
    expect(video, findsOneWidget);
    expect(tester.widget<VideoPlayer>(video).controller, same(controller));
    expect(controller.value, same(playback));
    final preview = tester.element(find.byType(ClipPreview));
    expect(TickerMode.valuesOf(preview).enabled, isTrue);

    await tester.tap(find.byTooltip(tr('close')));
    await tester.pump();
    expect(video, findsOneWidget);
    await tester.pumpAndSettle();

    expect(frame, findsNothing);
    expect(video, findsOneWidget);
    expect(tester.widget<VideoPlayer>(video).controller, same(controller));
    expect(controller.value, same(playback));
  });

  testWidgets('Tab and Enter open the clip and Escape closes it', (
    tester,
  ) async {
    await _showPreview(tester, _clip());

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(frame, findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(frame, findsNothing);
  });

  for (final size in [const Size(1280, 720), const Size(720, 1280)]) {
    testWidgets('expanded clip fits its window without cropping a $size clip', (
      tester,
    ) async {
      await _showPreview(tester, _clip(size));
      await tester.tap(find.byType(ClipPreview));
      await tester.pumpAndSettle();

      for (final window in [const Size(1280, 720), const Size(920, 360)]) {
        tester.view.physicalSize = window;
        await tester.pumpAndSettle();
        final panel = tester.getRect(frame);
        final picture = tester.getRect(video);
        expect(panel.width, closeTo(window.width * .92, 1));
        expect(panel.height, closeTo(window.height * .90, 1));
        expect(picture.width / picture.height, closeTo(size.aspectRatio, .001));
        expect(picture.width, lessThanOrEqualTo(panel.width + .01));
        expect(picture.height, lessThanOrEqualTo(panel.height + .01));
      }

      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(frame, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('changing or removing the clip dismisses its old dialog', (
    tester,
  ) async {
    final source = await _showPreview(tester, _clip());
    await tester.tap(find.byType(ClipPreview));
    await tester.pumpAndSettle();
    expect(frame, findsOneWidget);

    final next = _clip();
    source.value = next;
    await tester.pumpAndSettle();
    expect(frame, findsNothing);
    expect(tester.widget<VideoPlayer>(video).controller, same(next));

    await tester.tap(find.byType(ClipPreview));
    await tester.pumpAndSettle();
    expect(frame, findsOneWidget);
    source.value = null;
    await tester.pumpAndSettle();
    expect(frame, findsNothing);
    expect(video, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
