import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/screens/home_screen.dart';
import 'package:shiki/track_selection.dart';

void main() {
  test(
    'Ctrl toggles tracks without playing; ordinary click clears selection',
    () {
      final selection = TrackSelection();
      expect(selection.tap(2, [1, 2, 3], control: true), isTrue);
      expect(selection.tap(3, [1, 2, 3], control: true), isTrue);
      expect(selection.ids, {2, 3});
      selection.tap(2, [1, 2, 3], control: true);
      expect(selection.ids, {3});
      expect(selection.tap(1, [1, 2, 3]), isFalse);
      expect(selection.ids, isEmpty);
    },
  );

  test(
    'Shift follows displayed order, supports backward range and Ctrl union',
    () {
      final selection = TrackSelection();
      selection.tap(4, [4, 2, 3, 1], control: true);
      selection.tap(3, [4, 2, 3, 1], shift: true);
      expect(selection.ids, {4, 2, 3});
      selection.tap(2, [4, 2, 3, 1], shift: true);
      expect(selection.ids, {4, 2});
      selection.tap(1, [4, 2, 3, 1], control: true);
      selection.tap(3, [4, 2, 3, 1], shift: true, control: true);
      expect(selection.ids, {4, 2, 1, 3});
      expect(selection.tap(999, [4, 2, 3, 1], shift: true), isTrue);
      expect(selection.ids, {4, 2, 1, 3});
    },
  );

  test('touch taps toggle selection only after a hold started selection', () {
    final selection = TrackSelection();
    expect(selection.tap(1, [1, 2, 3], touch: true), isFalse);
    selection.toggle(1);
    expect(selection.tap(3, [1, 2, 3], touch: true), isTrue);
    expect(selection.ids, {1, 3});
    selection.tap(1, [1, 2, 3], touch: true);
    expect(selection.ids, {3});
  });

  test('an initial Shift click establishes an anchor for the next range', () {
    final selection = TrackSelection();
    selection.tap(2, [1, 2, 3, 4], shift: true);
    selection.tap(4, [1, 2, 3, 4], shift: true);
    expect(selection.ids, {2, 3, 4});
  });

  test(
    'actions use visible order, ignore duplicates, and isolate unselected rows',
    () {
      final selection = TrackSelection()
        ..toggle(3)
        ..toggle(1);
      final tracks = [
        for (var id = 1; id <= 4; id++) {'id': id},
      ];
      expect(selection.actionTargets(tracks[2], tracks), [
        tracks[0],
        tracks[2],
      ]);
      expect(selection.actionTargets(tracks[1], tracks), [tracks[1]]);
      selection.retain([3, 4]);
      expect(selection.ids, {3});
      selection.removeAll([3]);
      expect(selection.isNotEmpty, isFalse);
    },
  );

  Future<MainAppScreenState> fixture() async {
    final directory = await Directory.systemTemp.createTemp(
      'shiki_multiselect_',
    );
    final state = MainAppScreenState()
      ..localPath = directory.path
      ..myPlaylists = [
        {
          'id': 42,
          'name': 'Target',
          'image': 'cover.png',
          'tracks': [4, 2, 999],
        },
        {
          'id': 43,
          'name': 'Untouched',
          'tracks': [7, 8],
        },
      ];
    addTearDown(() async {
      state.catalogSyncStatus.dispose();
      state.lyricsSearchIndex.dispose();
      state.searchInput.dispose();
      state.searchFocusNode.dispose();
      state.currentPositionNotifier.dispose();
      state.fullDurationNotifier.dispose();
      final prefix =
          '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}shiki_multiselect_';
      if (!directory.absolute.path.startsWith(prefix)) {
        throw StateError('Unexpected fixture directory');
      }
      await directory.delete(recursive: true);
    });
    return state;
  }

  test(
    'mixed favorites add all in one persisted state, then remove all',
    () async {
      final state = await fixture()
        ..favs = {2, 9};
      await state.toggleTrackFavorites([1, 2, 3, 1]);
      expect(state.favs, {1, 2, 3, 9});
      final file = File('${state.localPath}/liked_tracks.json');
      expect(
        (jsonDecode(await file.readAsString()) as List).toSet(),
        state.favs,
      );
      await state.toggleTrackFavorites([3, 1, 2]);
      expect(state.favs, {9});
      expect(jsonDecode(await file.readAsString()), [9]);
    },
  );

  test('rapid single favorite toggles remain ordered', () async {
    final state = await fixture();
    await Future.wait([state.toggleFavorite(1), state.toggleFavorite(1)]);
    expect(state.favs, isEmpty);
  });

  test('favorite write failure restores previous likes', () async {
    final state = await fixture()
      ..favs = {2, 9};
    await Directory('${state.localPath}/liked_tracks.json').create();
    await state.toggleTrackFavorites([1, 2, 3]);
    expect(state.favs, {2, 9});
  });

  test(
    'batch playlist add is ordered, deduplicated and preserves unrelated data',
    () async {
      final state = await fixture();
      expect(await state.changePlaylistTracks(42, [3, 2, 1, 3]), isTrue);
      expect(state.myPlaylists.first['tracks'], [4, 2, 999, 3, 1]);
      expect(state.myPlaylists.first['image'], 'cover.png');
      expect(state.myPlaylists.last['tracks'], [7, 8]);
      expect(await state.changePlaylistTracks(42, [3, 2, 1]), isTrue);
      expect(state.myPlaylists.first['tracks'], [4, 2, 999, 3, 1]);
      expect(
        await state.changePlaylistTracks(42, [2, 1], remove: true),
        isTrue,
      );
      expect(state.myPlaylists.first['tracks'], [4, 999, 3]);
      final saved = jsonDecode(
        await File('${state.localPath}/my_playlists.json').readAsString(),
      );
      expect(saved.first['tracks'], [4, 999, 3]);
    },
  );

  test(
    'playlist save failure restores order without deleting tracks',
    () async {
      final state = await fixture();
      await Directory('${state.localPath}/my_playlists.json').create();
      expect(await state.changePlaylistTracks(42, [1, 3]), isFalse);
      expect(state.myPlaylists.first['tracks'], [4, 2, 999]);
      expect(
        await state.changePlaylistTracks(42, [4, 2], remove: true),
        isFalse,
      );
      expect(state.myPlaylists.first['tracks'], [4, 2, 999]);
    },
  );
}
