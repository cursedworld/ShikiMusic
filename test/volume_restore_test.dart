import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/app_paths.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/screens/home_screen.dart';

class _VolumeScreen extends MainAppScreen {
  const _VolumeScreen();

  @override
  MainAppScreenState createState() => _VolumeScreenState();
}

class _VolumeScreenState extends MainAppScreenState {
  @override
  void updateRPC({bool force = false}) {}
}

void main() {
  testWidgets('mute survives reopening and restores the exact volume', (
    tester,
  ) async {
    // Never let a test with an overridden data directory open a real profile.
    expect(hasAppDataDirectoryOverride, isFalse);
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('shiki-volume-test-'),
    ))!;
    addTearDown(() => root.delete(recursive: true));
    final previousPath = globalLocalPath;
    final previousTrack = activeTrackNotifier.value;
    addTearDown(() {
      globalLocalPath = previousPath;
      activeTrackNotifier.value = previousTrack;
    });

    const beforeMute = .27;
    final stateFile = File('${root.path}/ShikiMusic/app_state.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'volume': beforeMute,
          'playingQueue': [
            {
              'id': 1,
              'title': 'Volume fixture',
              'audio_file': 'http://127.0.0.1/fixture.mp3',
              'album': {
                'title': 'Album',
                'cover': '',
                'artist': {'id': 2, 'name': 'Artist'},
              },
            },
          ],
        }),
      );

    // Use real session I/O and the real desktop control; replace native audio
    // and the Documents lookup so nothing plays or touches the user's files.
    final messenger = tester.binding.defaultBinaryMessenger;
    void mock(String name, Future<Object?> Function(MethodCall) handler) {
      final channel = MethodChannel(name);
      messenger.setMockMethodCallHandler(channel, handler);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }

    mock('plugins.flutter.io/path_provider', (_) async => root.path);
    expect((await getDocumentsRootDirectory()).path, root.path);
    mock('xyz.luan/audioplayers.global', (_) async => null);
    mock('xyz.luan/audioplayers.global/events', (_) async => null);
    final gains = <double>[];
    var sources = 0;
    mock('xyz.luan/audioplayers', (call) async {
      final args = call.arguments as Map;
      final events = 'xyz.luan/audioplayers/events/${args['playerId']}';
      switch (call.method) {
        case 'create':
          mock(events, (_) async => null);
        case 'setSourceUrl':
          sources++;
          await messenger.handlePlatformMessage(
            events,
            const StandardMethodCodec().encodeSuccessEnvelope({
              'event': 'audio.onPrepared',
              'value': true,
            }),
            (_) {},
          );
        case 'getDuration':
          return 180000;
        case 'setVolume':
          gains.add(args['volume'] as double);
      }
      return null;
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1250, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    Future<void> until(bool Function() done, String message) async {
      for (var i = 0; i < 250; i++) {
        await tester.pump();
        if (done()) return;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 8)),
        );
      }
      fail(message);
    }

    MainAppScreenState state() => tester.state(find.byType(_VolumeScreen));
    bool savedVolume(double volume) {
      try {
        return (jsonDecode(stateFile.readAsStringSync()) as Map)['volume'] ==
            volume;
      } on FileSystemException {
        return false;
      }
    }

    final off = find.byIcon(Icons.volume_off);
    const app = MaterialApp(home: _VolumeScreen());
    Future<void> open() async {
      await tester.pumpWidget(app);
      await until(
        () => state().fullDurationNotifier.value == const Duration(minutes: 3),
        'Saved session did not load',
      );
    }

    try {
      await open();
      expect(state().volume, beforeMute);
      await tester.tap(find.byIcon(Icons.volume_down));
      await until(() => savedVolume(0), 'Mute was not saved');
      expect(tester.widget<Icon>(off).color, Colors.redAccent);

      await tester.pumpWidget(const SizedBox.shrink());
      await open();
      final colorAfterReopening = tester.widget<Icon>(off).color;
      expect(state().volume, 0);
      expect(gains.last, 0);
      final sourcesBeforeClick = sources;
      await tester.tap(off);
      await tester.pump();
      expect(
        (colorAfterReopening, state().volume),
        (Colors.redAccent, beforeMute),
      );
      await until(
        () => savedVolume(beforeMute),
        'Restored volume was not saved',
      );
      expect(gains.last, beforeMute);
      expect(sources, sourcesBeforeClick);

      // Old sessions did not store a volume to unmute to.
      await tester.pumpWidget(const SizedBox.shrink());
      final oldState = (jsonDecode(stateFile.readAsStringSync()) as Map)
        ..['volume'] = 0
        ..remove('volumeBeforeMute');
      stateFile.writeAsStringSync(jsonEncode(oldState));
      await open();
      expect(tester.widget<Icon>(off).color, Colors.redAccent);
      expect(gains.last, 0);
      await tester.tap(off);
      await until(() => savedVolume(.5), 'Legacy unmute did not save volume');
      expect(gains.last, .5);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
