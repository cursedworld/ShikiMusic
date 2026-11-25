import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shiki/background_photo.dart';
import 'package:shiki/screens/settings_screen.dart';

import 'fixtures/animated_background.dart';
import 'fixtures/playlist_photos.dart';

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'shiki_background_image_test_',
    );
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('keeps existing resize dimensions and JPEG quality path', () {
    final source = img.Image(width: 2400, height: 1200)
      ..clear(img.ColorRgb8(40, 120, 200));
    final sourceFile = File('${tempDirectory.path}/background.png')
      ..writeAsBytesSync(img.encodePng(source));

    final result = processCustomBackgroundImage(sourceFile.path);
    final decoded = result == null ? null : img.decodeJpg(result);

    expect(decoded, isNotNull);
    expect(decoded!.width, 1920);
    expect(decoded.height, 960);
    expect(decoded.getPixel(100, 100).r.toInt(), closeTo(40, 3));
    expect(decoded.getPixel(100, 100).g.toInt(), closeTo(120, 3));
    expect(decoded.getPixel(100, 100).b.toInt(), closeTo(200, 3));
  });

  test('rejects encoded files above the 64 MiB limit before reading', () {
    final sourceFile = File('${tempDirectory.path}/oversized.png');
    final handle = sourceFile.openSync(mode: FileMode.write);
    try {
      handle.truncateSync(64 * 1024 * 1024 + 1);
    } finally {
      handle.closeSync();
    }

    expect(processCustomBackgroundImage(sourceFile.path), isNull);
  });

  test('rejects unsafe declared pixel dimensions before decoding', () {
    final encoded = Uint8List.fromList(
      img.encodeBmp(img.Image(width: 1, height: 1)),
    );
    final header = ByteData.sublistView(encoded);
    header.setInt32(18, 8000, Endian.little);
    header.setInt32(22, 6000, Endian.little);
    final sourceFile = File('${tempDirectory.path}/oversized.bmp')
      ..writeAsBytesSync(encoded);

    expect(processCustomBackgroundImage(sourceFile.path), isNull);
  });

  test('playlist photos fit a portrait frame without changing the source', () {
    final bytes = img.encodePng(
      img.Image(width: 1200, height: 1600)..clear(img.ColorRgb8(60, 90, 120)),
    );
    final source = File('${tempDirectory.path}/phone.png')
      ..writeAsBytesSync(bytes);
    final jpeg = processPlaylistBackgroundPhoto(source.path);
    final decoded = img.decodeJpg(jpeg!)!;
    expect(decoded.width, 1080);
    expect(decoded.height, 1440);
    expect(source.readAsBytesSync(), bytes);
  });

  for (final lossless in [true, false]) {
    test('accepts a still WebP photo (lossless: $lossless)', () {
      final source = File('${tempDirectory.path}/chosen.webp')
        ..writeAsBytesSync(stillWebP(lossless: lossless));
      final prepared = processPlaylistBackgroundPhoto(source.path);
      expect(prepared, isNotNull);
      final decoded = img.decodeJpg(prepared!);
      expect(decoded?.width, 12);
      expect(decoded?.height, 8);
    });
  }

  test('a picker copy does not have to end in an image extension', () {
    final source = File('${tempDirectory.path}/picker-cache')
      ..writeAsBytesSync(img.encodeJpg(img.Image(width: 12, height: 8)));
    expect(processPlaylistBackgroundPhoto(source.path), isNotNull);
  });

  test('animated WebP is not imported as a playlist photo', () {
    final bytes = animatedWebP();
    expect(img.WebPDecoder().startDecode(bytes)?.hasAnimation, isTrue);
    final source = File('${tempDirectory.path}/moving.webp')
      ..writeAsBytesSync(bytes);
    expect(processPlaylistBackgroundPhoto(source.path), isNull);
  });

  test(
    'playlist backgrounds refuse animation and videos even through a wrong name',
    () {
      final gif = File('${tempDirectory.path}/chosen.gif')
        ..writeAsBytesSync(testGif());
      final renamed = File('${tempDirectory.path}/chosen.png')
        ..writeAsBytesSync(testGif());
      final video = File('${tempDirectory.path}/chosen.mp4')
        ..writeAsStringSync('video');
      expect(processPlaylistBackgroundPhoto(gif.path), isNull);
      expect(processPlaylistBackgroundPhoto(renamed.path), isNull);
      expect(processPlaylistBackgroundPhoto(video.path), isNull);
      expect(processCustomBackgroundImage(gif.path), isNotNull);
    },
  );

  test('settings persistence includes async setup in FIFO order', () async {
    final queue = SettingsPersistenceQueue();
    final releaseFirstSetup = Completer<void>();
    final setupOrder = <String>[];
    final writeOrder = <String>[];

    final first = queue.enqueue(() async {
      setupOrder.add('first');
      await releaseFirstSetup.future;
      writeOrder.add('first');
      return true;
    });
    final second = queue.enqueue(() async {
      setupOrder.add('second');
      writeOrder.add('second');
      return true;
    });

    await Future<void>.delayed(Duration.zero);
    expect(setupOrder, ['first']);
    expect(writeOrder, isEmpty);

    releaseFirstSetup.complete();
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(setupOrder, ['first', 'second']);
    expect(writeOrder, ['first', 'second']);
  });

  test('failed settings persistence does not block newer saves', () async {
    final queue = SettingsPersistenceQueue();
    final writes = <String>[];

    final failed = queue.enqueue<void>(() async {
      writes.add('failed');
      throw StateError('write failed');
    });
    final recovered = queue.enqueue(() async {
      writes.add('recovered');
      return true;
    });

    await expectLater(failed, throwsStateError);
    expect(await recovered, isTrue);
    expect(writes, ['failed', 'recovered']);
  });
}
