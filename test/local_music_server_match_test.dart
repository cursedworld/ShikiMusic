import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiki/local_music_catalog.dart';
import 'package:shiki/local_music_server_match.dart';

void main() {
  final endpoint = Uri.parse('http://localhost:8000$localMusicMatchPath');
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
          return http.Response('{"status":"imported","track_id":11}', 201);
        }),
      );
      expect(await client.isAvailable(endpoint), isTrue);
      expect(
        await client.match(endpoint, entry),
        LocalMusicMatchOutcome.imported,
      );
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
        http.Response('{"status":"existing","track_id":21}', 200),
        http.Response('{"status":"no_match"}', 422),
        http.Response('{"status":"search_failed"}', 502),
        http.Response('{"status":"imported","track_id":-1}', 201),
      ];
      final client = LocalMusicServerMatchClient(
        client: MockClient((_) async => responses.removeAt(0)),
      );
      expect(
        await client.match(endpoint, entry),
        LocalMusicMatchOutcome.existing,
      );
      expect(
        await client.match(endpoint, entry),
        LocalMusicMatchOutcome.noMatch,
      );
      expect(
        await client.match(endpoint, entry),
        LocalMusicMatchOutcome.failed,
      );
      expect(
        await client.match(endpoint, entry),
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
        await client.match(
          endpoint,
          const LocalMusicEntry(id: -7, digest: '', title: 'No duration'),
        ),
        LocalMusicMatchOutcome.noMatch,
      );
    },
  );
}
