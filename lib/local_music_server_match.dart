import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'local_music_catalog.dart';

const localMusicMatchPath = '/api/local-music/match/';

enum LocalMusicMatchOutcome { imported, existing, noMatch, failed }

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
      ).timeout(const Duration(seconds: 2));
      return status == 200 && json is Map && json['version'] == 1;
    } catch (_) {
      return false;
    }
  }

  Future<LocalMusicMatchOutcome> match(
    Uri endpoint,
    LocalMusicEntry entry,
  ) async {
    if (entry.duration <= 0) return LocalMusicMatchOutcome.noMatch;
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
      ).timeout(const Duration(minutes: 5));
      if (body is! Map) return LocalMusicMatchOutcome.failed;
      final id = body['track_id'];
      if (id is int && id > 0) {
        if (status == 201 && body['status'] == 'imported') {
          return LocalMusicMatchOutcome.imported;
        }
        if (status == 200 && body['status'] == 'existing') {
          return LocalMusicMatchOutcome.existing;
        }
      }
      if (status == 422 || status == 400) return LocalMusicMatchOutcome.noMatch;
    } catch (_) {
      // A network failure cannot undo the local import.
    }
    return LocalMusicMatchOutcome.failed;
  }

  Future<(int, Object?)> _request(http.Request request) async {
    // Do not forward any tags on a redirect to another origin.
    request.followRedirects = false;
    final response = await _client.send(request);
    final body = BytesBuilder(copy: false);
    await for (final bytes in response.stream) {
      if (body.length + bytes.length > 4096) {
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
