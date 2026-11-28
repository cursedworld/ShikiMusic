import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../localization.dart';
import '../playback_order.dart';
import '../track_details.dart';

/// The temporary insertions only. Neither removal action edits a playlist or
/// the original file.
class PlayNextPanel extends StatelessWidget {
  const PlayNextPanel({
    super.key,
    required this.playing,
    required this.insertions,
    required this.startingSlot,
    required this.onRemove,
    required this.onClear,
    this.isUnavailable,
  });

  final Map? playing;
  final List<PlaybackEntry> insertions;
  final int? startingSlot;
  final ValueChanged<int> onRemove;
  final VoidCallback onClear;
  final bool Function(PlaybackEntry)? isUnavailable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canClear = insertions.any((entry) => entry.slot != startingSlot);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 460,
          maxHeight: math.min(468, MediaQuery.sizeOf(context).height * .72),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 10, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      tr('play_next_queue'),
                      style: theme.textTheme.titleLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (canClear)
                    Flexible(
                      child: TextButton(
                        key: const ValueKey('clear_play_next'),
                        onPressed: onClear,
                        child: Text(
                          tr('play_next_clear'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    tooltip: tr('close'),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              if (playing != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 0, 8, 6),
                  child: Text(
                    tr(
                      'play_next_now_playing',
                    ).replaceFirst('{title}', trackDisplayTitle(playing)),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white70,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              const Divider(height: 1, color: Colors.white12),
              Flexible(
                child: insertions.isEmpty
                    ? SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(0, 16, 8, 6),
                        child: Text(
                          tr('play_next_empty'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.white70,
                          ),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: insertions.length,
                        padding: const EdgeInsets.only(top: 4),
                        separatorBuilder: (_, _) =>
                            const Divider(height: 1, color: Colors.white12),
                        itemBuilder: (context, i) {
                          final entry = insertions[i];
                          final starting = entry.slot == startingSlot;
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Text(
                              '${i + 1}',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: Colors.white54,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                            title: Text(
                              trackDisplayTitle(entry.track),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              starting
                                  ? tr('play_next_starting')
                                  : isUnavailable?.call(entry) == true
                                  ? tr('downloaded_only_unavailable')
                                  : trackDisplayArtist(entry.track),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: starting
                                ? Tooltip(
                                    message: tr('play_next_starting'),
                                    child: const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: Icon(
                                        Icons.graphic_eq_rounded,
                                        size: 20,
                                      ),
                                    ),
                                  )
                                : IconButton(
                                    key: ValueKey(
                                      'remove_play_next_${entry.slot}',
                                    ),
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      size: 20,
                                    ),
                                    tooltip: tr('play_next_remove'),
                                    onPressed: () => onRemove(entry.slot),
                                  ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shares a slot with the old add-to-playlist popup where one already exists.
class TrackPlayNextMenu extends StatelessWidget {
  const TrackPlayNextMenu({
    super.key,
    this.onPlayNext,
    this.playNextCount = 1,
    this.playlists = const {},
    this.onPlaylistSelected,
    this.onMatchLocal,
    this.onEditDetails,
  });

  final VoidCallback? onPlayNext;
  final int playNextCount;
  final Map<int, String> playlists;
  final ValueChanged<int>? onPlaylistSelected;
  final VoidCallback? onMatchLocal;
  final VoidCallback? onEditDetails;

  static const _next = 'play_next';
  static const _match = 'match_local';
  static const _details = 'track_details';

  @override
  Widget build(BuildContext context) {
    final compact = switch (Theme.of(context).platform) {
      TargetPlatform.windows ||
      TargetPlatform.linux ||
      TargetPlatform.macOS => true,
      _ => false,
    };

    final hasTrackActions =
        onPlayNext != null || onMatchLocal != null || onEditDetails != null;
    PopupMenuItem<Object> entry(Object value, String title) =>
        PopupMenuItem<Object>(
          value: value,
          height: compact ? 32 : kMinInteractiveDimension,
          padding: compact ? const EdgeInsets.symmetric(horizontal: 10) : null,
          child: Text(
            title,
            maxLines: compact ? 2 : null,
            overflow: compact ? TextOverflow.ellipsis : null,
          ),
        );
    final divider = compact
        ? const PopupMenuDivider(height: 8, indent: 10, endIndent: 10)
        : const PopupMenuDivider();

    return PopupMenuButton<Object>(
      style: IconButton.styleFrom(
        minimumSize: const Size(40, 44),
        padding: EdgeInsets.zero,
      ),
      menuPadding: compact ? const EdgeInsets.symmetric(vertical: 4) : null,
      constraints: compact
          ? const BoxConstraints(minWidth: 112, maxWidth: 224)
          : null,
      tooltip: tr(
        hasTrackActions ? 'track_actions' : 'add_selected_to_playlist',
      ),
      icon: Icon(
        hasTrackActions ? Icons.more_horiz_rounded : Icons.add_circle_outline,
        color: Colors.white54,
        size: 21,
      ),
      onSelected: (item) {
        if (item == _next) {
          onPlayNext?.call();
        } else if (item == _match) {
          onMatchLocal?.call();
        } else if (item == _details) {
          onEditDetails?.call();
        } else if (item is int) {
          onPlaylistSelected?.call(item);
        }
      },
      itemBuilder: (_) => [
        if (onPlayNext != null)
          entry(
            _next,
            tr(playNextCount > 1 ? 'play_next_selection' : 'play_next_track'),
          ),
        if (onEditDetails != null) entry(_details, tr('track_details')),
        if (onMatchLocal != null) entry(_match, tr('local_match_on_server')),
        if (hasTrackActions && playlists.isNotEmpty) divider,
        for (final playlist in playlists.entries)
          entry(playlist.key, playlist.value),
      ],
    );
  }
}
