import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/playlist_artwork.dart';

void main() {
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
