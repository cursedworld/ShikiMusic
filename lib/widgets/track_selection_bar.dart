import 'package:flutter/material.dart';

import '../localization.dart';

/// A small transparent mode indicator, not an opaque replacement background.
class TrackSelectionBar extends StatelessWidget {
  const TrackSelectionBar({
    super.key,
    required this.count,
    required this.onClear,
    this.onPlay,
    this.playlists = const {},
    this.onPlaylistSelected,
  });

  final int count;
  final VoidCallback onClear;
  final VoidCallback? onPlay;
  final Map<int, String> playlists;
  final ValueChanged<int>? onPlaylistSelected;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: Row(
      children: [
        Text(
          tr('tracks_selected').replaceAll('{count}', '$count'),
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        const Spacer(),
        if (playlists.isNotEmpty && onPlaylistSelected != null)
          PopupMenuButton<int>(
            key: const ValueKey('selection_playlist'),
            tooltip: tr('add_selected_to_playlist'),
            icon: const Icon(
              Icons.playlist_add,
              color: Colors.white70,
              size: 20,
            ),
            onSelected: onPlaylistSelected,
            itemBuilder: (_) => [
              for (final entry in playlists.entries)
                PopupMenuItem(value: entry.key, child: Text(entry.value)),
            ],
          ),
        if (onPlay != null)
          IconButton(
            key: const ValueKey('play_track_selection'),
            tooltip: tr('play_selected_tracks'),
            onPressed: onPlay,
            icon: const Icon(Icons.play_arrow, color: Colors.white70, size: 20),
          ),
        IconButton(
          key: const ValueKey('clear_track_selection'),
          tooltip: tr('clear_track_selection'),
          onPressed: onClear,
          icon: const Icon(Icons.close, color: Colors.white54, size: 18),
        ),
      ],
    ),
  );
}
