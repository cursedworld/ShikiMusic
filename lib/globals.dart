import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:convert';

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
ValueNotifier<Color> accentColorNotifier = ValueNotifier(
  const Color(0xFFFF5252),
);
ValueNotifier<String> languageNotifier = ValueNotifier('ru');
ValueNotifier<bool> vinylRotationNotifier = ValueNotifier(true);
ValueNotifier<String?> customBackgroundNotifier = ValueNotifier(null);
ValueNotifier<bool> playVideoClipNotifier = ValueNotifier(false);
ValueNotifier<bool> discordShowGitHubButtonNotifier = ValueNotifier(true);
ValueNotifier<bool> discordLyricsStatusNotifier = ValueNotifier(false);

// ── Track duration cache (populated as songs are played) ──────────────────

Map<int, int> trackDurations = {};

// ── Audio service globals ──────────────────────────────────────────────────

late AudioPlayerHandler audioHandler;
bool isAudioServiceActive = false;

// ── Platform helpers ───────────────────────────────────────────────────────

bool get isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

final Map<String, ImageProvider> _coverCache = {};
final ImageProvider _emptyCover = MemoryImage(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=',
  ),
);

String getCoverFileName(dynamic currentObject) {
  if (currentObject == null ||
      currentObject['album'] == null ||
      currentObject['album']['cover'] == null) {
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

String? getVersionedCoverName(dynamic track) {
  final version = track['album']?['cover_version']?.toString();
  if (version == null || !RegExp(r'^[a-f0-9]{64}$').hasMatch(version)) {
    return null;
  }
  return 'cover_${track['id']}_$version.jpg';
}

/// Returns [FileImage] if a local cover exists, otherwise [NetworkImage].
/// Results are cached to avoid rebuilding the provider on every frame.
ImageProvider getPictureProvider(dynamic currentObject) {
  final id = currentObject['id'] as int;
  final coverFileName = getCoverFileName(currentObject);
  final coverUrl = currentObject['album']?['cover']?.toString().trim() ?? '';
  final versionedName = getVersionedCoverName(currentObject);
  final artist = currentObject['album']?['artist'];
  final cacheKey =
      '$id-$coverFileName|$versionedName|$globalLocalPath|$coverUrl|'
      'artist:${artist?['id']}|${artist?['photo']}|${artist?['photo_version']}';
  final cached = _coverCache[cacheKey];
  if (cached != null) return cached;

  ImageProvider provider;
  if (globalLocalPath.isNotEmpty) {
    final localImage = File('$globalLocalPath/cover_${id}_$coverFileName');
    final fallbackImage = File('$globalLocalPath/cover_$id.jpg');
    final versionedImage = versionedName == null
        ? null
        : File('$globalLocalPath/$versionedName');
    if (versionedImage != null &&
        versionedImage.existsSync() &&
        versionedImage.lengthSync() > 0) {
      provider = FileImage(versionedImage);
    } else if (localImage.existsSync() && localImage.lengthSync() > 0) {
      provider = FileImage(localImage);
    } else if (fallbackImage.existsSync() && fallbackImage.lengthSync() > 0) {
      provider = FileImage(fallbackImage);
    } else {
      provider = coverUrl.isEmpty
          ? getArtistPhotoProvider(artist) ?? _emptyCover
          : NetworkImage(coverUrl);
    }
  } else {
    provider = coverUrl.isEmpty
        ? getArtistPhotoProvider(artist) ?? _emptyCover
        : NetworkImage(coverUrl);
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
Uri? getArtUri(dynamic track) {
  final id = track['id'] as int;
  final coverFileName = getCoverFileName(track);
  if (globalLocalPath.isNotEmpty) {
    final versionedName = getVersionedCoverName(track);
    if (versionedName != null) {
      final versioned = File('$globalLocalPath/$versionedName');
      if (versioned.existsSync() && versioned.lengthSync() > 0) {
        return Uri.file(versioned.path);
      }
    }
    final localCover = File('$globalLocalPath/cover_${id}_$coverFileName');
    if (localCover.existsSync() && localCover.lengthSync() > 0) {
      return Uri.file(localCover.path);
    }
    final fallbackCover = File('$globalLocalPath/cover_$id.jpg');
    if (fallbackCover.existsSync() && fallbackCover.lengthSync() > 0) {
      return Uri.file(fallbackCover.path);
    }
  }
  final coverUrl = track['album']?['cover']?.toString().trim() ?? '';
  if (coverUrl.isNotEmpty) return Uri.parse(coverUrl);
  final artistPhoto = getArtistPhotoProvider(track['album']?['artist']);
  if (artistPhoto is FileImage) return Uri.file(artistPhoto.file.path);
  if (artistPhoto is NetworkImage) return Uri.tryParse(artistPhoto.url);
  return null;
}

/// Returns an [ImageProvider] for an artist avatar/photo.
ImageProvider? getArtistPhotoProvider(dynamic artistData) {
  if (artistData == null) return null;
  final artistId = artistData is Map ? artistData['id'] : null;
  if (artistId != null && globalLocalPath.isNotEmpty) {
    final version = artistData['photo_version']?.toString();
    if (version != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(version)) {
      final versioned = File(
        '$globalLocalPath/artist_${artistId}_$version.jpg',
      );
      if (versioned.existsSync() && versioned.lengthSync() > 0) {
        return FileImage(versioned);
      }
    }
    final localPhoto = File('$globalLocalPath/artist_$artistId.jpg');
    if (localPhoto.existsSync() && localPhoto.lengthSync() > 0) {
      return FileImage(localPhoto);
    }
  }

  final photoUrl = artistData is Map ? artistData['photo']?.toString() : null;
  if (photoUrl == null || photoUrl.isEmpty) return null;

  return NetworkImage(photoUrl);
}

/// Clears the in-memory cover cache. Call this after cache wipe.
void clearCoverCache() => _coverCache.clear();

/// Refresh only the provider whose local cover was written or removed.
void invalidateTrackCover(int trackId) =>
    _coverCache.removeWhere((key, _) => key.startsWith('$trackId-'));

void invalidateArtistPhoto(int artistId) =>
    _coverCache.removeWhere((key, _) => key.contains('|artist:$artistId|'));
