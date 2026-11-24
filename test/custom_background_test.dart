import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shiki/custom_background.dart';

import 'fixtures/animated_background.dart';

// Only the container prefix for storage tests. Playback uses real test media.
const testMp4Header = [
  0,
  0,
  0,
  16,
  102,
  116,
  121,
  112,
  105,
  115,
  111,
  109,
  0,
  0,
  0,
  0,
];

void main() {
  late Directory temp;
  setUp(
    () async => temp = await Directory.systemTemp.createTemp('shiki-bg-test-'),
  );
  tearDown(() async => temp.delete(recursive: true));
  File file(String name) => File('${temp.path}/$name');

  test(
    'copies every GIF frame without changing any bytes or dimensions',
    () async {
      final original = await file('original.GIF').writeAsBytes(testGif());
      final copied = file('custom_bg_1.gif');
      await copyMotionBackground(original, copied);
      expect(await copied.readAsBytes(), await original.readAsBytes());
      final decoded = img.decodeGif(await copied.readAsBytes());
      expect(decoded?.numFrames, 2);
      expect(decoded?.width, 32);
      expect(
        await availableCustomBackground(temp, 'custom_bg_1.gif'),
        'custom_bg_1.gif',
      );
    },
  );

  test('streams the MP4 copy and leaves the selected file in place', () async {
    final original = await file(
      'source.mp4',
    ).writeAsBytes([...testMp4Header, ...List.filled(200000, 42)]);
    final destination = file('custom_bg_2.mp4');
    await copyMotionBackground(original, destination);
    expect(await original.readAsBytes(), await destination.readAsBytes());
    expect(await file('custom_bg_2.mp4.part').exists(), isFalse);
  });

  test('rejects a truncated GIF and cleans up its unpublished copy', () async {
    final original = await file(
      'bad.gif',
    ).writeAsBytes(testGif().take(16).toList());
    final destination = file('custom_bg_3.gif');
    await expectLater(
      copyMotionBackground(original, destination),
      throwsA(BackgroundProblem.invalid),
    );
    expect(await destination.exists(), isFalse);
    expect(await file('custom_bg_3.gif.part').exists(), isFalse);
    expect(await original.exists(), isTrue);
  });

  test('rejects oversized files and GIF dimensions before decoding', () async {
    final gif = Uint8List.fromList(testGif());
    ByteData.sublistView(gif).setUint16(6, 4096, Endian.little);
    final wide = await file('wide.gif').writeAsBytes(gif);
    await expectLater(
      copyMotionBackground(wide, file('custom_bg_4.gif')),
      throwsA(BackgroundProblem.tooLarge),
    );
    final huge = await file('huge.mp4').writeAsBytes(testMp4Header);
    final handle = await huge.open(mode: FileMode.append);
    await handle.truncate(backgroundVideoMaxBytes + 1);
    await handle.close();
    await expectLater(
      copyMotionBackground(huge, file('custom_bg_5.mp4')),
      throwsA(BackgroundProblem.tooLarge),
    );
    expect(isMotionBackgroundSizeAllowed(1080, 1920), isTrue);
    expect(isMotionBackgroundSizeAllowed(1920, 1080), isTrue);
    expect(isMotionBackgroundSizeAllowed(1920, 1200), isFalse);
  });

  test(
    'never replaces an existing wallpaper or reads a path out of the profile',
    () async {
      final stored = await file('custom_bg_6.mp4').writeAsBytes(testMp4Header);
      final prior = await file('custom_bg_7.mp4.part').writeAsString('keep me');
      await expectLater(
        copyMotionBackground(stored, stored),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        copyMotionBackground(stored, file('custom_bg_7.mp4')),
        throwsA(isA<FileSystemException>()),
      );
      expect(await prior.readAsString(), 'keep me');
      expect(
        await availableCustomBackground(temp, '../custom_bg_6.mp4'),
        isNull,
      );
      expect(
        await availableCustomBackground(temp, 'custom_bg_6.mp4'),
        'custom_bg_6.mp4',
      );
    },
  );
}
