import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/disposable_cache.dart';
import 'package:shiki/globals.dart' show LyricLine;
import 'package:shiki/lrc_parser.dart';
import 'package:shiki/lyric_timing.dart';

void main() {
  const lrc = '[00:00.100]One\n[00:02]Two\n[offset:+200]';
  final audio = sha256.convert([1, 2, 3]).toString();
  late Directory directory;
  late LyricTimingStore store;
  late File dataFile;
  late List<LyricLine> published;
  late int audioReads;
  late bool isCurrent;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shiki_lyric_timing_');
    store = LyricTimingStore(directory);
    dataFile = File('${directory.path}/lyric_offsets.json');
    published = [];
    audioReads = 0;
    isCurrent = true;
  });
  tearDown(() => directory.delete(recursive: true));

  LyricTimingSession session({
    int trackId = 17,
    String contents = lrc,
    Future<String> Function()? fingerprint,
    LyricTimingStore? offsets,
  }) => LyricTimingSession(
    store: offsets ?? store,
    trackId: trackId,
    contents: contents,
    fingerprintAudio: () async {
      audioReads++;
      return fingerprint == null ? audio : fingerprint();
    },
    isCurrent: () => isCurrent,
    onTimeline: (lines) => published = lines,
  );

  List<int> times() => [for (final line in published) line.time.inMilliseconds];

  test(
    'preview and cancellation do not read the MP3 or write a correction',
    () async {
      final timing = session();
      await timing.restore();
      timing.preview(-300);
      expect(times(), [200, 2100]);
      expect(
        lyricLineIndexAt(published, const Duration(milliseconds: 150)),
        -1,
      );
      timing.cancelPreview();
      expect(times(), [0, 1800]);
      expect(lyricLineIndexAt(published, const Duration(milliseconds: 150)), 0);
      expect(audioReads, 0);
      expect(await dataFile.exists(), isFalse);
    },
  );

  test(
    'save survives reopening and artwork cleanup; reset removes only the correction',
    () async {
      final lrcFile = await File(
        '${directory.path}/track_17.lrc',
      ).writeAsString(lrc);
      final timing = session()..preview(300);
      await timing.savePreview();
      expect(audioReads, 1);
      expect(timing.hasPreview, isFalse);
      await clearDisposableArtwork(
        directory,
        protectedTrackIds: const {},
        protectedArtistIds: const {},
      );
      final reopened = session(offsets: LyricTimingStore(directory));
      await reopened.restore();
      expect(times(), [0, 1500]);
      expect(reopened.advanceMilliseconds, 300);
      reopened.preview(0);
      await reopened.savePreview();
      final reset = session(offsets: LyricTimingStore(directory));
      await reset.restore();
      expect(reset.advanceMilliseconds, 0);
      expect(await lrcFile.readAsString(), lrc);
    },
  );

  test('restore requires the same LRC, audio bytes and track', () async {
    await (session()..preview(200)).savePreview();
    audioReads = 0;
    final changedText = session(contents: lrc.replaceAll('One', 'Updated'));
    final differentTrack = session(trackId: 18);
    await changedText.restore();
    await differentTrack.restore();
    expect(audioReads, 0, reason: 'No correction for this track/LRC');
    final changedAudio = session(
      fingerprint: () async => sha256.convert([3, 2, 1]).toString(),
    );
    await changedAudio.restore();
    expect(audioReads, 1);
    expect(changedText.advanceMilliseconds, 0);
    expect(differentTrack.advanceMilliseconds, 0);
    expect(changedAudio.advanceMilliseconds, 0);
  });

  test('a late restore cannot take over after a track change', () async {
    await (session()..preview(100)).savePreview();
    published = [];
    final started = Completer<void>();
    final digest = Completer<String>();
    final timing = session(
      fingerprint: () {
        started.complete();
        return digest.future;
      },
    );
    final restore = timing.restore();
    await started.future;
    isCurrent = false;
    digest.complete(audio);
    await restore;
    timing.preview(200);
    timing.cancelPreview();
    expect(published, isEmpty);
  });

  test(
    'a save prepared for an already replaced track does not write',
    () async {
      final digest = Completer<String>();
      final timing = session(fingerprint: () => digest.future)..preview(100);
      final saving = timing.savePreview();
      isCurrent = false;
      digest.complete(audio);
      await saving;
      expect(await dataFile.exists(), isFalse);
    },
  );

  test(
    'saving an invalidated audio file cannot replace a good correction',
    () async {
      await (session()..preview(200)).savePreview();
      final failing = session(
        fingerprint: () async {
          throw StateError('The opened audio file changed');
        },
      )..preview(-300);
      await expectLater(failing.savePreview(), throwsStateError);
      final reopen = session(offsets: LyricTimingStore(directory));
      await reopen.restore();
      expect(reopen.advanceMilliseconds, 200);
    },
  );

  test(
    'a captured audio file fingerprints its bytes and rejects replacement',
    () async {
      final file = await File(
        '${directory.path}/track_17.mp3',
      ).writeAsBytes([1, 2, 3]);
      final opened = (await LyricAudioFile.inspect(file))!;
      expect(await opened.fingerprint(), audio);
      await file.writeAsBytes([4, 5, 6, 7]);
      await expectLater(opened.fingerprint(), throwsStateError);
      expect(
        await (await LyricAudioFile.inspect(file))!.fingerprint(),
        sha256.convert([4, 5, 6, 7]).toString(),
      );
    },
  );
}
