import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/listening_statistics.dart';
import 'package:shiki/statistics_artwork.dart';

void main() {
  late Directory directory;
  late String oldPath;
  const rank = StatisticsRank('Song', '', 60000, 1, key: 'source:youtube:one');
  const artistRank = StatisticsRank('Artist', '', 60000, 1, key: 'artist:7');
  final artist = {
    'id': 7,
    'name': 'Artist',
    'photo': 'https://example.invalid/artist.jpg',
  };
  final track = {
    'id': 1,
    'source_id': 'youtube:one',
    'title': 'Song',
    'album': {'cover': 'https://example.invalid/cover.jpg', 'artist': artist},
    'artists': [artist],
  };

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shiki-stats-artwork-');
    oldPath = globalLocalPath;
    globalLocalPath = directory.path;
    clearCoverCache();
  });
  tearDown(() async {
    globalLocalPath = oldPath;
    clearCoverCache();
    final prefix =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}shiki-stats-artwork-';
    if (!directory.absolute.path.startsWith(prefix)) {
      throw StateError('Unexpected test directory');
    }
    await directory.delete(recursive: true);
  });

  test('uses exact source identity and existing local art only', () async {
    final cover = File('${directory.path}/cover_1.jpg');
    await cover.writeAsBytes([1, 2, 3]);
    final photo = File('${directory.path}/artist_7.jpg');
    await photo.writeAsBytes([1, 2, 3]);
    final artwork = StatisticsArtwork(tracks: [track], artists: [artist]);
    expect(
      (artwork.forRank(rank, artist: false) as FileImage).file.path,
      cover.path,
    );
    expect(
      (artwork.forRank(artistRank, artist: true) as FileImage).file.path,
      photo.path,
    );
    expect(
      artwork.forRank(
        const StatisticsRank('Song', '', 0, 0, key: 'track:2'),
        artist: false,
      ),
      isNull,
    );
    expect(
      artwork.forRank(const StatisticsRank('Song', '', 0, 0), artist: false),
      isNull,
    );
  });

  test('missing and remote-only art does not return a network provider', () {
    final artwork = StatisticsArtwork(tracks: [track], artists: [artist]);
    expect(artwork.forRank(rank, artist: false), isNull);
    expect(artwork.forRank(artistRank, artist: true), isNull);
  });
}
