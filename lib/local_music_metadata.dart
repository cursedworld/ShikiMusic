import 'dart:convert';

import 'package:crypto/crypto.dart';

String localMusicServerKey(Uri base) =>
    sha256.convert(utf8.encode(base.toString())).toString();

String _normalized(Object? text) => (text?.toString() ?? '')
    .trim()
    .toLowerCase()
    .replaceAll('ё', 'е')
    .replaceAll(RegExp(r'\s+'), ' ');

String _tag(Object? value, [int limit = 1024]) =>
    value is String && value.length <= limit ? value.trim() : '';

/// A cached description of a verified recording, never an audio URL.
/// Server references have meaning only on the server that matched it.
class LocalMusicMetadata {
  const LocalMusicMetadata._({
    required this.serverKey,
    required this.title,
    required this.artists,
    required this.album,
    required this.lyrics,
    required this.sourceId,
    required this.trackId,
    required this.cover,
    required this.video,
  });

  final String serverKey, title, album, lyrics, sourceId, cover, video;
  final List<String> artists;
  final int? trackId;

  static LocalMusicMetadata? decode(Object? value, {String? serverKey}) {
    if (value is! Map) return null;
    final key = serverKey ?? _tag(value['server_key'], 64);
    final title = _tag(value['title']);
    final names = value['artists'];
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key) ||
        title.isEmpty ||
        names is! List ||
        names.isEmpty ||
        names.length > 24) {
      return null;
    }
    final artists = names.map(_tag).toSet().toList();
    if (artists.any((name) => name.isEmpty)) return null;
    const maxLyricsBytes = 256 * 1024;
    final text = value['lyrics'];
    final lyrics =
        text is String &&
            text.length <= maxLyricsBytes &&
            utf8.encode(text).length <= maxLyricsBytes
        ? text
        : '';
    final id = value['track_id'];
    return LocalMusicMetadata._(
      serverKey: key,
      title: title,
      artists: List.unmodifiable(artists),
      album: _tag(value['album']),
      lyrics: lyrics,
      sourceId: _tag(value['source_id'], 200),
      trackId: id is int && id > 0 ? id : null,
      cover: _tag(value['cover'], 2048),
      video: _tag(value['video'], 2048),
    );
  }

  Map<String, Object?> toJson() => {
    'server_key': serverKey,
    'title': title,
    'artists': artists,
    'album': album,
    if (lyrics.isNotEmpty) 'lyrics': lyrics,
    if (sourceId.isNotEmpty) 'source_id': sourceId,
    if (trackId != null) 'track_id': trackId,
    if (cover.isNotEmpty) 'cover': cover,
    if (video.isNotEmpty) 'video': video,
  };

  bool matchesCatalogRow(Map row, int duration) {
    if (sourceId.isNotEmpty) return row['source_id'] == sourceId;
    if (trackId == null ||
        row['id'] != trackId ||
        _normalized(row['title']) != _normalized(title)) {
      return false;
    }
    final seconds = row['duration'];
    if (seconds is! int || duration <= 0 || (seconds - duration).abs() > 3) {
      return false;
    }
    final album = row['album'];
    if (album is! Map ||
        _normalized(album['title']) != _normalized(this.album)) {
      return false;
    }
    final credits = row['artists'];
    final names = {
      if (album['artist'] case final Map artist) _normalized(artist['name']),
      if (credits is List)
        for (final credit in credits.whereType<Map>())
          _normalized(credit['name']),
    };
    return artists.every((name) => names.contains(_normalized(name)));
  }
}

/// Relative media routes stay on the configured server. Only the two lookup
/// artwork providers are accepted as external URLs; clips stay on Django.
String localMatchMediaUrl(
  Uri? base,
  Object? value, {
  bool externalArtwork = false,
}) {
  if (base == null || value is! String || value.isEmpty) return '';
  final raw = Uri.tryParse(value);
  if (raw == null) return '';
  final uri = base.resolveUri(raw);
  if ((uri.scheme != 'http' && uri.scheme != 'https') ||
      !uri.hasAuthority ||
      uri.userInfo.isNotEmpty) {
    return '';
  }
  if (uri.origin == base.origin) return uri.toString();
  if (externalArtwork &&
      uri.scheme == 'https' &&
      (uri.host == 'i.ytimg.com' || uri.host.endsWith('.mzstatic.com'))) {
    return uri.toString();
  }
  return '';
}
