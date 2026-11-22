import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'lyric_timing.dart';
import 'server_config.dart';

enum LyricTimingProposalResult {
  pending,
  accepted,
  rejected,
  versionConflict,
  unavailable,
  rateLimited,
  failed,
}

/// Used only in the editor; no background probing, uploads or retry queue.
class LyricTimingProposalClient {
  LyricTimingProposalClient({
    http.Client? client,
    String? serverBase,
    this.timeout = const Duration(seconds: 4),
  }) : _client = client ?? http.Client(),
       _serverBase = serverBase ?? configuredServerBaseUrl;

  final http.Client _client;
  final String _serverBase;
  final Duration timeout;

  Future<bool> supportsProposals() async {
    try {
      final response = await _request('GET', 'api/lyric-timing-proposals/');
      if (response.statusCode != HttpStatus.ok) return false;
      final body = jsonDecode(response.body);
      return body is Map && body['lyric_timing_proposals'] == 1;
    } catch (_) {
      // Older, offline or unrelated servers do not expose the action.
      return false;
    }
  }

  Future<LyricTimingProposalResult> submit(
    LyricTimingCorrection correction,
  ) async {
    try {
      final response = await _request(
        'POST',
        'api/tracks/${correction.trackId}/lyric-timing-proposals/',
        body: {
          'audio_sha256': correction.audioSha256,
          'lrc_sha256': correction.lrcSha256,
          'advance_ms': correction.advanceMilliseconds,
        },
      );
      return switch (response.statusCode) {
        HttpStatus.ok || HttpStatus.created => switch (jsonDecode(
          response.body,
        )) {
          {'status': 'pending'} => LyricTimingProposalResult.pending,
          {'status': 'accepted'} => LyricTimingProposalResult.accepted,
          {'status': 'rejected'} => LyricTimingProposalResult.rejected,
          _ => LyricTimingProposalResult.failed,
        },
        HttpStatus.conflict => LyricTimingProposalResult.versionConflict,
        HttpStatus.tooManyRequests => LyricTimingProposalResult.rateLimited,
        HttpStatus.notFound ||
        HttpStatus.serviceUnavailable => LyricTimingProposalResult.unavailable,
        _ => LyricTimingProposalResult.failed,
      };
    } on FormatException {
      return LyricTimingProposalResult.failed;
    } on Exception {
      return LyricTimingProposalResult.unavailable;
    }
  }

  Future<http.Response> _request(
    String method,
    String path, {
    Map<String, Object>? body,
  }) async {
    final cancel = Completer<void>();
    final request = http.AbortableRequest(
      method,
      buildServerUriForBase(_serverBase, path),
      abortTrigger: cancel.future,
    )..followRedirects = false;
    request.headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      return await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
    } finally {
      cancel.complete();
    }
  }

  void close() => _client.close();
}
