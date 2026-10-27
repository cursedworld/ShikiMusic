import 'package:flutter/material.dart';

import '../globals.dart';
import '../localization.dart';
import '../mobile_motion.dart';

class MobilePlaybackControls extends StatelessWidget {
  const MobilePlaybackControls({
    super.key,
    required this.isFavorite,
    required this.isPlaying,
    required this.loopMode,
    required this.isShuffled,
    required this.onFavorite,
    required this.onPrevious,
    required this.onPlayPause,
    required this.onNext,
    required this.onRepeat,
    required this.onShuffle,
  });

  final bool isFavorite, isPlaying, isShuffled;
  final LoopMode loopMode;
  final VoidCallback onFavorite,
      onPrevious,
      onPlayPause,
      onNext,
      onRepeat,
      onShuffle;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 296,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          key: const ValueKey('mobile_shuffle'),
          tooltip: tr(
            isShuffled ? 'shuffle_on_tooltip' : 'shuffle_off_tooltip',
          ),
          isSelected: isShuffled,
          icon: Icon(
            Icons.shuffle,
            color: isShuffled ? Colors.redAccent : Colors.white38,
            size: 22,
          ),
          onPressed: onShuffle,
        ),
        IconButton(
          tooltip: tr(
            isFavorite ? 'taskbar_favorite_remove' : 'taskbar_favorite_add',
          ),
          icon: Icon(
            isFavorite ? Icons.favorite : Icons.favorite_border,
            color: isFavorite ? Colors.redAccent : Colors.white38,
            size: 22,
          ),
          onPressed: onFavorite,
        ),
        IconButton(
          tooltip: tr('taskbar_previous'),
          icon: const Icon(
            Icons.skip_previous_rounded,
            color: Colors.white,
            size: 28,
          ),
          onPressed: onPrevious,
        ),
        IconButton(
          tooltip: tr(isPlaying ? 'taskbar_pause' : 'taskbar_play'),
          icon: AnimatedSwitcher(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : mobileControlTransition,
            child: Icon(
              isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
              key: ValueKey(isPlaying),
              color: Colors.white,
              size: 40,
            ),
          ),
          onPressed: onPlayPause,
        ),
        IconButton(
          tooltip: tr('taskbar_next'),
          icon: const Icon(
            Icons.skip_next_rounded,
            color: Colors.white,
            size: 28,
          ),
          onPressed: onNext,
        ),
        IconButton(
          key: const ValueKey('mobile_repeat'),
          tooltip: tr(switch (loopMode) {
            LoopMode.off => 'repeat_off',
            LoopMode.list => 'repeat_queue',
            LoopMode.one => 'repeat_track',
          }),
          isSelected: loopMode != LoopMode.off,
          icon: Icon(
            loopMode == LoopMode.one ? Icons.repeat_one : Icons.repeat,
            color: loopMode == LoopMode.off ? Colors.white38 : Colors.redAccent,
            size: 24,
          ),
          onPressed: onRepeat,
        ),
      ],
    ),
  );
}
