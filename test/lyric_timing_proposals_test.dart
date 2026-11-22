import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiki/lyric_timing.dart';
import 'package:shiki/lyric_timing_proposals.dart';

void main() {
  final LyricTimingCorrection correction = (
    trackId: 23,
    audioSha256: 'a' * 64,
    lrcSha256: 'b' * 64,
    advanceMilliseconds: -300,
  );

  LyricTimingProposalClient makeClient(
    Future<http.Response> Function(http.Request) handle, {
    Duration timeout = const Duration(seconds: 4),
  }) {
    final service = LyricTimingProposalClient(
      client: MockClient(handle),
      serverBase: 'http://127.0.0.1:8000/player/',
      timeout: timeout,
    );
    addTearDown(service.close);
    return service;
  }

  test(
    'probe only requests anonymous capability on the configured server',
    () async {
      final client = makeClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.url.toString(),
          'http://127.0.0.1:8000/player/api/lyric-timing-proposals/',
        );
        expect(request.body, isEmpty);
        expect(request.followRedirects, isFalse);
        return http.Response('{"lyric_timing_proposals":1}', 200);
      });
      expect(await client.supportsProposals(), isTrue);
    },
  );

  test('old or not-yet-migrated servers hide the feature', () async {
    for (final response in [
      http.Response('<html>Not found</html>', 404),
      http.Response('{"error":"lyric_timing_unavailable"}', 503),
      http.Response('{"lyric_timing_proposals":2}', 200),
      http.Response('<html>Other application</html>', 200),
    ]) {
      expect(
        await makeClient((_) async => response).supportsProposals(),
        isFalse,
      );
    }
  });

  test(
    'only the signed shift and two hashes are posted, without redirects',
    () async {
      final client = makeClient((request) async {
        expect(request.method, 'POST');
        expect(
          request.url.path,
          '/player/api/tracks/23/lyric-timing-proposals/',
        );
        expect(request.followRedirects, isFalse);
        expect(request.headers['content-type'], contains('application/json'));
        expect(jsonDecode(request.body), {
          'audio_sha256': correction.audioSha256,
          'lrc_sha256': correction.lrcSha256,
          'advance_ms': -300,
        });
        return http.Response('{"status":"pending"}', 201);
      });
      expect(
        await client.submit(correction),
        LyricTimingProposalResult.pending,
      );
    },
  );

  test(
    'duplicate, stale, rate-limited and invalid responses stay distinct',
    () async {
      for (final (code, body, result) in [
        (200, '{"status":"pending"}', LyricTimingProposalResult.pending),
        (200, '{"status":"accepted"}', LyricTimingProposalResult.accepted),
        (200, '{"status":"rejected"}', LyricTimingProposalResult.rejected),
        (409, '{}', LyricTimingProposalResult.versionConflict),
        (429, '{}', LyricTimingProposalResult.rateLimited),
        (404, '{}', LyricTimingProposalResult.unavailable),
        (503, '{}', LyricTimingProposalResult.unavailable),
        (302, '', LyricTimingProposalResult.failed),
        (200, 'not JSON', LyricTimingProposalResult.failed),
      ]) {
        final client = makeClient((_) async => http.Response(body, code));
        expect(await client.submit(correction), result, reason: '$code $body');
      }
    },
  );

  test('timeout and connection failure do not queue retries', () async {
    var posts = 0;
    final client = makeClient((request) async {
      if (request.method == 'GET') throw http.ClientException('Disconnected');
      posts++;
      return Completer<http.Response>().future;
    }, timeout: const Duration(milliseconds: 10));
    expect(await client.supportsProposals(), isFalse);
    expect(
      await client.submit(correction),
      LyricTimingProposalResult.unavailable,
    );
    expect(posts, 1);
  });
}
