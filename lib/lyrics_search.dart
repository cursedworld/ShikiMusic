import 'dart:io';

import 'package:flutter/foundation.dart';

final _lyricsTags = RegExp(r'\[[^\]\r\n]*\]|<\d+:\d{2}(?:[.:]\d{1,3})?>');
// Explicit separator ranges avoid costly Unicode property-class scans over lyrics.
final _nonLyricsWord = RegExp(
  r'''[\s!"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~\u00ab\u00ad\u00bb\u2000-\u206f\u2e00-\u2e7f\u3000-\u303f\ufe00-\ufe0f\ufeff\uff01-\uff0f\uff1a-\uff20\uff3b-\uff40\uff5b-\uff65\u2600-\u27bf\u{1f000}-\u{1faff}]+''',
  unicode: true,
);
final _unspacedScripts = RegExp(r'[\u3040-\u30ff\u3400-\u9fff]');

String normalizeLyricsSearch(String value) => value
    .toLowerCase()
    .replaceAll('ё', 'е')
    .replaceAll(_nonLyricsWord, ' ')
    .trim();

/// A literal phrase, not a regular expression or an unordered word search.
class LyricsSearchQuery {
  LyricsSearchQuery(String query) : text = normalizeLyricsSearch(query);

  final String text;
  late final String _needle = _unspacedScripts.hasMatch(text)
      ? text
      : ' $text ';

  bool matches(String document) {
    if (text.isEmpty) return false;
    // Japanese and Chinese lyrics need substring matching without word spaces.
    return document.contains(_needle);
  }
}

typedef LyricsSearchBuilder =
    Future<Map<int, String>> Function(List<Map<String, Object?>> jobs);

class _LyricsSearchSource {
  const _LyricsSearchSource(this.text, this.path);
  final String text;
  final String? path;
}

/// Runs only on demand. No network, watcher, periodic work, or persistent files.
class LyricsSearchIndex {
  LyricsSearchIndex({LyricsSearchBuilder? builder})
    : _builder = builder ?? _buildInBackground;

  final LyricsSearchBuilder _builder;
  final _sources = <int, _LyricsSearchSource>{};
  final _documents = <int, String>{};
  Future<void> _tail = Future<void>.value();
  Future<bool>? _pending;
  int _epoch = 0;
  bool _closed = false;
  bool _ready = false;

  bool get isReady => _ready && _pending == null;

  bool matches(int id, LyricsSearchQuery query) =>
      query.matches(_documents[id] ?? '');

  Future<bool> prepare(
    Iterable<dynamic> tracks, {
    required File Function(int id) lyricsFile,
  }) {
    if (_closed) return Future.value(false);
    final jobs = <Map<String, Object?>>[];
    final captured = <int, _LyricsSearchSource>{};
    final ids = <int>{};
    for (final track in tracks) {
      if (track is! Map || track['id'] is! int) continue;
      final id = track['id'] as int;
      if (id <= 0 || !ids.add(id)) continue;
      final text = track['lyrics'] is String ? track['lyrics'] as String : '';
      final path = text.trim().isEmpty ? lyricsFile(id).path : null;
      final previous = _sources[id];
      if (previous != null && previous.text == text && previous.path == path) {
        continue;
      }
      final source = _LyricsSearchSource(text, path);
      _sources[id] = source;
      // Never show stale lyrics while a changed document is being rebuilt.
      _documents.remove(id);
      captured[id] = source;
      jobs.add({'id': id, 'text': text, 'path': source.path});
    }
    _sources.removeWhere((id, _) => !ids.contains(id));
    _documents.removeWhere((id, _) => !ids.contains(id));
    if (jobs.isEmpty) {
      _ready = true;
      return _pending ?? Future.value(false);
    }
    _ready = false;
    final epoch = _epoch;
    final work = _tail.then((_) async {
      if (_closed || epoch != _epoch) return false;
      try {
        final result = await _builder(jobs);
        if (_closed || epoch != _epoch) return false;
        var changed = false;
        for (final entry in captured.entries) {
          if (_sources[entry.key] != entry.value) continue;
          _documents[entry.key] = result[entry.key] ?? '';
          changed = true;
        }
        return changed;
      } catch (_) {
        for (final entry in captured.entries) {
          if (epoch == _epoch && _sources[entry.key] == entry.value) {
            _sources.remove(entry.key);
          }
        }
        rethrow;
      }
    });
    _tail = work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _pending = work;
    void finished(bool succeeded) {
      if (identical(_pending, work)) {
        _pending = null;
        _ready =
            succeeded &&
            !_closed &&
            epoch == _epoch &&
            _sources.length == _documents.length;
      }
    }

    // Both branches consume this bookkeeping future's errors.
    work.then<void>(
      (_) => finished(true),
      onError: (Object _, StackTrace _) => finished(false),
    );
    return work;
  }

  void invalidate(int id) {
    if (_closed) return;
    _sources.remove(id);
    _documents.remove(id);
    _ready = false;
  }

  void clear() {
    _epoch++;
    _sources.clear();
    _documents.clear();
    _pending = null;
    _ready = false;
  }

  void dispose() {
    _closed = true;
    clear();
  }
}

Future<Map<int, String>> _buildInBackground(List<Map<String, Object?>> jobs) =>
    compute(buildLyricsSearchDocuments, jobs);

/// All file reads and normalization happen in the worker, never during build.
Map<int, String> buildLyricsSearchDocuments(List<Map<String, Object?>> jobs) {
  const maxLyricsBytes = 1024 * 1024;
  final documents = <int, String>{};
  for (final job in jobs) {
    final id = job['id'] as int;
    var text = job['text'] as String;
    if (text.trim().isEmpty && job['path'] is String) {
      try {
        final file = File(job['path'] as String);
        if (file.existsSync() && file.lengthSync() <= maxLyricsBytes) {
          text = file.readAsStringSync();
        }
      } on FileSystemException {
        // A missing/unreadable cache must not break title/artist search.
      } on FormatException {
        // Ignore malformed UTF-8, keeping the rest of the library searchable.
      }
    }
    final normalized = normalizeLyricsSearch(text.replaceAll(_lyricsTags, ' '));
    documents[id] = normalized.isEmpty ? '' : ' $normalized ';
  }
  return documents;
}
