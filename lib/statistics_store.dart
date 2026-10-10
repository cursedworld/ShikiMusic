import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';

/// All native database calls and backup parsing run in a short-lived isolate.
/// No database connection or worker isolate stays open while the store is idle.
class StatisticsStore {
  const StatisticsStore(this.path);
  final String path;

  Future<Object?> _job(
    String action, [
    Map<String, Object?> arguments = const {},
  ]) => compute(_statisticsJob, {'path': path, 'action': action, ...arguments});

  Future<void> write(List<Map<String, Object?>> rows) async {
    await _job('write', {'rows': rows});
  }

  Future<Map<String, Object?>> summary({
    String? from,
    String? to,
    bool byPlays = false,
  }) async =>
      (await _job('summary', {'from': from, 'to': to, 'by_plays': byPlays}))
          as Map<String, Object?>;

  Future<Uint8List> exportData() async => (await _job('export')) as Uint8List;
  Future<int> importFile(String source) async =>
      (await _job('import', {'source': source})) as int;
}

const _columns =
    'id, day, track_key, title, artists, listening_ms, app_ms, plays, updated_at';
const _maxBackupBytes = 64 * 1024 * 1024;

Object? _statisticsJob(Map<String, Object?> job) {
  // Validate the whole backup before opening a write transaction.
  final imported = job['action'] == 'import'
      ? _readBackup(job['source'] as String)
      : null;
  final path = job['path'] as String;
  Directory(File(path).parent.path).createSync(recursive: true);
  final db = sqlite3.open(path);
  try {
    db.execute('PRAGMA busy_timeout = 5000');
    db.execute('PRAGMA cache_size = -1024');
    final version = db.select('PRAGMA user_version').first.values.first as int;
    if (version > 1) {
      throw const FormatException('Statistics database is from a newer app');
    }
    if (version == 0) {
      db.execute('PRAGMA journal_mode = WAL');
      db.execute('''CREATE TABLE IF NOT EXISTS counters (
        id TEXT NOT NULL, day TEXT NOT NULL, track_key TEXT NOT NULL,
        title TEXT NOT NULL, artists TEXT NOT NULL,
        listening_ms INTEGER NOT NULL, app_ms INTEGER NOT NULL,
        plays INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        PRIMARY KEY (id, day)
      )''');
      db.execute('CREATE INDEX IF NOT EXISTS counters_day ON counters(day)');
      db.execute('PRAGMA user_version = 1');
    }
    switch (job['action']) {
      case 'write':
        _merge(db, (job['rows'] as List).cast<Map<String, Object?>>());
        return null;
      case 'summary':
        db.execute('BEGIN');
        final summary = _summary(
          db,
          job['from'] as String?,
          job['to'] as String?,
          job['by_plays'] == true,
        );
        db.execute('COMMIT');
        return summary;
      case 'export':
        final rows = db
            .select('SELECT $_columns FROM counters ORDER BY day, id')
            .map(
              (row) => {
                ...row,
                'artists': jsonDecode(row['artists'] as String),
              },
            )
            .toList();
        final bytes = utf8.encode(
          jsonEncode({
            'format': 'shiki-listening-statistics',
            'version': 1,
            'rows': rows,
          }),
        );
        if (bytes.length > _maxBackupBytes || rows.length > 250000) {
          throw const FormatException('Statistics backup is too large');
        }
        return Uint8List.fromList(bytes);
      case 'import':
        _merge(db, imported!);
        return imported.length;
      default:
        throw ArgumentError('Unknown statistics operation');
    }
  } finally {
    db.close();
  }
}

void _merge(Database db, List<Map<String, Object?>> rows) {
  db.execute('BEGIN IMMEDIATE');
  final statement = db.prepare(
    '''INSERT INTO counters ($_columns) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id, day) DO UPDATE SET
      listening_ms = MAX(counters.listening_ms, excluded.listening_ms),
      app_ms = MAX(counters.app_ms, excluded.app_ms),
      plays = MAX(counters.plays, excluded.plays),
      title = CASE WHEN excluded.updated_at >= counters.updated_at THEN excluded.title ELSE counters.title END,
      artists = CASE WHEN excluded.updated_at >= counters.updated_at THEN excluded.artists ELSE counters.artists END,
      updated_at = MAX(counters.updated_at, excluded.updated_at)
    WHERE counters.track_key = excluded.track_key''',
  );
  try {
    for (final row in rows) {
      statement.execute([
        row['id'],
        row['day'],
        row['track_key'],
        row['title'],
        jsonEncode(row['artists']),
        row['listening_ms'],
        row['app_ms'],
        row['plays'],
        row['updated_at'],
      ]);
    }
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    statement.close();
  }
}

