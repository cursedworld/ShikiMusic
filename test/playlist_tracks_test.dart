import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/playlist_tracks.dart';

void main() {
  final library = [
    {'id': 1, 'title': 'First imported'},
    {'id': 2, 'title': 'Second imported'},
    {'id': 3, 'title': 'Third imported'},
  ];

  List<int> ids(List<dynamic> tracks) => [
    for (final track in tracks) track['id'] as int,
  ];

  test('playlist insertion order overrides library import order', () {
    expect(ids(playlistTracksInOrder(library, [3, 1, 2])), [3, 1, 2]);
    expect(ids(library), [1, 2, 3]);
  });

  test('order survives saving and restoring playlist JSON', () {
    final playlist =
        jsonDecode(
              jsonEncode({
                'tracks': [2, 3, 1],
              }),
            )
            as Map;
    expect(ids(playlistTracksInOrder(library, playlist['tracks'])), [2, 3, 1]);
  });

  test('removing then adding a track puts it at the end', () {
    final saved = [3, 1, 2]
      ..remove(1)
      ..add(1);
    expect(ids(playlistTracksInOrder(library, saved)), [3, 2, 1]);
  });

  test('missing tracks are skipped but kept in saved playlist order', () {
    final saved = [3, 999, 1];
    expect(ids(playlistTracksInOrder(library, saved)), [3, 1]);
    expect(saved, [3, 999, 1]);
    final refreshed = [
      ...library,
      {'id': 999, 'title': 'Restored'},
    ];
    expect(ids(playlistTracksInOrder(refreshed, saved)), [3, 999, 1]);
  });

  test(
    'refreshed metadata and changed library sorting retain playlist order',
    () {
      final fresh = [
        {'id': 3, 'title': 'Updated title'},
        library[1],
        library[0],
      ];
      final result = playlistTracksInOrder(fresh, [2, 3, 1]);
      expect(ids(result), [2, 3, 1]);
      expect(result[1], same(fresh[0]));
      expect(result[1]['title'], 'Updated title');
    },
  );

  test(
    'filtering preserves relative insertion order for the playback queue',
    () {
      final result = playlistTracksInOrder(library, [
        3,
        2,
        1,
      ]).where((track) => track['id'] != 2).toList();
      expect(ids(result), [3, 1]);
    },
  );

  test('empty, duplicated and malformed IDs never add extra rows', () {
    expect(playlistTracksInOrder(library, []), isEmpty);
    expect(playlistTracksInOrder([], [1, 2]), isEmpty);
    expect(ids(playlistTracksInOrder(library, [3, 3, null, '2', 1])), [3, 1]);
  });
}
