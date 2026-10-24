import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Event-driven Windows thumbnail controls. No polling or progress timer.
class WindowsTaskbarControls {
  WindowsTaskbarControls({
    required this.onAction,
    MethodChannel channel = const MethodChannel('shiki/taskbar_controls'),
    bool? supported,
  }) : _channel = channel,
       _supported = supported ?? Platform.isWindows {
    if (_supported) _channel.setMethodCallHandler(_handleCall);
  }

  final FutureOr<void> Function(String action) onAction;
  final MethodChannel _channel;
  final bool _supported;
  bool _disposed = false;
  bool _hasTrack = false;
  String? _lastState;

  Future<void> _handleCall(MethodCall call) async {
    if (_disposed ||
        !_hasTrack ||
        call.method != 'action' ||
        !const [
          'favorite',
          'previous',
          'toggle',
          'next',
        ].contains(call.arguments)) {
      return;
    }
    await onAction(call.arguments as String);
  }

  Future<void> update({
    required bool hasTrack,
    required bool playing,
    required bool favorite,
    required String favoriteTip,
    required String previousTip,
    required String playPauseTip,
    required String nextTip,
  }) async {
    if (!_supported || _disposed) return;
    _hasTrack = hasTrack;
    final state = <String, Object>{
      'hasTrack': hasTrack,
      'playing': hasTrack && playing,
      'favorite': hasTrack && favorite,
      'favoriteTip': favoriteTip,
      'previousTip': previousTip,
      'playPauseTip': playPauseTip,
      'nextTip': nextTip,
    };
    final signature = jsonEncode(state);
    if (signature == _lastState) return;
    _lastState = signature;
    try {
      await _channel.invokeMethod<void>('update', state);
    } on MissingPluginException {
      if (_lastState == signature) _lastState = null;
    } on PlatformException {
      if (_lastState == signature) _lastState = null;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_supported) _channel.setMethodCallHandler(null);
  }
}
