import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/library_transfer.dart';
import 'package:shiki/local_music_catalog.dart';
import 'package:shiki/local_music_import.dart';
import 'package:shiki/lyric_timing.dart';

import 'fixtures/local_mp3.dart';

void main() {
  late Directory root, source, target;
  late String archive;
  const lrc = '[00:00.10]Синхронный текст';
  final lrcDigest = sha256.convert(utf8.encode(lrc)).toString();
  final mp3 = fixtureMp3(tags: [utf8Tag('TIT2', 'Track from ZIP')]);
  final digest = sha256.convert(mp3).toString();
  const incomingId = -57;
  final song = LocalMusicEntry(
    id: incomingId,
    digest: digest,
    title: 'Track from ZIP',
    lyrics: lrc,
  );
  final other = LocalMusicEntry(
    id: incomingId,
    digest: 'e' * 64,
    title: 'Existing',
  );

  File file(Directory d, String name) => File('${d.path}/$name');
  Future<void> json(Directory d, String name, Object value) =>
      file(d, name).writeAsString(jsonEncode(value));
  Future<dynamic> read(Directory d, String name) async =>
      jsonDecode(await file(d, name).readAsString());
  Future<void> createCatalog(Directory d, LocalMusicEntry entry) =>
      json(d, localMusicCatalogName, encodeLocalMusicCatalog([entry]));
  Future<int> offset(Directory d, int id) => LyricTimingStore(d).lookup(
    id,
    lyricsFingerprint: () => lrcDigest,
    audioFingerprint: () async => digest,
  );
  Future<void> saveOffset(Directory d, int id, int advance) => LyricTimingStore(
    d,
  ).save(id, audio: digest, text: lrcDigest, advanceMilliseconds: advance);
  Future<void> fixture() async {
    await createCatalog(source, song);
    await ensureLocalMusicDirectory(source);
    await localMusicAsset(source, localAudioName(digest)).writeAsBytes(mp3);
    await json(source, 'liked_tracks.json', [incomingId, 12]);
    await json(source, 'my_playlists.json', [
      {
        'id': 90,
        'name': 'Mixed playlist',
        'tracks': [12, incomingId],
        'image': '',
      },
    ]);
    await saveOffset(source, incomingId, 200);
  }

  Future<void> export({bool media = true}) => exportLibraryArchive(
    directory: source,
    destination: archive,
    includeMedia: media,
  ).then((_) {});
  Future<void> restore() async {
    await prepareLibraryImport(directory: target, archive: archive);
    expect(await applyPendingLibraryImport(target), isTrue);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('shiki-own-zip-');
    source = await Directory('${root.path}/source').create();
    target = await Directory('${root.path}/target').create();
    archive = '${root.path}/library.zip';
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'v2 full transfer remaps collision, keeps order and repeats idempotently',
    () async {
      await fixture();
      await createCatalog(target, other);
      await json(target, 'liked_tracks.json', [other.id]);
      await export();
      await restore();
      await restore();
      final catalog = await readLocalMusicCatalog(target);
      expect(catalog, hasLength(2));
      final imported = catalog.singleWhere((entry) => entry.digest == digest);
      expect(catalog.first.id, incomingId);
      expect(imported.id, isNot(incomingId));
      expect(imported.lyrics, lrc);
      expect(
        await localMusicAsset(target, localAudioName(digest)).readAsBytes(),
        mp3,
      );
      expect(await read(target, 'liked_tracks.json'), [
        other.id,
        imported.id,
        12,
      ]);
      expect(
        (await read(target, 'my_playlists.json') as List).single['tracks'],
        [12, imported.id],
      );
      expect(await offset(target, imported.id), 200);
      expect(await offset(target, other.id), 0);
    },
  );

  test(
    'metadata-only v2 reattaches exact bytes and keeps existing correction',
    () async {
      await fixture();
      await createCatalog(target, song.withIdAndLyrics(-99, lrc));
      await saveOffset(target, -99, -300);
      await export(media: false);
      await restore();
      final copy = localMusicAsset(target, localAudioName(digest));
      expect(await copy.exists(), isFalse);
      final saved = (await readLocalMusicCatalog(target)).single;
      expect(saved.id, -99);
      expect(saved.lyrics, lrc);
      expect(await offset(target, -99), -300);
      expect(await read(target, 'liked_tracks.json'), [-99, 12]);
      final original = await file(root, 'rename.mp3').writeAsBytes(mp3);
      final repaired = await importLocalMusic(
        directory: target,
        files: [(name: 'rename.mp3', path: original.path)],
        cancel: LocalImportCancel(),
      );
      expect(repaired.restored, 1);
      expect(repaired.entries.single.id, -99);
      expect(await copy.readAsBytes(), mp3);
    },
  );

  test('v1 archive still merges into a library with local favorites', () async {
    await json(source, 'liked_tracks.json', [12]);
    await json(source, 'my_playlists.json', [
      {
        'id': 90,
        'name': 'Server playlist',
        'tracks': [12],
        'image': '',
      },
    ]);
    await createCatalog(target, song);
    await json(target, 'liked_tracks.json', [song.id]);
    await export();
    final contents = ZipDecoder().decodeBytes(
      await File(archive).readAsBytes(),
    );
    final manifest = jsonDecode(
      utf8.decode(contents.find('shiki-transfer.json')!.readBytes()!),
    );
    expect(manifest['version'], 1);
    await restore();
    expect(await read(target, 'liked_tracks.json'), [song.id, 12]);
    expect((await readLocalMusicCatalog(target)).single.digest, digest);
  });

  test(
    'v2 will not export an audio copy whose bytes no longer match',
    () async {
      await fixture();
      await localMusicAsset(
        source,
        localAudioName(digest),
      ).writeAsBytes([4, 5, 6]);
      await expectLater(export(), throwsFormatException);
      expect(await File(archive).exists(), isFalse);
      expect(
        await localMusicAsset(source, localAudioName(digest)).readAsBytes(),
        [4, 5, 6],
      );
    },
  );

  test('v2 rejects references to a missing local catalog entry', () async {
    final bytes = utf8.encode(jsonEncode([-9]));
    final raw = ZipFileEncoder()..create(archive, level: 0);
    final manifest = utf8.encode(
      jsonEncode({
        'format': 'shiki-library',
        'version': 2,
        'media': false,
        'files': {
          'liked_tracks.json': {
            'size': bytes.length,
            'sha256': sha256.convert(bytes).toString(),
          },
        },
      }),
    );
    raw.addArchiveFile(
      ArchiveFile('liked_tracks.json', bytes.length, bytes)
        ..compression = CompressionType.none,
    );
    raw.addArchiveFile(
      ArchiveFile('shiki-transfer.json', manifest.length, manifest)
        ..compression = CompressionType.none,
    );
    await raw.close();
    await expectLater(
      prepareLibraryImport(directory: target, archive: archive),
      throwsFormatException,
    );
    expect(await target.list().isEmpty, isTrue);
  });
}
