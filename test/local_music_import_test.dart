import 'dart:io';

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
      expect(
        await localMusicDirectory(
          library,
        ).list().where((f) => f is Directory).isEmpty,
        isTrue,
      );
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
