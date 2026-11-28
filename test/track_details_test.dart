import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/music_import.dart';
import 'package:shiki/track_details.dart';

final _server = Uri.parse('https://music.example.test');

Map<String, Object?> _catalogTrack({
  String title = 'Catalog title',
  String? source = 'youtube:fixture-song',
  String audio = '/media/tracks/song.mp3',
}) => {
  'id': 42,
  'source_id': source,
  'audio_file': audio,
  'duration': 120,
  'title': title,
  'album': {
    'id': 17,
    'title': 'Catalog album',
    'artist': {'id': 8, 'name': 'Catalog artist'},
  },
};

const _override = (title: 'My title', artist: 'My artist', album: 'My album');

void main() {
  late Directory profile;
  late TrackDetailsStore store;
  setUp(() async {
    profile = await Directory.systemTemp.createTemp('shiki-track-info-test-');
    store = TrackDetailsStore(profile, server: _server);
    await store.load();
  });
  tearDown(() => profile.delete(recursive: true));

  test(
    'local MP3 edit survives reprojection and a restart without changing tags',
    () async {
      final track = {
        'id': -1,
        'title': 'From MP3',
        'local_key': 'local:${'a' * 64}',
      };
      final key = store.bind(track)!;
      await store.save(key, _override);
      expect(trackDisplayTitle(track), 'My title');
      expect(track['title'], 'From MP3');
      expect(jsonEncode(track), isNot(contains('My title')));

      final restored = TrackDetailsStore(
        profile,
        server: Uri.parse('https://other.example.test'),
      );
      await restored.load();
      final fresh = {...track, 'id': -7, 'title': 'From refreshed tags'};
      expect(restored.bind(fresh), key);
      expect(trackDisplayTitle(fresh), 'My title');
      await restored.save(key, null);
      expect(trackDisplayTitle(fresh), 'From refreshed tags');
    },
  );

  test(
    'catalog edits survive refresh but do not affect raw credits, titles or search',
    () async {
      final track = _catalogTrack();
      final key = store.bind(track)!;
      await store.save(key, _override);
      final fresh = _catalogTrack(title: 'Corrected on server');
      expect(store.bind(fresh), key);
      expect(trackDisplayTitle(fresh), 'My title');
      expect(trackDisplayArtist(fresh), 'My artist');
      expect(trackDisplayAlbum(fresh), 'My album');
      expect(trackArtistLabel(fresh), 'Catalog artist');
      expect(matchesTrackDetailsSearch(fresh, 'my title artist album'), isTrue);
      expect(matchesTrackDetailsSearch(fresh, 'corrected'), isFalse);

      final restored = TrackDetailsStore(profile, server: _server);
      await restored.load();
      expect(restored.bind(fresh), key);
      expect(displayTrackDetails(fresh), _override);
      await restored.save(key, null);
      expect(trackDisplayTitle(fresh), 'Corrected on server');
      expect(trackDisplayArtist(fresh), 'Catalog artist');
      final reopened = TrackDetailsStore(profile, server: _server);
      await reopened.load();
      reopened.bind(fresh);
      expect(trackDetailsPatch(fresh), isNull);
    },
  );

  test(
    'a reused catalog ID and another server cannot inherit an edit',
    () async {
      final track = _catalogTrack();
      final key = store.bind(track)!;
      await store.save(key, _override);
      final newRecording = _catalogTrack(source: 'youtube:different');
      expect(store.bind(newRecording), isNot(key));
      expect(trackDisplayTitle(newRecording), 'Catalog title');
      final oldServerMedia = _catalogTrack(
        audio: 'https://previous.example.test/media/tracks/song.mp3',
      );
      expect(store.bind(oldServerMedia), isNull);
      final anotherServer = TrackDetailsStore(
        profile,
        server: Uri.parse('https://other.example.test'),
      );
      await anotherServer.load();
      expect(anotherServer.bind(track), isNot(key));
      expect(trackDisplayTitle(track), 'Catalog title');
    },
  );

  test(
    'audio fingerprints keep older tracks editable across renamed metadata',
    () async {
      final audioVersion = 'a' * 64;
      final track = _catalogTrack(source: null)
        ..['content_versions'] = {'audio': audioVersion};
      final key = store.bind(track)!;
      await store.save(key, _override);

      final renamed = _catalogTrack(source: null, title: 'Updated title')
        ..['content_versions'] = {'audio': audioVersion};
      expect(store.bind(renamed), key);
      expect(displayTrackDetails(renamed), _override);

      final replacement = _catalogTrack(source: null)
        ..['content_versions'] = {'audio': 'b' * 64};
      expect(store.bind(replacement), isNot(key));
      expect(trackDetailsPatch(replacement), isNull);
    },
  );

  test(
    'legacy rows distinguish file identity and same-path ID reuse',
    () async {
      final track = _catalogTrack(source: null);
      final key = store.bind(track)!;
      await store.save(key, _override);
      final fresh = _catalogTrack(source: null)..['lyrics'] = 'new lyrics';
      expect(store.bind(fresh), key);
      expect(trackDisplayTitle(fresh), 'My title');
      final different = _catalogTrack(
        source: null,
        audio: '/media/tracks/other.mp3',
      );
      expect(store.bind(different), isNot(key));
      expect(trackDisplayTitle(different), 'Catalog title');
      final reused = _catalogTrack(source: null, title: 'Different recording');
      expect(store.bind(reused), isNot(key));
      expect(trackDisplayTitle(reused), 'Different recording');
      expect(store.bind(_catalogTrack(source: null, audio: '')), isNull);
    },
  );

  test('only fields changed in the form override refreshed catalog values', () {
    const shown = (
      title: 'Old title',
      artist: 'Old artist',
      album: 'Old album',
    );
    const newer = (
      title: 'New title',
      artist: 'New artist',
      album: 'New album',
    );
    const edited = (title: 'Old title', artist: 'Old artist', album: '');
    expect(
      resolveTrackDetailsEdit(shown: shown, edited: edited, original: newer),
      (title: null, artist: null, album: ''),
    );
  });

  test(
    'rejects invalid edited fields and keeps the saved correction',
    () async {
      final track = _catalogTrack();
      final key = store.bind(track)!;
      await store.save(key, _override);
      await expectLater(
        store.save(key, (title: 'w' * 513, artist: null, album: null)),
        throwsFormatException,
      );
      await expectLater(
        store.save(key, (title: null, artist: 'line\nbreak', album: null)),
        throwsFormatException,
      );
      expect(trackDisplayTitle(track), 'My title');
    },
  );
}
