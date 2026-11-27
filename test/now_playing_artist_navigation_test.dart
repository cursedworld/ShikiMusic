import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/downloaded_only.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/localization.dart';
import 'package:shiki/screens/artist_screen.dart';
import 'package:shiki/screens/home_screen.dart';

class _PlayerState extends MainAppScreenState {
  late BuildContext testContext;
  int lyricsOpened = 0;

  @override
  BuildContext get context => testContext;

  @override
  void showLyricsScreen() => lyricsOpened++;
}

const _track = {
  'id': 1,
  'title': 'Current track',
  'artists': [
    {'id': 27, 'name': 'Solo artist'},
  ],
};
const _position = Duration(seconds: 42);
const _duration = Duration(minutes: 3);

Future<_PlayerState> _openPlayer(
  WidgetTester tester, {
  bool mobile = false,
  Map<String, dynamic> track = _track,
}) async {
  final previousMode = downloadedOnly.value;
  final previousPath = globalLocalPath;
  downloadedOnly.value = true;
  globalLocalPath = '';
  addTearDown(() {
    downloadedOnly.value = previousMode;
    globalLocalPath = previousPath;
  });
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = mobile
      ? const Size(320, 800)
      : const Size(1440, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final state = _PlayerState()
    ..playingQueue = [
      track,
      {..._track, 'id': 2, 'title': 'Next track'},
    ]
    ..playingPlaylistId = 16
    ..isPlaying = true;
  state.currentPositionNotifier.value = _position;
  state.fullDurationNotifier.value = _duration;
  addTearDown(() {
    state.catalogSyncStatus.dispose();
    state.searchInput.dispose();
    state.searchFocusNode.dispose();
    state.currentPositionNotifier.dispose();
    state.fullDurationNotifier.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Builder(
        builder: (context) {
          state.testContext = context;
          return Scaffold(
            bottomNavigationBar: mobile ? state.buildMobileMiniPlayer() : null,
            body: mobile
                ? null
                : Row(
                    children: [
                      const Spacer(),
                      state.buildDesktopPlayer(context),
                    ],
                  ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

void main() {
  testWidgets(
    'clicking the artist opens their page without changing playback',
    (tester) async {
      final state = await _openPlayer(tester);

      final artist = find.text('Solo artist');
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(4, 4));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(artist));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text(tr('artist_open_page')), findsNothing);
      expect(
        tester.widget<Text>(artist).style?.decoration,
        isNot(TextDecoration.underline),
      );

      await tester.tap(artist);
      await tester.pumpAndSettle();

      expect(find.byType(ArtistScreen), findsOneWidget);
      expect(
        tester.widget<ArtistScreen>(find.byType(ArtistScreen)).artistId,
        27,
      );
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(find.text('Current track'), findsOneWidget);
      expect(state.playingTrack, same(_track));
      expect(state.playingQueue.map((track) => track['id']), [1, 2]);
      expect(state.playingPlaylistId, 16);
      expect(state.isPlaying, isTrue);
      expect(state.currentPositionNotifier.value, _position);
      expect(state.fullDurationNotifier.value, _duration);
    },
  );

  testWidgets('the artist link is reachable and opens with the keyboard', (
    tester,
  ) async {
    await _openPlayer(
      tester,
      track: {
        ..._track,
        'artists': [
          {'id': -10, 'name': 'Local artist'},
        ],
      },
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.byType(ArtistScreen), findsOneWidget);
    expect(
      tester.widget<ArtistScreen>(find.byType(ArtistScreen)).artistId,
      -10,
    );
  });

  testWidgets(
    'mini-player can open a guest artist and the title opens lyrics',
    (tester) async {
      final state = await _openPlayer(
        tester,
        mobile: true,
        track: {
          ..._track,
          'album': {
            'artist': {'id': 45, 'name': 'Lead artist'},
          },
          'artists': [
            {'id': 45, 'name': 'Lead artist'},
            {'id': 76, 'name': 'Guest artist'},
          ],
        },
      );
      await tester.tap(find.text('Current track'));
      expect(state.lyricsOpened, 1);
      expect(find.byTooltip(tr('artist_choose')), findsNothing);

      await tester.tap(find.text('Lead artist, Guest artist'));
      await tester.pumpAndSettle();
      expect(find.text('Lead artist'), findsOneWidget);
      expect(state.lyricsOpened, 1);
      await tester.tap(find.text('Guest artist'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<ArtistScreen>(find.byType(ArtistScreen)).artistId,
        76,
      );
    },
  );

  testWidgets('a name without an artist ID stays plain text', (tester) async {
    await _openPlayer(
      tester,
      track: {
        ..._track,
        'artists': [
          {'name': 'Name without a page'},
        ],
      },
    );

    await tester.tap(find.text('Name without a page'));
    await tester.pumpAndSettle();

    expect(find.byType(ArtistScreen), findsNothing);
  });
}
