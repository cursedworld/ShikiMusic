import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'statistics_store.dart';

String statisticsDay(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

String _sessionId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

int _trackDurationMilliseconds(Object? value) {
  final seconds = num.tryParse('$value');
  if (seconds == null || !seconds.isFinite || seconds <= 0) return 0;
  return (seconds.clamp(0, 31536000) * 1000).round();
}

class StatisticsRank {
  const StatisticsRank(
    this.name,
    this.detail,
    this.milliseconds,
    this.plays, {
    this.key = '',
  });
  final String key;
  final String name;
  final String detail;
  final int milliseconds;
  final int plays;
}

class StatisticsDayTotal {
  const StatisticsDayTotal(this.day, this.milliseconds);
  final String day;
  final int milliseconds;
}

class StatisticsSummary {
  StatisticsSummary.fromMap(Map<String, Object?> data)
    : listeningMs = data['listening_ms'] as int,
      appMs = data['app_ms'] as int,
      plays = data['plays'] as int,
      tracks = data['tracks'] as int,
      artists = data['artists'] as int,
      firstDay = data['first_day'] as String?,
      days = (data['days'] as List)
          .map(
            (dynamic row) =>
                StatisticsDayTotal(row['day'] as String, row['ms'] as int),
          )
          .toList(),
      topTracks = _ranks(data['top_tracks']),
      topArtists = _ranks(data['top_artists']);

  final int listeningMs, appMs, plays, tracks, artists;
  final String? firstDay;
  final List<StatisticsDayTotal> days;
  final List<StatisticsRank> topTracks, topArtists;

  static List<StatisticsRank> _ranks(Object? rows) => (rows as List)
      .map(
        (dynamic row) => StatisticsRank(
          row['name'] as String,
          row['detail'] as String? ?? '',
          row['ms'] as int,
          row['plays'] as int,
          key: row['key'] as String? ?? '',
        ),
      )
      .toList();
}

class _Counter {
  _Counter(this.id, this.day, this.trackKey, this.title, this.artists);
  final String id, day, trackKey, title;
  final List<Map<String, String>> artists;
  int listeningMs = 0, appMs = 0, plays = 0, revision = 0, updatedAt = 0;
  String get key => '$id/$day';
  Map<String, Object?> toMap() => {
    'id': id,
    'day': day,
    'track_key': trackKey,
    'title': title,
    'artists': artists,
    'listening_ms': listeningMs,
    'app_ms': appMs,
    'plays': plays,
    'updated_at': updatedAt,
  };
}

class _ListeningSession {
  _ListeningSession(Map track, this.durationMs)
    : id = _sessionId(),
      trackKey = (track['source_id']?.toString().trim().isNotEmpty ?? false)
          ? 'source:${track['source_id']}'
          : 'track:${track['id']}',
      title = track['title']?.toString() ?? '',
      artists = _credits(track);

  final String id, trackKey, title;
  final List<Map<String, String>> artists;
  final Map<String, _Counter> days = {};
  int durationMs, listenedMs = 0;
  bool counted = false;

  static List<Map<String, String>> _credits(Map track) {
    final candidates = track['artists'] is List
        ? track['artists'] as List
        : const [];
    final album = track['album'];
    final fallback = album is Map ? album['artist'] : null;
    final result = <String, Map<String, String>>{};
    for (final artist in [
      ...candidates,
      if (candidates.isEmpty && fallback is Map) fallback,
    ]) {
      if (artist is! Map) continue;
      final name = artist['name']?.toString().trim() ?? '';
      if (name.isEmpty) continue;
      final key = artist['id'] != null
          ? 'artist:${artist['id']}'
          : 'name:${name.toLowerCase()}';
      result[key] = {'key': key, 'name': name};
    }
    return result.values.toList(growable: false);
  }

  _Counter counter(String day) =>
      days.putIfAbsent(day, () => _Counter(id, day, trackKey, title, artists));
}

class _SummarySnapshot {
  _SummarySnapshot(this.data, this.from, this.to, this.byPlays, this.counters)
    : included = {
        for (final entry in counters.entries) entry.key: entry.value.toMap(),
      };

  final Map<String, Object?> data;
  final String? from, to;
  final bool byPlays;
  final Map<String, _Counter> counters;
  final Map<String, Map<String, Object?>> included;

  StatisticsSummary current({bool? sortByPlays}) {
    final tracks = {
      for (final row in (data['top_tracks'] as List).cast<Map>())
        row['key'] as String: Map<String, Object?>.from(row),
    };
    final artists = {
      for (final row in (data['top_artists'] as List).cast<Map>())
        row['key'] as String: Map<String, Object?>.from(row),
    };
    final days = {
      for (final row in (data['days'] as List).cast<Map>())
        row['day'] as String: row['ms'] as int,
    };
    var listening = data['listening_ms'] as int;
    var app = data['app_ms'] as int;
    var plays = data['plays'] as int;
    var firstDay = data['first_day'] as String?;
    for (final entry in counters.entries) {
      final counter = entry.value;
      if (firstDay == null || counter.day.compareTo(firstDay) < 0) {
        firstDay = counter.day;
      }
      if ((from != null && counter.day.compareTo(from!) < 0) ||
          (to != null && counter.day.compareTo(to!) > 0)) {
        continue;
      }
      final base = included[entry.key];
      final ms = max(
        0,
        counter.listeningMs - (base?['listening_ms'] as int? ?? 0),
      );
      final count = max(0, counter.plays - (base?['plays'] as int? ?? 0));
      listening += ms;
      app += max(0, counter.appMs - (base?['app_ms'] as int? ?? 0));
      plays += count;
      if (ms > 0) {
        days.update(counter.day, (value) => value + ms, ifAbsent: () => ms);
      }
      if (counter.trackKey.isEmpty || (ms == 0 && count == 0)) continue;
      final track = tracks.putIfAbsent(
        counter.trackKey,
        () => {
          'key': counter.trackKey,
          'name': counter.title,
          'detail': counter.artists.map((artist) => artist['name']).join(', '),
          'ms': 0,
          'plays': 0,
        },
      );
      track['ms'] = (track['ms'] as int) + ms;
      track['plays'] = (track['plays'] as int) + count;
      for (final credit in counter.artists) {
        final artist = artists.putIfAbsent(
          credit['key']!,
          () => {
            'key': credit['key'],
            'name': credit['name'],
            'ms': 0,
            'plays': 0,
          },
        );
        artist['ms'] = (artist['ms'] as int) + ms;
        artist['plays'] = (artist['plays'] as int) + count;
      }
    }
    List<Map<String, Object?>> ranked(Map<String, Map<String, Object?>> rows) {
      final result = rows.values
          .where((row) => (row['ms'] as int) > 0)
          .toList();
      result.sort((a, b) {
        for (final key
            in (sortByPlays ?? byPlays) ? ['plays', 'ms'] : ['ms', 'plays']) {
          final comparison = (b[key] as int).compareTo(a[key] as int);
          if (comparison != 0) return comparison;
        }
        return (a['name'] as String).compareTo(b['name'] as String);
      });
      return result.take(100).toList(growable: false);
    }

    final dates = days.keys.toList()..sort();
    return StatisticsSummary.fromMap({
      'listening_ms': listening,
      'app_ms': app,
      'plays': plays,
      'tracks': tracks.values.where((row) => (row['ms'] as int) > 0).length,
      'artists': artists.values.where((row) => (row['ms'] as int) > 0).length,
      'first_day': firstDay,
      'days': [
        for (final day in dates) {'day': day, 'ms': days[day]},
      ],
      'top_tracks': ranked(tracks),
      'top_artists': ranked(artists),
    });
  }
}

/// Playback events update only two small counters. SQLite work runs off the UI
/// isolate, in batches; no additional timer or per-position disk writes.
class ListeningStatistics {
  ListeningStatistics(
    this.store, {
    DateTime Function()? wallClock,
    int Function()? monotonicMilliseconds,
    bool foreground = true,
  }) : _wallClock = wallClock ?? DateTime.now,
       _monotonic = monotonicMilliseconds,
       _foreground = foreground {
    _watch.start();
    _lastAppSample = _elapsed;
    _lastFlush = _elapsed;
  }

  final StatisticsStore store;
  final DateTime Function() _wallClock;
  final int Function()? _monotonic;
  final Stopwatch _watch = Stopwatch();
  final String _appSession = _sessionId();
  final Map<String, _Counter> _appDays = {}, _dirty = {};
  _ListeningSession? _session;
  bool _foreground, _playing = false, _seeking = false, _closed = false;
  int _lastAppSample = 0, _lastFlush = 0;
  int? _lastPosition, _lastPositionTime;
  Future<void> _writeTail = Future<void>.value();
  _SummarySnapshot? _snapshot;
  Map<String, _Counter>? _readingCounters;
  Future<StatisticsSummary>? _pendingSummary;
  (String?, String?, bool)? _pendingSummaryQuery;
  int _summaryGeneration = 0;
  int get _elapsed => _monotonic?.call() ?? _watch.elapsedMilliseconds;

  void beginTrack(Map track, {Duration? duration}) {
    if (_closed || track['id'] == null) return;
    endTrack();
    _session = _ListeningSession(
      track,
      duration?.inMilliseconds ?? _trackDurationMilliseconds(track['duration']),
    );
    _seeking = false;
    _resetPosition();
  }

  void endTrack() {
    _session = null;
    _resetPosition();
    if (!_closed && _dirty.isNotEmpty) _saveInBackground();
  }

  void setDuration(Duration duration) {
    if (duration > Duration.zero) {
      _session?.durationMs = duration.inMilliseconds;
    }
  }

  void setPlaying(bool playing) {
    if (_closed || playing == _playing) return;
    _playing = playing;
    _resetPosition();
    if (!playing) _saveInBackground();
  }

  void setSeeking(bool seeking) {
    _seeking = seeking;
    _resetPosition();
  }

  void _resetPosition() {
    _lastPosition = null;
    _lastPositionTime = null;
  }

  void position(Duration position) {
    if (_closed) return;
    final now = _elapsed;
    final previousPosition = _lastPosition;
    final previousTime = _lastPositionTime;
    _lastPosition = position.inMilliseconds;
    _lastPositionTime = now;
    final session = _session;
    if (!_playing ||
        _seeking ||
        session == null ||
        previousPosition == null ||
        previousTime == null) {
      return;
    }
    final delta = position.inMilliseconds - previousPosition;
    final elapsed = now - previousTime;
    // Backwards jumps and forwards jumps larger than elapsed time are seeks.
    // Stationary positions (buffering, paused device) earn no listening time.
    if (delta <= 0 || elapsed <= 0 || delta > elapsed + 1500) return;
    final credited = min(delta, elapsed + 250);
    final wall = _wallClock();
    _splitDays(credited, wall, (day, amount) {
      final counter = session.counter(day)..listeningMs += amount;
      _mark(counter, wall);
    });
    session.listenedMs += credited;
    final threshold = session.durationMs > 0
        ? min(30000, max(1, session.durationMs ~/ 2))
        : 30000;
    if (!session.counted && session.listenedMs >= threshold) {
      session.counted = true;
      final counter = session.counter(statisticsDay(wall))..plays = 1;
      _mark(counter, wall);
    }
    _maybeSave();
  }

  void setForeground(bool foreground) {
    if (_closed) return;
    _accountApp();
    _foreground = foreground;
    if (!foreground) _saveInBackground();
  }

  void tick() {
    if (_closed) return;
    _accountApp();
    _maybeSave();
  }

  void _accountApp() {
    final now = _elapsed;
    final delta = (now - _lastAppSample).clamp(0, 5000);
    _lastAppSample = now;
    if (!_foreground || delta == 0 || _closed) return;
    final wall = _wallClock();
    _splitDays(delta, wall, (day, amount) {
      final counter = _appDays.putIfAbsent(
        day,
        () => _Counter(_appSession, day, '', '', const []),
      )..appMs += amount;
      _mark(counter, wall);
    });
  }

  void _splitDays(
    int milliseconds,
    DateTime end,
    void Function(String, int) add,
  ) {
    end = end.toLocal();
    var start = end.subtract(Duration(milliseconds: milliseconds));
    while (start.isBefore(end)) {
      final midnight = DateTime(start.year, start.month, start.day + 1);
      final until = midnight.isBefore(end) ? midnight : end;
      add(statisticsDay(start), until.difference(start).inMilliseconds);
      start = until;
    }
  }

  void _mark(_Counter counter, DateTime wall) {
    counter.revision++;
    counter.updatedAt = wall.millisecondsSinceEpoch;
    _dirty[counter.key] = counter;
    final snapshot = _snapshot;
    snapshot?.counters[counter.key] = counter;
    if (snapshot != null && snapshot.counters.length > 512) _snapshot = null;
    _readingCounters?[counter.key] = counter;
  }

  void _maybeSave() {
    if (_elapsed - _lastFlush >= 30000) _saveInBackground();
  }

  void _saveInBackground() {
    _lastFlush = _elapsed;
    unawaited(
      flush().catchError((Object error) {
        debugPrint('Listening statistics save failed: $error');
      }),
    );
  }

  Future<void> flush() {
    _lastFlush = _elapsed;
    _accountApp();
    final result = _writeTail.then((_) async {
      if (_dirty.isEmpty) return;
      final revisions = {
        for (final entry in _dirty.entries) entry.key: entry.value.revision,
      };
      final rows = _dirty.values.map((counter) => counter.toMap()).toList();
      await store.write(rows);
      for (final entry in revisions.entries) {
        if (_dirty[entry.key]?.revision == entry.value) {
          _dirty.remove(entry.key);
        }
      }
    });
    _writeTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  StatisticsSummary? cachedSummary({
    String? from,
    String? to,
    bool byPlays = false,
  }) {
    _accountApp();
    final snapshot = _snapshot;
    if (snapshot == null || snapshot.from != from || snapshot.to != to) {
      return null;
    }
    return snapshot.current(sortByPlays: byPlays);
  }

  Future<void> prepareSummary() async {
    final now = _wallClock();
    await summary(
      from: statisticsDay(DateTime(now.year, now.month, now.day - 29)),
      to: statisticsDay(now),
    );
  }

  Future<StatisticsSummary> summary({
    String? from,
    String? to,
    bool byPlays = false,
  }) {
    final query = (from, to, byPlays);
    if (_pendingSummaryQuery == query && _pendingSummary != null) {
      return _pendingSummary!;
    }
    final generation = _summaryGeneration;
    final result = _writeTail.then((_) async {
      _accountApp();
      final counters = <String, _Counter>{
        for (final counter in [
          ..._appDays.values,
          ...?_session?.days.values,
          ..._dirty.values,
        ])
          counter.key: counter,
      };
      final snapshot = _SummarySnapshot({}, from, to, byPlays, counters);
      _readingCounters = counters;
      try {
        final data = await store.liveSummary(
          counters: snapshot.included.values.toList(growable: false),
          from: from,
          to: to,
          byPlays: byPlays,
        );
        final included = data.remove('included_counters');
        if (included is List) {
          snapshot.included
            ..clear()
            ..addEntries(
              included.cast<Map>().map(
                (row) => MapEntry(
                  '${row['id']}/${row['day']}',
                  Map<String, Object?>.from(row),
                ),
              ),
            );
        }
        snapshot.data.addAll(data);
        if (!_closed &&
            generation == _summaryGeneration &&
            counters.length <= 512 &&
            (data['top_tracks'] as List).length <= 10000) {
          _snapshot = snapshot;
        }
        return snapshot.current();
      } finally {
        _readingCounters = null;
      }
    });
    // Reads and existing writes share a queue. New listening remains in memory;
    // neither the settings route nor the statistics route waits for a save.
    _writeTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _pendingSummaryQuery = query;
    _pendingSummary = result;
    result.then<void>(
      (_) {
        if (identical(_pendingSummary, result)) _pendingSummary = null;
      },
      onError: (Object _, StackTrace _) {
        if (identical(_pendingSummary, result)) _pendingSummary = null;
      },
    );
    return result;
  }

  Future<Uint8List> exportData() async {
    await flush();
    return store.exportData();
  }

  Future<int> importFile(String path) async {
    _summaryGeneration++;
    _snapshot = null;
    _pendingSummary = null;
    await flush();
    try {
      final result = _writeTail.then((_) => store.importFile(path));
      _writeTail = result.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      return await result;
    } finally {
      _summaryGeneration++;
      _snapshot = null;
      _pendingSummary = null;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _accountApp();
    _foreground = false;
    _session = null;
    _closed = true;
    _snapshot = null;
    await flush();
    _watch.stop();
  }
}
