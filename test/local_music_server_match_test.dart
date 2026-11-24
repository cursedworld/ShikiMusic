import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiki/local_music_catalog.dart';
import 'package:shiki/local_music_server_match.dart';

void main() {
  final endpoint = Uri.parse('http://localhost:8000$localMusicMatchPath');
  final key = 'c' * 64;
  const entry = LocalMusicEntry(
    id: -7,
    digest: 'not transmitted',
    title: 'Трек 東京',
    artist: 'Исполнитель',
    album: 'Test Album',
    duration: 164,
    lyrics: 'not transmitted',
  );

  test(
    'probes support then sends tags only and never follows redirects',
    () async {
      final methods = <String>[];
      final client = LocalMusicServerMatchClient(
        client: MockClient((request) async {
          expect(request.url, endpoint);
          expect(request.followRedirects, isFalse);
          methods.add(request.method);
          if (request.method == 'GET') {
            expect(request.body, isEmpty);
            return http.Response('{"version":1}', 200);
          }
          expect(jsonDecode(utf8.decode(request.bodyBytes)), {
            'title': entry.title,
            'artist': entry.artist,
            'album': entry.album,
            'duration': entry.duration,
          });
          return http.Response(
            jsonEncode({
              'status': 'queued',
              'metadata': {
                'title': entry.title,
                'artists': [entry.artist, 'Guest'],
                'album': entry.album,
                'source_id': 'youtube:abcdefghijk',
                'lyrics': List.filled(600, '[00:01.00]Some text').join('\n'),
                'audio_file': 'ignored',
              },
            }),
            202,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      expect(await client.isAvailable(endpoint), isTrue);
      final result = await client.match(endpoint, entry, serverKey: key);
      expect(result.outcome, LocalMusicMatchOutcome.queued);
      expect(result.metadata?.artists, [entry.artist, 'Guest']);
      expect(result.metadata!.lyrics.length, greaterThan(4096));
      expect(result.metadata!.toJson().containsKey('audio_file'), isFalse);
      expect(methods, ['GET', 'POST']);
    },
  );

  test(
    'old, offline and redirecting servers do not advertise support',
    () async {
      for (final status in [404, 307, 503]) {
        final client = LocalMusicServerMatchClient(
          client: MockClient((request) async {
            return http.Response('{"version":1}', status);
          }),
        );
        expect(await client.isAvailable(endpoint), isFalse);
      }
      final offline = LocalMusicServerMatchClient(
        client: MockClient((_) async {
          throw http.ClientException('Offline');
        }),
      );
      expect(await offline.isAvailable(endpoint), isFalse);
    },
  );

  test(
    'maps existing, unconfirmed and failed results without inventing success',
    () async {
      final responses = [
        http.Response(
          '{"status":"existing","metadata":{"track_id":21,"title":"Track","artists":["Artist"]}}',
          200,
        ),
        http.Response('{"status":"no_match"}', 422),
        http.Response('{"status":"search_failed"}', 502),
        http.Response(
          '{"status":"queued","metadata":{"title":"Track","artists":[]}}',
          202,
        ),
      ];
      final client = LocalMusicServerMatchClient(
        client: MockClient((_) async => responses.removeAt(0)),
      );
      expect(
        (await client.match(endpoint, entry, serverKey: key)).outcome,
        LocalMusicMatchOutcome.existing,
      );
      expect(
        (await client.match(endpoint, entry, serverKey: key)).outcome,
        LocalMusicMatchOutcome.noMatch,
      );
      expect(
        (await client.match(endpoint, entry, serverKey: key)).outcome,
        LocalMusicMatchOutcome.failed,
      );
      expect(
        (await client.match(endpoint, entry, serverKey: key)).outcome,
        LocalMusicMatchOutcome.failed,
      );
    },
  );

  test(
    'unmeasurable recordings are not submitted as an automatic match',
    () async {
      final client = LocalMusicServerMatchClient(
        client: MockClient((_) async {
          fail('Must not contact the server');
        }),
      );
      expect(
        (await client.match(
          endpoint,
          const LocalMusicEntry(id: -7, digest: '', title: 'No duration'),
          serverKey: key,
        )).outcome,
        LocalMusicMatchOutcome.noMatch,
      );
    },
  );
}
