import 'package:flutter_discord_rpc/flutter_discord_rpc.dart';

typedef DiscordPrivacy = ({bool enabled, bool hideOnPause});

const DiscordPrivacy defaultDiscordPrivacy = (
  enabled: true,
  hideOnPause: false,
);

DiscordPrivacy discordPrivacyFromSettings(Map<dynamic, dynamic> settings) => (
  enabled:
      settings['discordPresenceEnabled'] == null ||
      settings['discordPresenceEnabled'] == true,
  hideOnPause: settings['discordHideOnPause'] == true,
);

bool discordActivityAllowed(
  DiscordPrivacy privacy, {
  required bool isPlaying,
}) => privacy.enabled && (isPlaying || !privacy.hideOnPause);

/// Keep the profile card unchanged; only select the compact status source.
StatusDisplayType resolveDiscordStatusDisplayType({
  required bool showLyrics,
  required bool isPlaying,
  String? currentLyric,
}) {
  if (showLyrics && isPlaying && currentLyric?.trim().isNotEmpty == true) {
    return StatusDisplayType.state;
  }
  return StatusDisplayType.details;
}
