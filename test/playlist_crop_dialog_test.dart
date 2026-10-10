import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shiki/playlist_artwork.dart';
import 'package:shiki/widgets/playlist_crop_dialog.dart';

void main() {
  late Directory directory;
  late File photo;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shiki-crop-dialog-');
    final image = img.Image(width: 600, height: 300)
      ..clear(img.ColorRgb8(255, 0, 0));
    img.fillRect(
      image,
      x1: 300,
      y1: 0,
      x2: 599,
      y2: 299,
      color: img.ColorRgb8(0, 0, 255),
    );
    photo = File('${directory.path}/photo.png')
      ..writeAsBytesSync(img.encodePng(image));
  });
  tearDown(() async => directory.delete(recursive: true));

  Future<void> driveUntil(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 150; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (done()) return;
    }
    fail('Crop image operation did not complete');
  }

  Future<void> open(
    WidgetTester tester,
    void Function(CroppedPlaylistArtwork?) result, {
    String? path,
  }) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('crop_screenshot'),
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => result(
                  await showPlaylistCropDialog(context, path ?? photo.path),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await driveUntil(
      tester,
      () =>
          find.byType(InteractiveViewer).evaluate().isNotEmpty ||
          find
              .text('Не удалось сохранить обложку плейлиста')
              .evaluate()
              .isNotEmpty,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('pan and zoom crop exactly the region inside the circle', (
    tester,
  ) async {
    CroppedPlaylistArtwork? result;
    var completed = false;
    await open(tester, (value) {
      result = value;
      completed = true;
    });
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    final initialX = viewer.transformationController!.value.storage[12];
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(InteractiveViewer)),
    );
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-70, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      viewer.transformationController!.value.storage[12],
      lessThan(initialX),
    );
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('playlist_crop_zoom')),
    );
    slider.onChanged!(2);
    await tester.pump();
    expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 2);
    await tester.tap(find.byKey(const ValueKey('playlist_crop_apply')));
    await driveUntil(tester, () => completed);
    final cropped = img.decodePng(result!.bytes)!;
    expect([cropped.width, cropped.height], [150, 150]);
    expect(cropped.getPixel(75, 75).b, 255);
    expect(cropped.getPixel(75, 75).r, 0);
    expect(photo.existsSync(), isTrue);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel leaves original image and produces no avatar file', (
    tester,
  ) async {
    var completed = false;
    CroppedPlaylistArtwork? result;
    final before = photo.readAsBytesSync();
    await open(tester, (value) {
      completed = true;
      result = value;
    });
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(result, isNull);
    expect(photo.readAsBytesSync(), before);
    expect(directory.listSync().length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('corrupt photo reports an error and cannot be applied', (
    tester,
  ) async {
    final broken = File('${directory.path}/broken.png')
      ..writeAsBytesSync([1, 2, 3]);
    await open(tester, (_) {}, path: broken.path);
    expect(find.text('Не удалось сохранить обложку плейлиста'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('playlist_crop_apply')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final width in [375.0, 768.0, 1024.0, 1440.0]) {
    testWidgets('crop controls fit at width $width', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await open(tester, (_) {});
      expect(tester.takeException(), isNull);
      final viewport = tester.getRect(
        find.byKey(const ValueKey('playlist_crop_viewport')),
      );
      expect(viewport.left, greaterThanOrEqualTo(0));
      expect(viewport.right, lessThanOrEqualTo(width));
      expect(
        tester
            .getSize(find.byKey(const ValueKey('playlist_crop_reset')))
            .height,
        greaterThanOrEqualTo(44),
      );
      if (const bool.fromEnvironment('SHIKI_CROP_SCREENSHOT') &&
          (width == 375 || width == 1024)) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('crop_screenshot')),
          );
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('build').create(recursive: true);
          await File(
            'build/playlist_crop_${width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
    });
  }
}
