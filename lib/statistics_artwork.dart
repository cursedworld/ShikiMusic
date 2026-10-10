import 'package:flutter/painting.dart';

import 'globals.dart';
import 'listening_statistics.dart';

/// Joins historical identities to existing library artwork, without downloads.
class StatisticsArtwork {
  StatisticsArtwork({
    Iterable<dynamic> tracks = const [],
    Iterable<dynamic> artists = const [],
  }) {
    for (final track in tracks) {
      if (track is! Map || track['id'] is! int) continue;
      _tracks['track:${track['id']}'] = track;
      final source = track['source_id']?.toString().trim() ?? '';
      if (source.isNotEmpty) _tracks['source:$source'] = track;
      final credits = track['artists'];
      if (credits is List) {
        for (final artist in credits) {
          _addArtist(artist);
        }
      }
      final album = track['album'];
      if (album is Map) _addArtist(album['artist']);
    }
    for (final artist in artists) {
      _addArtist(artist);
    }
  }

  final _tracks = <String, Map>{};
  final _artists = <String, Map>{};
  final _resolved = <String, ImageProvider?>{};

  void _addArtist(dynamic artist) {
    if (artist is! Map) return;
    final name = artist['name']?.toString().trim() ?? '';
    final key = artist['id'] == null
        ? 'name:${name.toLowerCase()}'
        : 'artist:${artist['id']}';
    _artists[key] = {...?_artists[key], ...artist};
  }

  ImageProvider? forRank(StatisticsRank rank, {required bool artist}) {
    final key = '${artist ? 'artist' : 'track'}:${rank.key}';
    if (_resolved.containsKey(key)) return _resolved[key];
    final data = (artist ? _artists : _tracks)[rank.key];
    ImageProvider? provider;
    if (data != null) {
      try {
        provider = artist
            ? getArtistPhotoProvider(data)
            : getPictureProvider(data);
      } catch (_) {
        // A removed/corrupt local image must not break historical statistics.
      }
    }
    // Do not fetch remote artwork just because a statistics page was opened.
    return _resolved[key] = provider is FileImage ? provider : null;
  }
}
