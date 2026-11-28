import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiki/app_paths.dart';
import 'package:shiki/atomic_file_store.dart';
import 'package:shiki/downloaded_only.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/local_music_import.dart';
import 'package:shiki/localization.dart';
import 'package:shiki/screens/home_screen.dart';
import 'package:shiki/screens/settings_screen.dart';

import 'fixtures/local_mp3.dart';

class _Screen extends MainAppScreen {
  const _Screen();

  @override
  MainAppScreenState createState() => _State();
}

class _State extends MainAppScreenState {
  @override
  void updateRPC({bool force = false}) {}
}

Map<String, dynamic> _track(int id, String title) => {
  'id': id,
  'title': title,
  'duration': 180,
  'audio_file': '/media/track_$id.mp3',
  'source_id': 'youtube:offline-fixture-$id',
  'album': {
    'id': 1,
    'title': 'Album',
    'cover': '',
    'artist': {'id': 1, 'name': 'Artist'},
  },
};

void main() {
  testWidgets(
    'local-only startup, track edits, lyrics search and playback do not contact Django',
    (tester) async {
      expect(hasAppDataDirectoryOverride, isFalse);
      final previousMode = downloadedOnly.value;
      final previousLocalPath = globalLocalPath;
      final previousTrack = activeTrackNotifier.value;
      final previousLanguage = languageNotifier.value;
      final previousClips = playVideoClipNotifier.value;
      final previousVinyl = vinylRotationNotifier.value;
      final previousPlaying = isPlayingNotifier.value;
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('shiki-only-downloaded-'),
      ))!;
      final profile = Directory('${root.path}/ShikiMusic')..createSync();
      final tracks = [
        _track(1, 'First download'),
        _track(2, 'Server only'),
        _track(3, 'Last download'),
      ];
      final catalogJson = jsonEncode(tracks);
      File(
        '${profile.path}/offline_tracks.json',
      ).writeAsStringSync(catalogJson);
      final settingsFile = File('${profile.path}/shiki_settings.json')
        ..writeAsStringSync('{"language":"ru","downloadedOnly":true}');
      File('${profile.path}/app_state.json').writeAsStringSync(
        jsonEncode({'playingQueue': tracks, 'playingIndex': 1}),
      );
      final favoritesFile = File('${profile.path}/liked_tracks.json')
        ..writeAsStringSync('[1]');
      File('${profile.path}/my_playlists.json').writeAsStringSync(
        jsonEncode([
          {
            'id': 42,
            'name': 'Mixed playlist',
            'image': '',
            'tracks': [1, 2, 3],
          },
        ]),
      );
      for (final id in [1, 3]) {
        File('${profile.path}/track_$id.mp3').writeAsBytesSync(fixtureMp3());
      }
      File(
        '${profile.path}/track_1.lrc',
      ).writeAsStringSync('[00:01.00]Blue skyline');
      final ownFile = File('${root.path}/Voice note.mp3')
        ..writeAsBytesSync(fixtureMp3(variation: 7));
      final own = (await tester.runAsync(
        () => importLocalMusic(
          directory: profile,
          files: [(name: 'Voice note.mp3', path: ownFile.path)],
          cancel: LocalImportCancel(),
        ),
      ))!.entries.single;

      addTearDown(() async {
        downloadedOnly.value = previousMode;
        globalLocalPath = previousLocalPath;
        activeTrackNotifier.value = previousTrack;
        languageNotifier.value = previousLanguage;
        playVideoClipNotifier.value = previousClips;
        vinylRotationNotifier.value = previousVinyl;
        isPlayingNotifier.value = previousPlaying;
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (true) {
          try {
            await root.delete(recursive: true);
            break;
          } on FileSystemException catch (error) {
            if (!Platform.isWindows ||
                error.osError?.errorCode != 32 ||
                DateTime.now().isAfter(deadline)) {
              rethrow;
            }
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
        }
      });
      downloadedOnly.value = downloadedOnlyFromSettings(
        jsonDecode(settingsFile.readAsStringSync()) as Map,
      );
      languageNotifier.value = 'ru';
      playVideoClipNotifier.value = false;
      vinylRotationNotifier.value = false;

      final messenger = tester.binding.defaultBinaryMessenger;
      void mock(
        String channelName,
        Future<Object?> Function(MethodCall) handler,
      ) {
        final channel = MethodChannel(channelName);
        messenger.setMockMethodCallHandler(channel, handler);
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      }

      mock('plugins.flutter.io/path_provider', (_) async => root.path);
      expect((await getDocumentsRootDirectory()).path, root.path);
      mock('xyz.luan/audioplayers.global', (_) async => null);
      mock('xyz.luan/audioplayers.global/events', (_) async => null);
      final sources = <Map>[];
      var releases = 0;
      String? eventChannel;
      Future<void> audioEvent(String channel, String event, Object value) =>
          messenger.handlePlatformMessage(
            channel,
            const StandardMethodCodec().encodeSuccessEnvelope({
              'event': event,
              'value': value,
            }),
            (_) {},
          );
      mock('xyz.luan/audioplayers', (call) async {
        final args = call.arguments as Map;
        final events = 'xyz.luan/audioplayers/events/${args['playerId']}';
        switch (call.method) {
          case 'create':
            mock(events, (_) async => null);
          case 'setSourceUrl':
            sources.add(args);
            eventChannel = events;
            await audioEvent(events, 'audio.onPrepared', true);
          case 'getDuration':
            return 180000;
          case 'release':
            releases++;
        }
        return null;
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1250, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final calls = <String>[];
      Future<void> until(bool Function() done) async {
        for (var i = 0; i < 200; i++) {
          await tester.pump();
          if (done()) return;
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 8)),
          );
        }
        fail('Timed out waiting for profile I/O or playback');
      }

      final switchFinder = find.byKey(const ValueKey('downloaded_only_switch'));
      final catalogSync = find.byKey(const ValueKey('catalog_sync'));
      Finder rowTitle(int id, String title) => find.descendant(
        of: find.byKey(ValueKey(id)),
        matching: find.text(title),
      );
      Future<void> changeTitle(int id, String title) async {
        final menu = find.descendant(
          of: find.byKey(ValueKey(id)),
          matching: find.byTooltip(tr('track_actions')),
        );
        await tester.tap(menu);
        await tester.pumpAndSettle();
        await tester.tap(find.text(tr('track_details')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('track_details_title')),
          title,
        );
        await tester.pump();
        final save = find.byKey(const ValueKey('track_details_save'));
        await tester.runAsync(() async => tester.tap(save));
        await until(() => rowTitle(id, title).evaluate().isNotEmpty);
        await tester.pumpAndSettle();
      }

      Future<void> openSettings() async {
        await tester.tap(find.byIcon(Icons.settings));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          switchFinder,
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await until(
          () => tester.widget<SwitchListTile>(switchFinder).onChanged != null,
        );
      }

      Future<void> toggle() async {
        await tester.runAsync(() async => tester.tap(switchFinder));
        await tester.pumpAndSettle();
      }

      Future<void> goBack() async {
        Navigator.of(tester.element(find.byType(SettingsScreen))).pop();
        await tester.pumpAndSettle();
      }

      bool saved(bool value) =>
          // The toggle is disabled until the atomic settings write completes.
          tester.widget<SwitchListTile>(switchFinder).onChanged != null &&
          (jsonDecode(settingsFile.readAsStringSync())
                  as Map)['downloadedOnly'] ==
              value;

      await http.runWithClient(
        () async {
          try {
            await tester.pumpWidget(const MaterialApp(home: _Screen()));
            final state = tester.state<_State>(find.byType(_Screen));
            await until(
              () => state.playingTrack?['id'] == 2 && !state.isLoading,
            );
            expect(catalogSync, findsNothing);
            expect(find.byKey(const ValueKey(2)), findsNothing);
            expect(find.byKey(ValueKey(own.id)), findsOneWidget);
            state.didChangeAppLifecycleState(AppLifecycleState.hidden);
            state.didChangeAppLifecycleState(AppLifecycleState.resumed);
            await tester.pump(const Duration(seconds: 13));
            expect(calls, isEmpty);
            expect(
              sources,
              isEmpty,
              reason: 'Do not reopen the saved server stream',
            );
            await changeTitle(own.id, 'My local title');
            expect(rowTitle(own.id, 'My local title'), findsOneWidget);

            await tester.enterText(find.byType(TextField), 'blue skyline');
            await tester.pump(const Duration(milliseconds: 200));
            await until(
              () => find.byKey(const ValueKey(1)).evaluate().isNotEmpty,
            );
            expect(find.byKey(ValueKey(own.id)), findsNothing);
            await tester.enterText(find.byType(TextField), '');
            state.navId = 3;
            state.updateSearchQuery('');
            await tester.pump();
            expect(
              find.text(tr('downloaded_only_unavailable')),
              findsOneWidget,
            );
            expect(state.myPlaylists.single['tracks'], [1, 2, 3]);

            await tester.tap(rowTitle(1, 'First download'));
            await tester.pump();
            expect(
              state.playingTrack?['id'],
              1,
              reason: 'The row click must start the selected track',
            );
            await until(
              () =>
                  sources.length == 1 &&
                  state.fullDurationNotifier.value.inSeconds == 180 &&
                  globalLyrics.isNotEmpty,
            );
            expect(sources.single['isLocal'], isTrue);
            expect(globalLyrics.single.txt, 'Blue skyline');
            state.currentPositionNotifier.value = const Duration(seconds: 46);
            await changeTitle(1, 'My downloaded title');
            expect(state.playingTrack?['id'], 1);
            expect(state.playingTrack?['title'], 'First download');
            expect(find.text('My downloaded title'), findsNWidgets(2));
            expect(
              state.currentPositionNotifier.value,
              const Duration(seconds: 46),
            );
            expect(
              sources,
              hasLength(1),
              reason: 'Editing must not reopen audio',
            );
            expect(state.myPlaylists.single['tracks'], [1, 2, 3]);
            expect(favoritesFile.readAsStringSync(), '[1]');
            expect(
              File('${profile.path}/offline_tracks.json').readAsStringSync(),
              catalogJson,
            );
            expect(
              File('${profile.path}/track_1.mp3').readAsBytesSync(),
              fixtureMp3(),
            );
            await tester.enterText(find.byType(TextField), 'my downloaded');
            await tester.pump(const Duration(milliseconds: 200));
            expect(rowTitle(1, 'My downloaded title'), findsOneWidget);
            expect(rowTitle(3, 'Last download'), findsNothing);
            await tester.enterText(find.byType(TextField), '');
            await tester.pump(const Duration(milliseconds: 200));
            await audioEvent(eventChannel!, 'audio.onComplete', true);
            await until(
              () => sources.length == 2 && state.playingTrack?['id'] == 3,
            );
            expect(sources.last['isLocal'], isTrue);
            expect(calls, isEmpty);

            await openSettings();
            expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);
            await toggle();
            await until(() => saved(false) && calls.contains('/api/tracks/'));
            expect(downloadedOnly.value, isFalse);
            expect(
              calls.where((path) => path == '/api/tracks/catalog-revision/'),
              hasLength(1),
            );
            expect(
              sources,
              hasLength(2),
              reason: 'The playing file stays open',
            );
            expect(calls, isNot(contains('/api/smart_search/')));
            await until(
              () =>
                  tester.widget<SwitchListTile>(switchFinder).onChanged != null,
            );
            state.downloadQueue.add(3);
            await toggle();
            expect(find.text(tr('downloaded_only_busy')), findsOneWidget);
            expect(downloadedOnly.value, isFalse);
            state.downloadQueue.clear();
            await goBack();
            expect(catalogSync, findsOneWidget);
            expect(rowTitle(1, 'My downloaded title'), findsOneWidget);

            await tester.tap(rowTitle(2, 'Server only'));
            await until(
              () =>
                  sources.length == 3 &&
                  state.fullDurationNotifier.value.inSeconds == 180,
            );
            expect(sources.last['isLocal'], isFalse);
            await openSettings();
            await toggle();
            expect(
              find.text(tr('downloaded_only_stop_stream')),
              findsOneWidget,
            );
            expect(downloadedOnly.value, isFalse);
            final beforeRelease = releases;
            await tester.tap(find.text(tr('cancel')));
            await tester.pumpAndSettle();
            await until(
              () =>
                  tester.widget<SwitchListTile>(switchFinder).onChanged != null,
            );
            expect(releases, beforeRelease);
            await toggle();
            expect(
              find.text(tr('downloaded_only_stop_and_enable')),
              findsOneWidget,
            );
            await tester.runAsync(
              () async =>
                  tester.tap(find.text(tr('downloaded_only_stop_and_enable'))),
            );
            await until(() => saved(true) && downloadedOnly.value);
            expect(releases, beforeRelease + 1);
            expect(state.isPlaying, isFalse);
            await goBack();
            expect(catalogSync, findsNothing);
            final beforePoll = calls.length;
            await tester.pump(const Duration(seconds: 13));
            expect(calls, hasLength(beforePoll));
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            final savedSession = File('${profile.path}/app_state.json');
            var sessionIdle = false;
            final drain = atomicFileStore.writeStringLazy(
              savedSession,
              savedSession.readAsString,
            );
            drain.then((_) => sessionIdle = true);
            await until(() => sessionIdle);
          }
        },
        () => MockClient((request) async {
          final path = request.url.path;
          calls.add(path);
          return switch (path) {
            '/api/tracks/catalog-revision/' => http.Response(
              '{}',
              200,
              headers: {'etag': 'fixture'},
            ),
            '/api/tracks/' => http.Response(catalogJson, 200),
            '/api/artists/' ||
            '/api/tracks/revisions/' => http.Response('[]', 200),
            _ => http.Response('{}', 404),
          };
        }),
      );
    },
  );
}
