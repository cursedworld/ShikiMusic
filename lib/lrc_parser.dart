import 'globals.dart';

final RegExp _lrcTimestamp = RegExp(r'\[(\d+):(\d{2})(?:\.(\d{1,3}))?\]');
final RegExp _lrcOffset = RegExp(
  r'\[offset\s*:\s*([+-]?\d+)\s*\]',
  caseSensitive: false,
);
final _lineControls = RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]');
const lyricLineTextLimit = 512;
const lyricSourceLineLimit = 65536;

bool validLyricLineText(String text) =>
    text.runes.length <= lyricLineTextLimit &&
    !_lineControls.hasMatch(text) &&
    !_lrcTimestamp.hasMatch(text) &&
    !_lrcOffset.hasMatch(text);

/// Parses ordinary LRC without discarding repeated timestamps or silent gaps.
/// Positive LRC offsets advance the lyrics; negative offsets delay them.
List<LyricLine> parseLrcString(
  String contents, {
  int advanceMilliseconds = 0,
  Map<int, String> lineEdits = const {},
}) {
  var offsetMilliseconds = 0;
  for (final match in _lrcOffset.allMatches(contents)) {
    offsetMilliseconds = int.tryParse(match.group(1)!) ?? offsetMilliseconds;
  }
  offsetMilliseconds += advanceMilliseconds;

  final entries = <({LyricLine line, int order})>[];
  var order = 0;
  final rows = contents.split(RegExp(r'\r?\n'));
  for (var row = 0; row < rows.length; row++) {
    final rawLine = rows[row];
    final matches = _lrcTimestamp.allMatches(rawLine).toList();
    if (matches.isEmpty) continue;
    final original = rawLine.substring(matches.last.end).trim();
    // Replacing a suffix that contains an offset directive would alter timing.
    final sourceLine =
        row < lyricSourceLineLimit && !_lrcOffset.hasMatch(original)
        ? row
        : null;
    final text = lineEdits[sourceLine] ?? original;
    for (final match in matches) {
      final minutes = int.tryParse(match.group(1)!);
      final seconds = int.tryParse(match.group(2)!);
      if (minutes == null || seconds == null || seconds >= 60) continue;
      final fraction = match.group(3) ?? '';
      final milliseconds = fraction.isEmpty
          ? 0
          : int.parse(fraction.padRight(3, '0'));
      final timestamp =
          (minutes * 60 + seconds) * 1000 + milliseconds - offsetMilliseconds;
      entries.add((
        line: LyricLine(
          Duration(milliseconds: timestamp < 0 ? 0 : timestamp),
          text,
          text,
          sourceLine: sourceLine,
        ),
        order: order++,
      ));
    }
  }
  entries.sort((a, b) {
    final byTime = a.line.time.compareTo(b.line.time);
    return byTime == 0 ? a.order.compareTo(b.order) : byTime;
  });
  return entries.map((entry) => entry.line).toList();
}

/// Last cue at or before [position]. Input must be sorted by time.
int lyricLineIndexAt(List<LyricLine> lyrics, Duration position) {
  var low = 0;
  var high = lyrics.length;
  while (low < high) {
    final middle = low + ((high - low) >> 1);
    if (lyrics[middle].time <= position) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low - 1;
}
