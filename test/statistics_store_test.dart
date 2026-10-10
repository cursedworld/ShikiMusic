import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/disposable_cache.dart';
import 'package:shiki/statistics_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late StatisticsStore store;
  Map<String, Object?> record(
    String id,
    String day,
    int ms, {
    int plays = 0,
    int trackId = 1,
  }) => {
    'id': id.padLeft(32, '0'),
    'day': day,
    'track_key': 'track:$trackId',
    'title': 'Track $trackId',
    'artists': [
      {'key': 'artist:7', 'name': 'First'},
      {'key': 'artist:8', 'name': 'Second'},
    ],
    'listening_ms': ms,
    'app_ms': 0,
    'plays': plays,
    'updated_at': 1791540000000,
  };
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shiki-statistics-test-');
    store = StatisticsStore('${directory.path}/listening_statistics.sqlite');
  });
  tearDown(() async {
    final prefix =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}shiki-statistics-test-';
    if (!directory.absolute.path.startsWith(prefix)) {
      throw StateError('Unexpected test directory');
    }
    await directory.delete(recursive: true);
  });

  test(
    'persists totals, periods and distinct artists across reopening',
    () async {
      await store.write([
        record('a', '2026-10-01', 45000, plays: 1),
        record('b', '2026-10-09', 90000, plays: 1, trackId: 2),
      ]);
      final reopened = StatisticsStore(store.path);
      final all = await reopened.summary();
      expect(all['listening_ms'], 135000);
      expect(all['tracks'], 2);
      expect(all['artists'], 2);
      expect(all['plays'], 2);
      expect((all['top_tracks'] as List).first['name'], 'Track 2');
      expect((all['top_tracks'] as List).first['key'], 'track:2');
      expect((all['top_artists'] as List).first['key'], 'artist:7');
      expect((all['top_artists'] as List).first['ms'], 135000);
      final period = await reopened.summary(
        from: '2026-10-08',
        to: '2026-10-09',
      );
      expect(period['listening_ms'], 90000);
      expect(period['tracks'], 1);
      expect(period['first_day'], '2026-10-01');
    },
  );

  test(
    'export and repeated import merge absolute counters without duplicates',
    () async {
      await store.write([record('a', '2026-10-09', 45000, plays: 1)]);
      final file = File('${directory.path}/backup.json');
      await file.writeAsBytes(await store.exportData());
      final other = StatisticsStore('${directory.path}/other.sqlite');
      await other.write([record('b', '2026-10-09', 12000, trackId: 2)]);
      await other.importFile(file.path);
      await other.importFile(file.path);
      expect((await other.summary())['listening_ms'], 57000);
      await store.write([record('a', '2026-10-09', 60000, plays: 1)]);
      await file.writeAsBytes(await store.exportData());
      await other.importFile(file.path);
      expect((await other.summary())['listening_ms'], 72000);
      expect((await other.summary())['plays'], 1);
      // An older snapshot cannot roll back a counter.
      await other.write([record('a', '2026-10-09', 1000)]);
      expect((await other.summary())['listening_ms'], 72000);
    },
  );

  test('malformed import cannot partially alter existing history', () async {
    await store.write([record('a', '2026-10-09', 45000, plays: 1)]);
    final file = File('${directory.path}/bad.json');
    await file.writeAsString(
      jsonEncode({
        'format': 'shiki-listening-statistics',
        'version': 1,
        'rows': [
          record('b', '2026-10-09', 60000),
          {...record('c', '2026-10-09', 1000), 'listening_ms': -1},
        ],
      }),
    );
    await expectLater(
      store.importFile(file.path),
      throwsA(isA<FormatException>()),
    );
    expect((await store.summary())['listening_ms'], 45000);
  });

  test('cache cleanup preserves the entire statistics database', () async {
    await store.write([record('a', '2026-10-09', 45000)]);
    await clearDisposableArtwork(
      directory,
      protectedTrackIds: {},
      protectedArtistIds: {},
    );
    expect(File(store.path).existsSync(), isTrue);
    expect((await store.summary())['listening_ms'], 45000);
  });

  test('ranking by plays and by time can produce different leaders', () async {
    await store.write([
      record('a', '2026-10-09', 200000, plays: 1),
      record('b', '2026-10-09', 30000, plays: 1, trackId: 2),
      record('c', '2026-10-09', 30000, plays: 1, trackId: 2),
    ]);
    expect(
      ((await store.summary())['top_tracks'] as List).first['name'],
      'Track 1',
    );
    expect(
      ((await store.summary(byPlays: true))['top_tracks'] as List)
          .first['name'],
      'Track 2',
    );
  });
}
