import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shiki/screens/home_screen.dart';

// Exercise the real sidebar builder without starting playback or reading data.
class _SidebarLayoutState extends MainAppScreenState {
  _SidebarLayoutState(this.artwork);

  final ImageProvider artwork;

  @override
  ImageProvider getPlaylistImage(String pathOrUrl) => artwork;
}

void main() {
  final photo = img.Image(width: 100, height: 100)
    ..clear(img.ColorRgb8(0, 0, 255));
  img.fillRect(
    photo,
    x1: 0,
    y1: 0,
    x2: 99,
    y2: 29,
    color: img.ColorRgb8(0, 255, 0),
  );
  final artwork = MemoryImage(img.encodePng(photo));

  Future<void> showSidebar(
    WidgetTester tester, {
    required double width,
    required bool selected,
    bool withArtwork = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final state = _SidebarLayoutState(artwork)
      ..navId = selected ? 3 : 0
      ..myPlaylists = [
        {'id': 1, 'name': 'Playlist', 'image': withArtwork ? 'photo.png' : ''},
      ];
    addTearDown(() {
      state.searchInput.dispose();
      state.searchFocusNode.dispose();
      state.currentPositionNotifier.dispose();
      state.fullDurationNotifier.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              RepaintBoundary(
                key: const ValueKey('sidebar'),
                child: state.buildSidebar(),
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
      if (PaintingBinding.instance.imageCache.pendingImageCount == 0) break;
    }
    await tester.pumpAndSettle();
  }

  for (final width in [375.0, 1440.0]) {
    for (final selected in [false, true]) {
      testWidgets(
        'sidebar avatar preserves crop at width $width, selected $selected',
        (tester) async {
          await showSidebar(tester, width: width, selected: selected);
          final diameter = selected ? 36.0 : 28.0;
          final avatar = find.byType(CircleAvatar);
          expect(tester.getSize(avatar), Size.square(diameter));

          final gesture = find.ancestor(
            of: avatar,
            matching: find.byType(GestureDetector),
          );
          expect(tester.getSize(gesture), Size(70, diameter));
          final detector = tester.widget<GestureDetector>(gesture);
          expect(detector.onTap, isNotNull);
          expect(detector.onSecondaryTapDown, isNotNull);
          expect(detector.onLongPressStart, isNotNull);

          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('sidebar')),
          );
          final avatarRect = tester.getRect(avatar);
          final sample = boundary.globalToLocal(
            Offset(avatarRect.center.dx, avatarRect.top + diameter / 4),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            try {
              final pixels = await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              );
              final offset =
                  (sample.dy.floor() * image.width + sample.dx.floor()) * 4;
              // Allow interpolation at this small size, but not the blue
              // center that the stretched avatar displayed before the fix.
              expect(pixels!.getUint8(offset), 0);
              expect(
                pixels.getUint8(offset + 1),
                greaterThan(240),
                reason:
                    'The selected top of the image must not be cropped again',
              );
              expect(pixels.getUint8(offset + 2), lessThan(16));
            } finally {
              image.dispose();
            }
          });
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('playlist without artwork keeps its centered music icon', (
    tester,
  ) async {
    await showSidebar(tester, width: 1024, selected: false, withArtwork: false);
    final avatar = find.byType(CircleAvatar);
    expect(tester.getSize(avatar), const Size.square(28));
    expect(find.byIcon(Icons.music_note), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
