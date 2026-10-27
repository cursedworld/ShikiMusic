import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/atomic_file_store.dart';
import 'package:shiki/local_download_remover.dart';

final throwsFileSystemException = throwsA(isA<FileSystemException>());

void main() {
  late Directory directory;
  late File index;
  final digest = 'a' * 64;
  late Map<String, dynamic> original;
  File file(String name) => File('${directory.path}/$name');
  Future<void> save(Map<String, dynamic> data) =>
      atomicFileStore.writeString(index, jsonEncode(data));

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shiki-remove-test-');
    index = file('track_versions.json');
    original = {
      '1': {'audio': 'track_1_$digest.mp3'},
      '2': {'audio': 'track_2.mp3'},
    };
    await save(original);
    for (final name in [
      'track_1_$digest.mp3',
      'track_1.mp3',
      'track_1_$digest.lrc',
      'track_1.lrc',
      'video_1_$digest.mp4',
      'video_1.mp4',
      'cover_1.jpg',
      'cover_1_${digest}_600.jpg',
      'track_2.mp3',
      'my_playlists.json',
      'liked_tracks.json',
      'listening_statistics.db',
      'track_11.mp3',
    ]) {
      await file(name).writeAsString('fixture:$name');
    }
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'only selected managed files are removed, index committed last',
    () async {
      final remover = LocalDownloadRemover(directory);
      var commits = 0;
      Future<void> commit() async {
        commits++;
        expect(await file('track_1_$digest.mp3').exists(), isFalse);
        expect(jsonDecode(await index.readAsString()), original);
        await save({...original}..remove('1'));
      }

      expect(await remover.remove(1, commitIndex: commit), isFalse);
      expect(commits, 1);
      for (final name in [
        'track_2.mp3',
        'my_playlists.json',
        'liked_tracks.json',
        'listening_statistics.db',
        'track_11.mp3',
      ]) {
        expect(await file(name).readAsString(), 'fixture:$name');
      }
      expect(
        (jsonDecode(await index.readAsString()) as Map).containsKey('1'),
        isFalse,
      );
      await remover.remove(1, commitIndex: () async {});
    },
  );

  test('a rename/access failure rolls back all earlier file moves', () async {
    var moves = 0;
    final remover = LocalDownloadRemover(
      directory,
      moveFile: (source, target) async {
        if (++moves == 2) throw const FileSystemException('Access denied');
        await source.rename(target.path);
      },
    );
    await expectLater(
      remover.remove(1, commitIndex: () async => fail('must not commit')),
      throwsFileSystemException,
    );
    expect(jsonDecode(await index.readAsString()), original);
    expect(
      await file('track_1_$digest.mp3').readAsString(),
      'fixture:track_1_$digest.mp3',
    );
    expect(await file('track_1.mp3').exists(), isTrue);
  });

  test(
    'index write failure restores files and old target record only',
    () async {
      final remover = LocalDownloadRemover(directory);
      await expectLater(
        remover.remove(
          1,
          commitIndex: () async {
            await save({
              '2': {'audio': 'track_2_new.mp3'},
            });
            throw const FileSystemException('Index flush failed');
          },
        ),
        throwsFileSystemException,
      );
      final restored = jsonDecode(await index.readAsString()) as Map;
      expect(restored['1'], original['1']);
      expect(restored['2'], {'audio': 'track_2_new.mp3'});
      expect(await file('track_1_$digest.mp3').exists(), isTrue);
    },
  );

  Future<Directory> interrupted({
    required String phase,
    bool legacy = false,
  }) async {
    final transaction = Directory(
      '${directory.path}/.download_removals/track_1',
    );
    await transaction.create(recursive: true);
    await file(
      'track_1_$digest.mp3',
    ).rename('${transaction.path}/track_1_$digest.mp3');
    await atomicFileStore.writeString(
      File('${transaction.path}/journal.json'),
      jsonEncode({
        'version': 1,
        'id': 1,
        'phase': phase,
        'files': ['track_1_$digest.mp3'],
        'oldRecord': legacy ? null : original['1'],
      }),
    );
    await save({...original}..remove('1'));
    return transaction;
  }

  test(
    'startup recovers crash after index save but before commit marker',
    () async {
      final transaction = await interrupted(phase: 'staging');
      await LocalDownloadRemover(directory).recover();
      expect(await file('track_1_$digest.mp3').exists(), isTrue);
      expect(jsonDecode(await index.readAsString()), original);
      expect(await transaction.exists(), isFalse);
    },
  );

  test(
    'startup finishes committed deletion without resurrecting the index',
    () async {
      final transaction = await interrupted(phase: 'committed');
      await LocalDownloadRemover(directory).recover();
      expect(await file('track_1_$digest.mp3').exists(), isFalse);
      expect(
        (jsonDecode(await index.readAsString()) as Map).containsKey('1'),
        isFalse,
      );
      expect(await transaction.exists(), isFalse);
    },
  );

  test(
    'legacy interrupted removal restores file without inventing a version',
    () async {
      await interrupted(phase: 'staging', legacy: true);
      await LocalDownloadRemover(directory).recover();
      expect(await file('track_1_$digest.mp3').exists(), isTrue);
      expect(
        (jsonDecode(await index.readAsString()) as Map).containsKey('1'),
        isFalse,
      );
    },
  );

  test('untrusted journal path cannot reach another file', () async {
    final transaction = await interrupted(phase: 'staging');
    await File('${transaction.path}/journal.json').writeAsString(
      jsonEncode({
        'version': 1,
        'id': 1,
        'phase': 'committed',
        'files': ['../../my_playlists.json'],
        'oldRecord': null,
      }),
    );
    await expectLater(
      LocalDownloadRemover(directory).recover(),
      throwsFormatException,
    );
    expect(
      await file('my_playlists.json').readAsString(),
      'fixture:my_playlists.json',
    );
  });

  test('Windows file lock preserves every file and index', () async {
    if (!Platform.isWindows) return;
    // An open native file handle exercises Windows rename rejection.
    // Native lock semantics vary by Dart SDK; injectable access-denied test
    // above is the deterministic fault-injection contract on every platform.
    final handle = await file('track_1_$digest.mp3').open();
    try {
      final remover = LocalDownloadRemover(directory);
      await expectLater(
        remover.remove(
          1,
          commitIndex: () async => save({...original}..remove('1')),
        ),
        throwsFileSystemException,
      );
      expect(jsonDecode(await index.readAsString()), original);
      expect(await file('track_1_$digest.mp3').exists(), isTrue);
    } finally {
      await handle.close();
    }
  });
}
