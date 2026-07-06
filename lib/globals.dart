import 'package:flutter/material.dart';
import 'dart:io';

import 'audio_handler.dart';

// ── Enums ──────────────────────────────────────────────────────────────────

enum LoopMode { off, list, one }

// ── Models ─────────────────────────────────────────────────────────────────

class LyricLine {
  final Duration time;
  final String txt;
  final String textPayload;
  LyricLine(this.time, this.textPayload, this.txt);
}

// ── Global state ───────────────────────────────────────────────────────────

List<LyricLine> globalLyrics = [];
String noLrcData = "";
bool lrcLoading = false;
ValueNotifier<int> uiSignal = ValueNotifier(0);
int currentLine = -1;
ValueNotifier<dynamic> activeTrackNotifier = ValueNotifier(null);
String globalLocalPath = "";

// ── Reactive notifiers for cross-screen state ─────────────────────────────

ValueNotifier<bool> isPlayingNotifier = ValueNotifier(false);
ValueNotifier<bool> isShuffledNotifier = ValueNotifier(false);
ValueNotifier<LoopMode> loopModeNotifier = ValueNotifier(LoopMode.off);
ValueNotifier<Color> accentColorNotifier = ValueNotifier(const Color(0xFFFF5252));
ValueNotifier<String> languageNotifier = ValueNotifier('ru');
ValueNotifier<bool> vinylRotationNotifier = ValueNotifier(true);
ValueNotifier<String?> customBackgroundNotifier = ValueNotifier(null);
ValueNotifier<bool> playVideoClipNotifier = ValueNotifier(false);

// ── Track duration cache (populated as songs are played) ──────────────────

Map<int, int> trackDurations = {};

// ── Audio service globals ──────────────────────────────────────────────────

late AudioPlayerHandler audioHandler;
bool isAudioServiceActive = false;

// ── Platform helpers ───────────────────────────────────────────────────────

bool get isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

final Map<String, ImageProvider> _coverCache = {};

String getCoverFileName(dynamic currentObject) {
  if (currentObject == null || currentObject['album'] == null || currentObject['album']['cover'] == null) {
    return 'default.jpg';
  }
  final coverUrl = currentObject['album']['cover'].toString();
  try {
    final uri = Uri.parse(coverUrl);
    if (uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.last;
    }
  } catch (_) {}
  return 'default.jpg';
}

/// Returns [FileImage] if a local cover exists, otherwise [NetworkImage].
/// Results are cached to avoid rebuilding the provider on every frame.
ImageProvider getPictureProvider(dynamic currentObject) {
  final id = currentObject['id'] as int;
  final coverFileName = getCoverFileName(currentObject);
  final cacheKey = '$id-$coverFileName';
  final cached = _coverCache[cacheKey];
  if (cached != null) return cached;

  ImageProvider provider;
  if (globalLocalPath.isNotEmpty) {
    final localImage = File(
      '$globalLocalPath/cover_${id}_$coverFileName',
    );
    if (localImage.existsSync() && localImage.lengthSync() > 0) {
      provider = FileImage(localImage);
    } else {
      provider = NetworkImage(currentObject['album']['cover']);
    }
  } else {
    provider = NetworkImage(currentObject['album']['cover']);
  }

  // Simple LRU-like eviction when cache grows too large
  if (_coverCache.length > 150) {
    _coverCache.remove(_coverCache.keys.first);
  }
  _coverCache[cacheKey] = provider;
  return provider;
}

/// Returns a [Uri] pointing to the local cover file if it exists,
/// otherwise falls back to the network URL.
/// Used for Android notification artwork.
Uri getArtUri(dynamic track) {
  final id = track['id'] as int;
  final coverFileName = getCoverFileName(track);
  if (globalLocalPath.isNotEmpty) {
    final localCover = File('$globalLocalPath/cover_${id}_$coverFileName');
    if (localCover.existsSync() && localCover.lengthSync() > 0) return Uri.file(localCover.path);
  }
  return Uri.parse(track['album']['cover'].toString());
}

/// Clears the in-memory cover cache. Call this after cache wipe.
void clearCoverCache() => _coverCache.clear();