Map<String, Object?> _summary(
  Database db,
  String? from,
  String? to,
  bool byPlays,
) {
  final clauses = <String>[];
  final arguments = <Object?>[];
  if (from != null) {
    clauses.add('day >= ?');
    arguments.add(from);
  }
  if (to != null) {
    clauses.add('day <= ?');
    arguments.add(to);
  }
  final where = clauses.isEmpty ? '1' : clauses.join(' AND ');
  final totals = db.select(
    '''SELECT COALESCE(SUM(listening_ms), 0) listening_ms,
    COALESCE(SUM(app_ms), 0) app_ms, COALESCE(SUM(plays), 0) plays,
    COUNT(DISTINCT CASE WHEN listening_ms > 0 THEN track_key END) tracks
    FROM counters WHERE $where''',
    arguments,
  ).first;
  final artistCount = db.select(
    '''SELECT COUNT(DISTINCT json_extract(j.value, '\$.key')) count
    FROM counters, json_each(counters.artists) j WHERE $where AND listening_ms > 0''',
    arguments,
  ).first['count'];
  final order = byPlays
      ? 'plays DESC, ms DESC, name'
      : 'ms DESC, plays DESC, name';
  // SQLite's single MAX aggregate chooses the metadata from the newest row.
  final tracks = db
      .select('''SELECT track_key, title name, artists,
    SUM(listening_ms) ms, SUM(plays) plays, MAX(updated_at) latest
    FROM counters WHERE $where AND track_key != '' GROUP BY track_key
    HAVING ms > 0 ORDER BY $order LIMIT 100''', arguments)
      .map(
        (row) => <String, Object?>{
          'key': row['track_key'],
          'name': row['name'],
          'ms': row['ms'],
          'plays': row['plays'],
          'detail': (jsonDecode(row['artists'] as String) as List)
              .map((dynamic artist) => artist['name'])
              .join(', '),
        },
      )
      .toList();
  final artists = db
      .select(
        '''SELECT json_extract(j.value, '\$.key') artist_key,
    json_extract(j.value, '\$.name') name, SUM(listening_ms) ms, SUM(plays) plays,
    MAX(updated_at) latest FROM counters, json_each(counters.artists) j
    WHERE $where GROUP BY artist_key HAVING ms > 0 ORDER BY $order LIMIT 100''',
        arguments,
      )
      .map(
        (row) => <String, Object?>{
          'key': row['artist_key'],
          'name': row['name'],
          'ms': row['ms'],
          'plays': row['plays'],
        },
      )
      .toList();
  return {
    ...totals,
    'artists': artistCount,
    'first_day': db.select('SELECT MIN(day) day FROM counters').first['day'],
    'top_tracks': tracks,
    'top_artists': artists,
    'days': db
        .select(
          'SELECT day, SUM(listening_ms) ms FROM counters WHERE $where GROUP BY day HAVING ms > 0 ORDER BY day',
          arguments,
        )
        .map((row) => <String, Object?>{'day': row['day'], 'ms': row['ms']})
        .toList(),
  };
}

List<Map<String, Object?>> _readBackup(String path) {
  final file = File(path);
  if (file.lengthSync() > _maxBackupBytes) {
    throw const FormatException('Statistics backup is too large');
  }
  final data = jsonDecode(file.readAsStringSync());
  if (data is! Map ||
      data['format'] != 'shiki-listening-statistics' ||
      data['version'] != 1 ||
      data['rows'] is! List) {
    throw const FormatException('Unsupported statistics backup');
  }
  final rows = data['rows'] as List;
  if (rows.length > 250000) {
    throw const FormatException('Too many statistics records');
  }
  return rows.map(_validateRow).toList();
}

Map<String, Object?> _validateRow(dynamic row) {
  if (row is! Map) throw const FormatException('Invalid statistics record');
  String text(String key, int maxLength) {
    final value = row[key];
    if (value is! String || value.length > maxLength) {
      throw const FormatException('Invalid statistics text');
    }
    return value;
  }

  int number(String key, int maxValue) {
    final value = row[key];
    if (value is! int || value < 0 || value > maxValue) {
      throw const FormatException('Invalid statistics count');
    }
    return value;
  }

  final id = text('id', 32);
  if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
    throw const FormatException('Invalid statistics ID');
  }
  final day = text('day', 10);
  final parsed = DateTime.tryParse(day);
  if (parsed == null ||
      parsed.year < 1970 ||
      parsed.year > 2200 ||
      parsed.toIso8601String().substring(0, 10) != day) {
    throw const FormatException('Invalid statistics date');
  }
  final artists = row['artists'];
  if (artists is! List || artists.length > 100) {
    throw const FormatException('Invalid artist credits');
  }
  final seen = <String>{};
  final credits = <Map<String, String>>[];
  for (final artist in artists) {
    if (artist is! Map ||
        artist['key'] is! String ||
        artist['name'] is! String) {
      throw const FormatException('Invalid artist');
    }
    final key = artist['key'] as String;
    final name = artist['name'] as String;
    if (key.isEmpty ||
        key.length > 1024 ||
        name.isEmpty ||
        name.length > 1024 ||
        !seen.add(key)) {
      throw const FormatException('Invalid artist');
    }
    credits.add({'key': key, 'name': name});
  }
  final trackKey = text('track_key', 1024);
  // Local calendar days can exceed 24 hours around DST / timezone changes.
  final listening = number('listening_ms', 172800000);
  final app = number('app_ms', 172800000);
  final plays = number('plays', 1);
  if ((trackKey.isEmpty &&
          (listening > 0 || plays > 0 || credits.isNotEmpty)) ||
      (trackKey.isNotEmpty && app > 0)) {
    throw const FormatException('Invalid statistics category');
  }
  return {
    'id': id,
    'day': day,
    'track_key': trackKey,
    'title': text('title', 4096),
    'artists': credits,
    'listening_ms': listening,
    'app_ms': app,
    'plays': plays,
    'updated_at': number('updated_at', 7258118400000),
  };
}
