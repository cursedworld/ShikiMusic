/// Album imports are explicit YouTube playlists. Ordinary song URLs and search
/// phrases keep the single-track flow.
bool isSupportedAlbumLink(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
    return false;
  }
  final host = uri.host.toLowerCase();
  final isYouTube =
      host == 'youtube.com' ||
      host.endsWith('.youtube.com') ||
      host == 'youtu.be';
  return isYouTube && (uri.queryParameters['list']?.trim().isNotEmpty ?? false);
}

int? downloadTrackId(dynamic track) {
  if (track is! Map) return null;
  final value = track['id'];
  final id = value is int ? value : int.tryParse(value?.toString() ?? '');
  return id != null && id > 0 ? id : null;
}

/// Keep album ownership separate from the full performer credit.
String trackArtistLabel(dynamic track, {String fallback = 'Unknown'}) {
  if (track is! Map) return fallback;
  final album = track['album'];
  final primary = album is Map ? album['artist'] : null;
  final credited = track['artists'];
  final names = <String>[];
  final seen = <String>{};
  for (final artist in [
    if (primary is Map) primary,
    if (credited is List) ...credited.whereType<Map>(),
  ]) {
    final name = artist['name']?.toString().trim() ?? '';
    if (name.isNotEmpty && seen.add(_normalizeSearch(name))) names.add(name);
  }
  return names.isEmpty ? fallback : names.join(', ');
}

bool lyricsLookupUnchanged(
  dynamic track, {
  required String artists,
  required String title,
  required int duration,
  required String originalLyrics,
}) =>
    track is Map &&
    track['title']?.toString() == title &&
    trackArtistLabel(track) == artists &&
    (int.tryParse(track['duration']?.toString() ?? '') ?? 0) == duration &&
    (track['lyrics']?.toString() ?? '') == originalLyrics;

/// Provider credits may omit guests, but never name an unrelated performer.
/// Timed lyrics also require a matching recording length.
String validatedLyricsText(
  dynamic data, {
  required String artists,
  required String title,
  required int duration,
}) {
  if (data is! Map ||
      _normalizeSearch(data['trackName']?.toString() ?? '') !=
          _normalizeSearch(title)) {
    return '';
  }
  List<String> credits(String value) => value
      .split(
        RegExp(
          r'\s*[,;&]\s*|\s+(?:feat\.?|ft\.?|featuring|with|x)\s+',
          caseSensitive: false,
        ),
      )
      .map(_normalizeSearch)
      .where((name) => name.isNotEmpty)
      .toList();
  final expected = credits(artists);
  final actual = credits(data['artistName']?.toString() ?? '');
  if (expected.isEmpty ||
      !actual.contains(expected.first) ||
      !actual.every(expected.contains)) {
    return '';
  }
  final providerDuration = data['duration'];
  if (duration > 0 && providerDuration is num && providerDuration > 0) {
    if ((providerDuration - duration).abs() > 3) return '';
    final synced = data['syncedLyrics'];
    if (synced is String && synced.trim().isNotEmpty) return synced;
  }
  final plain = data['plainLyrics'];
  return plain is String ? plain : '';
}

bool matchesTrackSearch(dynamic track, String query) {
  final normalizedQuery = _normalizeSearch(query);
  if (normalizedQuery.isEmpty) return true;
  if (track is! Map) return false;
  final album = track['album'];
  final artist = album is Map ? album['artist'] : null;
  final artists = track['artists'];
  final values = <String>[
    track['title']?.toString() ?? '',
    if (album is Map) album['title']?.toString() ?? '',
    if (artist is Map) artist['name']?.toString() ?? '',
    if (artists is List)
      ...artists.whereType<Map>().map((item) => item['name']?.toString() ?? ''),
  ];
  final text = _normalizeSearch(values.join(' '));
  return normalizedQuery.split(' ').every(text.contains);
}

/// Shared canonical text matching; never use substring artist matching.
String normalizeMusicSearch(String value) => _normalizeSearch(value);

String _normalizeSearch(String value) {
  final words = value
      .toLowerCase()
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'[\s\-–—_,.:;!/?()\[\]{}&]+'), ' ')
      .trim()
      .split(' ');
  const numbers = {
    'ноль': 0,
    'один': 1,
    'два': 2,
    'три': 3,
    'четыре': 4,
    'пять': 5,
    'шесть': 6,
    'семь': 7,
    'восемь': 8,
    'девять': 9,
    'десять': 10,
    'одиннадцать': 11,
    'двенадцать': 12,
    'тринадцать': 13,
    'четырнадцать': 14,
    'пятнадцать': 15,
    'шестнадцать': 16,
    'семнадцать': 17,
    'восемнадцать': 18,
    'девятнадцать': 19,
    'двадцать': 20,
    'тридцать': 30,
    'сорок': 40,
    'пятьдесят': 50,
    'шестьдесят': 60,
    'семьдесят': 70,
    'восемьдесят': 80,
    'девяносто': 90,
    'сто': 100,
    'двести': 200,
    'триста': 300,
    'четыреста': 400,
    'пятьсот': 500,
    'шестьсот': 600,
    'семьсот': 700,
    'восемьсот': 800,
    'девятьсот': 900,
  };
  final result = <String>[];
  int? number;
  var previous = 1000;
  for (final word in words) {
    final part = numbers[word];
    if (part != null &&
        (number == null || (part < previous && previous >= 20))) {
      number = (number ?? 0) + part;
      previous = part;
      continue;
    }
    if (number != null) {
      result.add('$number');
      number = null;
      previous = 1000;
    }
    if (part == null) {
      result.add(word);
    } else {
      number = part;
      previous = part;
    }
  }
  if (number != null) result.add('$number');
  return result.join(' ');
}
