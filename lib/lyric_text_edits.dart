import 'dart:convert';
import 'dart:io';

import 'atomic_file_store.dart';
import 'lrc_parser.dart';

const lyricLineEditLimit = 128;

typedef LyricTextCorrection = ({
  int trackId,
  String audioSha256,
  String lrcSha256,
  Map<int, String> edits,
});
typedef _Version = ({String audio, String lrc});
typedef _Drafts = Map<int, Map<_Version, Map<int, String>>>;

/// Separate from the original LRC and timing offsets, which an update or ZIP
/// import may replace. Drafts only apply to the exact audio and text version.
class LyricTextEditStore {
  LyricTextEditStore(Directory directory)
    : _file = File('${directory.path}/lyric_text_edits.json');

  final File _file;
  static final _digest = RegExp(r'^[a-f0-9]{64}$');
  Future<_Drafts>? _loaded;
  Future<void> _tail = Future<void>.value();

  Future<_Drafts> _drafts() => _loaded ??= _read();

  Future<_Drafts> _read() async {
    if (!await _file.exists()) return {};
    final data = jsonDecode(await _file.readAsString());
    if (data is! Map || data['version'] != 1 || data['drafts'] is! List) {
      throw const FormatException('Invalid lyric text edits');
    }
    final result = <int, Map<_Version, Map<int, String>>>{};
    for (final draft in data['drafts'] as List) {
      if (draft is! Map) continue;
      final id = draft['track_id'];
      final audio = draft['audio_sha256'];
      final lrc = draft['lrc_sha256'];
      final rows = draft['edits'];
      if (id is! int ||
          audio is! String ||
          !_digest.hasMatch(audio) ||
          lrc is! String ||
          !_digest.hasMatch(lrc) ||
          rows is! Map ||
          rows.length > lyricLineEditLimit) {
        continue;
      }
      final edits = <int, String>{};
      for (final row in rows.entries) {
        final index = int.tryParse(row.key.toString());
        final text = row.value;
        if (index != null &&
            index >= 0 &&
            index < lyricSourceLineLimit &&
            text is String &&
            validLyricLineText(text)) {
          edits[index] = text;
        }
      }
      if (edits.isNotEmpty) {
        (result[id] ??= {})[(audio: audio, lrc: lrc)] = Map.unmodifiable(edits);
      }
    }
    return result;
  }

  Future<Map<int, String>> lookup(
    int trackId, {
    required String Function() lyricsFingerprint,
    required Future<String> Function() audioFingerprint,
  }) async {
    await _tail;
    final versions = (await _drafts())[trackId];
    if (versions == null) return const {};
    final lrc = lyricsFingerprint();
    if (!versions.keys.any((version) => version.lrc == lrc)) return const {};
    return versions[(audio: await audioFingerprint(), lrc: lrc)] ?? const {};
  }

  Future<Map<int, String>> saveLine(
    int trackId, {
    required String audio,
    required String lrc,
    required int index,
    required String? replacement,
  }) {
    final result = _tail.then((_) async {
      final drafts = await _drafts();
      final versions = {...?drafts[trackId]};
      final version = (audio: audio, lrc: lrc);
      final edits = {...?versions[version]};
      if (edits[index] == replacement) {
        return Map<int, String>.unmodifiable(edits);
      }
      if (replacement == null) {
        edits.remove(index);
      } else {
        if (edits.length >= lyricLineEditLimit && !edits.containsKey(index)) {
          throw const FormatException('Too many edited lines');
        }
        edits[index] = replacement;
      }
      final saved = Map<int, String>.unmodifiable(edits);
      if (saved.isEmpty) {
        versions.remove(version);
      } else {
        versions[version] = saved;
      }
      final next = {...drafts, trackId: versions};
      await atomicFileStore.writeString(
        _file,
        jsonEncode({
          'version': 1,
          'drafts': [
            for (final track in next.entries)
              for (final item in track.value.entries)
                {
                  'track_id': track.key,
                  'audio_sha256': item.key.audio,
                  'lrc_sha256': item.key.lrc,
                  'edits': {
                    for (final line in item.value.entries)
                      '${line.key}': line.value,
                  },
                },
          ],
        }),
      );
      if (versions.isEmpty) {
        drafts.remove(trackId);
      } else {
        drafts[trackId] = versions;
      }
      return saved;
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
