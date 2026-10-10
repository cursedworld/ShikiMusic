import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/listening_statistics.dart';
import 'package:shiki/statistics_store.dart';

class MemoryStatisticsStore extends StatisticsStore {
  MemoryStatisticsStore() : super('unused');
  final Map<String, Map<String, Object?>> rows = {};
  bool failNext = false;
  Completer<void>? gate;
  int writes = 0;

  @override
  Future<void> write(List<Map<String, Object?>> records) async {
    writes++;
    if (failNext) {
      failNext = false;
      throw StateError('disk unavailable');
    }
    if (gate != null) await gate!.future;
    for (final row in records) {
      rows['${row['id']}/${row['day']}'] = row;
    }
  }

  int total(String field) =>
      rows.values.fold(0, (sum, row) => sum + (row[field] as int));
}

void main() {
  late MemoryStatisticsStore store;
  late ListeningStatistics statistics;
  late DateTime wall;
  var elapsed = 0;
  final track = {
    'id': 1,
    'title': 'Track',
    'duration': 180,
    'artists': [
      {'id': 7, 'name': 'First'},
      {'id': 8, 'name': 'Second'},
    ],
  };

  setUp(() {
    store = MemoryStatisticsStore();
    wall = DateTime(2026, 10, 9, 12);
    elapsed = 0;
    statistics = ListeningStatistics(
      store,
      wallClock: () => wall,
      monotonicMilliseconds: () => elapsed,
    );
  });
  tearDown(() => statistics.close());

  void advance(int milliseconds) {
    elapsed += milliseconds;
    wall = wall.add(Duration(milliseconds: milliseconds));
  }

  void start([Map? song]) {
    statistics.beginTrack(song ?? track);
    statistics.setPlaying(true);
    statistics.position(Duration.zero);
  }

  void play(int seconds, {int from = 0}) {
    for (var i = 1; i <= seconds; i++) {
      advance(1000);
      statistics.position(Duration(seconds: from + i));
      statistics.tick();
    }
  }

  test(
    'counts actual audio and all collaborators, qualifying once per play',
    () async {
      start();
      play(29);
      await statistics.flush();
      expect(store.total('plays'), 0);
      expect(store.total('listening_ms'), 29000);
      play(5, from: 29);
      await statistics.flush();
      expect(store.total('plays'), 1);
      expect(store.total('listening_ms'), 34000);
      expect(store.total('app_ms'), 34000);
      final row = store.rows.values.firstWhere(
        (row) => row['track_key'] == 'track:1',
      );
      expect((row['artists'] as List).length, 2);
    },
  );

  test(
    'pauses, buffering and both seek directions add no phantom minutes',
    () async {
      start();
      play(5);
      statistics.setPlaying(false);
      advance(60000);
      statistics.position(const Duration(seconds: 5));
      statistics.setPlaying(true);
      statistics.position(const Duration(seconds: 5));
      advance(1000);
      statistics.position(const Duration(seconds: 5));
      statistics.setSeeking(true);
      advance(1000);
      statistics.position(const Duration(seconds: 100));
      statistics.setSeeking(false);
      statistics.position(const Duration(seconds: 100));
      play(2, from: 100);
      advance(1000);
      statistics.position(const Duration(seconds: 1));
      play(2, from: 1);
      // Unannounced large forward jumps are rejected too.
      advance(1000);
      statistics.position(const Duration(seconds: 150));
      await statistics.flush();
      expect(store.total('listening_ms'), 9000);
      expect(store.total('plays'), 0);
    },
  );

  test('background music counts while active-window time stops', () async {
    start();
    play(2);
    statistics.setForeground(false);
    play(10, from: 2);
    statistics.setForeground(true);
    play(3, from: 12);
    await statistics.flush();
    expect(store.total('listening_ms'), 15000);
    expect(store.total('app_ms'), 5000);
  });

  test('repeats get separate plays; short songs qualify after half', () async {
    final short = {...track, 'duration': 8};
    start(short);
    play(4);
    start(short);
    play(4);
    await statistics.flush();
    expect(store.total('listening_ms'), 8000);
    expect(store.total('plays'), 2);
  });

  test(
    'midnight splits real listening time without duplicating a play',
    () async {
      wall = DateTime(2026, 10, 9, 23, 59, 58);
      start();
      play(35);
      await statistics.flush();
      int onDay(String day) => store.rows.values
          .where((row) => row['day'] == day)
          .fold(0, (sum, row) => sum + (row['listening_ms'] as int));
      expect(onDay('2026-10-09'), 2000);
      expect(onDay('2026-10-10'), 33000);
      expect(store.total('plays'), 1);
    },
  );

  test('disk failure retains counters for retry', () async {
    start();
    play(2);
    store.failNext = true;
    await expectLater(statistics.flush(), throwsStateError);
    await statistics.flush();
    expect(store.total('listening_ms'), 2000);
  });

  test(
    'events during a pending write remain dirty and are saved next',
    () async {
      start();
      play(2);
      store.gate = Completer<void>();
      final saving = statistics.flush();
      await Future<void>.delayed(Duration.zero);
      play(2, from: 2);
      store.gate!.complete();
      await saving;
      store.gate = null;
      await statistics.flush();
      expect(store.total('listening_ms'), 4000);
    },
  );

  test('position updates do not write to disk every second', () async {
    start();
    play(29);
    expect(store.writes, 0);
    play(1, from: 29);
    await statistics.flush();
    expect(store.writes, 1);
  });
}
