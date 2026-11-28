import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/listening_statistics.dart';
import 'package:shiki/statistics_playlist.dart';

StatisticsRank _rank(String key) =>
    StatisticsRank('Same title', '', 60000, 1, key: key);

void main() {
  test('resolves catalog, local MP3 and legacy keys in ranking order', () {
    final ownKey = 'local:${'a' * 64}';
    final library = [
      {'id': 1, 'source_id': 'youtube:second', 'title': 'Same title'},
      {'id': 2, 'source_id': 'youtube:first', 'title': 'Renamed on server'},
      {'id': -7, 'local_key': ownKey, 'title': 'A local recording'},
      {'id': 8, 'title': 'Old title'},
    ];
    final result = resolveStatisticsPlaylist([
      _rank('source: youtube:first '),
      _rank(ownKey),
      _rank('track:8'),
      _rank('source:youtube:second'),
    ], library);

    expect(result.trackIds, [2, -7, 8, 1]);
    expect(result.missing, 0);
  });

  test('deduplicates aliases without looking up missing records by title', () {
    final result = resolveStatisticsPlaylist(
      [
        _rank('track:42'),
        _rank('source:youtube:gone'),
        _rank('source:youtube:still-here'),
        _rank('local:${'b' * 64}'),
      ],
      [
        {'id': 42, 'source_id': 'youtube:still-here', 'title': 'Same title'},
        {'id': 43, 'title': 'Same title'},
      ],
    );

    expect(result.trackIds, [42]);
    expect(result.missing, 2);
  });

  test(
    'skips ambiguous sources and returns an empty list if no track fits',
    () {
      final result = resolveStatisticsPlaylist(
        [_rank('source:youtube:duplicate'), _rank('track:9')],
        [
          {'id': 1, 'source_id': 'youtube:duplicate'},
          {'id': 2, 'source_id': 'youtube:duplicate'},
          {'id': 6, 'title': 'Same title'},
        ],
      );

      expect(result.trackIds, isEmpty);
      expect(result.missing, 2);
    },
  );
}
