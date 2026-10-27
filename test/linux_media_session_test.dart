import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/linux_media_session.dart';

void main() {
  late LinuxMediaSession session;
  late List<(String, Duration?)> actions;
  late List<Object> settings;
  setUp(() {
    actions = [];
    settings = [];
    session = LinuxMediaSession(
      onAction: (name, position) => actions.add((name, position)),
      onShuffle: settings.add,
      onRepeat: settings.add,
      onVolume: settings.add,
    );
  });
  tearDown(() => session.close());
  void track({bool playing = false, bool canNext = true}) => session.update(
    id: 12,
    title: 'Track',
    artists: ['First', 'Second'],
    album: 'Album',
    artwork: 'file:///tmp/cover.jpg',
    duration: const Duration(minutes: 3),
    position: const Duration(seconds: 10),
    playing: playing,
    canNext: canNext,
    canPrevious: true,
    shuffled: false,
    loop: 'None',
    volume: 0.5,
  );
  Future<DBusMethodResponse> call(
    String name, [
    List<DBusValue> values = const [],
  ]) => session.handleMethodCall(
    DBusMethodCall(
      sender: 'fixture',
      interface: mprisPlayerInterface,
      name: name,
      values: values,
    ),
  );

  test(
    'empty queue exposes no commands; command executes once for loaded track',
    () async {
      await call('Next');
      await call('PlayPause');
      expect(actions, isEmpty);
      track();
      await call('Next');
      await call('PlayPause');
      expect(actions, [('next', null), ('toggle', null)]);
      track(canNext: false);
      await call('Next');
      expect(actions.length, 2);
      expect(
        await call('Play', [const DBusString('bad')]),
        isA<DBusMethodErrorResponse>(),
      );
    },
  );

  test(
    'metadata includes collaborators, exact duration and stable track ID',
    () async {
      track();
      final response =
          await session.getProperty(mprisPlayerInterface, 'Metadata')
              as DBusGetPropertyResponse;
      final values = response.returnValues.single
          .asVariant()
          .asStringVariantDict();
      expect(values['xesam:artist']!.asStringArray(), ['First', 'Second']);
      expect(
        values['mpris:length']!.asInt64(),
        const Duration(minutes: 3).inMicroseconds,
      );
      expect(
        values['mpris:trackid'],
        DBusObjectPath('/org/mpris/MediaPlayer2/track_12'),
      );
      expect(
        session.introspect().map((value) => value.name),
        containsAll([mprisRootInterface, mprisPlayerInterface]),
      );
    },
  );

  test(
    'seek uses microseconds; stale SetPosition cannot seek a new track',
    () async {
      track();
      await call('Seek', [const DBusInt64(5000000)]);
      expect(actions.single, ('seek', const Duration(seconds: 15)));
      await call('SetPosition', [
        DBusObjectPath('/org/mpris/MediaPlayer2/track_99'),
        const DBusInt64(1),
      ]);
      expect(actions.length, 1);
      await call('SetPosition', [
        DBusObjectPath('/org/mpris/MediaPlayer2/track_12'),
        const DBusInt64(2000000),
      ]);
      expect(actions.last, ('seek', const Duration(seconds: 2)));
      await call('Seek', [const DBusInt64(-999999999)]);
      expect(actions.last, ('seek', Duration.zero));
      await call('Seek', [const DBusInt64(999999999)]);
      expect(actions.last, ('next', null));
      session.seeked(const Duration(seconds: 41));
      expect(session.position, const Duration(seconds: 41));
    },
  );

  test(
    'shuffle/repeat/volume validate inputs and unsupported writes fail',
    () async {
      track();
      await session.setProperty(
        mprisPlayerInterface,
        'Shuffle',
        const DBusBoolean(true),
      );
      await session.setProperty(
        mprisPlayerInterface,
        'LoopStatus',
        const DBusString('Track'),
      );
      await session.setProperty(
        mprisPlayerInterface,
        'Volume',
        const DBusDouble(0.7),
      );
      expect(settings, [true, 'Track', 0.7]);
      expect(
        await session.setProperty(
          mprisPlayerInterface,
          'LoopStatus',
          const DBusString('garbage'),
        ),
        isA<DBusMethodErrorResponse>(),
      );
      expect(
        await session.setProperty(
          mprisPlayerInterface,
          'Rate',
          const DBusDouble(2),
        ),
        isA<DBusMethodErrorResponse>(),
      );
      expect(
        await session.getProperty(mprisPlayerInterface, 'Missing'),
        isA<DBusMethodErrorResponse>(),
      );
    },
  );

  testWidgets('position extrapolates only while playing, no ticker or timer', (
    tester,
  ) async {
    track(playing: true);
    final before = session.position;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    expect(session.position, greaterThan(before));
    track(playing: false);
    final paused = session.position;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    expect(session.position, paused);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
