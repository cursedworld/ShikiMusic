import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiki/discord_cover.dart';

Map<String, dynamic> track({
  String title = 'Song',
  String artist = 'Artist',
  String? guest,
  int duration = 200,
}) => {
  'id': 1,
  'title': title,
  'duration': duration,
  'album': {
    'title': 'Album',
    'artist': {'name': artist},
  },
  'artists': [
    if (guest != null) {'name': guest},
  ],
};

Map<String, dynamic> apple({
  String title = 'Song',
  String artist = 'Artist',
  String album = 'Album',
  int duration = 200,
  String? url = 'https://covers.example/apple/100x100bb.jpg',
}) => {
  'kind': 'song',
  'trackName': title,
  'artistName': artist,
  'collectionName': album,
  'trackTimeMillis': duration * 1000,
  'artworkUrl100': url,
};

Map<String, dynamic> deezer({
  String title = 'Song',
  String artist = 'Artist',
}) => {
  'title': title,
  'artist': {'name': artist},
  'duration': 200,
  'album': {'title': 'Album', 'cover_big': 'https://covers.example/deezer.jpg'},
};

Map<String, dynamic> lastfm({
  String title = 'Song',
  String artist = 'Artist',
}) => {
  'name': title,
  'artist': {'name': artist},
  'duration': '200000',
  'album': {
    'title': 'Album',
    'image': [
      {'size': 'extralarge', '#text': 'https://covers.example/lastfm.jpg'},
    ],
  },
};

