import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/lyric_timing.dart';
import 'package:shiki/playback_deck.dart';
import 'package:shiki/track_crossfade.dart';

import 'fixtures/local_mp3.dart';

const _length = Duration(seconds: 12);

class _Audio implements AudioPlayer {
  final List<double> writes = [];
  final List<String> operations = [];
  double output = 1;
  final prepared = Completer<void>();
  @override
  PlayerState state = PlayerState.stopped;

  @override
  set positionUpdater(PositionUpdater? value) {}

  @override
  Future<void> setVolume(double volume) async {
    writes.add(volume);
    output = volume;
  }

  @override
  Future<void> setSource(Source source) async => operations.add('source');

  @override
  Future<void> pause() async {
    operations.add('pause');
    state = PlayerState.paused;
  }

  @override
  Future<void> resume() async {
    operations.add('resume');
    state = PlayerState.playing;
  }

  @override
  Future<Duration?> getDuration() async {
    if (!prepared.isCompleted) prepared.complete();
    return _length;
  }

  @override
  Future<Duration?> getCurrentPosition() async => null;

  @override
  Future<void> dispose() async {
    state = PlayerState.disposed;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  late Directory directory;
  late LyricAudioFile first, second;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shiki-deck-gain-');
    Future<LyricAudioFile> track(String name, String db) async {
      final file = await File('${directory.path}/$name.mp3').writeAsBytes(
        fixtureMp3(
          tags: [utf8Tag('TXXX', 'REPLAYGAIN_TRACK_GAIN\u0000$db dB')],
        ),
      );
      return (await LyricAudioFile.inspect(file))!;
    }

    first = await track('first', '-6.0206');
    second = await track('second', '-12.0412');
  });
  tearDown(() async {
    await File(first.path).delete();
    await File(second.path).delete();
    await directory.delete();
  });

  test(
    'disabled does not read, toggle and mute do not reopen the source',
    () async {
      final player = _Audio();
      var reads = 0;
      final deck = PlaybackDeck(
        volume: .8,
        fadeEnabled: false,
        onError: (error) => fail('$error'),
        player: player,
        trackGainReader: (_) async {
          reads++;
          return .5;
        },
      );
      addTearDown(deck.dispose);
      await deck.fade.setVolume(.8);
      await deck.setTrackSource(
        DeviceFileSource(first.path),
        localAudio: first,
      );
      await deck.resume();
      expect(reads, 0);
      expect(player.output, .8);
      await deck.setReplayGainEnabled(true);
      expect(player.output, .4);
      await deck.fade.setVolume(0);
      expect(player.output, 0);
      await deck.setReplayGainEnabled(false);
      expect(player.output, 0);
      await deck.fade.setVolume(.6);
      expect(player.output, .6);
      await deck.setReplayGainEnabled(true);
      expect(player.output, .3);
      expect(reads, 1);
      expect(player.operations, ['source', 'resume']);
    },
  );

  test(
    'a late gain read cannot change a different song or a network source',
    () async {
      final player = _Audio();
      final lateRead = Completer<double>();
      final deck = PlaybackDeck(
        volume: .8,
        fadeEnabled: false,
        onError: (error) => fail('$error'),
        player: player,
        trackGainReader: (path) =>
            path == first.path ? lateRead.future : Future.value(.5),
      );
      addTearDown(deck.dispose);
      await deck.setTrackSource(
        DeviceFileSource(first.path),
        localAudio: first,
      );
      final enabling = deck.setReplayGainEnabled(true);
      await deck.resume();
      await deck.setTrackSource(
        DeviceFileSource(second.path),
        localAudio: second,
      );
      expect(player.operations, ['source', 'resume', 'pause', 'source']);
      expect(player.output, .4);
      lateRead.complete(.2);
      await enabling;
      expect(player.output, .4);
      await deck.setTrackSource(UrlSource('https://example.test/audio.mp3'));
      expect(player.output, .8);
    },
  );

  test(
    'crossfade keeps each tag gain and the handoff does not apply it twice',
    () async {
      final out = _Audio();
      final input = _Audio();
      PlaybackDeck deck(_Audio player) => PlaybackDeck(
        volume: .8,
        fadeEnabled: true,
        replayGainEnabled: true,
        player: player,
        onError: (error) => fail('$error'),
      );
      final outgoing = deck(out);
      final incoming = deck(input);
      addTearDown(outgoing.dispose);
      addTearDown(incoming.dispose);
      await outgoing.setTrackSource(
        DeviceFileSource(first.path),
        localAudio: first,
      );
      final source = (slot: 1, trackId: 2, path: second.path);
      final crossfade = TrackCrossfade<PlaybackDeck>(
        createDeck: () => incoming,
        fileReady: (_) async => true,
        nextSource: () => source,
        onError: (error) => fail('$error'),
        onReleased: () {},
      );
      addTearDown(crossfade.cancel);
      crossfade.update(const Duration(milliseconds: 1200), .8);
      await input.prepared.future;
      await _flush();
      expect(crossfade.incomingDeck, same(incoming));
      expect(input.output, 0);
      crossfade.update(const Duration(milliseconds: 600), .8);
      await _flush();
      crossfade.update(const Duration(milliseconds: 300), .8);
      await outgoing.fade.updatePosition(
        _length - const Duration(milliseconds: 300),
        _length,
        playing: false,
      );
      await _flush();
      expect(out.output, closeTo(.8 * .5 * (7 / 27), 1e-6));
      expect(input.output, closeTo(.8 * .5 * .25, 1e-6));
      final handoff = crossfade.takeAtEnd()!;
      expect(handoff.deck, same(incoming));
      incoming.fade.beginTrack(fadeIn: false);
      await incoming.fade.setVolume(.8);
      expect(input.output, closeTo(.8 * .25, 1e-6));
      expect(input.operations, ['source', 'resume']);
    },
  );
}
