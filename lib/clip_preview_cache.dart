import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'atomic_file_store.dart';
import 'media_file_downloader.dart';
import 'server_config.dart';

final _sha256 = RegExp(r'^[a-f0-9]{64}$');
const _previewLimit = 24 * 1024 * 1024;

/// Only consumes versioned advertisements from the configured Django server.
class ClipPreviewReference {
  ClipPreviewReference._(this.endpoint, this._version);

  final Uri endpoint;
  final String _version;

  static ClipPreviewReference? fromAdvertisement(
    Object? value, {
    required int serverTrackId,
    required String? originalUrl,
    required String serverBaseUrl,
  }) {
    if (value is! String || serverTrackId <= 0 || originalUrl == null) {
      return null;
    }
    final prefix = '/api/tracks/$serverTrackId/clip-preview/';
    if (!value.startsWith(prefix) ||
        value.length != prefix.length + 65 ||
        !value.endsWith('/')) {
      return null;
    }
    final version = value.substring(prefix.length, value.length - 1);
    if (!_sha256.hasMatch(version)) return null;
    final endpoint = buildServerUriForBase(serverBaseUrl, value);
    final video = Uri.tryParse(
      resolveMediaUrlForBase(serverBaseUrl, originalUrl),
    );
    if (video == null ||
        video.scheme != endpoint.scheme ||
        video.host != endpoint.host ||
        video.port != endpoint.port ||
        video.userInfo.isNotEmpty) {
      return null;
    }
    return ClipPreviewReference._(endpoint, version);
  }

  Uri? _assetUri(Object? url) {
    if (url is! String || !url.startsWith('/')) return null;
    final path = Uri.tryParse(url);
    if (path == null ||
        path.hasScheme ||
        path.hasAuthority ||
        path.hasQuery ||
        path.hasFragment ||
        path.pathSegments.any((part) => part == '.' || part == '..')) {
      return null;
    }
    if (!path.path.endsWith('/clip_previews/v1_$_version.mp4')) return null;
    return endpoint.resolveUri(path);
  }

  String get cacheName =>
      'clip_preview_${sha256.convert(utf8.encode(endpoint.toString()))}.mp4';
}

class ClipPreviewAsset {
  const ClipPreviewAsset(this.file, this.originalSha256);

  final File file;
  final String originalSha256;
}

class ClipPreviewCache {
  ClipPreviewCache(this.directory);

  final Directory directory;
  final _originals = <String, ({FileStat stamp, String digest})>{};

  File _file(ClipPreviewReference ref) =>
      File('${directory.path}/${ref.cacheName}');
  File _marker(File file) => File('${file.path}.sha256');

  Future<ClipPreviewAsset?> read(ClipPreviewReference ref) async {
    final file = _file(ref);
    final marker = _marker(file);
    try {
      if (!await _regularFile(file) ||
          !await _regularFile(marker) ||
          await marker.length() != 64) {
        return null;
      }
      final size = await file.length();
      if (size == 0 || size >= _previewLimit) return null;
      final digest = await marker.readAsString();
      return _sha256.hasMatch(digest) ? ClipPreviewAsset(file, digest) : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<ClipPreviewAsset?> fetch(
    ClipPreviewReference ref,
    http.Client client,
    MediaFileDownloader downloader, {
    required Future<void> abort,
    Future<bool> Function(String originalSha256)? acceptOriginal,
  }) async {
    final cached = await read(ref);
    if (cached != null) return cached;
    final stop = Completer<void>();
    void cancel() {
      if (!stop.isCompleted) stop.complete();
    }

    unawaited(abort.then((_) => cancel()));
    final timer = Timer(const Duration(seconds: 57), cancel);
    try {
      await Future<void>.value();
      if (stop.isCompleted) return null;
      final request = http.AbortableRequest(
        'GET',
        ref.endpoint,
        abortTrigger: stop.future,
      )..followRedirects = false;
      final response = await client.send(request);
      if (response.statusCode != HttpStatus.ok ||
          (response.contentLength ?? 0) > 4096) {
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > 4096) return null;
        bytes.addAll(chunk);
      }
      final data = jsonDecode(utf8.decode(bytes));
      if (data is! Map) return null;
      final digest = data['source_sha256'];
      final url = ref._assetUri(data['url']);
      if (digest is! String ||
          !_sha256.hasMatch(digest) ||
          url == null ||
          stop.isCompleted) {
        return null;
      }
      if (acceptOriginal != null && !await acceptOriginal(digest)) return null;
      final file = await downloader.download(
        source: url,
        destination: _file(ref),
        abortTrigger: stop.future,
      );
      if (!stop.isCompleted) {
        await atomicFileStore.writeString(_marker(file), digest);
      }
      return stop.isCompleted ? null : await read(ref);
    } on FormatException {
      return null;
    } finally {
      timer.cancel();
      cancel();
    }
  }

  Future<bool> matchesOriginal(ClipPreviewAsset preview, File original) =>
      matchesDigest(preview.originalSha256, original);

  Future<bool> matchesDigest(String originalSha256, File original) async {
    try {
      final path = original.path;
      final before = await original.stat();
      if (before.type != FileSystemEntityType.file || before.size == 0) {
        return false;
      }
      if (_originals[path] case (stamp: final stamp, digest: final digest)) {
        if (_sameStamp(before, stamp)) return digest == originalSha256;
      }
      final digest = await Isolate.run(() => _digestFile(path));
      if (!_sameStamp(before, await original.stat())) return false;
      if (_originals.length >= 32) _originals.remove(_originals.keys.first);
      _originals[path] = (stamp: before, digest: digest);
      return digest == originalSha256;
    } on FileSystemException {
      return false;
    }
  }
}

Future<bool> _regularFile(File file) async =>
    await FileSystemEntity.type(file.path, followLinks: false) ==
    FileSystemEntityType.file;

Future<String> _digestFile(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

bool _sameStamp(FileStat first, FileStat second) =>
    first.type == second.type &&
    first.size == second.size &&
    first.modified == second.modified &&
    first.changed == second.changed;

/// Keep playing the available preview while the larger file is on its way.
({bool usePreview, bool fetchPreview, bool fetchOriginal}) planClipPlayback({
  required bool expanded,
  required bool originalReady,
  required bool previewReady,
  required bool canFetchPreview,
  required bool canFetchOriginal,
}) {
  final fetchPreview = !expanded && !previewReady && canFetchPreview;
  return (
    usePreview: previewReady && (!expanded || !originalReady),
    fetchPreview: fetchPreview,
    fetchOriginal:
        !originalReady &&
        canFetchOriginal &&
        (expanded || (!previewReady && !fetchPreview)),
  );
}
