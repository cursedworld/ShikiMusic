import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shiki/globals.dart';

void main() {
  late Directory directory;
  late String previousPath;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shiki_cover_test_');
    previousPath = globalLocalPath;
    globalLocalPath = directory.path;
    clearCoverCache();
  });

  tearDown(() async {
    clearCoverCache();
    globalLocalPath = previousPath;
    final prefix =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}shiki_cover_test_';
    if (!directory.absolute.path.startsWith(prefix)) {
      throw StateError('Unexpected test directory');
    }
    await directory.delete(recursive: true);
  });

  Map<String, dynamic> track(int id, String? cover) => {
    'id': id,
    'album': {'cover': cover},
  };

  test(
    'missing optional artwork is transparent and has no notification URI',
    () {
      final missing = track(1, null);
      final provider = getPictureProvider(missing) as MemoryImage;
      final decoded = img.decodePng(provider.bytes)!;
      expect(decoded.width, 1);
      expect(decoded.height, 1);
      expect(decoded.getPixel(0, 0).a.toInt(), 0);
      expect(getArtUri(missing), isNull);
    },
  );

  test(
    'cover invalidation replaces network fallback with a downloaded file',
    () {
      final first = track(1, 'http://localhost/covers/a.jpg');
      final second = track(2, 'http://localhost/covers/b.jpg');
      final oldFirst = getPictureProvider(first);
      final oldSecond = getPictureProvider(second);
      expect(oldFirst, isA<NetworkImage>());
      final file = File('${directory.path}/cover_1_a.jpg')
        ..writeAsBytesSync([1]);

      invalidateTrackCover(1);

      expect((getPictureProvider(first) as FileImage).file.path, file.path);
      expect(getPictureProvider(second), same(oldSecond));
      expect(getArtUri(first), Uri.file(file.path));
    },
  );

  test(
    'changing storage does not retain a FileImage from the old directory',
    () {
      final song = track(1, null);
      File('${directory.path}/cover_1.jpg').writeAsBytesSync([1]);
      final old = getPictureProvider(song) as FileImage;
      final other = Directory('${directory.path}/new_storage')..createSync();
      globalLocalPath = other.path;
      final file = File('${other.path}/cover_1.jpg')..writeAsBytesSync([1]);

      final current = getPictureProvider(song) as FileImage;
      expect(current.file.path, file.path);
      expect(current.file.path, isNot(old.file.path));
    },
  );

  test('changing server URL refreshes a same-name cover', () {
    getPictureProvider(track(1, 'http://old.local/covers/a.jpg'));
    final current = getPictureProvider(
      track(1, 'http://new.local/covers/a.jpg'),
    );
    expect((current as NetworkImage).url, 'http://new.local/covers/a.jpg');
  });
}
