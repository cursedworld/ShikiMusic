import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'local_music_catalog.dart';
import 'local_music_metadata.dart';

const localMusicMatchPath = '/api/local-music/metadata/';

enum LocalMusicMatchOutcome { queued, existing, metadata, noMatch, failed }

typedef LocalMusicMatchResult = ({
  LocalMusicMatchOutcome outcome,
  LocalMusicMetadata? metadata,
});

/// One-shot lookups against the configured server. Nothing is queued for
/// later reconnection; the copied audio always remains usable offline.
class LocalMusicServerMatchClient {
  LocalMusicServerMatchClient({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  Future<bool> isAvailable(Uri endpoint) async {
    try {
      final (status, json) = await _request(
        http.Request('GET', endpoint),
        maxBytes: 4096,
      ).timeout(const Duration(seconds: 2));
      return status == 200 && json is Map && json['version'] == 1;
    } catch (_) {
      return false;
    }
  }

  Future<LocalMusicMatchResult> match(
    Uri endpoint,
    LocalMusicEntry entry, {
    required String serverKey,
  }) async {
    if (entry.duration <= 0) {
      return (outcome: LocalMusicMatchOutcome.noMatch, metadata: null);
    }
    try {
      final request = http.Request('POST', endpoint)
        ..headers['Content-Type'] = 'application/json; charset=utf-8'
        ..body = jsonEncode({
          'title': entry.title,
          'artist': entry.artist,
          'album': entry.album,
          'duration': entry.duration,
        });
      final (status, body) = await _request(
        request,
        maxBytes: 1024 * 1024,
      ).timeout(const Duration(minutes: 2));
      if (body is Map) {
        final outcome = switch ((status, body['status'])) {
          (202, 'queued') => LocalMusicMatchOutcome.queued,
          (200, 'existing') => LocalMusicMatchOutcome.existing,
          (200, 'metadata') => LocalMusicMatchOutcome.metadata,
          _ => null,
        };
        if (outcome != null) {
          final metadata = LocalMusicMetadata.decode(
            body['metadata'],
            serverKey: serverKey,
          );
          if (metadata != null) return (outcome: outcome, metadata: metadata);
        }
      }
      if (status == 422 || status == 400) {
        return (outcome: LocalMusicMatchOutcome.noMatch, metadata: null);
      }
    } catch (_) {
      // A network failure cannot undo the local import.
    }
    return (outcome: LocalMusicMatchOutcome.failed, metadata: null);
  }

  Future<(int, Object?)> _request(
    http.Request request, {
    required int maxBytes,
  }) async {
    // Do not forward any tags on a redirect to another origin.
    request.followRedirects = false;
    final response = await _client.send(request);
    final body = BytesBuilder(copy: false);
    await for (final bytes in response.stream) {
      if (body.length + bytes.length > maxBytes) {
        return (response.statusCode, null);
      }
      body.add(bytes);
    }
    return (response.statusCode, jsonDecode(utf8.decode(body.takeBytes())));
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
