import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../localization.dart';

/// Use lazy rows for both ordinary lists and reorderable user playlists.
class PlaylistTrackList extends StatelessWidget {
  const PlaylistTrackList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.onReorder,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final ReorderCallback? onReorder;

  @override
  Widget build(BuildContext context) {
    const physics = BouncingScrollPhysics(
      parent: AlwaysScrollableScrollPhysics(),
    );
    if (onReorder == null) {
      return ListView.builder(
        physics: physics,
        cacheExtent: 500,
        itemCount: itemCount,
        itemBuilder: itemBuilder,
      );
    }
    return ReorderableListView.builder(
      physics: physics,
      cacheExtent: 500,
      buildDefaultDragHandles: false,
      itemCount: itemCount,
      itemBuilder: itemBuilder,
      onReorder: onReorder!,
      proxyDecorator: (child, index, animation) => Material(
        type: MaterialType.transparency,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(10),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Reuse the artwork hit target instead of reserving another list column.
class PlaylistTrackDragHandle extends StatefulWidget {
  const PlaylistTrackDragHandle({
    super.key,
    required this.index,
    required this.itemCount,
    required this.onReorder,
    required this.artwork,
    this.touchMode = false,
  });

  final int index;
  final int itemCount;
  final ReorderCallback onReorder;
  final Widget artwork;
  final bool touchMode;

  @override
  State<PlaylistTrackDragHandle> createState() =>
      _PlaylistTrackDragHandleState();
}

class _PlaylistTrackDragHandleState extends State<PlaylistTrackDragHandle> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final index = widget.index;
    final up = index > 0 ? () => widget.onReorder(index, index - 1) : null;
    final down = index + 1 < widget.itemCount
        ? () => widget.onReorder(index, index + 2)
        : null;
    final grip = SizedBox(
      width: 50,
      height: 50,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          children: [
            Positioned.fill(child: widget.artwork),
            if (widget.touchMode)
              Positioned(
                right: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Icon(
                    Icons.drag_indicator,
                    size: 16,
                    color: Colors.white70,
                  ),
                ),
              )
            else
              Positioned.fill(
                child: AnimatedOpacity(
                  opacity: _hovered || _focused ? 1 : 0,
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 120),
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.48),
                    child: const Center(
                      child: Icon(
                        Icons.drag_indicator,
                        size: 22,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    final semanticsActions = <CustomSemanticsAction, VoidCallback>{};
    if (up != null) {
      semanticsActions[CustomSemanticsAction(label: tr('playlist_move_up'))] =
          up;
    }
    if (down != null) {
      semanticsActions[CustomSemanticsAction(label: tr('playlist_move_down'))] =
          down;
    }
    return Focus(
      onFocusChange: (value) => setState(() => _focused = value),
      child: Builder(
        builder: (context) => Semantics(
          label: tr(
            widget.touchMode ? 'playlist_reorder_touch' : 'playlist_reorder',
          ),
          customSemanticsActions: semanticsActions,
          child: MouseRegion(
            cursor: SystemMouseCursors.grab,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: Tooltip(
              message: tr(
                widget.touchMode
                    ? 'playlist_reorder_touch'
                    : 'playlist_reorder',
              ),
              child: !widget.touchMode
                  ? ReorderableDragStartListener(index: index, child: grip)
                  : ReorderableDelayedDragStartListener(
                      index: index,
                      child: grip,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
