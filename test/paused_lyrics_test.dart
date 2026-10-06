import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/lrc_parser.dart';
import 'package:shiki/screens/home_screen.dart';

void main() {
  test('paused position changes refresh highlighted lyrics both ways', () {
    final previousLyrics = globalLyrics;
    final previousLine = currentLine;
    final previousSignal = uiSignal.value;
    try {
      globalLyrics = parseLrcString('[00:01]First\n[00:05]Second');
      currentLine = -1;
      final state = MainAppScreenState();
      expect(state.isPlaying, isFalse);
      state.checkLyrics(const Duration(seconds: 6));
      expect(currentLine, 1);
      state.checkLyrics(const Duration(seconds: 2));
      expect(currentLine, 0);
      state.checkLyrics(Duration.zero);
      expect(currentLine, -1);
      expect(uiSignal.value, previousSignal + 3);
    } finally {
      globalLyrics = previousLyrics;
      currentLine = previousLine;
      uiSignal.value = previousSignal;
    }
  });
}
