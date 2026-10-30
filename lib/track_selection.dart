import 'dart:collection';

/// Ephemeral selection by stable ID; never changes playback or playlist order.
class TrackSelection {
  final Set<int> _ids = {};
  int? _anchor;

  Set<int> get ids => UnmodifiableSetView(_ids);
  bool get isNotEmpty => _ids.isNotEmpty;
  bool contains(int id) => _ids.contains(id);

  void clear({int? anchor}) {
    _ids.clear();
    _anchor = anchor;
  }

  void toggle(int id) {
    if (!_ids.add(id)) _ids.remove(id);
    _anchor = id;
  }

  void retain(Iterable<int> visibleIds) {
    final visible = visibleIds.toSet();
    _ids.retainAll(visible);
    if (!visible.contains(_anchor)) _anchor = null;
  }

  void removeAll(Iterable<int> ids) {
    _ids.removeAll(ids);
    if (!_ids.contains(_anchor)) _anchor = null;
  }

  /// True means selection consumed the tap; false preserves ordinary playback.
  bool tap(
    int id,
    List<int> visibleIds, {
    bool control = false,
    bool shift = false,
    bool touch = false,
  }) {
    if (!visibleIds.contains(id)) return true;
    if (shift) {
      final target = visibleIds.indexOf(id);
      final anchor = visibleIds.indexOf(_anchor ?? id);
      final start = anchor < 0 ? target : anchor;
      if (!control) _ids.clear();
      _ids.addAll(
        visibleIds.sublist(
          start < target ? start : target,
          (start > target ? start : target) + 1,
        ),
      );
      if (_anchor == null || anchor < 0) _anchor = id;
      return true;
    }
    if (control || (touch && _ids.isNotEmpty)) {
      toggle(id);
      return true;
    }
    clear(anchor: id);
    return false;
  }

  List<dynamic> inOrder(Iterable<dynamic> tracks) => [
    for (final track in tracks)
      if (track is Map && _ids.contains(track['id'])) track,
  ];

  /// A button on an unselected row still affects only that row.
  List<dynamic> actionTargets(dynamic clicked, List<dynamic> visibleTracks) =>
      contains(clicked['id'] as int) ? inOrder(visibleTracks) : [clicked];
}
