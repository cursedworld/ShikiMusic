import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/disposable_cache.dart';
import 'package:shiki/atomic_file_store.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shiki_cache_test_');
  });
  tearDown(() async {
    final prefix =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}shiki_cache_test_';
    if (!directory.absolute.path.startsWith(prefix)) {
      throw StateError('Unexpected test path');
    }
    await directory.delete(recursive: true);
  });

  test(
    'clears orphan artwork only, retaining all library and user files',
    () async {
      final keep = [
        'track_1.mp3',
        'track_1_revision.mp3',
        'video_1.mp4',
        'video_1_revision.mp4',
        'track_1.lrc',
        'track_1_revision.lrc',
        'track_versions.json',
        'offline_tracks.json',
        'offline_artists.json',
        'artist_details_7.json',
        'liked_tracks.json',
        'playlists.json',
        'my_playlists.json',
        'my_playlists.json.tmp.1.2.3',
        'playlist_artwork_123.jpg',
        'custom_background.jpg',
        'playlist_cover.jpg',
        'cover_1.jpg',
        'cover_1_album.jpg',
        'artist_7.jpg',
        'unrecognized.jpg',
        'track_1.mp3.part',
        'cover_2.jpg.tmp.1.2.3',
      ];
      final remove = ['cover_2.jpg', 'cover_3_album.png', 'artist_8.jpg'];
      for (final name in [...keep, ...remove]) {
        await File('${directory.path}/$name').writeAsString(name);
      }
      final folder = await Directory(
        '${directory.path}/cover_999.jpg',
      ).create();
      await File('${folder.path}/keep.mp3').writeAsString('music');
      await clearDisposableArtwork(
        directory,
        protectedTrackIds: {1},
        protectedArtistIds: {7},
      );
      for (final name in keep) {
        expect(
          await File('${directory.path}/$name').readAsString(),
          name,
          reason: name,
        );
      }
      for (final name in remove) {
        expect(
          await File('${directory.path}/$name').exists(),
          isFalse,
          reason: name,
        );
      }
      expect(await File('${folder.path}/keep.mp3').exists(), isTrue);
    },
  );

  test('playlist data and artwork survive cleanup and a fresh read', () async {
    final playlists = [
      {
        'id': 123,
        'name': 'Мой плейлист',
        'image': 'playlist_artwork_123.jpg',
        'tracks': [7, 3, 12],
      },
      {'id': 456, 'name': 'Пустой плейлист', 'image': '', 'tracks': <int>[]},
    ];
    final dataFile = File('${directory.path}/my_playlists.json');
    final imageFile = File('${directory.path}/playlist_artwork_123.jpg');
    final imageBytes = [1, 2, 3, 4];
    await AtomicFileStore().writeString(dataFile, json.encode(playlists));
    await AtomicFileStore().writeBytes(imageFile, imageBytes);
    final originalData = await dataFile.readAsBytes();
    final orphan = File('${directory.path}/cover_999.jpg');
    await orphan.writeAsString('disposable artwork');

    // Even an empty/offline library must not turn personal playlists into cache.
    await clearDisposableArtwork(
      directory,
      protectedTrackIds: {},
      protectedArtistIds: {},
    );

    final reopened = File('${directory.path}/my_playlists.json');
    expect(await reopened.readAsBytes(), originalData);
    expect(json.decode(await reopened.readAsString()), playlists);
    expect(await imageFile.readAsBytes(), imageBytes);
    expect(await orphan.exists(), isFalse);
  });

  test(
    'removes only old artwork temporary files, not media temporary files',
    () async {
      final old = File('${directory.path}/cover_2_album.jpg.tmp.1.2.3');
      final media = File('${directory.path}/track_2.mp3.tmp.1.2.3');
      await old.writeAsString('old');
      await media.writeAsString('media');
      final now = DateTime(2026, 10, 4, 12);
      await old.setLastModified(now.subtract(const Duration(days: 2)));
      await media.setLastModified(now.subtract(const Duration(days: 2)));
      await clearDisposableArtwork(
        directory,
        protectedTrackIds: {},
        protectedArtistIds: {},
        now: now,
      );
      expect(await old.exists(), isFalse);
      expect(await media.readAsString(), 'media');
    },
  );
}
