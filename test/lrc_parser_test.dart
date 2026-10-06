import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/lrc_parser.dart';

void main() {
  test('parses integer, tenths, hundredths and millisecond timestamps', () {
    final lyrics = parseLrcString(
      '[00:01]One\n[00:02.3]Two\n[00:03.45]Three\n[01:04.567]Four',
    );
    expect(lyrics.map((line) => line.time.inMilliseconds), [
      1000,
      2300,
      3450,
      64567,
    ]);
    expect(lyrics.map((line) => line.txt), ['One', 'Two', 'Three', 'Four']);
  });

  test('expands repeated tags, orders cues and preserves same-time order', () {
    final lyrics = parseLrcString(
      '[00:20][00:05]Chorus\n[00:05.000]Translation\n[00:01]Intro',
    );
    expect(lyrics.map((line) => line.time.inSeconds), [1, 5, 5, 20]);
    expect(lyrics.map((line) => line.txt), [
      'Intro',
      'Chorus',
      'Translation',
      'Chorus',
    ]);
  });

  test('applies offsets anywhere in document and clamps before zero', () {
    final advanced = parseLrcString(
      '[00:00.2]Start\n[00:02]Later\n[offset:+500]',
    );
    expect(advanced.map((line) => line.time.inMilliseconds), [0, 1500]);
    final delayed = parseLrcString('[OFFSET: -250]\n[00:02]Later');
    expect(delayed.single.time.inMilliseconds, 2250);
  });

  test('keeps blank timed cues but ignores metadata and invalid seconds', () {
    final lyrics = parseLrcString(
      '[ar:Artist]\r\n[00:01]Verse\r\n[00:03]\r\n[00:70]Invalid\r\nplain text',
    );
    expect(lyrics.map((line) => line.txt), ['Verse', '']);
    expect(parseLrcString('plain text'), isEmpty);
  });

  test(
    'lookup works before first cue, across gaps, backwards and duplicates',
    () {
      final lyrics = parseLrcString(
        '[00:01]First\n[00:04]\n[00:08]Last\n[00:08]Translation',
      );
      expect(lyricLineIndexAt(lyrics, Duration.zero), -1);
      expect(lyricLineIndexAt(lyrics, const Duration(seconds: 1)), 0);
      expect(lyricLineIndexAt(lyrics, const Duration(seconds: 6)), 1);
      expect(lyricLineIndexAt(lyrics, const Duration(seconds: 8)), 3);
      expect(lyricLineIndexAt(lyrics, const Duration(seconds: 2)), 0);
      expect(lyricLineIndexAt([], const Duration(seconds: 2)), -1);
    },
  );
}
