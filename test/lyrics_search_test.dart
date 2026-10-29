import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shiki/lyrics_search.dart';

void main() {
  File missing(int id) => File('nonexistent-lyrics-search-fixture-$id.lrc');

  Future<LyricsSearchIndex> indexed(String lyrics) async {
    final index = LyricsSearchIndex();
    addTearDown(index.dispose);
    await index.prepare([
      {'id': 1, 'lyrics': lyrics},
    ], lyricsFile: missing);
    return index;
  }

  test(
    'phrase is case insensitive, ordered, adjacent, and matches whole words',
    () async {
      final index = await indexed(
        'Любовь из кучи обломков.\nМне скоро 25.\nЖёлтый свет.',
      );
      bool match(String query) => index.matches(1, LyricsSearchQuery(query));
      expect(match('ЛЮБОВЬ, из   кучи'), isTrue);
      expect(match('кучи любовь'), isFalse);
      expect(match('любовь обломков'), isFalse);
      expect(match('люб'), isFalse);
      expect(match('скоро 25'), isTrue);
      expect(match('желтый свет'), isTrue);
      expect(match('обломков мне скоро'), isTrue);
      expect(match(''), isFalse);
      expect(match('…!?'), isFalse);
    },
  );

  test(
    'single words do not match word fragments; repeats must be present',
    () async {
      final index = await indexed('кумир мира\nты ты мой свет');
      expect(index.matches(1, LyricsSearchQuery('мир')), isFalse);
      expect(index.matches(1, LyricsSearchQuery('мира')), isTrue);
      expect(index.matches(1, LyricsSearchQuery('ты ты')), isTrue);
      expect(index.matches(1, LyricsSearchQuery('ты ты ты')), isFalse);
    },
  );

  test(
    'LRC headers, repeated timestamps, offsets and enhanced times are not lyrics',
    () async {
      final index = await indexed(
        '[ar:Not Actual Singer]\n[ti:Wrong Title]\n[offset:-500]\n'
        '[00:01.00][00:13.00]Первое слово\n'
        '[00:05.00]<00:05.100>Второе <00:05.300>слово\n[Припев]',
      );
      expect(index.matches(1, LyricsSearchQuery('первое слово')), isTrue);
      expect(index.matches(1, LyricsSearchQuery('второе слово')), isTrue);
      for (final query in [
        'not actual',
        'wrong title',
        'offset',
        '00 13',
        'припев',
      ]) {
        expect(
          index.matches(1, LyricsSearchQuery(query)),
          isFalse,
          reason: query,
        );
      }
    },
  );

  test('English punctuation and Japanese phrases stay searchable', () async {
    final index = await indexed("Don't stop—hold on!\nいつか君の声が届く");
    expect(index.matches(1, LyricsSearchQuery("don't stop")), isTrue);
    expect(index.matches(1, LyricsSearchQuery('hold on')), isTrue);
    expect(index.matches(1, LyricsSearchQuery('君の声')), isTrue);
    expect(index.matches(1, LyricsSearchQuery('声の君')), isFalse);
  });

  test(
    'Russian quotation marks and emoji do not glue neighboring words',
    () async {
      final index = await indexed('«Любовь»❤️из кучи');
      expect(index.matches(1, LyricsSearchQuery('любовь из кучи')), isTrue);
    },
  );

  test(
    'plain and versioned local LRC are read offline when catalog has no text',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'shiki_lyrics_search_',
      );
      addTearDown(() => directory.delete(recursive: true));
      await File(
        '${directory.path}/track_1.lrc',
      ).writeAsString('[00:01]Старый текст');
      final versioned = File('${directory.path}/track_1_version.lrc');
      await versioned.writeAsString('[00:01]Новая версия песни');
      final index = LyricsSearchIndex();
      addTearDown(index.dispose);
      final tracks = [
        {'id': 1, 'lyrics': ''},
      ];
      await index.prepare(tracks, lyricsFile: (_) => versioned);
      expect(index.matches(1, LyricsSearchQuery('новая версия')), isTrue);
      expect(index.matches(1, LyricsSearchQuery('старый текст')), isFalse);
      tracks.first['lyrics'] = 'Свежий текст из каталога';
      await index.prepare(tracks, lyricsFile: (_) => versioned);
      expect(index.matches(1, LyricsSearchQuery('свежий текст')), isTrue);
      expect(index.matches(1, LyricsSearchQuery('новая версия')), isFalse);
    },
  );

  test(
    'missing, oversized and malformed local files do not break other tracks',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'shiki_lyrics_bad_',
      );
      addTearDown(() => directory.delete(recursive: true));
      await File(
        '${directory.path}/track_2.lrc',
      ).writeAsBytes([0xff, 0xfe, 0xff]);
      await File(
        '${directory.path}/track_3.lrc',
      ).writeAsString('x' * (1024 * 1024 + 1));
      final index = LyricsSearchIndex();
      addTearDown(index.dispose);
      await index.prepare([
        {'id': 1},
        {'id': 2},
        {'id': 3},
        {'id': 4, 'lyrics': 'Нужная фраза'},
      ], lyricsFile: (id) => File('${directory.path}/track_$id.lrc'));
      expect(index.matches(4, LyricsSearchQuery('нужная фраза')), isTrue);
      for (final id in [1, 2, 3]) {
        expect(index.matches(id, LyricsSearchQuery('x')), isFalse);
      }
    },
  );

  test('typing reuses the index; only changed lyrics are rebuilt', () async {
    final batches = <List<int>>[];
    final index = LyricsSearchIndex(
      builder: (jobs) async {
        batches.add([for (final job in jobs) job['id'] as int]);
        return buildLyricsSearchDocuments(jobs);
      },
    );
    addTearDown(index.dispose);
    final tracks = [
      {'id': 1, 'lyrics': 'Первая песня'},
      {'id': 2, 'lyrics': 'Вторая песня'},
    ];
    await index.prepare(tracks, lyricsFile: missing);
    for (final query in ['п', 'пе', 'первая', 'первая песня']) {
      await index.prepare(tracks, lyricsFile: missing);
      index.matches(1, LyricsSearchQuery(query));
    }
    expect(batches, [
      [1, 2],
    ]);
    tracks[0]['lyrics'] = 'Исправленные слова';
    await index.prepare(tracks, lyricsFile: missing);
    expect(batches, [
      [1, 2],
      [1],
    ]);
    expect(index.matches(1, LyricsSearchQuery('первая песня')), isFalse);
    expect(index.matches(1, LyricsSearchQuery('исправленные слова')), isTrue);
    tracks.removeAt(1);
    await index.prepare(tracks, lyricsFile: missing);
    expect(index.matches(2, LyricsSearchQuery('вторая песня')), isFalse);
    index.clear();
    expect(index.isReady, isFalse);
    expect(index.matches(1, LyricsSearchQuery('исправленные слова')), isFalse);
  });

  test('clearing a search discards a pending worker result', () async {
    final worker = Completer<Map<int, String>>();
    final index = LyricsSearchIndex(builder: (_) => worker.future);
    addTearDown(index.dispose);
    final work = index.prepare([
      {'id': 1, 'lyrics': 'Старые слова'},
    ], lyricsFile: missing);
    await Future<void>.delayed(Duration.zero);
    index.clear();
    worker.complete({1: ' старые слова '});
    expect(await work, isFalse);
    expect(index.matches(1, LyricsSearchQuery('старые слова')), isFalse);
    expect(index.isReady, isFalse);
  });

  test(
    'invalidation rejects stale results even if the local path stayed the same',
    () async {
      final old = Completer<Map<int, String>>();
      var calls = 0;
      final index = LyricsSearchIndex(
        builder: (_) {
          calls++;
          return calls == 1 ? old.future : Future.value({1: ' свежие слова '});
        },
      );
      addTearDown(index.dispose);
      final first = index.prepare([
        {'id': 1},
      ], lyricsFile: missing);
      await Future<void>.delayed(Duration.zero);
      index.invalidate(1);
      final second = index.prepare([
        {'id': 1},
      ], lyricsFile: missing);
      old.complete({1: ' старые слова '});
      await Future.wait([first, second]);
      expect(index.matches(1, LyricsSearchQuery('старые слова')), isFalse);
      expect(index.matches(1, LyricsSearchQuery('свежие слова')), isTrue);
    },
  );

  test(
    'worker failure is retryable and disposal ignores late completions',
    () async {
      var calls = 0;
      final index = LyricsSearchIndex(
        builder: (jobs) async {
          if (++calls == 1) throw StateError('worker fixture failure');
          return buildLyricsSearchDocuments(jobs);
        },
      );
      final tracks = [
        {'id': 1, 'lyrics': 'Нужные слова'},
      ];
      await expectLater(
        index.prepare(tracks, lyricsFile: missing),
        throwsStateError,
      );
      expect(index.isReady, isFalse);
      await index.prepare(tracks, lyricsFile: missing);
      expect(index.matches(1, LyricsSearchQuery('нужные слова')), isTrue);
      index.dispose();
      expect(await index.prepare(tracks, lyricsFile: missing), isFalse);
      expect(index.matches(1, LyricsSearchQuery('нужные слова')), isFalse);
    },
  );

  test('warm phrase-search benchmark over 1000 saved lyrics', () async {
    final index = LyricsSearchIndex();
    addTearDown(index.dispose);
    final tracks = [
      for (var id = 1; id <= 1000; id++)
        {
          'id': id,
          'lyrics':
              '${List.filled(40, '[00:01.00]Это обычная строка для проверки поиска').join('\n')}\n'
              'Любовь из кучи обломков $id',
        },
    ];
    final build = Stopwatch()..start();
    await index.prepare(tracks, lyricsFile: missing);
    build.stop();
    final query = LyricsSearchQuery('любовь из кучи');
    final measurements = <int>[];
    for (var repeat = 0; repeat < 50; repeat++) {
      final watch = Stopwatch()..start();
      final matches = tracks
          .where((track) => index.matches(track['id'] as int, query))
          .length;
      watch.stop();
      expect(matches, 1000);
      measurements.add(watch.elapsedMicroseconds);
    }
    measurements.sort();
    // Diagnostic timings only: hardware and debug VM speed are not product gates.
    debugPrint(
      'Lyrics search: build=${build.elapsedMilliseconds}ms; '
      '1000 tracks warm p50=${measurements[25]}us, p95=${measurements[47]}us',
    );
  });
}
