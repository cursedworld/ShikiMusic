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
