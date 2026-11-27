import 'dart:async';

import 'package:flutter_discord_rpc/flutter_discord_rpc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/discord_presence.dart';
import 'package:shiki/discord_status.dart';

class _PresenceProbe {
  final events = <String>[];
  DiscordPrivacy privacy = defaultDiscordPrivacy;
  bool playing = true;
  String track = 'First';
  Completer<void>? connecting;
  Completer<void>? publishing;
  bool clearFails = false;
  bool publishFails = false;

  late final publisher = DiscordPresencePublisher(
    canPublish: () => discordActivityAllowed(privacy, isPlaying: playing),
    buildActivity: () {
      events.add('artwork:$track');
      return RPCActivity(details: track, activityType: ActivityType.listening);
    },
    cancelArtwork: () => events.add('cancel artwork'),
    connect: () async {
      events.add('connect');
      await connecting?.future;
    },
    setActivity: (activity) async {
      events.add('publish:${activity.details}');
      await publishing?.future;
      if (publishFails) throw StateError('Pipe failed');
    },
    clearActivity: () async {
      events.add('clear');
      if (clearFails) throw StateError('Pipe failed');
      return true;
    },
    disconnect: () async => events.add('disconnect'),
  );

  Future<void> refresh() {
    publisher.refresh(force: true, clearBeforePublish: !playing);
    return publisher.idle;
  }
}

void main() {
  test('legacy settings keep showing the paused track', () async {
    final probe = _PresenceProbe()
      ..privacy = discordPrivacyFromSettings({})
      ..playing = false;
    await probe.refresh();
    expect(probe.events, ['connect', 'artwork:First', 'publish:First']);
  });

  test(
    'disabled presence opens no connection and submits no artwork',
    () async {
      final probe = _PresenceProbe()
        ..privacy = (enabled: false, hideOnPause: false);
      await probe.refresh();
      expect(probe.events, isEmpty);

      probe.privacy = defaultDiscordPrivacy;
      await probe.refresh();
      expect(probe.events.last, 'publish:First');
      probe.privacy = (enabled: false, hideOnPause: false);
      await probe.refresh();
      expect(probe.events.skip(3), ['cancel artwork', 'clear']);
      probe.track = 'Hidden';
      await probe.refresh();
      expect(probe.events, hasLength(5));
    },
  );

  test(
    'hide on pause clears; resume publishes the current track only',
    () async {
      final probe = _PresenceProbe()
        ..privacy = (enabled: true, hideOnPause: true);
      await probe.refresh();
      probe.playing = false;
      await probe.refresh();
      probe.track = 'Second';
      await probe.refresh();
      expect(probe.events.skip(3), ['cancel artwork', 'clear']);

      probe.playing = true;
      await probe.refresh();
      expect(probe.events.skip(5), ['artwork:Second', 'publish:Second']);
    },
  );

  test(
    'a connection completing after hiding cannot build or send activity',
    () async {
      final probe = _PresenceProbe()..connecting = Completer<void>();
      unawaited(probe.refresh());
      await Future<void>.delayed(Duration.zero);
      expect(probe.events, ['connect']);
      probe.privacy = (enabled: false, hideOnPause: false);
      final done = probe.refresh();
      probe.connecting!.complete();
      await done;
      expect(probe.events, ['connect', 'cancel artwork']);
    },
  );

  test('queued old activity cannot overtake clear and re-enable', () async {
    final probe = _PresenceProbe()..publishing = Completer<void>();
    unawaited(probe.refresh());
    await Future<void>.delayed(Duration.zero);
    expect(probe.events.last, 'publish:First');
    probe.track = 'Queued old';
    unawaited(probe.refresh());
    probe.privacy = (enabled: false, hideOnPause: false);
    unawaited(probe.refresh());
    probe.track = 'Current';
    probe.privacy = defaultDiscordPrivacy;
    final done = probe.refresh();
    probe.publishing!.complete();
    await done;
    expect(probe.events, [
      'connect',
      'artwork:First',
      'publish:First',
      'cancel artwork',
      'clear',
      'artwork:Current',
      'publish:Current',
    ]);
  });

  test('a failed clear closes only the app connection', () async {
    final probe = _PresenceProbe()..clearFails = true;
    await probe.refresh();
    probe.privacy = (enabled: false, hideOnPause: false);
    await probe.refresh();
    expect(probe.events.skip(3), ['cancel artwork', 'clear', 'disconnect']);
  });

  test(
    'a failed send can reconnect only for a newly built current activity',
    () async {
      final probe = _PresenceProbe()..publishFails = true;
      await probe.refresh();
      expect(probe.events.last, 'disconnect');
      probe.privacy = (enabled: false, hideOnPause: false);
      await probe.refresh();
      probe.track = 'Current';
      probe.publishFails = false;
      await probe.refresh();
      expect(probe.events.last, 'cancel artwork');
      probe.privacy = defaultDiscordPrivacy;
      await probe.refresh();
      expect(probe.events.skip(5), [
        'connect',
        'artwork:Current',
        'publish:Current',
      ]);
    },
  );

  testWidgets('hiding cancels a throttled activity update', (tester) async {
    final probe = _PresenceProbe();
    await probe.refresh();
    probe.track = 'Waiting';
    probe.publisher.refresh();
    probe.privacy = (enabled: false, hideOnPause: false);
    await probe.refresh();
    await tester.pump(const Duration(seconds: 2));
    await probe.publisher.idle;
    expect(probe.events.skip(3), ['cancel artwork', 'clear']);
  });

  test('track and artist remain the default when lyrics mode is off', () {
    expect(
      resolveDiscordStatusDisplayType(
        showLyrics: false,
        isPlaying: true,
        currentLyric: 'Current lyric',
      ),
      StatusDisplayType.details,
    );
  });

  test('lyrics mode selects state without replacing card text', () {
    final activity = RPCActivity(
      details: 'Song — Artist',
      state: 'Current lyric',
      activityType: ActivityType.listening,
      statusDisplayType: resolveDiscordStatusDisplayType(
        showLyrics: true,
        isPlaying: true,
        currentLyric: 'Current lyric',
      ),
    );
    expect(activity.statusDisplayType, StatusDisplayType.state);
    expect(activity.details, 'Song — Artist');
    expect(activity.state, 'Current lyric');
  });

  for (final lyric in [null, '', '   ']) {
    test('missing or unavailable lyric falls back to track: $lyric', () {
      expect(
        resolveDiscordStatusDisplayType(
          showLyrics: true,
          isPlaying: true,
          currentLyric: lyric,
        ),
        StatusDisplayType.details,
      );
    });
  }

  test('paused playback falls back to track even with a current lyric', () {
    expect(
      resolveDiscordStatusDisplayType(
        showLyrics: true,
        isPlaying: false,
        currentLyric: 'Current lyric',
      ),
      StatusDisplayType.details,
    );
  });
}
