import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiki/discord_artwork.dart';

const groupId = '3a048869-2167-4db4-9a9b-c0ec0484580f';
const imageUrl =
    'https://coverartarchive.org/release/25dac7c3-4f4f-49bd-af82-13b4091edce9/4735403281.gif';

Map<String, dynamic> track({
  String album = 'Airbrushed',
  String artist = 'Anamanaguchi',
}) => {
  'title': 'Track',
  'album': {
    'title': album,
    'artist': {'name': artist},
  },
};

Map<String, dynamic> group({
  String title = 'Airbrushed',
  String artist = 'Anamanaguchi',
  int score = 100,
}) => {
  'id': groupId,
  'title': title,
  'score': score,
  'artist-credit': [
    {
      'name': artist,
      'artist': {'name': artist},
    },
  ],
};

Map<String, dynamic> cover({
  String url = imageUrl,
  bool front = true,
  bool approved = true,
}) => {
  'image': url,
  'front': front,
  'approved': approved,
  'thumbnails': {'500': imageUrl.replaceFirst('.gif', '-500.jpg')},
};

// A tiny GIF with image sub-blocks, rather than counting marker bytes inside
// compressed data (which can contain arbitrary bytes, including 0x2c).
List<int> gif({int frames = 2}) => [
  ...ascii.encode('GIF89a'),
  1,
  0,
  1,
  0,
  0x80,
  0,
  0,
  0,
  0,
  0,
  255,
  255,
  255,
  ...[
    for (var i = 0; i < frames; i++) ...[
      0x21,
      0xf9,
      4,
      0,
      0,
      0,
      0,
      0,
      0x2c,
      0,
      0,
      0,
      0,
      1,
      0,
      1,
      0,
      0,
      2,
      2,
      0x4c,
      1,
      0,
    ],
  ],
  0x3b,
];

List<int> uint32(int value) => [
  value & 255,
  (value >> 8) & 255,
  (value >> 16) & 255,
  (value >> 24) & 255,
];

List<int> webp({int frames = 2, bool animated = true}) {
  List<int> chunk(String tag, List<int> payload) => [
    ...ascii.encode(tag),
    ...uint32(payload.length),
    ...payload,
    if (payload.length.isOdd) 0,
  ];
  final chunks = [
    ...chunk('VP8X', [animated ? 2 : 0, ...List.filled(9, 0)]),
    ...chunk('ANIM', List.filled(6, 0)),
    for (var i = 0; i < frames; i++) ...chunk('ANMF', List.filled(16, 0)),
  ];
  return [
    ...ascii.encode('RIFF'),
    ...uint32(chunks.length + 4),
    ...ascii.encode('WEBP'),
    ...chunks,
  ];
}

