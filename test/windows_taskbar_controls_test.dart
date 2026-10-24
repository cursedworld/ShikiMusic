import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/windows_taskbar_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('shiki/taskbar_controls');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> updates;
  late List<String> actions;
  late WindowsTaskbarControls controls;

  setUp(() {
    updates = [];
    actions = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      updates.add(call);
      return null;
    });
    controls = WindowsTaskbarControls(
      channel: channel,
      supported: true,
      onAction: actions.add,
    );
  });
  tearDown(() {
    controls.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> state({
    bool hasTrack = true,
    bool playing = false,
    bool favorite = false,
  }) => controls.update(
    hasTrack: hasTrack,
    playing: playing,
    favorite: favorite,
    favoriteTip: favorite ? 'Remove favorite' : 'Add favorite',
    previousTip: 'Previous',
    playPauseTip: playing ? 'Pause' : 'Play',
    nextTip: 'Next',
  );

  Future<void> click(String action) async {
    final reply = Completer<void>();
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('action', action),
      ),
      (_) => reply.complete(),
    );
    await reply.future;
  }

  test(
    'empty queue disables controls; repeated state never polls native toolbar',
    () async {
      await state(hasTrack: false, playing: true, favorite: true);
      expect(updates.single.arguments['hasTrack'], isFalse);
      expect(updates.single.arguments['playing'], isFalse);
      expect(updates.single.arguments['favorite'], isFalse);
      for (var i = 0; i < 100; i++) {
        await state(hasTrack: false, playing: true, favorite: true);
      }
      expect(updates.length, 1);
      await click('next');
      expect(actions, isEmpty);
    },
  );

  test('all four actions dispatch to playback and favorite handlers', () async {
    await state();
    for (final action in ['favorite', 'previous', 'toggle', 'next']) {
      await click(action);
    }
    await click('unsupported');
    expect(actions, ['favorite', 'previous', 'toggle', 'next']);
  });

  test('pause and favorite states refresh icons and tooltips', () async {
    await state();
    await state(playing: true);
    await state(playing: true, favorite: true);
    await state(playing: false, favorite: true);
    expect(updates.length, 4);
    expect(updates[1].arguments['playPauseTip'], 'Pause');
    expect(updates[2].arguments['favorite'], isTrue);
    expect(updates.last.arguments['playPauseTip'], 'Play');
  });

  test(
    'missing or temporarily failing native bridge never breaks playback',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw MissingPluginException(),
      );
      await state();
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'unavailable'),
      );
      await state();
      messenger.setMockMethodCallHandler(channel, (call) async {
        updates.add(call);
        return null;
      });
      await state();
      expect(updates.length, 1);
    },
  );

  test(
    'non-Windows platforms never call native code; disposal stops updates',
    () async {
      controls.dispose();
      controls = WindowsTaskbarControls(
        channel: channel,
        supported: false,
        onAction: actions.add,
      );
      await state();
      controls.dispose();
      await state(playing: true);
      expect(updates, isEmpty);
    },
  );
}
