import 'package:flutter_discord_rpc/flutter_discord_rpc.dart';

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