void main() {
  late Directory directory;
  late File cacheFile;
  late DateTime now;
  late List<http.Request> requests;
  late List<String> notifications;
  final services = <DiscordAnimatedArtwork>[];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'shiki_discord_artwork_test_',
    );
    cacheFile = File('${directory.path}/discord_artwork_cache.json');
    now = DateTime.utc(2026, 10, 6);
    requests = [];
    notifications = [];
  });
  tearDown(() async {
    for (final service in services) {
      service.dispose();
    }
    for (final service in services) {
      await service.idle;
    }
    services.clear();
    final prefix =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}shiki_discord_artwork_test_';
    if (!directory.absolute.path.startsWith(prefix)) {
      throw StateError('Unexpected test directory');
    }
    await directory.delete(recursive: true);
  });

  DiscordAnimatedArtwork service({
    FutureOr<http.Response> Function(http.Request)? handler,
    Duration timeout = const Duration(seconds: 12),
  }) {
    final result = DiscordAnimatedArtwork(
      cacheFile: cacheFile,
      onAvailable: notifications.add,
      now: () => now,
      searchInterval: Duration.zero,
      lookupTimeout: timeout,
      clientFactory: () => MockClient((request) async {
        requests.add(request);
        if (handler != null) return await handler(request);
        if (request.url.host == 'musicbrainz.org') {
          return http.Response(
            jsonEncode({
              'release-groups': [group()],
            }),
            200,
          );
        }
        if (request.url.path.startsWith('/release-group/')) {
          return http.Response(
            jsonEncode({
              'images': [cover()],
            }),
            200,
          );
        }
        return http.Response.bytes(gif(), 200);
      }),
    );
    services.add(result);
    return result;
  }

  test(
    'discovers an approved original animated cover without blocking RPC',
    () async {
      final artwork = service();
      expect(artwork.imageFor(track()), isNull);
      expect(requests, isEmpty);
      await artwork.idle;
      expect(artwork.imageFor(track()), imageUrl);
      expect(requests.length, 3);
      expect(notifications, [DiscordAnimatedArtwork.albumKey(track())]);
      expect(requests.first.headers['User-Agent'], contains('ShikiMusic'));
      expect(
        requests.first.url.queryParameters['query'],
        'releasegroup:"Airbrushed" AND artist:"Anamanaguchi"',
      );
      for (var i = 0; i < 100; i++) {
        artwork.imageFor(track());
      }
      await artwork.idle;
      expect(requests.length, 3);
    },
  );

  test('album cache serves other tracks and survives restart', () async {
    final first = service();
    first.imageFor(track());
    await first.idle;
    first.dispose();
    requests.clear();
    notifications.clear();
    final second = service();
    final otherTrack = track()..['title'] = 'Another track';
    second.imageFor(otherTrack);
    await second.idle;
    expect(second.imageFor(otherTrack), imageUrl);
    expect(requests, isEmpty);
    expect(notifications.length, 1);
  });

  test(
    'missing animations are persisted and not searched on every lyric',
    () async {
      final first = service(
        handler: (_) => http.Response('{"release-groups":[]}', 200),
      );
      first.imageFor(track());
      await first.idle;
      for (var i = 0; i < 50; i++) {
        first.imageFor(track());
      }
      await first.idle;
      expect(requests.length, 1);
      first.dispose();
      final second = service();
      second.imageFor(track());
      await second.idle;
      expect(requests.length, 1);
      now = now.add(const Duration(days: 15));
      second.imageFor(track());
      await second.idle;
      expect(second.imageFor(track()), imageUrl);
    },
  );

  for (final invalid in [
    group(title: 'Airbrushed (Remix)'),
    group(artist: 'Different artist'),
    group(score: 99),
    {
      ...group(),
      'artist-credit': [
        {'name': 'Anamanaguchi'},
        {'name': 'Unrelated'},
      ],
    },
    {...group(), 'id': '../../localhost'},
  ]) {
    test('rejects uncertain identity: $invalid', () async {
      final artwork = service(
        handler: (_) => http.Response(
          jsonEncode({
            'release-groups': [invalid],
          }),
          200,
        ),
      );
      artwork.imageFor(track());
      await artwork.idle;
      expect(artwork.imageFor(track()), isNull);
      expect(requests.length, 1);
      expect(notifications, isEmpty);
    });
  }

  test('rejects ambiguous exact album matches', () async {
    final artwork = service(
      handler: (_) => http.Response(
        jsonEncode({
          'release-groups': [group(), group()],
        }),
        200,
      ),
    );
    artwork.imageFor(track());
    await artwork.idle;
    expect(requests.length, 1);
    expect(artwork.imageFor(track()), isNull);
  });

  test('only approved front artwork can replace the static cover', () async {
    final artwork = service(
      handler: (request) {
        if (request.url.host == 'musicbrainz.org') {
          return http.Response(
            jsonEncode({
              'release-groups': [group()],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'images': [
              cover(front: false),
              cover(approved: false),
              cover(url: imageUrl.replaceFirst('.gif', '.jpg')),
              cover(url: 'http://127.0.0.1/cover.gif'),
              cover(url: 'https://example.org/cover.gif'),
            ],
          }),
          200,
        );
      },
    );
    artwork.imageFor(track());
    await artwork.idle;
    expect(requests.length, 2);
    expect(artwork.imageFor(track()), isNull);
  });

  test('a static GIF is not mistaken for animated artwork', () async {
    final artwork = service(
      handler: (request) {
        if (request.url.host == 'musicbrainz.org') {
          return http.Response(
            jsonEncode({
              'release-groups': [group()],
            }),
            200,
          );
        }
        if (request.url.path.startsWith('/release-group/')) {
          return http.Response(
            jsonEncode({
              'images': [cover()],
            }),
            200,
          );
        }
        return http.Response.bytes(gif(frames: 1), 200);
      },
    );
    artwork.imageFor(track());
    await artwork.idle;
    expect(artwork.imageFor(track()), isNull);
    expect(notifications, isEmpty);
  });

  test('transient provider failure uses a short backoff', () async {
    var failed = true;
    final artwork = service(
      handler: (_) {
        if (failed) return http.Response('Rate limited', 503);
        return http.Response('{"release-groups":[]}', 200);
      },
    );
    artwork.imageFor(track());
    await artwork.idle;
    failed = false;
    now = now.add(const Duration(minutes: 9));
    artwork.imageFor(track());
    await artwork.idle;
    expect(requests.length, 1);
    now = now.add(const Duration(minutes: 2));
    artwork.imageFor(track());
    await artwork.idle;
    expect(requests.length, 2);
  });

  test('rapid track skips retain only the latest pending album', () async {
    final gate = Completer<http.Response>();
    final started = Completer<void>();
    final artwork = service(
      handler: (request) {
        if (!started.isCompleted) {
          started.complete();
          return gate.future;
        }
        return http.Response('{"release-groups":[]}', 200);
      },
    );
    artwork.imageFor(track(album: 'First'));
    await started.future;
    artwork.imageFor(track(album: 'Skipped'));
    artwork.imageFor(track(album: 'Latest'));
    gate.complete(http.Response('{"release-groups":[]}', 200));
    await artwork.idle;
    expect(requests.length, 2);
    expect(requests.last.url.queryParameters['query'], contains('Latest'));
    expect(
      requests.any(
        (r) => r.url.queryParameters['query']?.contains('Skipped') ?? false,
      ),
      isFalse,
    );
  });

  test('old track artwork does not trigger a stale RPC update', () async {
    final gate = Completer<http.Response>();
    final started = Completer<void>();
    final artwork = service(
      handler: (request) {
        if (request.url.host == 'musicbrainz.org') {
          final query = request.url.queryParameters['query']!;
          return http.Response(
            jsonEncode({
              'release-groups': query.contains('Latest') ? [] : [group()],
            }),
            200,
          );
        }
        if (request.url.path.startsWith('/release-group/')) {
          return http.Response(
            jsonEncode({
              'images': [cover()],
            }),
            200,
          );
        }
        started.complete();
        return gate.future;
      },
    );
    artwork.imageFor(track());
    await started.future;
    artwork.imageFor(track(album: 'Latest'));
    gate.complete(http.Response.bytes(gif(), 200));
    await artwork.idle;
    expect(notifications, isEmpty);
    expect(artwork.imageFor(track(album: 'Latest')), isNull);
    expect(artwork.imageFor(track()), imageUrl);
  });

  test('dispose prevents callbacks and further lookups', () async {
    final gate = Completer<http.Response>();
    final started = Completer<void>();
    final artwork = service(
      handler: (_) {
        started.complete();
        return gate.future;
      },
    );
    artwork.imageFor(track());
    await started.future;
    artwork.dispose();
    gate.complete(http.Response('{"release-groups":[]}', 200));
    await artwork.idle;
    expect(artwork.imageFor(track()), isNull);
    expect(notifications, isEmpty);
    expect(requests.length, 1);
  });

  test('lookup timeout does not block normal status updates', () async {
    final gate = Completer<http.Response>();
    final artwork = service(
      handler: (_) => gate.future,
      timeout: const Duration(milliseconds: 30),
    );
    artwork.imageFor(track());
    await artwork.idle;
    expect(artwork.imageFor(track()), isNull);
    expect(notifications, isEmpty);
    gate.complete(http.Response('{"release-groups":[]}', 200));
  });

  test(
    'malformed cache and missing identity do not prevent discovery',
    () async {
      await cacheFile.writeAsString('broken');
      final artwork = service();
      expect(artwork.imageFor({'title': 'Unknown'}), isNull);
      expect(requests, isEmpty);
      artwork.imageFor(track());
      await artwork.idle;
      expect(artwork.imageFor(track()), imageUrl);
    },
  );

  test('cache cannot inject a local/private image URL', () async {
    await cacheFile.writeAsString(
      jsonEncode({
        'version': 1,
        'entries': {
          DiscordAnimatedArtwork.albumKey(track()): {
            'url': 'http://127.0.0.1/cover.gif',
            'expires': now.add(const Duration(days: 7)).millisecondsSinceEpoch,
          },
        },
      }),
    );
    final artwork = service();
    artwork.imageFor(track());
    await artwork.idle;
    expect(artwork.imageFor(track()), imageUrl);
    expect(requests.length, 3);
  });

  test('large artwork is skipped without decoding or displaying it', () async {
    final artwork = service(
      handler: (request) {
        if (request.url.host == 'musicbrainz.org') {
          return http.Response(
            jsonEncode({
              'release-groups': [group()],
            }),
            200,
          );
        }
        if (request.url.path.startsWith('/release-group/')) {
          return http.Response(
            jsonEncode({
              'images': [cover()],
            }),
            200,
          );
        }
        return http.Response.bytes(List.filled(2 * 1024 * 1024 + 1, 0), 200);
      },
    );
    artwork.imageFor(track());
    await artwork.idle;
    expect(artwork.imageFor(track()), isNull);
  });

  test('GIF parser requires real complete frame sub-blocks', () {
    expect(isAnimatedDiscordImage(gif()), isTrue);
    expect(isAnimatedDiscordImage(gif(frames: 1)), isFalse);
    expect(isAnimatedDiscordImage(gif().take(20).toList()), isFalse);
    final markersInCompressedData = gif(frames: 1);
    markersInCompressedData[markersInCompressedData.length - 3] = 0x2c;
    expect(isAnimatedDiscordImage(markersInCompressedData), isFalse);
    expect(isAnimatedDiscordImage(ascii.encode('<html>error</html>')), isFalse);
  });

  test('WebP parser requires animation header, flag and multiple frames', () {
    expect(isAnimatedDiscordImage(webp()), isTrue);
    expect(isAnimatedDiscordImage(webp(frames: 1)), isFalse);
    expect(isAnimatedDiscordImage(webp(animated: false)), isFalse);
    expect(isAnimatedDiscordImage(webp().take(30).toList()), isFalse);
  });

  test('non-Latin album identities are retained', () {
    expect(
      DiscordAnimatedArtwork.albumKey(track(album: '夜に駆ける', artist: 'ヨアソビ')),
      isNotNull,
    );
    expect(
      DiscordAnimatedArtwork.albumKey(track(album: 'ألبوم', artist: 'فنان')),
      isNotNull,
    );
  });

  test('cached artwork survives a transient refresh error', () async {
    final first = service();
    first.imageFor(track());
    await first.idle;
    first.dispose();
    final second = service(handler: (_) => http.Response('Unavailable', 503));
    now = now.add(const Duration(days: 8));
    second.imageFor(track());
    await second.idle;
    expect(second.imageFor(track()), imageUrl);
  });

  test(
    'live provider returns the original animated GIF',
    () async {
      final live = DiscordAnimatedArtwork(
        cacheFile: cacheFile,
        onAvailable: notifications.add,
      );
      services.add(live);
      expect(live.imageFor(track()), isNull);
      await live.idle;
      expect(live.imageFor(track()), imageUrl);
      expect(notifications, [DiscordAnimatedArtwork.albumKey(track())]);
    },
    skip: !const bool.fromEnvironment('SHIKI_LIVE_DISCORD_ARTWORK'),
  );
}
