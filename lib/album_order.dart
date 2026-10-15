/// Album numbering affects album views only, never playlist insertion order.
List<T> albumTrackOrder<T>(Iterable<T> tracks) {
  final indexed = tracks.toList().asMap().entries.toList();
  int? number(dynamic track, String key) {
    final value = track is Map ? track[key] : null;
    return value is int && value > 0 ? value : null;
  }

  indexed.sort((a, b) {
    final an = number(a.value, 'track_number');
    final bn = number(b.value, 'track_number');
    if (an == null || bn == null) {
      if (an != bn) return an == null ? 1 : -1;
      return a.key.compareTo(b.key);
    }
    final disc = (number(a.value, 'disc_number') ?? 1).compareTo(
      number(b.value, 'disc_number') ?? 1,
    );
    if (disc != 0) return disc;
    final track = an.compareTo(bn);
    return track != 0 ? track : a.key.compareTo(b.key);
  });
  return indexed.map((entry) => entry.value).toList();
}
