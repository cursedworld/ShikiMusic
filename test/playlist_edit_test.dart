import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/player_shortcuts.dart';
import 'package:shiki/screens/home_screen.dart';
import 'package:shiki/widgets/playlist_name_dialog.dart';

void main() {
  test(
    'renaming and artwork changes preserve playlist ID, track order and other playlists',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'shiki_playlist_edit_',
      );
      final state = MainAppScreenState()
        ..localPath = directory.path
        ..myPlaylists = [
          {
            'id': 42,
            'name': 'Old name',
            'image': 'old.png',
            'tracks': [9, 3, 7],
          },
          {
            'id': 43,
            'name': 'Other',
            'image': '',
            'tracks': [2],
          },
        ];
      addTearDown(() async {
        state.searchInput.dispose();
        state.searchFocusNode.dispose();
        state.currentPositionNotifier.dispose();
        state.fullDurationNotifier.dispose();
        await directory.delete(recursive: true);
      });
      expect(
        await state.updatePlaylistDetails(42, {
          'name': '  My favorite songs  ',
        }),
        isTrue,
      );
      expect(
        await state.updatePlaylistDetails(42, {
          'image': 'playlist_artwork_42.png',
        }),
        isTrue,
      );
      final stored =
          jsonDecode(
                await File(
                  '${directory.path}/my_playlists.json',
                ).readAsString(),
              )
              as List;
      expect(stored.first, {
        'id': 42,
        'name': 'My favorite songs',
        'image': 'playlist_artwork_42.png',
        'tracks': [9, 3, 7],
      });
      expect(stored.last, {
        'id': 43,
        'name': 'Other',
        'image': '',
        'tracks': [2],
      });
      expect(await state.updatePlaylistDetails(42, {'name': '   '}), isFalse);
      expect(
        await state.updatePlaylistDetails(999, {'name': 'Missing'}),
        isFalse,
      );
      expect(
        await state.updatePlaylistDetails(42, {'id': 99, 'tracks': []}),
        isFalse,
      );
    },
  );

  for (final width in [375.0, 1440.0]) {
    testWidgets(
      'rename allows spaces without toggling playback at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var toggles = 0;
        String? saved;
        await tester.pumpWidget(
          MaterialApp(
            home: Focus(
              onKeyEvent: (_, event) =>
                  handlePlaybackSpace(event, onToggle: () => toggles++)
                  ? KeyEventResult.handled
                  : KeyEventResult.ignored,
              child: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async => saved = await showDialog<String>(
                      context: context,
                      builder: (_) =>
                          const PlaylistNameDialog(initialName: 'Old name'),
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final input = find.byKey(const ValueKey('playlist_rename_input'));
        await tester.enterText(input, 'Music for walks');
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        expect(toggles, 0);
        await tester.tap(find.text('Сохранить'));
        await tester.pumpAndSettle();
        expect(saved, 'Music for walks');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
