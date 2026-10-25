import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/listening_statistics.dart';
import 'package:shiki/statistics_store.dart';

class _GatedStore extends StatisticsStore {
  _GatedStore(super.path);
  Completer<void>? gate;
  Completer<void>? readStarted;
  int reads = 0;

  @override
  Future<Map<String, Object?>> liveSummary({
    required List<Map<String, Object?>> counters,
    String? from,
    String? to,
    bool byPlays = false,
  }) async {
    reads++;
    final result = await super.liveSummary(
      counters: counters,
      from: from,
      to: to,
      byPlays: byPlays,
    );
    readStarted?.complete();
    await gate?.future;
    return result;
  }
}

void main() {
  late Directory directory;
  late _GatedStore store;
  late ListeningStatistics statistics;
  late DateTime wall;
  var elapsed = 0;
  const from = '2026-09-10', to = '2026-10-09';

  Map<String, Object?> record(int id, int ms, {String day = to}) => {
    'id': id.toRadixString(16).padLeft(32, '0'),
    'day': day,
    'track_key': 'track:$id',
    'title': 'Track $id',
    'artists': [
      {'key': 'artist:7', 'name': 'First'},
      {'key': 'artist:8', 'name': 'Second'},
    ],
    'listening_ms': ms,
    'app_ms': 0,
    'plays': 1,
    'updated_at': 1,
  };

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shiki-live-statistics-');
    store = _GatedStore('${directory.path}/history.sqlite');
    wall = DateTime(2026, 10, 9, 12);
    elapsed = 0;
    statistics = ListeningStatistics(
      store,
      wallClock: () => wall,
      monotonicMilliseconds: () => elapsed,
    );
  });
  tearDown(() async {
    store.gate?.complete();
    await statistics.close();
    if (!directory.absolute.path.startsWith(
      '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}shiki-live-statistics-',
    )) {
      throw StateError('Unexpected test directory');
    }
    await directory.delete(recursive: true);
  });

  void start(int id) {
    statistics.beginTrack({
      'id': id,
      'title': 'Track $id',
      'duration': 30,
      'artists': [
        {'id': 7, 'name': 'First'},
        {'id': 8, 'name': 'Second'},
      ],
    });
    statistics.setPlaying(true);
    statistics.position(Duration.zero);
  }

  void play(int seconds, {int offset = 0}) {
    for (var i = 1; i <= seconds; i++) {
      elapsed += 1000;
      wall = wall.add(const Duration(seconds: 1));
      statistics.position(Duration(seconds: offset + i));
      statistics.tick();
    }
  }

  StatisticsSummary? cached({bool byPlays = false}) =>
      statistics.cachedSummary(from: from, to: to, byPlays: byPlays);

  test(
    'live read includes unsaved counters without writing or double counting',
    () async {
      start(1);
      play(20);
      final summary = await statistics.summary(from: from, to: to);
      expect(summary.listeningMs, 20000);
      expect(summary.appMs, 20000);
      expect(summary.plays, 1);
      expect(summary.artists, 2);
      expect((await store.summary())['listening_ms'], 0);
      play(4, offset: 20);
      expect(cached()!.listeningMs, 24000);
      expect(cached()!.topArtists.map((artist) => artist.milliseconds), [
        24000,
        24000,
      ]);
      await statistics.flush();
      expect(cached()!.listeningMs, 24000);
      expect((await statistics.summary(from: from, to: to)).listeningMs, 24000);
      expect((await store.summary())['listening_ms'], 24000);
    },
  );

  test(
    'background preparation is deduplicated and includes playback during a read',
    () async {
      start(1);
      play(5);
      store.gate = Completer<void>();
      store.readStarted = Completer<void>();
      final first = statistics.summary(from: from, to: to);
      final second = statistics.summary(from: from, to: to);
      expect(identical(first, second), isTrue);
      await store.readStarted!.future;
      play(3, offset: 5);
      start(2);
      play(2);
      store.gate!.complete();
      store.gate = null;
      final summary = await first;
      expect(summary.listeningMs, 10000);
      expect(summary.tracks, 2);
      expect(store.reads, 1);
      expect(cached()!.listeningMs, 10000);
    },
  );

  test(
    'preparation gives fresh synchronous data and sorting does not reread SQLite',
    () async {
      await store.write([record(1, 60000), record(2, 10000)]);
      await statistics.prepareSummary();
      start(2);
      play(16);
      expect(cached()!.listeningMs, 86000);
      expect(cached()!.topTracks.first.key, 'track:1');
      expect(cached(byPlays: true)!.topTracks.first.key, 'track:2');
      expect(cached()!.plays, 3);
      expect(store.reads, 1);
    },
  );

  test(
    'a track outside the visible top 100 keeps its historical time',
    () async {
      await store.write([for (var i = 1; i <= 101; i++) record(i, 2000 - i)]);
      await statistics.prepareSummary();
      expect(cached()!.topTracks.length, 100);
      start(101);
      play(2);
      final summary = cached()!;
      expect(summary.topTracks.first.key, 'track:101');
      expect(summary.topTracks.first.milliseconds, 3899);
      expect(summary.tracks, 101);
    },
  );

  test(
    'snapshot respects date boundaries including listening after midnight',
    () async {
      start(1);
      play(2);
      await statistics.prepareSummary();
      wall = DateTime(2026, 10, 10, 0, 0, 1);
      play(1, offset: 2);
      expect(cached()!.listeningMs, 2000);
      expect(
        statistics.cachedSummary(from: '2026-09-11', to: '2026-10-10'),
        isNull,
      );
      final nextDay = await statistics.summary(
        from: '2026-09-11',
        to: '2026-10-10',
      );
      expect(nextDay.listeningMs, 3000);
      expect(nextDay.days.length, 2);
    },
  );

  test(
    'import invalidates the snapshot and preserves current listening',
    () async {
      start(1);
      play(3);
      await statistics.prepareSummary();
      final backup = File('${directory.path}/import.json');
      await backup.writeAsString(
        jsonEncode({
          'format': 'shiki-listening-statistics',
          'version': 1,
          'rows': [record(2, 12000)],
        }),
      );
      await statistics.importFile(backup.path);
      expect(cached(), isNull);
      expect((await statistics.summary(from: from, to: to)).listeningMs, 15000);
    },
  );

  test('live rows merge with persisted counters using maxima', () async {
    final existing = record(1, 20000);
    await store.write([existing]);
    final summary = await store.liveSummary(
      counters: [
        {...existing, 'listening_ms': 5000},
        record(2, 8000),
      ],
    );
    expect(summary['listening_ms'], 28000);
    expect((await store.summary())['listening_ms'], 20000);
  });

  test('prepared lookup timing on 10000 sessions and 500 tracks', () async {
    await store.write([
      for (var i = 1; i <= 10000; i++)
        {
          ...record(i, 60000),
          'track_key': 'track:${i % 500 + 1}',
          'title': 'Track ${i % 500 + 1}',
        },
    ]);
    start(1);
    play(5);
    final prepare = Stopwatch()..start();
    await statistics.prepareSummary();
    prepare.stop();
    play(2, offset: 5);
    final lookup = Stopwatch()..start();
    final summary = cached()!;
    lookup.stop();
    expect(summary.listeningMs, 600007000);
    expect(summary.tracks, 500);
    debugPrint(
      'Statistics fixture: prepare=${prepare.elapsedMicroseconds / 1000} ms, '
      'fresh synchronous lookup=${lookup.elapsedMicroseconds / 1000} ms',
    );
  });
}
