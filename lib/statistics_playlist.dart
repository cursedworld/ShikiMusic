import 'listening_statistics.dart';
import 'local_music_catalog.dart';

/// Resolves the ranked snapshot against the current library. Historical
/// titles are for display only; they cannot identify a recording.
({List<int> trackIds, int missing}) resolveStatisticsPlaylist(
  Iterable<StatisticsRank> ranking,
  Iterable<dynamic> library,
) {
  final byKey = <String, int?>{};
  void index(String key, int id) {
    if (!byKey.containsKey(key)) {
      byKey[key] = id;
    } else if (byKey[key] != id) {
      byKey[key] = null; // A shared key does not identify either entry.
    }
  }

  // Use the same effective row for an ID as the playlist renderer.
  final byId = <int, Map>{
    for (final track in library)
      if (track is Map && track['id'] is int) track['id'] as int: track,
  };
  for (final entry in byId.entries) {
    final id = entry.key;
    final track = entry.value;
    if (id < 0) {
      final digest = localTrackDigest(track);
      if (digest != null) index('local:$digest', id);
    } else if (id > 0) {
      index('track:$id', id);
      final source = track['source_id']?.toString().trim() ?? '';
      if (source.isNotEmpty) index('source:$source', id);
    }
  }

  final ids = <int>{};
  var missing = 0;
  for (final rank in ranking) {
    final key = rank.key.startsWith('source:')
        ? 'source:${rank.key.substring('source:'.length).trim()}'
        : rank.key;
    final id = byKey[key];
    if (id == null) {
      missing++;
    } else {
      ids.add(id);
    }
  }
  return (trackIds: ids.toList(growable: false), missing: missing);
}
