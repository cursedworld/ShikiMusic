import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Playback shortcuts must not steal text input or dialog button activation.
bool handlePlaybackSpace(KeyEvent event, {required VoidCallback onToggle}) {
  if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.space) {
    return false;
  }
  final context = FocusManager.instance.primaryFocus?.context;
  if (context != null &&
      (context.widget is EditableText ||
          context.findAncestorWidgetOfExactType<EditableText>() != null ||
          ModalRoute.of(context) is PopupRoute)) {
    return false;
  }
  onToggle();
  return true;
}
