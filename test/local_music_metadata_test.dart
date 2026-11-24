import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/local_music_catalog.dart';
import 'package:shiki/local_music_import.dart';
import 'package:shiki/local_music_metadata.dart';

import 'fixtures/local_mp3.dart';

void main() {
  final server = Uri.parse('http://localhost:8000');
  const sourceId = 'youtube:abcdefghijk';
  const entry = LocalMusicEntry(
    id: -3,
    digest: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    title: 'Original filename',
    duration: 160,
  );

  LocalMusicMetadata snapshot([Map<String, Object?> edits = const {}]) =>
      LocalMusicMetadata.decode({
        'title': 'Verified track',
        'artists': ['Artist', 'Guest'],
        'album': 'Album',
        'lyrics': '[00:01.00]Found words',
        'source_id': sourceId,
        'cover': 'https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg',
        ...edits,
      }, serverKey: localMusicServerKey(server))!;

  Map<String, Object?> row({String source = sourceId}) => {
    'id': 93,
    'source_id': source,
    'title': 'Verified track',
    'duration': 160,
    'audio_file': 'http://localhost:8000/media/tracks/server.mp3',
    'video_file': '/media/clips/found.mp4',
    'lyrics': '[00:01.00]Catalog words',
    'artists': [
      {'id': 5, 'name': 'Artist'},
      {'id': 6, 'name': 'Guest'},
    ],
    'album': {
      'id': 6,
      'title': 'Album',
      'artist': {'id': 5, 'name': 'Artist'},
      'cover': '/media/covers/cover.jpg',
    },
  };

  Map<String, Object?> project(
    LocalMusicEntry entry,
    Iterable<Map> catalog, {
    Uri? base,
  }) => projectLocalMusic(
    [entry],
    catalog,
    server: base ?? server,
    unknownArtist: 'Unknown',
    unknownAlbum: 'Unknown',
  )[entry.id]!;

  test(
    'server result enriches the owned row without adding a server audio source',
    () {
      final linked = entry.withMetadata(snapshot());
      final preview = project(linked, []);
      expect(preview['title'], 'Verified track');
      expect(preview['lyrics'], '[00:01.00]Found words');
      expect(preview['video_file'], isEmpty);
      expect(getPictureProvider(preview), isA<NetworkImage>());

      final loaded = project(linked, [row()]);
      expect(loaded['id'], entry.id);
      expect(localTrackDigest(loaded), entry.digest);
      expect(loaded['local_match_id'], 93);
      expect(loaded['audio_file'], isEmpty);
      expect(
        loaded['video_file'],
        'http://localhost:8000/media/clips/found.mp4',
      );
      expect(loaded['lyrics'], '[00:01.00]Catalog words');
      expect((loaded['artists'] as List).map((a) => a['id']), [5, 6]);
      expect(
        loaded['album'],
        containsPair('cover', 'http://localhost:8000/media/covers/cover.jpg'),
      );
    },
  );

  test(
    'a saved LRC wins and a different server cannot supply someone else’s clip',
    () {
      final linked = entry.withMetadata(snapshot({'track_id': 93}));
      final withOwnLyrics = linked.withIdAndLyrics(
        entry.id,
        '[00:01.00]Own words',
      );
      final restored = decodeLocalMusicCatalog(
        encodeLocalMusicCatalog([withOwnLyrics]),
      ).single;
      final normal = project(restored, [row()]);
      expect(normal['lyrics'], '[00:01.00]Own words');
      for (final wrong in [
        project(restored, [row(source: 'youtube:wrongtrack1')]),
        project(restored, [row()], base: Uri.parse('http://127.0.0.1:8000')),
      ]) {
        expect(wrong['title'], 'Verified track');
        expect(wrong['local_match_id'], isNull);
        expect(wrong['video_file'], isEmpty);
        expect(wrong['lyrics'], '[00:01.00]Own words');
      }
    },
  );

  test('legacy ID link checks metadata and duration', () {
    final linked = entry.withMetadata(
      snapshot({'source_id': '', 'track_id': 93}),
    );
    expect(project(linked, [row(source: '')])['local_match_id'], 93);
    expect(
      project(linked, [
        {...row(source: ''), 'duration': 177},
      ])['local_match_id'],
      isNull,
    );
    expect(
      project(linked, [
        {...row(source: ''), 'title': 'Other track'},
      ])['local_match_id'],
      isNull,
    );
  });

  test(
    'lookup cannot resurrect deletion; re-selecting never moves or duplicates MP3',
    () async {
      final root = await Directory.systemTemp.createTemp('shiki-metadata-');
      addTearDown(() => root.delete(recursive: true));
      final input = await File(
        '${root.path}/user.mp3',
      ).writeAsBytes(fixtureMp3());
      Future<LocalMusicImportResult> pick() => importLocalMusic(
        directory: root,
        files: [(name: 'user.mp3', path: input.path)],
        cancel: LocalImportCancel(),
      );
      final imported = (await pick()).entries.single;
      final repeated = await pick();
      expect(repeated.added, 0);
      expect(repeated.matchEntries.single.id, imported.id);
      final updated = await updateLocalMusicMetadata(
        directory: root,
        target: imported,
        metadata: snapshot(),
      );
      expect(updated!.single.id, imported.id);
      expect(
        (await readLocalMusicCatalog(root)).single.metadata?.title,
        'Verified track',
      );
      expect(
        await fileSha256(input),
        await fileSha256(
          resolveLocalMusicAsset(root, localAudioName(imported.digest)),
        ),
      );
      await removeLocalMusic(
        directory: root,
        id: imported.id,
        digest: imported.digest,
      );
      expect(
        await updateLocalMusicMetadata(
          directory: root,
          target: imported,
          metadata: snapshot(),
        ),
        isNull,
      );
      expect(await readLocalMusicCatalog(root), isEmpty);
      expect(await input.exists(), isTrue);
    },
  );

  test('only same-origin clip URLs are accepted', () {
    for (final url in [
      'https://elsewhere.example/movie.mp4',
      'file:///temp/movie.mp4',
    ]) {
      expect(localMatchMediaUrl(server, url), isEmpty);
    }
    expect(
      localMatchMediaUrl(server, '/media/movie.mp4'),
      'http://localhost:8000/media/movie.mp4',
    );
  });
}
