import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

enum CatalogSyncPhase { idle, checking, synced, offline, error }

class CatalogSyncStatus extends ChangeNotifier {
  CatalogSyncPhase phase = CatalogSyncPhase.idle;
  DateTime? lastSuccess;

  void checking() => _update(CatalogSyncPhase.checking);

  void succeeded({DateTime? at}) {
    lastSuccess = at ?? DateTime.now();
    _update(CatalogSyncPhase.synced, force: true);
  }

  void failed(Object error) {
    final offline =
        error is SocketException ||
        error is TimeoutException ||
        error is http.ClientException;
    _update(offline ? CatalogSyncPhase.offline : CatalogSyncPhase.error);
  }

  void _update(CatalogSyncPhase next, {bool force = false}) {
    if (!force && phase == next) return;
    phase = next;
    notifyListeners();
  }
}

/// Validate the whole response before any live queue or offline cache changes.
List<dynamic> decodeTrackCatalog(
  List<int> bytes, {
  bool hasCachedTracks = false,
}) {
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! List || (hasCachedTracks && decoded.isEmpty)) {
    throw const FormatException('Invalid or unexpectedly empty track catalog.');
  }
  final ids = <int>{};
  for (final track in decoded) {
    if (track is! Map ||
        track['id'] is! int ||
        (track['id'] as int) <= 0 ||
        !ids.add(track['id'] as int) ||
        track['title'] is! String ||
        (track['artists'] != null && track['artists'] is! List) ||
        (track['album'] != null && track['album'] is! Map)) {
      throw const FormatException('Invalid track in catalog.');
    }
  }
  return List<dynamic>.from(decoded);
}
