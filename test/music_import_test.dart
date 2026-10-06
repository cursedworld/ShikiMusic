import 'package:flutter_test/flutter_test.dart';
import 'dart:async';
import 'package:shiki/music_import.dart';

void main() {
  test(
    'a delayed lyric response cannot replace newer manually edited text',
    () async {
      final track = <String, dynamic>{
        'title': 'Song',
        'duration': 180,
        'lyrics': '',
        'album': {
          'artist': {'name': 'A'},
        },
      };
      final provider = Completer<Map<String, dynamic>>();
      final pending = provider.future.then((data) {
        if (!lyricsLookupUnchanged(
          track,
          artists: 'A',
          title: 'Song',
          duration: 180,
          originalLyrics: '',
        )) {
          return '';
        }
        return validatedLyricsText(
          data,
          artists: 'A',
          title: 'Song',
          duration: 180,
        );
      });
      track['lyrics'] = 'Manual text';
      provider.complete({
        'trackName': 'Song',
        'artistName': 'A',
        'duration': 180,
        'syncedLyrics': 'Stale text',
      });
      expect(await pending, '');
      expect(track['lyrics'], 'Manual text');
    },
  );
  test('lyrics validate song, credits and duration before using timings', () {
    final data = {
      'trackName': 'Без ответа',
      'artistName': 'Кишлак, семьсот семь',
      'duration': 62,
      'syncedLyrics': '[00:01.00]Right',
      'plainLyrics': 'Text',
    };
    String validate() => validatedLyricsText(
      data,
      artists: 'Кишлак, 707',
      title: 'Без ответа',
      duration: 62,
    );
    expect(validate(), '[00:01.00]Right');
    data['duration'] = 118;
    expect(validate(), '');
    data['duration'] = 62;
    data['artistName'] = 'Other';
    expect(validate(), '');
    data['artistName'] = 'Кишлак, Other';
    expect(validate(), '');
    data['artistName'] = 'Кишлак';
    expect(validate(), '[00:01.00]Right');
    data['duration'] = 0;
    expect(validate(), 'Text');
    data['trackName'] = 'Other song';
    expect(validate(), '');
  });
  test(
    'labels include coauthors, deduplicate aliases, preserve primary order',
    () {
      expect(
        trackArtistLabel({
          'album': {
            'artist': {'name': 'Кишлак'},
          },
          'artists': [
            {'name': 'КИШЛАК'},
            {'name': 'семьсот семь'},
            {'name': '707'},
            {'name': ' '},
          ],
        }),
        'Кишлак, семьсот семь',
      );
      expect(
        trackArtistLabel({
          'artists': [
            {'name': 'Guest'},
          ],
        }),
        'Guest',
      );
      expect(trackArtistLabel(null), 'Unknown');
      expect(
        trackArtistLabel({
          'album': {
            'artist': {'name': 'Solo'},
          },
        }),
        'Solo',
      );
    },
  );
  test('numeric stage names match spoken numbers both ways', () {
    final track = {
      'title': 'Без ответа',
      'artists': [
        {'name': 'Кишлак'},
        {'name': 'семьсот семь'},
      ],
    };
    expect(matchesTrackSearch(track, 'кишлак 707 без ответа'), isTrue);
    track['artists'] = [
      {'name': 'Кишлак'},
      {'name': '707'},
    ];
    expect(matchesTrackSearch(track, 'кишлак семьсот семь без ответа'), isTrue);
    expect(matchesTrackSearch(track, 'кишлак 708 без ответа'), isFalse);
  });
  test('only explicit supported playlist links use album flow', () {
    expect(
      isSupportedAlbumLink(
        'https://music.youtube.com/playlist?list=OLAK5uy_test',
      ),
      isTrue,
    );
    expect(
      isSupportedAlbumLink('https://www.youtube.com/watch?v=track&list=album'),
      isTrue,
    );
    expect(isSupportedAlbumLink('https://youtube.com/watch?v=track'), isFalse);
    expect(isSupportedAlbumLink('Artist - Album'), isFalse);
    expect(
      isSupportedAlbumLink('https://youtube.com.evil.test/playlist?list=album'),
      isFalse,
    );
    expect(isSupportedAlbumLink('file:///playlist?list=album'), isFalse);
    expect(isSupportedAlbumLink('https://youtube.com/playlist?list='), isFalse);
  });

  test(
    'download IDs tolerate valid numeric strings, reject invalid entries',
    () {
      expect(downloadTrackId({'id': 12}), 12);
      expect(downloadTrackId({'id': '12'}), 12);
      expect(downloadTrackId({'id': 0}), isNull);
      expect(downloadTrackId({'id': 'bad'}), isNull);
      expect(downloadTrackId(null), isNull);
    },
  );

  test(
    'search matches artist and title words together, all credited artists',
    () {
      final track = {
        'title': 'Ёжик — Сон',
        'album': {
          'title': 'Второй альбом',
          'artist': {'name': 'Первый'},
        },
        'artists': [
          {'name': 'Второй исполнитель'},
        ],
      };
      expect(matchesTrackSearch(track, 'первый ежик'), isTrue);
      expect(matchesTrackSearch(track, 'ВТОРОЙ, сон'), isTrue);
      expect(matchesTrackSearch(track, 'третий сон'), isFalse);
      expect(matchesTrackSearch(track, '  '), isTrue);
      expect(matchesTrackSearch({'title': 'Song'}, 'song'), isTrue);
    },
  );
}
