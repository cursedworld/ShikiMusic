import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
      final original = coverThumbnailTargetSize(600, 900, 0);
      expect([original.width, original.height], [600, 900]);
    },
  );

  test('equivalent thumbnails keep provider identity across rebuilds', () {
    const first = CoverThumbnailProvider(
      NetworkImage('https://example.com/cover.jpg'),
      pixelSize: 100,
    );
    final sameCover = CoverThumbnailProvider(
      const NetworkImage('https://example.com/cover.jpg'),
      pixelSize: 100,
    );
    expect(first, sameCover);
    expect(first.hashCode, sameCover.hashCode);
    expect(
      first,
      isNot(
        const CoverThumbnailProvider(
          NetworkImage('https://example.com/other.jpg'),
          pixelSize: 100,
        ),
      ),
    );
    expect(
      first,
      isNot(
        const CoverThumbnailProvider(
          NetworkImage('https://example.com/cover.jpg'),
          pixelSize: 200,
        ),
      ),
    );
  });

  test('synchronous source keys remain synchronous in thumbnails', () {
    const source = NetworkImage('https://example.com/cover.jpg');
    const thumbnail = CoverThumbnailProvider(source, pixelSize: 100);
    CoverThumbnailKey? immediateKey;
    final future = thumbnail.obtainKey(ImageConfiguration.empty);
    expect(future, isA<SynchronousFuture<CoverThumbnailKey>>());
    future.then((key) {
      immediateKey = key;
    });
    expect(immediateKey, const CoverThumbnailKey(source, 100));
  });

  test(
    'artwork replacement versions invalidate every thumbnail size',
    () async {
      const source = NetworkImage('https://example.com/same-playlist-path.jpg');
      for (final size in [28, 32, 36, 56, 64, 72]) {
        final old = CoverThumbnailProvider(source, pixelSize: size);
        final replacement = CoverThumbnailProvider(
          source,
          pixelSize: size,
          cacheVersion: 1,
        );
        expect(
          await old.obtainKey(ImageConfiguration.empty),
          isNot(await replacement.obtainKey(ImageConfiguration.empty)),
        );
        expect(old, isNot(replacement));
      }
    },
  );

  testWidgets(
    'real decoded album bytes shrink without undersampling at 1x and 2x',
    (tester) async {
      final source = MemoryImage(
        Uint8List.fromList(img.encodePng(img.Image(width: 600, height: 600))),
      );
      Future<Size> decode(ImageProvider provider) async {
        final result = Completer<Size>();
        final stream = provider.resolve(ImageConfiguration.empty);
        late ImageStreamListener listener;
        listener = ImageStreamListener((info, _) {
          result.complete(
            Size(info.image.width.toDouble(), info.image.height.toDouble()),
          );
          info.dispose();
          stream.removeListener(listener);
        }, onError: result.completeError);
        stream.addListener(listener);
        return result.future;
      }

      final original = await tester.runAsync(() => decode(source));
      expect(original, const Size(600, 600));
      for (final dpr in [1.0, 2.0]) {
        tester.view.devicePixelRatio = dpr;
        late ImageProvider thumbnail;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                thumbnail = coverThumbnail(context, source, 120);
                return const SizedBox();
              },
            ),
          ),
        );
        final actual = (await tester.runAsync(() => decode(thumbnail)))!;
        expect(actual, Size.square(120 * dpr));
        final originalBytes = original!.width * original.height * 4;
        final thumbnailBytes = actual.width * actual.height * 4;
        expect(thumbnailBytes, lessThan(originalBytes / 2));
        // Actual codec dimensions, not compressed file-size estimates.
        debugPrint(
          'Album ${dpr}x: decoded ${originalBytes.toInt()} -> ${thumbnailBytes.toInt()} bytes',
        );
      }
      tester.view.resetDevicePixelRatio();
      await tester.pumpWidget(const SizedBox());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    },
  );

  testWidgets('thumbnail decoding keeps animated GIF frames', (tester) async {
    final image = img.Image(width: 120, height: 120)
      ..clear(img.ColorRgb8(255, 0, 0))
      ..frameDuration = 100;
    image.addFrame(
      img.Image(width: 120, height: 120)
        ..clear(img.ColorRgb8(0, 0, 255))
        ..frameDuration = 100,
    );
    final source = MemoryImage(Uint8List.fromList(img.encodeGif(image)));
    final stream = CoverThumbnailProvider.original(
      source,
    ).resolve(ImageConfiguration.empty);
    final frames = <Color>[];
    final ready = Completer<void>();
    final listener = ImageStreamListener((info, _) {
      // Flutter may retain source dimensions for animated codecs. Animation
      // must survive even when a codec cannot downsample individual frames.
      expect(info.image.width, greaterThanOrEqualTo(36));
      expect(info.image.height, greaterThanOrEqualTo(36));
      info.image
          .toByteData()
          .then((bytes) {
            frames.add(
              Color.fromARGB(
                255,
                bytes!.getUint8(0),
                bytes.getUint8(1),
                bytes.getUint8(2),
              ),
            );
            if (frames.length >= 2 && !ready.isCompleted) ready.complete();
          })
          .whenComplete(info.dispose);
    });
    stream.addListener(listener);
    for (var i = 0; i < 100 && !ready.isCompleted; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(frames.take(2), [const Color(0xFFFF0000), const Color(0xFF0000FF)]);
    stream.removeListener(listener);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  test('asynchronous source keys and failures propagate unchanged', () async {
    final source = _DeferredKeyProvider();
    final thumbnail = CoverThumbnailProvider(source, pixelSize: 100);
    final key = thumbnail.obtainKey(ImageConfiguration.empty);
    source.completer.complete('cover');
    expect(await key, const CoverThumbnailKey('cover', 100));

    final failing = _DeferredKeyProvider();
    final future = CoverThumbnailProvider(
      failing,
      pixelSize: 100,
    ).obtainKey(ImageConfiguration.empty);
    final assertion = expectLater(future, throwsStateError);
    failing.completer.completeError(StateError('missing cover'));
    await assertion;
  });

  testWidgets('player controls never blank already loaded cover thumbnails', (
    tester,
  ) async {
    final colors = [Colors.red, Colors.green, Colors.blue];
    final loads = List<int>.filled(colors.length, 0);
    final sources = [
      for (final (index, color) in colors.indexed)
        _CountingMemoryImage(
          Uint8List.fromList(
            img.encodePng(
              img.Image(width: 120, height: 120)..clear(
                img.ColorRgb8(
                  (color.r * 255).round(),
                  (color.g * 255).round(),
                  (color.b * 255).round(),
                ),
              ),
            ),
          ),
          () => loads[index]++,
        ),
    ];
    late BuildContext coverContext;
    var revision = 0;
    var volume = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            coverContext = context;
            return Scaffold(
              body: Column(
                children: [
                  for (var i = 0; i < sources.length; i++)
                    Image(
                      key: ValueKey('cover_$i'),
                      image: coverThumbnail(context, sources[i], 50),
                      width: 50,
                      height: 50,
                      fit: BoxFit.cover,
                    ),
                  for (final control in ['pause', 'skip', 'video'])
                    TextButton(
                      key: ValueKey(control),
                      onPressed: () => setState(() => revision++),
                      child: Text(control),
                    ),
                  Slider(
                    value: volume,
                    onChanged: (value) => setState(() {
                      volume = value;
                      revision++;
                    }),
                  ),
                  Text('$revision'),
                ],
              ),
            );
          },
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future.wait([
        for (final source in sources)
          precacheImage(coverThumbnail(coverContext, source, 50), coverContext),
      ]);
    });
    await tester.pump();
    final initial = tester
        .widgetList<RawImage>(find.byType(RawImage))
        .map((image) => image.image)
        .toList();
    expect(initial, everyElement(isNotNull));

    for (final control in [
      find.byKey(const ValueKey('pause')),
      find.byKey(const ValueKey('skip')),
      find.byKey(const ValueKey('video')),
      find.byType(Slider),
    ]) {
      await tester.tap(control);
      await tester.pump();
      final images = tester
          .widgetList<RawImage>(find.byType(RawImage))
          .toList();
      expect(images.length, initial.length);
      for (var i = 0; i < images.length; i++) {
        expect(images[i].image, same(initial[i]), reason: 'cover_$i blinked');
      }
      expect(loads, everyElement(1));
    }
    expect(revision, 4);
    await tester.pumpWidget(const SizedBox());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
}

class _DeferredKeyProvider extends ImageProvider<Object> {
  final completer = Completer<Object>();

  @override
  Future<Object> obtainKey(ImageConfiguration configuration) =>
      completer.future;
}

class _CountingMemoryImage extends MemoryImage {
  const _CountingMemoryImage(super.bytes, this.onLoad);
  final VoidCallback onLoad;

  @override
  ImageStreamCompleter loadImage(MemoryImage key, ImageDecoderCallback decode) {
    onLoad();
    return super.loadImage(key, decode);
  }
}
