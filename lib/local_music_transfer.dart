import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'local_music_catalog.dart';
import 'lyric_timing.dart' show lyricTimingLimit;

const portableLocalOffsets = 'local_lyric_offsets.json';
const savedLyricOffsets = 'lyric_offsets.json';

typedef LocalMusicMerge = ({
  List<LocalMusicEntry> entries,
  Map<int, int> aliases,
});

LocalMusicMerge mergeLocalMusic(
  List<LocalMusicEntry> destination,
  List<LocalMusicEntry> incoming,
) {
  final byDigest = {for (final entry in destination) entry.digest: entry};
  final used = {for (final entry in destination) entry.id};
  final aliases = <int, int>{};
  for (final song in incoming) {
    final old = byDigest[song.digest];
    final id =
        old?.id ??
        (used.add(song.id) ? song.id : allocateLocalTrackId(song.digest, used));
    aliases[song.id] = id;
    byDigest[song.digest] = (old ?? song).withIdAndLyrics(
      id,
      old != null && old.lyrics.isNotEmpty ? old.lyrics : song.lyrics,
    );
  }
  return (entries: byDigest.values.toList(), aliases: aliases);
}

List<dynamic> readOffsetRows(dynamic data) {
  if (data is! Map ||
      data['version'] != 1 ||
      data['offsets'] is! List ||
      (data['offsets'] as List).length > 100000) {
    throw const FormatException('Invalid lyric timing data');
  }
  return data['offsets'] as List;
}

bool isPortableOffset(dynamic row) =>
    row is Map &&
    isLocalId(row['track_id']) &&
    isLocalDigest(row['audio_sha256']) &&
    isLocalDigest(row['lrc_sha256']) &&
    row['advance_ms'] is int &&
    row['advance_ms'] != 0 &&
    (row['advance_ms'] as int).abs() <= lyricTimingLimit;

/// Only export/rebind corrections for the exact lyric contents in the archive.
/// Older LRC versions stay on the device where they were made.
List<Map> compatibleLocalOffsets(
  Iterable<dynamic> offsets,
  Iterable<LocalMusicEntry> entries,
) {
  final byId = {for (final entry in entries) entry.id: entry};
  final textHashes = <int, String>{};
  return [
    for (final dynamic row in offsets)
      if (isPortableOffset(row))
        if (byId[row['track_id']] case final entry?)
          if (entry.digest == row['audio_sha256'] &&
              entry.preferredLyrics.isNotEmpty &&
              textHashes.putIfAbsent(
                    entry.id,
                    () => sha256
                        .convert(utf8.encode(entry.preferredLyrics))
                        .toString(),
                  ) ==
                  row['lrc_sha256'])
            row as Map,
  ];
}

Map<String, Object> offsetDocument(List<dynamic> rows) => {
  'version': 1,
  'offsets': rows,
};

List<dynamic> mergeLocalOffsets({
  required Iterable<dynamic> destination,
  required Iterable<dynamic> incoming,
  required LocalMusicMerge merged,
}) {
  (Object?, Object?, Object?) key(Map row) =>
      (row['track_id'], row['audio_sha256'], row['lrc_sha256']);
  final seen = {for (final item in destination.whereType<Map>()) key(item)};
  final remapped = [
    for (final row in incoming.whereType<Map>())
      if (merged.aliases[row['track_id']] case final id?)
        {...row, 'track_id': id},
  ];
  return [
    ...destination,
    for (final row in compatibleLocalOffsets(remapped, merged.entries))
      if (seen.add(key(row))) row,
  ];
}
