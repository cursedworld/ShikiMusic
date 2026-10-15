import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/library_transfer.dart';
import 'package:shiki/statistics_store.dart';
import 'package:shiki/track_updates.dart';

void main() {
  late Directory root, source, target;
  late String archive;
  Future<void> json(Directory directory, String name, Object value) =>
      File('${directory.path}/$name').writeAsString(jsonEncode(value));
  Map<String, Object?> track(int id, [String title = 'Song']) => {
    'id': id,
    'title': title,
    'source_id': 'youtube:$id',
    'album': {
      'id': 1,
      'artist': {'id': 1, 'name': 'Artist'},
    },
    'artists': [],
  };
  Future<void> export({bool media = true}) => exportLibraryArchive(
    directory: source,
    destination: archive,
    includeMedia: media,
  ).then((_) {});
  Future<void> restore({bool settings = false}) async {
    await prepareLibraryImport(
      directory: target,
      archive: archive,
      restoreSettings: settings,
    );
    expect(await applyPendingLibraryImport(target), isTrue);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('shiki-transfer-test-');
    source = await Directory('${root.path}/source').create();
    target = await Directory('${root.path}/target').create();
    archive = '${root.path}/library.zip';
    await json(source, 'offline_tracks.json', [track(1)]);
    await json(source, 'my_playlists.json', [
      {
        'id': 5,
        'name': 'My list',
        'tracks': [1],
        'image': 'playlist_artwork_5.png',
      },
    ]);
    await json(source, 'liked_tracks.json', [1]);
    await json(source, 'shiki_settings.json', {
      'language': 'en',
      'themeColor': 'color_purple',
    });
    await File('${source.path}/playlist_artwork_5.png').writeAsBytes([1, 2, 3]);
    await File('${source.path}/track_1.mp3').writeAsBytes([4, 5, 6]);
    await File('${source.path}/video_1.mp4').writeAsBytes([7, 8, 9]);
    await File('${source.path}/track_1.lrc').writeAsString('[00:01]Lyrics');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'full round trip retains playlist order, artwork and offline media',
    () async {
      await export();
      await restore(settings: true);
      final lists =
          jsonDecode(
                await File('${target.path}/my_playlists.json').readAsString(),
              )
              as List;
      expect(lists.single['tracks'], [1]);
      expect(
        await File('${target.path}/${lists.single['image']}').readAsBytes(),
        [1, 2, 3],
      );
      expect(await File('${target.path}/track_1.mp3').readAsBytes(), [4, 5, 6]);
      expect(await File('${target.path}/video_1.mp4').exists(), isTrue);
      expect(
        jsonDecode(
          await File('${target.path}/shiki_settings.json').readAsString(),
        )['language'],
        'en',
      );
      expect(await applyPendingLibraryImport(target), isFalse);
    },
  );
  test('small archive includes lyrics/artwork but omits audio/video', () async {
    await File(
      '${source.path}/cover_1_Обложка альбома.jpg',
    ).writeAsBytes([1, 2]);
    await export(media: false);
    await restore();
    expect(await File('${target.path}/track_1.mp3').exists(), isFalse);
    expect(await File('${target.path}/video_1.mp4').exists(), isFalse);
    expect(await File('${target.path}/track_1.lrc').exists(), isTrue);
    expect(
      await File('${target.path}/cover_1_Обложка альбома.jpg').exists(),
      isTrue,
    );
    expect(await File('${target.path}/shiki_settings.json').exists(), isFalse);
  });
  test(
    'merge preserves existing files/settings and imports are idempotent',
    () async {
      await json(target, 'my_playlists.json', [
        {
          'id': 5,
          'name': 'My list',
          'tracks': [2],
          'image': null,
        },
      ]);
      await json(target, 'liked_tracks.json', [2]);
      await json(target, 'shiki_settings.json', {'language': 'ru'});
      await File('${target.path}/track_1.mp3').writeAsBytes([99]);
      await export();
      await restore();
      await restore();
      final lists =
          jsonDecode(
                await File('${target.path}/my_playlists.json').readAsString(),
              )
              as List;
      expect(lists, hasLength(1));
      expect(lists.single['tracks'], [2, 1]);
      expect(
        jsonDecode(
          await File('${target.path}/liked_tracks.json').readAsString(),
        ),
        [2, 1],
      );
      expect(await File('${target.path}/track_1.mp3').readAsBytes(), [99]);
      expect(
        jsonDecode(
          await File('${target.path}/shiki_settings.json').readAsString(),
        )['language'],
        'ru',
      );
    },
  );
  test('colliding playlist IDs create a separate playlist only once', () async {
    await json(target, 'my_playlists.json', [
      {
        'id': 5,
        'name': 'Different',
        'tracks': [2],
        'image': null,
      },
    ]);
    await export();
    await restore();
    await restore();
    final lists =
        jsonDecode(
              await File('${target.path}/my_playlists.json').readAsString(),
            )
            as List;
    expect(lists, hasLength(2));
    expect(lists.map((dynamic p) => p['id']).toSet(), hasLength(2));
  });
  test('different libraries stop before metadata is changed', () async {
    final local = {...track(1, 'Other song'), 'source_id': 'youtube:other'};
    await json(target, 'offline_tracks.json', [local]);
    await export();
    await prepareLibraryImport(directory: target, archive: archive);
    await expectLater(applyPendingLibraryImport(target), throwsFormatException);
    expect(
      jsonDecode(
        await File('${target.path}/offline_tracks.json').readAsString(),
      ),
      [local],
    );
    expect(await File('${target.path}/track_1.mp3').exists(), isFalse);
  });
  test('pending imports are not overwritten', () async {
    await export();
    await prepareLibraryImport(directory: target, archive: archive);
    await expectLater(
      prepareLibraryImport(directory: target, archive: archive),
      throwsFormatException,
    );
  });

  test('cancelled import leaves existing library untouched', () async {
    await File('${target.path}/track_1.mp3').writeAsBytes([99]);
    await export();
    await prepareLibraryImport(directory: target, archive: archive);
    await cancelPendingLibraryImport(target);
    expect(await applyPendingLibraryImport(target), isFalse);
    expect(await File('${target.path}/track_1.mp3').readAsBytes(), [99]);
  });

  test('small archive retains managed lyrics when audio was omitted', () async {
    final hash = sha256.convert(utf8.encode('[00:01]Managed')).toString();
    final audioHash = sha256.convert([4, 5, 6]).toString();
    final name = 'track_1_$hash.lrc';
    await File('${source.path}/$name').writeAsString('[00:01]Managed');
    await json(source, 'track_versions.json', {
      '1': {
        'versions': {'audio': audioHash, 'lyrics': hash, 'metadata': hash},
        'audio': 'track_1.mp3',
        'lyrics': name,
        'has_audio': true,
      },
    });
    await export(media: false);
    await restore();
    final monitor = TrackUpdateMonitor(directory: target, tracks: () => []);
    await monitor.load();
    expect(await monitor.lyricsFile(1).readAsString(), '[00:01]Managed');
    expect(await monitor.audioFile(1).exists(), isFalse);
    monitor.dispose();
  });

  test('same track name but different explicit source is a conflict', () async {
    await json(target, 'offline_tracks.json', [
      {...track(1), 'source_id': 'youtube:alternate'},
    ]);
    await export();
    await prepareLibraryImport(directory: target, archive: archive);
    await expectLater(applyPendingLibraryImport(target), throwsFormatException);
  });

  test('different tracks cannot silently reuse another artists ID', () async {
    final other = track(2);
    other['album'] = {
      'id': 2,
      'title': 'Other album',
      'artist': {'id': 1, 'name': 'Other artist'},
    };
    await json(target, 'offline_tracks.json', [other]);
    await export();
    await prepareLibraryImport(directory: target, archive: archive);
    await expectLater(applyPendingLibraryImport(target), throwsFormatException);
  });
  test('private files and server databases are never included', () async {
    await File('${source.path}/db.sqlite3').writeAsString('private');
    await File('${source.path}/secret.env').writeAsString('secret');
    await export();
    final input = InputFileStream(archive);
    final zip = ZipDecoder().decodeStream(input);
    expect(zip.find('db.sqlite3'), isNull);
    expect(zip.find('secret.env'), isNull);
    await input.close();
  });
  test('statistics merge does not double-count repeated imports', () async {
    final store = StatisticsStore('${source.path}/listening_statistics.sqlite');
    await store.write([
      {
        'id': '0123456789abcdef0123456789abcdef',
        'day': '2026-10-13',
        'track_key': 'track:1',
        'title': 'Song',
        'artists': [
          {'key': 'artist:1', 'name': 'Artist'},
        ],
        'listening_ms': 1000,
        'app_ms': 0,
        'plays': 1,
        'updated_at': 1,
      },
    ]);
    await exportLibraryArchive(
      directory: source,
      destination: archive,
      includeMedia: false,
      statistics: await store.exportData(),
    );
    await restore();
    await restore();
    final restored = StatisticsStore(
      '${target.path}/listening_statistics.sqlite',
    );
    final bytes = jsonDecode(utf8.decode(await restored.exportData()));
    expect(bytes['rows'], hasLength(1));
    expect(bytes['rows'][0]['listening_ms'], 1000);
  });
  test('rejects traversal and untrusted non-Shiki archives', () async {
    final encoder = ZipFileEncoder()..create(archive, level: 0);
    encoder.addArchiveFile(
      ArchiveFile('../escape.txt', 1, [1])..compression = CompressionType.none,
    );
    await encoder.close();
    await expectLater(
      prepareLibraryImport(directory: target, archive: archive),
      throwsFormatException,
    );
    expect(await File('${root.path}/escape.txt').exists(), isFalse);
  });
  test('rejects corrupt checksums before queuing import', () async {
    final encoder = ZipFileEncoder()..create(archive, level: 0);
    final bytes = utf8.encode('[]');
    encoder.addArchiveFile(
      ArchiveFile('liked_tracks.json', bytes.length, bytes)
        ..compression = CompressionType.none,
    );
    final manifest = utf8.encode(
      jsonEncode({
        'format': 'shiki-library',
        'version': 1,
        'files': {
          'liked_tracks.json': {
            'size': bytes.length,
            'sha256': sha256.convert([0]).toString(),
          },
        },
      }),
    );
    encoder.addArchiveFile(
      ArchiveFile('shiki-transfer.json', manifest.length, manifest)
        ..compression = CompressionType.none,
    );
    await encoder.close();
    await expectLater(
      prepareLibraryImport(directory: target, archive: archive),
      throwsFormatException,
    );
    expect(
      await File('${target.path}/transfer_pending.json').exists(),
      isFalse,
    );
  });
}