void main() {
  late List<http.Request> requests;
  late List<String> resolved;
  late DateTime now;
  final lookups = <DiscordCoverLookup>[];
  setUp(() {
    requests = [];
    resolved = [];
    now = DateTime.utc(2026, 10, 7);
  });
  tearDown(() async {
    for (final lookup in lookups) {
      lookup.dispose();
    }
    for (final lookup in lookups) {
      await lookup.idle;
    }
    lookups.clear();
  });

  DiscordCoverLookup lookup({
    FutureOr<http.Response> Function(http.Request)? handler,
    List<dynamic>? apples,
    List<dynamic>? deezerTracks,
    Map? lastFmTrack,
  }) {
    final result = DiscordCoverLookup(
      onResolved: resolved.add,
      now: () => now,
      itunesInterval: Duration.zero,
      clientFactory: () => MockClient((request) async {
        requests.add(request);
        if (handler != null) return await handler(request);
        if (request.url.host == 'itunes.apple.com') {
          return http.Response(
            jsonEncode({
              'results': apples ?? [apple()],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.host == 'api.deezer.com') {
          return http.Response(
            jsonEncode({'data': deezerTracks ?? []}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.queryParameters['method'] == 'track.getInfo') {
          return http.Response(
            jsonEncode({'track': lastFmTrack}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 200);
      }),
    );
    lookups.add(result);
    return result;
  }

  Future<DiscordCoverResult?> find(
    DiscordCoverLookup lookup, [
    dynamic value,
  ]) async {
    lookup.imageFor(value ?? track());
    await lookup.idle;
    return lookup.imageFor(value ?? track());
  }

  test(
    'iTunes is first and no later provider runs after an exact match',
    () async {
      final covers = lookup();
      expect(covers.imageFor(track()), isNull);
      expect(covers.isResolved(track()), isFalse);
      await covers.idle;
      final result = covers.imageFor(track());
      expect(result?.source, DiscordCoverSource.itunes);
      expect(result?.url, 'https://covers.example/apple/600x600bb.jpg');
      expect(requests.length, 1);
      expect(requests.single.url.host, 'itunes.apple.com');
      expect(requests.single.url.queryParameters['limit'], '10');
      expect(covers.isResolved(track()), isTrue);
    },
  );

  test(
    'iTunes cover is pinned rather than replaced by a later fallback',
    () async {
      final covers = lookup();
      final first = await find(covers);
      now = now.add(const Duration(days: 100));
      for (var i = 0; i < 100; i++) {
        covers.imageFor(track());
      }
      await covers.idle;
      expect(covers.imageFor(track())?.url, first?.url);
      expect(requests.length, 1);
      expect(resolved.length, 1);
    },
  );

  test(
    'another song by the same artist is rejected; a later exact hit wins',
    () async {
      final result = await find(
        lookup(
          apples: [
            apple(title: 'Other song'),
            apple(),
          ],
        ),
      );
      expect(result?.source, DiscordCoverSource.itunes);
      expect(requests.length, 1);
    },
  );

  test(
    'matching album ranks ahead of a compilation for the same song',
    () async {
      final result = await find(
        lookup(
          apples: [
            apple(
              album: 'Compilation',
              url: 'https://covers.example/compilation.jpg',
            ),
            apple(),
          ],
        ),
      );
      expect(result?.url, contains('/apple/'));
    },
  );

  for (final wrong in [
    apple(title: 'Song (Remix)'),
    apple(title: 'Song (Live)'),
    apple(artist: 'Artist Junior'),
    apple(artist: 'Fake Artist'),
    apple(artist: 'Artist & Unrelated'),
    apple(duration: 260),
    apple(title: 'Song (feat. Unrelated)'),
    apple(url: null),
    apple(url: 'http://192.168.1.2/cover.jpg'),
  ]) {
    test(
      'uncertain iTunes result falls back to verified Deezer: $wrong',
      () async {
        final result = await find(
          lookup(apples: [wrong], deezerTracks: [deezer()]),
        );
        expect(result?.source, DiscordCoverSource.deezer);
        expect(requests.map((r) => r.url.host), [
          'itunes.apple.com',
          'api.deezer.com',
        ]);
      },
    );
  }

  test(
    'known guests and exact transliteration do not lose a correct cover',
    () async {
      final value = track(
        title: 'Без ответа',
        artist: 'Кишлак',
        guest: 'семьсотсемь',
      );
      final result = await find(
        lookup(
          apples: [
            apple(title: 'Без ответа (feat. 707)', artist: 'Kishlak & 707'),
          ],
        ),
        value,
      );
      expect(result?.source, DiscordCoverSource.itunes);
      expect(requests.length, 1);
    },
  );

  test('Last.fm is reached only after both earlier providers miss', () async {
    final result = await find(lookup(apples: [], lastFmTrack: lastfm()));
    expect(result?.source, DiscordCoverSource.lastfm);
    expect(requests.length, 3);
    expect(requests.map((r) => r.url.host), [
      'itunes.apple.com',
      'api.deezer.com',
      'ws.audioscrobbler.com',
    ]);
  });

  test(
    'Last.fm getInfo is validated rather than trusting any returned album',
    () async {
      final result = await find(
        lookup(
          apples: [],
          lastFmTrack: lastfm(title: 'Wrong song'),
        ),
      );
      expect(result, isNull);
      expect(requests.length, 6);
    },
  );

  test(
    'Last.fm search examines matching identity, not only its first hit',
    () async {
      final covers = lookup(
        handler: (request) {
          if (request.url.queryParameters['method'] == 'track.search') {
            Map row(String name, String artist, String url) => {
              'name': name,
              'artist': artist,
              'image': [
                {'size': 'extralarge', '#text': url},
              ],
            };
            return http.Response(
              jsonEncode({
                'results': {
                  'trackmatches': {
                    'track': [
                      row(
                        'Wrong song',
                        'Artist',
                        'https://covers.example/wrong.jpg',
                      ),
                      row('Song', 'Artist', 'https://covers.example/right.jpg'),
                    ],
                  },
                },
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        },
      );
      expect((await find(covers))?.url, 'https://covers.example/right.jpg');
      expect(requests.length, 4);
    },
  );

  test(
    'portraits are used only for the exact artist; no arbitrary album fallback',
    () async {
      final covers = lookup(
        handler: (request) {
          if (request.url.path == '/search/artist') {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'name': 'Unrelated',
                    'picture_big': 'https://covers.example/wrong-person.jpg',
                  },
                  {
                    'name': 'Artist',
                    'picture_big': 'https://covers.example/artist.jpg',
                  },
                ],
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        },
      );
      final result = await find(covers);
      expect(result?.source, DiscordCoverSource.artistPhoto);
      expect(result?.url, 'https://covers.example/artist.jpg');
      expect(
        requests.any((r) => r.url.queryParameters['entity'] == 'album'),
        isFalse,
      );
    },
  );

  test(
    'fallback is retried later, but not on every RPC lyric update',
    () async {
      var appleAvailable = false;
      final covers = lookup(
        handler: (request) => http.Response(
          jsonEncode(
            request.url.host == 'itunes.apple.com'
                ? {
                    'results': appleAvailable ? [apple()] : [],
                  }
                : {
                    'data': [deezer()],
                  },
          ),
          200,
        ),
      );
      expect((await find(covers))?.source, DiscordCoverSource.deezer);
      for (var i = 0; i < 100; i++) {
        covers.imageFor(track());
      }
      await covers.idle;
      expect(requests.length, 2);
      appleAvailable = true;
      now = now.add(const Duration(minutes: 31));
      expect((await find(covers))?.source, DiscordCoverSource.itunes);
      expect(requests.length, 3);
    },
  );

  test(
    'missing artwork is cached and invalidated when metadata changes',
    () async {
      final covers = lookup(handler: (_) => http.Response('{}', 200));
      expect(await find(covers), isNull);
      final initial = requests.length;
      await find(covers);
      expect(requests.length, initial);
      await find(covers, track(title: 'Updated title'));
      expect(requests.length, greaterThan(initial));
    },
  );

  test(
    'rapid skips deduplicate active work and keep only the latest pending track',
    () async {
      final gate = Completer<http.Response>();
      final started = Completer<void>();
      final covers = lookup(
        handler: (request) {
          if (!started.isCompleted) {
            started.complete();
            return gate.future;
          }
          final latest =
              request.url.queryParameters['term']?.contains('Latest') ?? false;
          return http.Response(
            jsonEncode({
              'results': latest ? [apple(title: 'Latest')] : [],
            }),
            200,
          );
        },
      );
      covers.imageFor(track());
      await started.future;
      covers.imageFor(track());
      covers.imageFor(track(title: 'Skipped'));
      covers.imageFor(track(title: 'Latest'));
      gate.complete(
        http.Response(
          jsonEncode({
            'results': [apple()],
          }),
          200,
        ),
      );
      await covers.idle;
      expect(requests.length, 2);
      expect(resolved, [DiscordCoverLookup.trackKey(track(title: 'Latest'))]);
      expect(
        covers.imageFor(track(title: 'Latest'))?.source,
        DiscordCoverSource.itunes,
      );
    },
  );

  test(
    'HTTP failure and malformed shapes stay contained in background lookup',
    () async {
      final covers = lookup(
        handler: (request) => request.url.host == 'itunes.apple.com'
            ? http.Response('Forbidden', 403)
            : http.Response('{"results":[],"data":[]}', 200),
      );
      expect(await find(covers), isNull);
      expect(covers.isResolved(track()), isTrue);
    },
  );

  test('dispose suppresses stale callbacks and future requests', () async {
    final gate = Completer<http.Response>();
    final started = Completer<void>();
    final covers = lookup(
      handler: (_) {
        started.complete();
        return gate.future;
      },
    );
    covers.imageFor(track());
    await started.future;
    covers.dispose();
    gate.complete(
      http.Response(
        jsonEncode({
          'results': [apple()],
        }),
        200,
      ),
    );
    await covers.idle;
    expect(covers.imageFor(track()), isNull);
    expect(resolved, isEmpty);
    expect(requests.length, 1);
  });

  test(
    'animation and stored artwork never override a verified track cover',
    () {
      for (final source in [
        DiscordCoverSource.itunes,
        DiscordCoverSource.deezer,
        DiscordCoverSource.lastfm,
      ]) {
        expect(
          selectDiscordCoverImage(
            discovered: DiscordCoverResult(
              'https://covers.example/exact.jpg',
              source,
            ),
            stored: 'https://covers.example/stored.jpg',
            animated: 'https://covers.example/animated.gif',
          ),
          'https://covers.example/exact.jpg',
        );
      }
      expect(
        selectDiscordCoverImage(
          discovered: const DiscordCoverResult(
            'https://covers.example/portrait.jpg',
            DiscordCoverSource.artistPhoto,
          ),
          animated: 'https://covers.example/animated.gif',
        ),
        'https://covers.example/animated.gif',
      );
    },
  );

  test(
    'private networks, credentials and known placeholders are not sent to Discord',
    () {
      for (final url in [
        'file:///E:/cover.jpg',
        'http://localhost/cover.jpg',
        'http://127.0.0.1/cover.jpg',
        'http://10.1.2.3/cover.jpg',
        'http://172.16.1.2/cover.jpg',
        'http://192.168.1.2/cover.jpg',
        'http://100.64.1.2/cover.jpg',
        'http://[::1]/cover.jpg',
        'http://[fc00::1]/cover.jpg',
        'http://[::ffff:127.0.0.1]/cover.jpg',
        'http://music.local/cover.jpg',
        'https://user:password@example.com/cover.jpg',
        'https://covers.example/noimage.png',
        'https://covers.example/2a96cbd8b46e442fc41c2b86b821562f.jpg',
      ]) {
        expect(publicDiscordArtworkUrl(url), isNull, reason: url);
      }
      expect(
        publicDiscordArtworkUrl('https://covers.example/cover.jpg'),
        isNotNull,
      );
    },
  );
}
