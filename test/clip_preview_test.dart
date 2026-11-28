import 'dart:ui' show PointerDeviceKind, SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/localization.dart';
import 'package:shiki/widgets/clip_preview.dart';
import 'package:video_player/video_player.dart';

const _cover = ColoredBox(color: Colors.brown);
const _frame = ValueKey('expanded_clip_frame');
const _desktop = TargetPlatformVariant({
  TargetPlatform.windows,
  TargetPlatform.linux,
  TargetPlatform.macOS,
});

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
  VideoPlayerController controller, {
  ValueChanged<bool>? onExpanded,
  ValueNotifier<int?>? track,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 720);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final source = ValueNotifier<VideoPlayerController?>(controller);
  addTearDown(source.dispose);
  final selectedTrack = track ?? ValueNotifier<int?>(1);
  if (track == null) addTearDown(selectedTrack.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Center(
          child: SizedBox.square(
            dimension: 240,
            child: ClipOval(
              child: ValueListenableBuilder(
                valueListenable: selectedTrack,
                builder: (context, id, child) => id == null
                    ? child!
                    : ClipPreview(
                        key: ValueKey(id),
                        controller: source,
                        cover: child!,
                        onExpanded: onExpanded ?? (_) {},
                      ),
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

  testWidgets('the clip has no close button and a click outside closes it', (
    tester,
  ) async {
    await _showPreview(tester, _clip());
    await tester.tap(find.byType(ClipPreview));
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: frame, matching: find.byIcon(Icons.close)),
      findsNothing,
    );
    await tester.tapAt(tester.getCenter(video));
    await tester.pumpAndSettle();
    expect(frame, findsOneWidget);

    final panel = tester.getRect(frame);
    await tester.tapAt(Offset(panel.right + 4, panel.center.dy));
    await tester.pumpAndSettle();
    expect(frame, findsNothing);
    expect(video, findsOneWidget);
  });

  testWidgets(
    'the expanded clip can be dismissed by assistive technology',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await _showPreview(tester, _clip());
        await tester.tap(find.byType(ClipPreview));
        await tester.pumpAndSettle();

        tester.semantics.performAction(
          find.semantics.byLabel(tr('play_video_clip_desc')),
          SemanticsAction.dismiss,
        );
        await tester.pumpAndSettle();
        expect(frame, findsNothing);
        expect(video, findsOneWidget);
      } finally {
        semantics.dispose();
      }
    },
    variant: _desktop,
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

    await tester.tapAt(const Offset(4, 4));
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
  }, variant: _desktop);

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

  testWidgets('switching quality keeps one surface and the same dialog', (
    tester,
  ) async {
    final small = _clip(const Size(640, 360));
    final large = _clip(const Size(1920, 1080));
    final changes = <bool>[];
    final source = await _showPreview(tester, small, onExpanded: changes.add);
    await tester.tap(find.byType(ClipPreview));
    await tester.pumpAndSettle();
    expect(changes, [true]);
    expect(tester.widget<VideoPlayer>(video).controller, same(small));

    source.value = null;
    await tester.pump();
    expect(frame, findsOneWidget);
    expect(video, findsNothing);
    source.value = large;
    await tester.pumpAndSettle();
    expect(frame, findsOneWidget);
    expect(tester.widget<VideoPlayer>(video).controller, same(large));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(changes, [true]);
    await tester.pumpAndSettle();
    expect(changes, [true, false]);
    source.value = small;
    await tester.pumpAndSettle();
    expect(tester.widget<VideoPlayer>(video).controller, same(small));
  });

  testWidgets('changing or removing the track dismisses its old dialog', (
    tester,
  ) async {
    final track = ValueNotifier<int?>(1);
    addTearDown(track.dispose);
    final source = await _showPreview(tester, _clip(), track: track);
    await tester.tap(find.byType(ClipPreview));
    await tester.pumpAndSettle();
    expect(frame, findsOneWidget);

    final next = _clip();
    track.value = 2;
    source.value = next;
    await tester.pumpAndSettle();
    expect(frame, findsNothing);
    expect(tester.widget<VideoPlayer>(video).controller, same(next));

    await tester.tap(find.byType(ClipPreview));
    await tester.pumpAndSettle();
    expect(frame, findsOneWidget);
    track.value = null;
    await tester.pumpAndSettle();
    expect(frame, findsNothing);
    expect(video, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
