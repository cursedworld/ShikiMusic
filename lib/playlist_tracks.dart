/// Resolve saved playlist IDs in insertion order, using current library data.
/// Missing tracks are skipped without removing their IDs from the playlist.
List<dynamic> playlistTracksInOrder(
  Iterable<dynamic> library,
  Iterable<dynamic> trackIds,
) {
  final byId = <int, dynamic>{
    for (final track in library)
      if (track is Map && track['id'] is int) track['id'] as int: track,
  };
  final seen = <int>{};
  return [
    for (final id in trackIds)
      if (id is int && seen.add(id) && byId.containsKey(id)) byId[id],
  ];
}

/// Reorder visible rows without moving hidden or temporarily missing IDs.
/// [newIndex] follows Flutter's ReorderableListView insertion-index contract.
List<dynamic> reorderPlaylistTracks(
  List<dynamic> savedIds,
  List<int> visibleIds,
  int oldIndex,
  int newIndex,
) {
  final result = List<dynamic>.from(savedIds);
  if (oldIndex < 0 ||
      oldIndex >= visibleIds.length ||
      newIndex < 0 ||
      newIndex > visibleIds.length ||
      visibleIds.toSet().length != visibleIds.length) {
    return result;
  }
  final visible = visibleIds.toSet();
  final slots = <int>[
    for (var i = 0; i < savedIds.length; i++)
      if (visible.contains(savedIds[i])) i,
  ];
  // Reject stale drag callbacks after membership/order changed during a drag.
  if (slots.length != visibleIds.length) return result;
  for (var i = 0; i < slots.length; i++) {
    if (savedIds[slots[i]] != visibleIds[i]) return result;
  }
  final reordered = List<int>.from(visibleIds);
  final moved = reordered.removeAt(oldIndex);
  reordered.insert(newIndex > oldIndex ? newIndex - 1 : newIndex, moved);
  for (var i = 0; i < slots.length; i++) {
    result[slots[i]] = reordered[i];
  }
  return result;
}

/// Keep queue membership and metadata, changing only playlist-owned positions.
List<dynamic> playlistQueueInOrder(
  List<dynamic> queue,
  List<dynamic> savedIds,
) {
  final rank = <dynamic, int>{
    for (var i = 0; i < savedIds.length; i++) savedIds[i]: i,
  };
  final slots = <int>[
    for (var i = 0; i < queue.length; i++)
      if (rank.containsKey(queue[i]['id'])) i,
  ];
  final ordered = [for (final i in slots) queue[i]]
    ..sort((a, b) => rank[a['id']]!.compareTo(rank[b['id']]!));
  final result = List<dynamic>.from(queue);
  for (var i = 0; i < slots.length; i++) {
    result[slots[i]] = ordered[i];
  }
  return result;
}
