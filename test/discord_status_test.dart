import 'package:flutter_discord_rpc/flutter_discord_rpc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/discord_status.dart';

void main() {
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
