import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;

import 'atomic_file_store.dart';
import 'globals.dart' show LyricLine;
import 'lrc_parser.dart';
import 'lyric_text_edits.dart';

const lyricTimingStep = 100;
const lyricTimingLimit = 10000;

typedef _AudioStamp = ({int size, DateTime modified, DateTime changed});
typedef _TimingVersion = ({String audio, String text});
typedef _Offsets = Map<int, Map<_TimingVersion, int>>;
typedef LyricTimingCorrection = ({
  int trackId,
  String audioSha256,
  String lrcSha256,
  int advanceMilliseconds,
});

/// Captures the file that was opened, not a newer download from the catalog.
/// The contents are read only when saving or restoring a matching correction.
class LyricAudioFile {
  const LyricAudioFile._(this.path, this._stamp);

  final String path;
  final _AudioStamp _stamp;

  static Future<LyricAudioFile?> inspect(File file) async {
    final stamp = await _audioStamp(file);
    return stamp == null ? null : LyricAudioFile._(file.path, stamp);
  }

  Future<String> fingerprint() =>
      compute(_fingerprintAudio, (path: path, stamp: _stamp));
}

Future<_AudioStamp?> _audioStamp(File file) async {
  try {
    final stat = await file.stat();
    if (stat.type == FileSystemEntityType.file && stat.size > 0) {
      return (size: stat.size, modified: stat.modified, changed: stat.changed);
    }
  } on FileSystemException {
    // Keep the existing fallback to a remote source if local audio is missing.
  }
  return null;
}

Future<String> _fingerprintAudio(
  ({String path, _AudioStamp stamp}) source,
) async {
  final file = File(source.path);
  if (await _audioStamp(file) != source.stamp) {
    throw StateError('The opened audio file changed');
  }
  final digest = await sha256.bind(file.openRead()).first;
  if (await _audioStamp(file) != source.stamp) {
    throw StateError('The opened audio file changed');
  }
  return digest.toString();
}

/// Durable, per-version corrections. A failed write leaves the old value live.
class LyricTimingStore {
  LyricTimingStore(Directory directory)
    : _file = File('${directory.path}/lyric_offsets.json');

  final File _file;
  static final _digest = RegExp(r'^[a-f0-9]{64}$');
  Future<_Offsets>? _loaded;
  Future<void> _tail = Future<void>.value();

  Future<_Offsets> _offsets() => _loaded ??= _read();

  Future<_Offsets> _read() async {
    if (!await _file.exists()) return {};
    final data = jsonDecode(await _file.readAsString());
    if (data is! Map || data['version'] != 1 || data['offsets'] is! List) {
      throw const FormatException('Invalid lyric offsets');
    }
    final result = <int, Map<_TimingVersion, int>>{};
    for (final row in data['offsets'] as List) {
      if (row is! Map) continue;
      final id = row['track_id'];
      final audio = row['audio_sha256'];
      final text = row['lrc_sha256'];
      final advance = row['advance_ms'];
      if (id is int &&
          audio is String &&
          _digest.hasMatch(audio) &&
          text is String &&
          _digest.hasMatch(text) &&
          advance is int &&
          advance != 0 &&
          advance.abs() <= lyricTimingLimit) {
        (result[id] ??= {})[(audio: audio, text: text)] = advance;
      }
    }
    return result;
  }

  Future<int> lookup(
    int trackId, {
    required String Function() lyricsFingerprint,
    required Future<String> Function() audioFingerprint,
  }) async {
    await _tail;
    final versions = (await _offsets())[trackId];
    if (versions == null || versions.isEmpty) return 0;
    final text = lyricsFingerprint();
    if (!versions.keys.any((version) => version.text == text)) return 0;
    final audio = await audioFingerprint();
    return versions[(audio: audio, text: text)] ?? 0;
  }

