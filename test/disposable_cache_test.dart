import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/disposable_cache.dart';
import 'package:shiki/atomic_file_store.dart';

class _DeniedDelete implements File {
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async =>
      throw const FileSystemException('Test: access denied');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

  test('counts finished media and previews only eligible artwork', () async {
    final digest = List.filled(64, 'a').join();
    final now = DateTime(2026, 10, 4, 12);
    final entries = {
      'track_1.mp3': 10,
      'track_2_$digest.mp3': 20,
      'local_audio_$digest.mp3': 30,
      'video_1.mp4': 40,
      'video_2_$digest.mp4': 50,
      'local_video_$digest.mp4': 60,
      'cover_1.jpg': 3,
      'cover_2_v2.webp': 4,
      'artist_7.jpg': 5,
      'artist_8.png': 6,
      'local_cover_$digest.jpg': 7,
      'playlist_artwork_42.gif': 8,
      'cover_1.jpg.tmp.1.2.3': 9,
      'cover_2.jpg.tmp.1.2.3': 11,
      'track_2_$digest.mp3.part.resume': 100,
      'track_1.lrc': 200,
      'custom_bg_1.mp4': 300,
      'playlist_bg_${List.filled(32, 'b').join()}.jpg': 400,
      'listening_statistics.sqlite': 500,
    };
    for (final entry in entries.entries) {
      await File(
        '${directory.path}/${entry.key}',
      ).writeAsBytes(List.filled(entry.value, 1));
    }
    await File(
      '${directory.path}/cover_1.jpg.tmp.1.2.3',
    ).setLastModified(now.subtract(const Duration(days: 2)));
    await File('${directory.path}/cover_2.jpg.tmp.1.2.3').setLastModified(now);
    final legacy = await Directory('${directory.path}/local_music').create();
    final legacyDigest = List.filled(64, 'c').join();
    await File(
      '${legacy.path}/local_audio_$legacyDigest.mp3',
    ).writeAsBytes(List.filled(70, 1));
    await File(
      '${legacy.path}/local_cover_$legacyDigest.jpg',
    ).writeAsBytes(List.filled(12, 1));
    final elsewhere = await Directory('${directory.path}/unmanaged').create();
    await File('${elsewhere.path}/track_999.mp3').writeAsString('unmanaged');

    final usage = await readStorageUsage(
      directory,
      protectedTrackIds: {1},
      protectedArtistIds: {7},
      now: now,
    );
    expect(usage.audioBytes, 130);
    expect(usage.clipBytes, 150);
    expect(usage.artworkBytes, 65);
    expect(usage.reclaimableBytes, 19);
    expect(usage.hasReclaimableArtwork, isTrue);
    expect(await File('${directory.path}/cover_2_v2.webp').exists(), isTrue);
  });

  test('reports an empty profile and fails to read an invalid root', () async {
    final usage = await readStorageUsage(
      directory,
      protectedTrackIds: {},
      protectedArtistIds: {},
    );
    expect([usage.audioBytes, usage.clipBytes, usage.artworkBytes], [0, 0, 0]);
    expect(usage.hasReclaimableArtwork, isFalse);
    final file = await File('${directory.path}/not_a_directory').create();
    await expectLater(
      readStorageUsage(
        Directory(file.path),
        protectedTrackIds: {},
        protectedArtistIds: {},
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('rechecks protected covers and old temporaries after preview', () async {
    final now = DateTime(2026, 10, 4, 12);
    final cover = await File(
      '${directory.path}/cover_1.jpg',
    ).writeAsString('one');
    final old = await File(
      '${directory.path}/cover_2.jpg.tmp.1.2.3',
    ).writeAsString('two');
    await old.setLastModified(now.subtract(const Duration(days: 2)));
    final orphan = await File(
      '${directory.path}/artist_9.jpg',
    ).writeAsString('three');
    final preview = await readStorageUsage(
      directory,
      protectedTrackIds: {},
      protectedArtistIds: {},
      now: now,
    );
    expect(preview.reclaimableBytes, 11);

    await old.setLastModified(now);
    final result = await clearDisposableArtwork(
      directory,
      protectedTrackIds: {1},
      protectedArtistIds: {},
      now: now,
    );
    expect(result.removedBytes, 5);
    expect(result.removedFiles, 1);
    expect(result.failed, isFalse);
    expect(await cover.readAsString(), 'one');
    expect(await old.readAsString(), 'two');
    expect(await orphan.exists(), isFalse);
  });

  test('reports actual bytes if a download interrupts cleanup', () async {
    final files = [
      await File('${directory.path}/cover_1.jpg').writeAsString('abcd'),
      await File('${directory.path}/cover_2.jpg').writeAsString('abcd'),
    ];
    final result = await clearDisposableArtwork(
      directory,
      protectedTrackIds: {},
      protectedArtistIds: {},
      isBusy: () => files.any((file) => !file.existsSync()),
    );
    expect(result.busy, isTrue);
    expect(result.removedBytes, 4);
    expect(result.removedFiles, 1);
    expect(files.where((file) => file.existsSync()), hasLength(1));
  });

  test(
    'continues after a deletion error and does not count that file',
    () async {
      final removed = await File(
        '${directory.path}/cover_1.jpg',
      ).writeAsString('123');
      final locked = await File(
        '${directory.path}/cover_2.jpg',
      ).writeAsString('12345');
      final filesystem = Zone.current;
      final result = await IOOverrides.runZoned(
        () => clearDisposableArtwork(
          directory,
          protectedTrackIds: {},
          protectedArtistIds: {},
        ),
        createFile: (path) {
          final file = filesystem.run(() => File(path));
          return file.uri.pathSegments.last == 'cover_2.jpg'
              ? _DeniedDelete()
              : file;
        },
        fseGetType: (path, followLinks) => filesystem.run(
          () => FileSystemEntity.type(path, followLinks: followLinks),
        ),
      );
      expect(result.failed, isTrue);
      expect(result.removedBytes, 3);
      expect(result.removedFiles, 1);
      expect(await removed.exists(), isFalse);
      expect(await locked.readAsString(), '12345');
    },
  );

  test(
    'does not follow a linked legacy folder or remove artwork links',
    () async {
      final unrelated = await Directory('${directory.path}/unrelated').create();
      final digest = List.filled(64, 'a').join();
      final track = await File(
        '${unrelated.path}/local_audio_$digest.mp3',
      ).writeAsString('protected');
      final legacy = await Link(
        '${directory.path}/local_music',
      ).create(unrelated.path);
      final cover = await Link(
        '${directory.path}/cover_1.jpg',
      ).create(unrelated.path);
      final usage = await readStorageUsage(
        directory,
        protectedTrackIds: {},
        protectedArtistIds: {},
      );
      expect(usage.audioBytes, 0);
      expect(usage.artworkBytes, 0);
      expect(usage.hasReclaimableArtwork, isFalse);
      await clearDisposableArtwork(
        directory,
        protectedTrackIds: {},
        protectedArtistIds: {},
      );
      expect(await legacy.exists(), isTrue);
      expect(await cover.exists(), isTrue);
      expect(await track.readAsString(), 'protected');
    },
  );

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
