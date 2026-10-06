import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'atomic_file_store.dart';
import 'media_file_downloader.dart';
import 'server_config.dart';

String _textHash(String text) => sha256.convert(utf8.encode(text)).toString();
const _unknownMetadata =
    '0000000000000000000000000000000000000000000000000000000000000000';

Future<String> _hashFile(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

Future<String> _backgroundHash(String path) =>
    Isolate.run(() => _hashFile(path));

class TrackContentVersions {
  const TrackContentVersions({
    required this.audio,
    required this.lyrics,
    required this.metadata,
    this.video,
    this.artwork,
  });

  factory TrackContentVersions.fromJson(dynamic value) {
    if (value is! Map) throw const FormatException('Missing track versions');
    final pattern = RegExp(r'^[a-f0-9]{64}$');
    String digest(String key) {
      final result = value[key];
      if (result is! String || !pattern.hasMatch(result)) {
        throw FormatException('Invalid $key version');
      }
      return result;
    }

    return TrackContentVersions(
      audio: value['audio'] == null ? null : digest('audio'),
      lyrics: digest('lyrics'),
      metadata: digest('metadata'),
      video: value['video'] == null ? null : digest('video'),
      artwork: value['artwork'] == null ? null : digest('artwork'),
    );
  }

  final String? audio;
  final String lyrics;
  final String metadata;
  final String? video;
  final String? artwork;

  Map<String, dynamic> toJson() => {
    'audio': audio,
    'lyrics': lyrics,
    'metadata': metadata,
    'video': video,
    'artwork': artwork,
  };

  String get signature => '$audio:$lyrics:$metadata:$video:$artwork';
}

class TrackUpdateOffer {
  const TrackUpdateOffer({
    required this.id,
    required this.title,
    required this.versions,
  });
  final int id;
  final String title;
  final TrackContentVersions versions;
  String get signature => '$id:${versions.signature}';
}

class _LocalTrack {
  const _LocalTrack(
    this.versions,
    this.audioName,
    this.lyricsName, {
    this.hasAudio = true,
    this.videoName,
  });
  final TrackContentVersions versions;
  final String audioName;
  final String? lyricsName;
  final bool hasAudio;
  final String? videoName;
  Map<String, dynamic> toJson() => {
    'versions': versions.toJson(),
    'audio': audioName,
    'lyrics': lyricsName,
    'has_audio': hasAudio,
    'video': videoName,
  };
}

/// Polls catalog revisions and cached audio/lyrics. Files and the index are promoted separately:
/// the old index remains authoritative until all new content is verified.
class TrackUpdateMonitor {
  TrackUpdateMonitor({
    required this.directory,
    required this.tracks,
    String? serverBase,
    http.Client? client,
    Future<String> Function(String)? hashFile,
    this.interval = const Duration(seconds: 12),
    this.requestTimeout = const Duration(seconds: 5),
    this.onCatalogChanged,
  }) : _base = serverBase ?? configuredServerBaseUrl,
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _downloader = MediaFileDownloader(client: client, maxConcurrent: 1),
       _hash = hashFile ?? _backgroundHash;

  final Directory directory;
  final Iterable<dynamic> Function() tracks;
  final String _base;
  final http.Client _client;
  final bool _ownsClient;
  final Future<String> Function(String) _hash;
  final Duration interval;
  final Duration requestTimeout;
  final Future<void> Function()? onCatalogChanged;
  final offers = ValueNotifier<List<TrackUpdateOffer>>(const []);
  final Map<int, _LocalTrack> _local = {};
  final Map<String, String> _etags = {};
  final Map<String, List<dynamic>> _manifests = {};
  final Set<Completer<void>> _requests = {};
  final MediaFileDownloader _downloader;
  Future<void> _tail = Future<void>.value();
  Timer? _timer;
  bool _closed = false;
  bool _checking = false;
  String? _catalogEtag;
  File get _index => File('${directory.path}/track_versions.json');

  File audioFile(int id) {
    final name = _local[id]?.audioName;
    return File('${directory.path}/${name ?? 'track_$id.mp3'}');
  }

  File lyricsFile(int id) =>
      File('${directory.path}/${_local[id]?.lyricsName ?? 'track_$id.lrc'}');
  File videoFile(int id) =>
      File('${directory.path}/${_local[id]?.videoName ?? 'video_$id.mp4'}');
  bool hasManagedLyrics(int id) =>
      _local[id]?.lyricsName ==
      'track_${id}_${_local[id]?.versions.lyrics}.lrc';

  Future<void> load() async {
    try {
      final data = jsonDecode(await _index.readAsString());
      if (data is! Map) return;
      for (final entry in data.entries) {
        final id = int.tryParse(entry.key.toString());
        final value = entry.value;
        if (id == null || id <= 0 || value is! Map) continue;
        try {
          final versions = TrackContentVersions.fromJson(value['versions']);
          bool safe(dynamic name, String extension) =>
              name is String &&
              RegExp(
                '^track_$id(?:_[a-f0-9]{64})?\\.$extension\$',
              ).hasMatch(name);
          if (!safe(value['audio'], 'mp3') ||
              (value['lyrics'] != null && !safe(value['lyrics'], 'lrc'))) {
            continue;
          }
          if (value['audio'] != 'track_$id.mp3' &&
              value['audio'] != 'track_${id}_${versions.audio}.mp3') {
            continue;
          }
          if (value['lyrics'] != null &&
              value['lyrics'] != 'track_$id.lrc' &&
              value['lyrics'] != 'track_${id}_${versions.lyrics}.lrc') {
            continue;
          }
          final videoName = value['video'];
          if (videoName != null &&
              videoName != 'video_$id.mp4' &&
              videoName != 'video_${id}_${versions.video}.mp4') {
            continue;
          }
          final audioStat = await File(
            '${directory.path}/${value['audio']}',
          ).stat();
          if (_closed) return;
          final hasAudio = value['has_audio'] != false;
          if (hasAudio) {
            if (audioStat.type != FileSystemEntityType.file ||
                audioStat.size == 0) {
              continue;
            }
          } else {
            final hasLyrics =
                value['lyrics'] != null &&
                await File('${directory.path}/${value['lyrics']}').exists();
            final hasVideo =
                videoName != null &&
                await File('${directory.path}/$videoName').exists();
            if (!hasLyrics && !hasVideo) {
              continue;
            }
          }
          _local[id] = _LocalTrack(
            versions,
            value['audio'] as String,
            value['lyrics'] as String?,
            hasAudio: hasAudio,
            videoName: videoName as String?,
          );
        } on FormatException {
          continue;
        }
      }
    } on FileSystemException {
      // First run or an unavailable index: legacy downloads remain usable.
    } on FormatException {
      // Do not delete files when an index cannot be decoded.
    }
  }

  void start() {
    if (_closed || _timer != null) return;
    unawaited(checkNow());
    _timer = Timer.periodic(interval, (_) => unawaited(checkNow()));
  }

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _tail.then((_) {
      if (_closed) throw StateError('Track update monitor closed');
      return operation();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<http.Response> _get(
    String path, {
    Map<String, Object?>? query,
    String? etag,
  }) async {
    if (_closed) throw StateError('Track update monitor closed');
    final abort = Completer<void>();
    _requests.add(abort);
    final timer = Timer(requestTimeout, () {
      if (!abort.isCompleted) abort.complete();
    });
    try {
      final request = http.AbortableRequest(
        'GET',
        buildServerUriForBase(_base, path, queryParameters: query),
        abortTrigger: abort.future,
      );
      if (etag != null) request.headers['If-None-Match'] = etag;
      return await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(requestTimeout);
    } finally {
      timer.cancel();
      if (!abort.isCompleted) abort.complete();
      _requests.remove(abort);
    }
  }

  Future<void> _save(Map<int, _LocalTrack> records) =>
      atomicFileStore.writeString(
        _index,
        jsonEncode(
          records.map((id, record) => MapEntry('$id', record.toJson())),
        ),
      );

  Future<_LocalTrack> _legacy(
    int id,
    Map track,
    TrackContentVersions? remote,
  ) async {
    final audio = audioFile(id);
    final lrc = lyricsFile(id);
    final lyrics = await lrc.exists()
        ? await lrc.readAsString()
        : (track['lyrics']?.toString() ?? '');
    final audioStat = await audio.stat();
    final hasAudio =
        audioStat.type == FileSystemEntityType.file && audioStat.size > 0;
    final digest = hasAudio ? await _hash(audio.path) : remote?.audio;
    final video = videoFile(id);
    final videoStat = await video.stat();
    final hasVideo =
        videoStat.type == FileSystemEntityType.file && videoStat.size > 0;
    return _LocalTrack(
      TrackContentVersions(
        audio: digest,
        lyrics: _textHash(lyrics),
        metadata: remote?.metadata ?? _unknownMetadata,
        video: hasVideo ? await _hash(video.path) : remote?.video,
        artwork: remote?.artwork,
      ),
      audio.uri.pathSegments.last,
      await lrc.exists() ? lrc.uri.pathSegments.last : null,
      hasAudio: hasAudio,
      videoName: hasVideo ? video.uri.pathSegments.last : null,
    );
  }

  Future<void> registerDownload(Map track) => _serial(() async {
    final id = track['id'];
    if (id is! int) return;
    final old = _local[id];
    final newAudio = !(old?.hasAudio ?? false) && await audioFile(id).exists();
    final newVideo = old?.videoName == null && await videoFile(id).exists();
    if (!newAudio && !newVideo) {
      return;
    }
    final record = await _legacy(id, track, _local[id]?.versions);
    if (_closed) return;
    final next = {..._local, id: record};
    await _save(next);
    if (!_closed) _local[id] = record;
  });

  Future<void> acknowledgeLocalLyrics(int id, String lyrics) =>
      _serial(() async {
        final old = _local[id];
        if (old == null || hasManagedLyrics(id)) return;
        final file = lyricsFile(id);
        if (!await file.exists() || await file.readAsString() != lyrics) return;
        final hash = _textHash(lyrics);
        final record = _LocalTrack(
          TrackContentVersions(
            audio: old.versions.audio,
            lyrics: hash,
            metadata: old.versions.metadata,
            video: old.versions.video,
            artwork: old.versions.artwork,
          ),
          old.audioName,
          file.uri.pathSegments.last,
          hasAudio: old.hasAudio,
          videoName: old.videoName,
        );
        final next = {..._local, id: record};
        await _save(next);
        if (_closed) return;
        _local[id] = record;
        _publish(
          offers.value
              .where(
                (offer) =>
                    offer.id != id ||
                    offer.versions.lyrics != hash ||
                    offer.versions.audio != old.versions.audio,
              )
              .toList(),
        );
      });

  Future<void> checkNow() async {
    if (_closed || _checking) return;
    _checking = true;
    try {
      await _serial(() async {
        final catalog = await _get(
          'api/tracks/catalog-revision/',
          etag: _catalogEtag,
        );
        if (catalog.statusCode == 200) {
          final previous = _catalogEtag;
          final next = catalog.headers['etag'];
          if ((previous == null || previous != next) && !_closed) {
            await onCatalogChanged?.call();
          }
          _catalogEtag = next;
        } else if (catalog.statusCode != 304) {
          throw HttpException('Catalog check: HTTP ${catalog.statusCode}');
        }
        final byId = <int, Map>{};
        for (final track in tracks()) {
          if (track is Map && track['id'] is int) {
            byId[track['id'] as int] = track;
          }
        }
        for (final entry in _local.entries) {
          byId.putIfAbsent(entry.key, () => {'id': entry.key});
        }
        final ids = <int>[];
        for (final id in byId.keys) {
          final stat = await audioFile(id).stat();
          if (_closed) return;
          if ((stat.type == FileSystemEntityType.file && stat.size > 0) ||
              await lyricsFile(id).exists() ||
              await videoFile(id).exists()) {
            ids.add(id);
          }
        }
        ids.sort();
        final pending = <TrackUpdateOffer>[];
        var changedIndex = false;
        for (var offset = 0; offset < ids.length; offset += 100) {
          final batch = ids.skip(offset).take(100).join(',');
          final response = await _get(
            'api/tracks/revisions/',
            query: {'ids': batch},
            etag: _etags[batch],
          );
          List<dynamic> manifest;
          if (response.statusCode == 304 && _manifests.containsKey(batch)) {
            manifest = _manifests[batch]!;
          } else if (response.statusCode == 200) {
            final data = jsonDecode(utf8.decode(response.bodyBytes));
            if (data is! List) {
              throw const FormatException('Invalid revision manifest');
            }
            manifest = data;
            _manifests[batch] = manifest;
            final tag = response.headers['etag'];
            if (tag != null) _etags[batch] = tag;
          } else {
            throw HttpException('Revision check: HTTP ${response.statusCode}');
          }
          for (final item in manifest) {
            if (_closed) return;
            if (item is! Map ||
                item['id'] is! int ||
                !byId.containsKey(item['id'])) {
              continue;
            }
            final id = item['id'] as int;
            final remote = TrackContentVersions.fromJson(
              item['content_versions'],
            );
            if (!_local.containsKey(id)) {
              _local[id] = await _legacy(id, byId[id]!, remote);
              changedIndex = true;
            } else if (_local[id]!.versions.metadata == _unknownMetadata) {
              final old = _local[id]!;
              _local[id] = _LocalTrack(
                TrackContentVersions(
                  audio: old.versions.audio,
                  lyrics: old.versions.lyrics,
                  metadata: remote.metadata,
                  video: old.versions.video,
                  artwork: remote.artwork,
                ),
                old.audioName,
                old.lyricsName,
                hasAudio: old.hasAudio,
                videoName: old.videoName,
              );
              changedIndex = true;
            }
            final local = _local[id]!;
            final changedMedia =
                (local.hasAudio &&
                    remote.audio != null &&
                    remote.audio != local.versions.audio) ||
                remote.lyrics != local.versions.lyrics ||
                (local.videoName != null &&
                    remote.video != null &&
                    remote.video != local.versions.video);
            if (!changedMedia && remote.metadata != local.versions.metadata) {
              _local[id] = _LocalTrack(
                TrackContentVersions(
                  audio: local.versions.audio,
                  lyrics: local.versions.lyrics,
                  metadata: remote.metadata,
                  video: local.versions.video,
                  artwork: remote.artwork,
                ),
                local.audioName,
                local.lyricsName,
                hasAudio: local.hasAudio,
                videoName: local.videoName,
              );
              changedIndex = true;
            }
            if (changedMedia) {
              pending.add(
                TrackUpdateOffer(
                  id: id,
                  title: item['title']?.toString() ?? '$id',
                  versions: remote,
                ),
              );
            }
          }
        }
        if (_closed) return;
        if (changedIndex) await _save(_local);
        _publish(pending);
        // Discard batches for files the user explicitly removed.
        final batches = <String>{};
        for (var offset = 0; offset < ids.length; offset += 100) {
          batches.add(ids.skip(offset).take(100).join(','));
        }
        _etags.removeWhere((key, _) => !batches.contains(key));
        _manifests.removeWhere((key, _) => !batches.contains(key));
      });
    } catch (_) {
      // Local server being offline is normal. Keep downloads and pending offers.
    } finally {
      _checking = false;
    }
  }

  void _publish(List<TrackUpdateOffer> next) {
    if (_closed) return;
    if (next.map((offer) => offer.signature).join('|') !=
        offers.value.map((offer) => offer.signature).join('|')) {
      offers.value = List.unmodifiable(next);
    }
  }

  Future<Map<String, dynamic>> updateTrack(
    TrackUpdateOffer offer,
  ) => _serial(() async {
    final response = await _get('api/tracks/${offer.id}/');
    if (response.statusCode != 200) {
      throw HttpException('Track update: HTTP ${response.statusCode}');
    }
    final track = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(response.bodyBytes)) as Map,
    );
    if (track['id'] != offer.id) throw const FormatException('Wrong track id');
    final remote = TrackContentVersions.fromJson(track['content_versions']);
    final old = _local[offer.id];
    if (old == null) throw StateError('No local track to update');
    var audioName = old.audioName;
    var videoName = old.videoName;
    if (old.hasAudio &&
        remote.audio != null &&
        remote.audio != old.versions.audio) {
      audioName = 'track_${offer.id}_${remote.audio}.mp3';
      final destination = File('${directory.path}/$audioName');
      await _downloader.download(
        source: Uri.parse(
          resolveMediaUrlForBase(_base, track['audio_file'].toString()),
        ),
        destination: destination,
      );
      if (await _hash(destination.path) != remote.audio) {
        // Quarantine only this failed candidate; never touch the old playable file.
        await destination.rename(
          '${destination.path}.invalid.${DateTime.now().microsecondsSinceEpoch}',
        );
        throw const FormatException(
          'Audio verification failed; original preserved',
        );
      }
    }
    if (old.videoName != null &&
        remote.video != null &&
        remote.video != old.versions.video) {
      final source = track['video_file']?.toString();
      if (source == null || source.trim().isEmpty) {
        throw const FormatException('Missing updated video URL');
      }
      videoName = 'video_${offer.id}_${remote.video}.mp4';
      final destination = File('${directory.path}/$videoName');
      await _downloader.download(
        source: Uri.parse(resolveMediaUrlForBase(_base, source)),
        destination: destination,
      );
      if (await _hash(destination.path) != remote.video) {
        await destination.rename(
          '${destination.path}.invalid.${DateTime.now().microsecondsSinceEpoch}',
        );
        throw const FormatException(
          'Video verification failed; original preserved',
        );
      }
    }
    final lyrics = track['lyrics']?.toString() ?? '';
    if (_textHash(lyrics) != remote.lyrics) {
      throw const FormatException('Lyrics verification failed');
    }
    final lyricsName = 'track_${offer.id}_${remote.lyrics}.lrc';
    await atomicFileStore.writeString(
      File('${directory.path}/$lyricsName'),
      lyrics,
    );
    final confirm = await _get('api/tracks/${offer.id}/');
    if (confirm.statusCode != 200) {
      throw HttpException('Unable to confirm track update');
    }
    final confirmed = jsonDecode(utf8.decode(confirm.bodyBytes));
    if (TrackContentVersions.fromJson(
          confirmed['content_versions'],
        ).signature !=
        remote.signature) {
      throw StateError('Track changed during download; retry update');
    }
    if (_closed) throw StateError('Track update monitor closed');
    final record = _LocalTrack(
      TrackContentVersions(
        audio: remote.audio ?? old.versions.audio,
        lyrics: remote.lyrics,
        metadata: remote.metadata,
        video: remote.video ?? old.versions.video,
        artwork: remote.artwork,
      ),
      audioName,
      lyricsName,
      hasAudio: old.hasAudio,
      videoName: videoName,
    );
    final next = {..._local, offer.id: record};
    await _save(next);
    if (_closed) throw StateError('Track update monitor closed');
    _local[offer.id] = record;
    _publish(offers.value.where((item) => item.id != offer.id).toList());
    return track;
  });

  Future<void> forget(int? id) => _serial(() async {
    final next = {..._local};
    if (id == null) {
      next.clear();
    } else {
      next.remove(id);
    }
    await _save(next);
    _local
      ..clear()
      ..addAll(next);
    _publish(
      id == null ? [] : offers.value.where((offer) => offer.id != id).toList(),
    );
  });

  void dispose() {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    for (final request in _requests) {
      if (!request.isCompleted) request.complete();
    }
    if (_ownsClient) _client.close();
    unawaited(_downloader.close());
    offers.dispose();
  }
}
