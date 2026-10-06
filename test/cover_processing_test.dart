import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shiki/cover_processing.dart';

void main() {
  test('keeps 600-square crop dimensions and source color', () {
    final source = img.Image(width: 900, height: 600)
      ..clear(img.ColorRgb8(40, 120, 200));
    final result = cropCoverBytes(img.encodePng(source));
    final decoded = img.decodeJpg(result!);
    expect(decoded!.width, 600);
    expect(decoded.height, 600);
    expect(decoded.getPixel(100, 100).r.toInt(), closeTo(40, 3));
    expect(decoded.getPixel(100, 100).g.toInt(), closeTo(120, 3));
    expect(decoded.getPixel(100, 100).b.toInt(), closeTo(200, 3));
  });

  test('invalid bytes and unsafe declared dimensions are rejected', () {
    expect(cropCoverBytes(Uint8List.fromList([1, 2, 3])), isNull);
    final bytes = Uint8List.fromList(
      img.encodeBmp(img.Image(width: 1, height: 1)),
    );
    final header = ByteData.sublistView(bytes);
    header.setInt32(18, 8000, Endian.little);
    header.setInt32(22, 6000, Endian.little);
    expect(cropCoverBytes(bytes), isNull);
  });

  test(
    'file validation detects missing, non-square and valid square images',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'shiki_cover_test_',
      );
      try {
        final file = File('${directory.path}/cover.png');
        expect(isSquareCoverFile(file.path), isFalse);
        await file.writeAsBytes(
          img.encodePng(img.Image(width: 20, height: 10)),
        );
        expect(isSquareCoverFile(file.path), isFalse);
        await file.writeAsBytes(
          img.encodePng(img.Image(width: 20, height: 20)),
        );
        expect(isSquareCoverFile(file.path), isTrue);
      } finally {
        final prefix =
            '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}shiki_cover_test_';
        if (!directory.absolute.path.startsWith(prefix)) {
          throw StateError('Unexpected test path');
        }
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'thumbnail decoding follows DPR and preserves original provider',
    (tester) async {
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetDevicePixelRatio);
      const provider = NetworkImage('http://localhost/cover.jpg');
      late ImageProvider thumbnail;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              thumbnail = coverThumbnail(context, provider, 52);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(thumbnail, isA<CoverThumbnailProvider>());
      final resize = thumbnail as CoverThumbnailProvider;
      expect(resize.pixelSize, 104);
      expect(resize.imageProvider, same(provider));
    },
  );

  test(
    'thumbnail decoder preserves cover crop resolution and aspect ratio',
    () {
      final square = coverThumbnailTargetSize(600, 600, 100);
      expect([square.width, square.height], [100, 100]);
      final landscape = coverThumbnailTargetSize(900, 600, 100);
      expect([landscape.width, landscape.height], [150, 100]);
      final portrait = coverThumbnailTargetSize(600, 900, 100);
      expect([portrait.width, portrait.height], [100, 150]);
      final tiny = coverThumbnailTargetSize(50, 100, 100);
      expect([tiny.width, tiny.height], [50, 100]);
    },
  );
}