  Future<void> save(
    int trackId, {
    required String audio,
    required String text,
    required int advanceMilliseconds,
  }) {
    final result = _tail.then((_) async {
      final offsets = await _offsets();
      final key = (audio: audio, text: text);
      final versions = {...?offsets[trackId]};
      if ((versions[key] ?? 0) == advanceMilliseconds) return;
      if (advanceMilliseconds == 0) {
        versions.remove(key);
      } else {
        versions[key] = advanceMilliseconds;
      }
      final next = {...offsets, trackId: versions};
      await atomicFileStore.writeString(
        _file,
        jsonEncode({
          'version': 1,
          'offsets': [
            for (final track in next.entries)
              for (final version in track.value.entries)
                {
                  'track_id': track.key,
                  'audio_sha256': version.key.audio,
                  'lrc_sha256': version.key.text,
                  'advance_ms': version.value,
                },
          ],
        }),
      );
      if (versions.isEmpty) {
        offsets.remove(trackId);
      } else {
        offsets[trackId] = versions;
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

/// A single loaded pair of audio and timed lyrics. The owner invalidates it
/// when either changes, including while a fingerprint or write is pending.
class LyricTimingSession {
  LyricTimingSession({
    required LyricTimingStore store,
    LyricTextEditStore? textStore,
    required int trackId,
    required String contents,
    required Future<String> Function() fingerprintAudio,
    required bool Function() isCurrent,
    required void Function(List<LyricLine>) onTimeline,
  }) : _store = store,
       _textStore = textStore,
       _trackId = trackId,
       _contents = contents,
       _fingerprintAudio = fingerprintAudio,
       _isCurrent = isCurrent,
       _onTimeline = onTimeline;

  final LyricTimingStore _store;
  final LyricTextEditStore? _textStore;
  final int _trackId;
  final String _contents;
  final Future<String> Function() _fingerprintAudio;
  final bool Function() _isCurrent;
  final void Function(List<LyricLine>) _onTimeline;
  late final String _lyricsHash = sha256
      .convert(utf8.encode(_contents))
      .toString();
  String? _audioHash;
  int _saved = 0;
  int? _preview;
  late final _originalLines = <int, String>{
    for (final line in parseLrcString(_contents)) ?line.sourceLine: line.txt,
  };
  Map<int, String> _textEdits = const {};

  bool get isCurrent => _isCurrent();
  bool get isServerTrack => _trackId > 0;
  bool get hasPreview => _preview != null;
  int get advanceMilliseconds => _preview ?? _saved;
  bool get canEditText => isCurrent && _textStore != null;
  bool get hasTextEdits => _textEdits.isNotEmpty;

  String? originalLine(int sourceLine) =>
      canEditText ? _originalLines[sourceLine] : null;

  String? lineText(int sourceLine) =>
      canEditText ? _textEdits[sourceLine] ?? _originalLines[sourceLine] : null;

  LyricTextCorrection? get savedTextCorrection {
    final audio = _audioHash;
    if (!canEditText || !isServerTrack || !hasTextEdits || audio == null) {
      return null;
    }
    return (
      trackId: _trackId,
      audioSha256: audio,
      lrcSha256: _lyricsHash,
      edits: _textEdits,
    );
  }

  LyricTimingCorrection? get savedCorrection {
    final audio = _audioHash;
    if (!isCurrent ||
        !isServerTrack ||
        hasPreview ||
        _saved == 0 ||
        audio == null) {
      return null;
    }
    return (
      trackId: _trackId,
      audioSha256: audio,
      lrcSha256: _lyricsHash,
      advanceMilliseconds: _saved,
    );
  }

  Future<String> _audioFingerprint() async =>
      _audioHash ??= await _fingerprintAudio();

  Future<void> restore() async {
    final value = await _store.lookup(
      _trackId,
      lyricsFingerprint: () => _lyricsHash,
      audioFingerprint: () =>
          isCurrent ? _audioFingerprint() : Future.value(''),
    );
    if (!isCurrent || value == _saved) return;
    _saved = value;
    _publish();
  }

  Future<void> restoreTextEdits() async {
    final store = _textStore;
    if (store == null || !isCurrent) return;
    final edits = await store.lookup(
      _trackId,
      lyricsFingerprint: () => _lyricsHash,
      audioFingerprint: () =>
          isCurrent ? _audioFingerprint() : Future.value(''),
    );
    if (isCurrent && edits.isNotEmpty) {
      _readTextEdits(edits);
      _publish();
    }
  }

  Future<bool> saveLineText(int sourceLine, String text) async {
    final store = _textStore;
    if (store == null || !isCurrent) return false;
    final original = _originalLines[sourceLine];
    final replacement = text.trim();
    if (original == null || !validLyricLineText(replacement)) {
      throw const FormatException('Invalid lyric line edit');
    }
    if (replacement == lineText(sourceLine)) return true;
    final audio = await _audioFingerprint();
    if (!isCurrent) return false;
    final saved = await store.saveLine(
      _trackId,
      audio: audio,
      lrc: _lyricsHash,
      index: sourceLine,
      replacement: replacement == original ? null : replacement,
    );
    if (!isCurrent) return false;
    _readTextEdits(saved);
    _publish();
    return true;
  }

  void _readTextEdits(Map<int, String> edits) {
    _textEdits = Map.unmodifiable({
      for (final edit in edits.entries)
        if (_originalLines.containsKey(edit.key) &&
            _originalLines[edit.key] != edit.value)
          edit.key: edit.value,
    });
  }

  void preview(int advance) {
    if (!isCurrent) return;
    final value = advance.clamp(-lyricTimingLimit, lyricTimingLimit);
    if (value == advanceMilliseconds) return;
    _preview = value;
    _publish();
  }

  void cancelPreview() {
    final before = advanceMilliseconds;
    _preview = null;
    if (isCurrent && before != _saved) _publish();
  }

  Future<void> savePreview() async {
    final value = _preview;
    if (!isCurrent || value == null) return;
    if (value == _saved) {
      _preview = null;
      return;
    }
    final audio = await _audioFingerprint();
    if (!isCurrent || value != _preview) return;
    await _store.save(
      _trackId,
      audio: audio,
      text: _lyricsHash,
      advanceMilliseconds: value,
    );
    final before = advanceMilliseconds;
    _saved = value;
    if (_preview == value) _preview = null;
    if (isCurrent && before != advanceMilliseconds) _publish();
  }

  void _publish() => _onTimeline(
    parseLrcString(
      _contents,
      advanceMilliseconds: advanceMilliseconds,
      lineEdits: _textEdits,
    ),
  );
}
