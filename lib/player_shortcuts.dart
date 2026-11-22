import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Lets inline controls receive Space without also toggling playback.
class PlaybackShortcutScope extends InheritedWidget {
  const PlaybackShortcutScope({super.key, required super.child});

  @override
  bool updateShouldNotify(PlaybackShortcutScope oldWidget) => false;
}

/// Playback shortcuts must not steal text input or button activation.
bool handlePlaybackSpace(KeyEvent event, {required VoidCallback onToggle}) {
  if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.space) {
    return false;
  }
  final context = FocusManager.instance.primaryFocus?.context;
  if (context != null &&
      (context.widget is EditableText ||
          context.findAncestorWidgetOfExactType<EditableText>() != null ||
          context.getInheritedWidgetOfExactType<PlaybackShortcutScope>() !=
              null ||
          ModalRoute.of(context) is PopupRoute)) {
    return false;
  }
  onToggle();
  return true;
}
