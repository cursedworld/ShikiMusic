import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shiki/playlist_artwork.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shiki-playlist-crop-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  File source(img.Image image, {bool gif = false}) {
    final file = File('${directory.path}/original.${gif ? 'gif' : 'png'}');
    file.writeAsBytesSync(gif ? img.encodeGif(image) : img.encodePng(image));
    return file;
  }

  test(
    'crop chooses requested square and leaves original image unchanged',
    () async {
      final image = img.Image(width: 400, height: 200)
        ..clear(img.ColorRgb8(255, 0, 0));
      img.fillRect(
        image,
        x1: 200,
        y1: 0,
        x2: 399,
        y2: 199,
        color: img.ColorRgb8(0, 0, 255),
      );
      final original = source(image);
      final before = original.readAsBytesSync();
      final artwork = cropPlaylistArtwork(
        PlaylistCropSelection(
          sourcePath: original.path,
          left: 0.5,
          top: 0,
          side: 1,
        ),
      );
      final decoded = img.decodePng(artwork.bytes)!;
      expect([decoded.width, decoded.height], [200, 200]);
      expect(decoded.getPixel(100, 100).b, 255);
      expect(decoded.getPixel(100, 100).r, 0);
      final name = await saveCroppedPlaylistArtwork(directory, artwork, 987);
      expect(name, 'playlist_artwork_987.png');
      expect(
        resolvePlaylistArtwork(directory, name).readAsBytesSync(),
        artwork.bytes,
      );
      expect(original.readAsBytesSync(), before);
    },
  );

  test(
    'preview and final avatar are bounded without distorting aspect ratio',
    () {
      final original = source(img.Image(width: 2000, height: 1000));
      final preview = loadPlaylistArtworkPreview(original.path);
      expect([preview.width, preview.height], [2000, 1000]);
      final previewImage = img.decodePng(preview.bytes)!;
      expect([previewImage.width, previewImage.height], [1024, 512]);
      final artwork = cropPlaylistArtwork(
        PlaylistCropSelection(
          sourcePath: original.path,
          left: 0.25,
          top: 0,
          side: 1,
        ),
      );
      final avatar = img.decodePng(artwork.bytes)!;
      expect([avatar.width, avatar.height], [512, 512]);
    },
  );

  test('zoomed crop and edge rounding select square pixels correctly', () {
    final original = source(img.Image(width: 300, height: 600));
    final result = cropPlaylistArtwork(
      PlaylistCropSelection(
        sourcePath: original.path,
        left: 0.5,
        top: 0.75,
        side: 0.5,
      ),
    );
    final image = img.decodePng(result.bytes)!;
    expect([image.width, image.height], [150, 150]);
  });

  test('animated GIF avatars retain frames and timings after cropping', () {
    final image = img.Image(width: 80, height: 40)
      ..clear(img.ColorRgb8(255, 0, 0))
      ..frameDuration = 100;
    image.addFrame(
      img.Image(width: 80, height: 40)
        ..clear(img.ColorRgb8(0, 0, 255))
        ..frameDuration = 200,
    );
    final original = source(image, gif: true);
    final result = cropPlaylistArtwork(
      PlaylistCropSelection(
        sourcePath: original.path,
        left: 0.25,
        top: 0,
        side: 1,
      ),
    );
    expect(result.animated, isTrue);
    final decoded = img.decodeGif(result.bytes)!;
    expect(decoded.numFrames, 2);
    expect([decoded.width, decoded.height], [40, 40]);
    expect(decoded.frames.map((frame) => frame.frameDuration), [100, 200]);
  });

  test('corrupt sources and invalid crop coordinates are rejected', () {
    final broken = File('${directory.path}/broken.png')
      ..writeAsBytesSync([1, 2, 3]);
    expect(
      () => loadPlaylistArtworkPreview(broken.path),
      throwsFormatException,
    );
    final original = source(img.Image(width: 20, height: 20));
    for (final values in [
      [-0.1, 0.0, 1.0],
      [0.0, 0.0, 0.0],
      [0.0, 0.0, 2.0],
      [double.nan, 0.0, 1.0],
      [0.5, 0.5, 1.0],
    ]) {
      expect(
        () => cropPlaylistArtwork(
          PlaylistCropSelection(
            sourcePath: original.path,
            left: values[0],
            top: values[1],
            side: values[2],
          ),
        ),
        throwsFormatException,
      );
    }
  });

  test(
    'playlist artwork is copied, source preserved, relative path portable',
    () async {
      final root = await Directory.systemTemp.createTemp('shiki-playlist-art-');
      try {
        final original = File('${root.path}/original.png');
        await original.writeAsBytes([1, 2, 3]);
        final data = Directory('${root.path}/library');
        final name = await copyPlaylistArtwork(data, original.path, 123);
        expect(name, 'playlist_artwork_123.png');
        expect(await original.exists(), isTrue);
        expect(await resolvePlaylistArtwork(data, name).readAsBytes(), [
          1,
          2,
          3,
        ]);
        final otherOs = Directory('${root.path}/other-os');
        await otherOs.create();
        await resolvePlaylistArtwork(data, name).copy('${otherOs.path}/$name');
        expect(await resolvePlaylistArtwork(otherOs, name).readAsBytes(), [
          1,
          2,
          3,
        ]);
        expect(
          isPortablePlaylistArtwork('../playlist_artwork_123.png'),
          isFalse,
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
