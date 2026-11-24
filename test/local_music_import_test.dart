import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shiki/local_music_catalog.dart';
import 'package:shiki/local_music_import.dart';
import 'package:shiki/lyrics_search.dart';
import 'package:shiki/mp3_metadata.dart';
import 'package:shiki/music_import.dart';
import 'package:shiki/widgets/artist_library_view.dart';

import 'fixtures/local_mp3.dart';

void main() {
  late Directory root, originals, library;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('shiki-local-mp3-');
    originals = await Directory('${root.path}/originals').create();
    library = await Directory('${root.path}/library').create();
  });
  tearDown(() => root.delete(recursive: true));

  Future<LocalMusicFile> given(String name, List<int> bytes) async {
    final file = await File('${originals.path}/$name').writeAsBytes(bytes);
    return (name: name, path: file.path);
  }

  Future<LocalMusicImportResult> add(
    List<LocalMusicFile> files, {
    bool desktop = false,
    LocalImportCancel? token,
    LocalMusicProgress? progress,
  }) => importLocalMusic(
    directory: library,
    files: files,
    cancel: token ?? LocalImportCancel(),
    lookForAdjacentLyrics: desktop,
    onProgress: progress,
  );

  test('imports with a progress callback that owns UI-isolate state', () async {
    final selection = await given('Вне библиотеки (1).MP3', fixtureMp3());
    final port = ReceivePort();
    addTearDown(port.close);
    var reports = 0;
    final result = await add(
      [selection],
      progress: (_, _, _, _) {
        port.sendPort.send('progress');
        reports++;
      },
    );
    expect(result.added, 1);
    expect(result.newEntries, result.entries);
    expect(reports, greaterThanOrEqualTo(2));
    final copy = File(
      '${library.path}/local_audio_${result.entries.single.digest}.mp3',
    );
    expect(await copy.readAsBytes(), await File(selection.path!).readAsBytes());
  });

  test(
    'reimport recognises a copy from the old subfolder without duplicating it',
    () async {
      final bytes = fixtureMp3();
      final selection = await given('Original.mp3', bytes);
      final digest = sha256.convert(bytes).toString();
      final oldDirectory = await Directory(
        '${library.path}/local_music',
      ).create();
      final name = localAudioName(digest);
      final oldCopy = await File(
        '${oldDirectory.path}/$name',
      ).writeAsBytes(bytes);
      final entry = LocalMusicEntry(id: -1, digest: digest, title: 'Existing');
      await File(
        '${library.path}/$localMusicCatalogName',
      ).writeAsString(encodeLocalMusicCatalogText([entry]));

      final result = await add([selection]);
      expect(result.alreadyPresent, 1);
      expect(result.added, 0);
      expect(result.newEntries, isEmpty);
      expect(result.entries.single.id, -1);
      expect(resolveLocalMusicAsset(library, name).path, oldCopy.path);
      expect(await oldCopy.readAsBytes(), bytes);
      expect(await localMusicAsset(library, name).exists(), isFalse);
    },
  );

  test('only removes the owned copy, cover and catalog row', () async {
    final source = await given('Original.mp3', fixtureMp3());
    final entry = (await add([source])).entries.single;
    final legacy = await Directory('${library.path}/local_music').create();
    final copies = [
      localMusicAsset(library, localAudioName(entry.digest)),
      await localMusicAsset(
        legacy,
        localAudioName(entry.digest),
      ).writeAsBytes(fixtureMp3()),
      await localMusicAsset(
        library,
        localCoverName(entry.digest),
      ).writeAsBytes([1, 2, 3]),
      await localMusicAsset(
        legacy,
        localCoverName(entry.digest),
      ).writeAsBytes([4, 5, 6]),
    ];
    final downloaded = await File(
      '${library.path}/track_1.mp3',
    ).writeAsBytes([1, 2, 3, 4]);
    final stale = await removeLocalMusic(
      directory: library,
      id: entry.id == -1 ? -2 : -1,
      digest: entry.digest,
    );
    expect(stale.removed, isFalse);
    expect(await copies.first.exists(), isTrue);

    final result = await removeLocalMusic(
      directory: library,
      id: entry.id,
      digest: entry.digest,
      onRemoved: (entries) async {
        expect(entries, isEmpty);
        expect(await readLocalMusicCatalog(library), isEmpty);
        expect(await copies.first.exists(), isTrue);
      },
    );
    expect(result, (removed: true, cleanupComplete: true));
    for (final copy in copies) {
      expect(await copy.exists(), isFalse);
    }
    expect(await File(source.path!).readAsBytes(), fixtureMp3());
    expect(await downloaded.readAsBytes(), [1, 2, 3, 4]);
  });

  test(
    'cleanup cannot erase a same-recording import waiting for its turn',
    () async {
      final source = await given('Original.mp3', fixtureMp3());
      final entry = (await add([source])).entries.single;
      final blocked = Completer<void>();
      final committed = Completer<void>();
      final removal = removeLocalMusic(
        directory: library,
        id: entry.id,
        digest: entry.digest,
        onRemoved: (_) {
          committed.complete();
          return blocked.future;
        },
      );
      await committed.future;
      final reimport = add([source]);
      blocked.complete();
      expect((await removal).cleanupComplete, isTrue);
      expect((await reimport).newEntries.single.digest, entry.digest);
      expect(await readLocalMusicCatalog(library), hasLength(1));
      expect(
        await localMusicAsset(library, localAudioName(entry.digest)).exists(),
        isTrue,
      );
    },
  );

  test('skips an unexpected directory instead of removing it', () async {
    final source = await given('Original.mp3', fixtureMp3());
    final entry = (await add([source])).entries.single;
    final unexpected = await Directory(
      localMusicAsset(library, localCoverName(entry.digest)).path,
    ).create();
    final result = await removeLocalMusic(
      directory: library,
      id: entry.id,
      digest: entry.digest,
    );
    expect(result, (removed: true, cleanupComplete: false));
    expect(await unexpected.exists(), isTrue);
    expect(await readLocalMusicCatalog(library), isEmpty);
  });

  test(
    'Unicode tags, disc/track number and attached PNG survive import',
    () async {
      final bytes = fixtureMp3(
        version: 3,
        tags: [
          utf16Tag('TIT2', 'Привет 東京 🎵'),
          utf16Tag('TPE1', 'Исполнитель'),
          utf16Tag('TALB', 'Альбом'),
          utf16Tag('TRCK', '7/10'),
          utf16Tag('TPOS', '2/2'),
          (
            id: 'APIC',
            bytes: [
              0,
              ...'image/png'.codeUnits,
              0,
              3,
              0,
              ...img.encodePng(img.Image(width: 24, height: 12)),
            ],
          ),
        ],
      );
      final source = await given('raw.MP3', bytes);
      const lyric = '[00:00.02]Первая строка\n[00:00.08]Вторая';
      await File('${originals.path}/raw.lrc').writeAsString(lyric);
      final result = await add([source], desktop: true);
      expect(result.added, 1);
      expect(result.problems, isEmpty);
      final record = (await readLocalMusicCatalog(library)).single;
      expect(record.digest, sha256.convert(bytes).toString());
      expect(record.title, 'Привет 東京 🎵');
      expect(record.artist, 'Исполнитель');
      expect(record.album, 'Альбом');
      expect(record.trackNumber, 7);
      expect(record.discNumber, 2);
      expect(record.lyrics, lyric);
      final copy = localMusicAsset(library, localAudioName(record.digest));
      final cover = localMusicAsset(library, localCoverName(record.digest));
      expect(await File(source.path!).readAsBytes(), bytes);
      await File(source.path!).delete();
      expect(await copy.readAsBytes(), bytes);
      expect(img.decodeJpg(await cover.readAsBytes())?.width, 24);
      final track = record.toTrack();
      expect(record.id, lessThan(0));
      expect(isLocalMusic(track), isTrue);
      expect(downloadTrackId(track), isNull);
      expect(matchesTrackSearch(track, '東京 альбом'), isTrue);
      final index = LyricsSearchIndex();
      addTearDown(index.dispose);
      await index.prepare([
        track,
      ], lyricsFile: (_) => throw StateError('No server LRC read'));
      expect(
        index.matches(record.id, LyricsSearchQuery('Первая строка')),
        isTrue,
      );
    },
  );

  test(
    'explicit sidecar works with cached picker paths and no folder scan',
    () async {
      final source = await given(
        'download.dat',
        fixtureMp3(tags: [utf8Tag('TIT2', 'Кишлак')]),
      );
      final lyric = await given('provider.tmp', [
        0xff,
        0xfe,
        for (final unit in '[00:00]歌'.codeUnits) ...[unit & 255, unit >> 8],
      ]);
      final batch = await add([
        (name: 'music.mp3', path: source.path),
        (name: 'music.lrc', path: lyric.path),
      ]);
      expect(batch.entries.single.title, 'Кишлак');
      expect(batch.entries.single.lyrics, '[00:00]歌');
    },
  );

  test(
    'dedupe by bytes, not title; refill a missing copy using same ID',
    () async {
      final one = await given(
        'one.mp3',
        fixtureMp3(tags: [utf8Tag('TIT2', 'Same title')]),
      );
      final dup = await given(
        'renamed.mp3',
        await File(one.path!).readAsBytes(),
      );
      final other = await given(
        'two.mp3',
        fixtureMp3(tags: [utf8Tag('TIT2', 'Same title')], variation: 1),
      );
      final first = await add([one, dup, other]);
      expect(first.added, 2);
      expect(first.alreadyPresent, 1);
      expect(first.entries.map((e) => e.title), ['Same title', 'Same title']);
      expect(first.entries.map((e) => e.id).toSet(), hasLength(2));
      final record = first.entries.first;
      await localMusicAsset(library, localAudioName(record.digest)).delete();
      final repaired = await add([dup]);
      expect(repaired.restored, 1);
      expect(repaired.added, 0);
      expect(repaired.entries.first.id, record.id);
      expect(
        await localMusicAsset(library, localAudioName(record.digest)).exists(),
        isTrue,
      );
    },
  );

  test(
    'no tags falls back to file name; broken APIC and wrong formats are isolated',
    () async {
      final invalid = await given('fake.mp3', 'RIFF WAV file'.codeUnits);
      final noTags = await given('Без тегов.mp3', fixtureMp3());
      final badCover = await given(
        'has-lyrics-tag.mp3',
        fixtureMp3(
          tags: [
            utf8Tag('TIT2', 'Song'),
            (
              id: 'APIC',
              bytes: [0, ...'image/jpeg'.codeUnits, 0, 3, 0, 255, 216, 0, 0],
            ),
          ],
        ),
      );
      final result = await add([
        invalid,
        noTags,
        badCover,
        (name: 'gone.mp3', path: '${originals.path}/not-present.mp3'),
        (name: 'other.wav', path: invalid.path),
        (name: 'isolated.lrc', path: invalid.path),
      ]);
      expect(result.added, 2);
      expect(result.entries.map((e) => e.title), ['Без тегов', 'Song']);
      expect(
        result.problems.map((e) => e.problem).toSet(),
        LocalImportProblem.values.toSet(),
      );
      expect(
        await localMusicAsset(
          library,
          localCoverName(result.entries.last.digest),
        ).exists(),
        isFalse,
      );
      expect(await readLocalMusicCatalog(library), hasLength(2));
    },
  );

  test(
    'cancel keeps finished tracks; unavailable target does not add a row',
    () async {
      final first = await given('first.mp3', fixtureMp3(variation: 1));
      final second = await given(
        'second.mp3',
        fixtureMp3(variation: 2, frames: 200),
      );
      final token = LocalImportCancel();
      final result = await add(
        [first, second],
        token: token,
        progress: (i, _, _, _) {
          if (i == 2) token.cancel();
        },
      );
      expect(result.cancelled, isTrue);
      expect(result.entries.single.title, 'first');
      expect(await library.list().where((f) => f is Directory).isEmpty, isTrue);
      final digest = sha256
          .convert(await File(second.path!).readAsBytes())
          .toString();
      await Directory(
        localMusicAsset(library, localAudioName(digest)).path,
      ).create();
      expect(
        (await add([second])).problems.single.problem,
        LocalImportProblem.cannotRead,
      );
      expect(await readLocalMusicCatalog(library), hasLength(1));
      expect(await File(second.path!).exists(), isTrue);
    },
  );

  test('concurrent batches keep both catalog commits', () async {
    final a = await given('a.mp3', fixtureMp3(variation: 21));
    final b = await given('b.mp3', fixtureMp3(variation: 22));
    await Future.wait([
      add([a]),
      add([b]),
    ]);
    expect((await readLocalMusicCatalog(library)).map((e) => e.title).toSet(), {
      'a',
      'b',
    });
  });

  test('first half of a frame is not treated as readable audio', () async {
    final bad = await given('short.mp3', fixtureMp3().sublist(0, 404));
    await expectLater(readMp3Metadata(bad.path!), throwsFormatException);
  });

  test('offline metadata does not merge with a same-name server artist', () {
    final record = LocalMusicEntry(
      id: -1,
      digest: 'a' * 64,
      title: 'Song',
      artist: 'Alias',
    );
    final artists = artistLibraryEntries(
      [
        {'id': 1, 'name': 'Alias'},
      ],
      [record.toTrack()],
      '',
    );
    expect(artists, hasLength(2));
    expect(artists.map((a) => a['id']).where((id) => id < 0), hasLength(1));
  });
}
