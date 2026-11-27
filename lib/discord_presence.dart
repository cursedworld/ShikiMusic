import 'dart:async';

import 'package:flutter_discord_rpc/flutter_discord_rpc.dart';

/// Orders local Discord IPC operations. Track data is built only after the
/// current privacy check and is never captured for a later reconnect.
class DiscordPresencePublisher {
  DiscordPresencePublisher({
    required this.canPublish,
    required this.buildActivity,
    required this.cancelArtwork,
    required this.connect,
    required this.setActivity,
    required this.clearActivity,
    required this.disconnect,
    this.onError,
  });

  final bool Function() canPublish;
  final RPCActivity Function() buildActivity;
  final void Function() cancelArtwork;
  final Future<void> Function() connect;
  final Future<void> Function(RPCActivity) setActivity;

  /// Clears this app's activity. Returns whether the connection stayed open.
  final Future<bool> Function() clearActivity;
  final Future<void> Function() disconnect;
  final void Function(Object)? onError;

  static const _updateInterval = Duration(milliseconds: 1500);
  static const _reconnectDelay = Duration(seconds: 5);
  Future<void> _tail = Future<void>.value();
  Timer? _throttle;
  DateTime? _lastSentAt;
  DateTime? _retryAt;
  bool _visible = false;
  bool _connected = false;
  bool _mayHaveActivity = false;
  bool _closed = false;
  int _revision = 0;

  Future<void> get idle => _tail;

  void refresh({bool force = false, bool clearBeforePublish = false}) {
    if (_closed) return;
    if (!canPublish()) {
      if (_visible) _hide();
      return;
    }
    final newlyVisible = !_visible;
    _visible = true;
    final revision = ++_revision;
    final last = _lastSentAt;
    final delay = last == null
        ? Duration.zero
        : _updateInterval - DateTime.now().difference(last);
    void schedule() => _queue(() => _publish(revision, clearBeforePublish));

    _throttle?.cancel();
    if (force || newlyVisible || delay <= Duration.zero) {
      schedule();
    } else {
      _throttle = Timer(delay, schedule);
    }
  }

  void _hide() {
    _visible = false;
    _revision++;
    _throttle?.cancel();
    cancelArtwork();
    _queue(_clearPublished);
  }

  bool _isCurrent(int revision) =>
      !_closed && revision == _revision && canPublish();

  void _queue(Future<void> Function() action) {
    _tail = _tail.then((_) => action()).catchError((Object error) {
      onError?.call(error);
    });
  }

  Future<void> _publish(int revision, bool clearFirst) async {
    if (!_isCurrent(revision)) return;
    if (clearFirst) await _clearPublished();
    if (!_isCurrent(revision)) return;
    if (!_connected) {
      final retryAt = _retryAt;
      if (retryAt != null && DateTime.now().isBefore(retryAt)) return;
      try {
        await connect();
        _connected = true;
        _retryAt = null;
      } catch (error) {
        _retryAt = DateTime.now().add(_reconnectDelay);
        onError?.call(error);
        return;
      }
    }
    if (!_isCurrent(revision)) return;
    final activity = buildActivity();
    if (!_isCurrent(revision)) return;
    _lastSentAt = DateTime.now();
    _mayHaveActivity = true;
    try {
      await setActivity(activity);
    } catch (error) {
      onError?.call(error);
      await _closeConnection();
      // A later refresh reconnects and builds the *current* track, not this one.
    }
  }

  Future<void> _clearPublished() async {
    if (!_connected || !_mayHaveActivity) return;
    try {
      // https://docs.discord.com/developers/topics/rpc#set_activity
      _connected = await clearActivity();
      _mayHaveActivity = false;
    } catch (error) {
      onError?.call(error);
      await _closeConnection();
    }
  }

  Future<void> _closeConnection() async {
    if (!_connected) return;
    try {
      await disconnect();
    } finally {
      _connected = false;
      _mayHaveActivity = false;
    }
  }

  Future<void> close() {
    if (_closed) return _tail;
    if (_visible) _hide();
    _closed = true;
    _queue(_closeConnection);
    return _tail;
  }
}
