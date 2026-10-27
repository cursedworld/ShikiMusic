import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'atomic_file_store.dart';

Future<String> _backgroundDigest(String path) => Isolate.run(
  () async => (await sha256.bind(File(path).openRead()).first).toString(),
);

/// Called while holding the destination's inter-process download lock.
/// A known content digest is mandatory: mixed versions can never be promoted.
Future<File> transferVerifiedMedia({
  required http.Client client,
  required Uri source,
  required File destination,
  required String expectedSha256,
  required Duration connectionTimeout,
  required Duration idleTimeout,
  required Duration stalePartialAge,
  required Future<void> cancelled,
  required void Function() checkCancelled,
}) async {
  final partial = File('${destination.path}.part.resume');
  final metadata = File('${destination.path}.resume.json');
  final abort = Completer<void>();
  unawaited(
    cancelled.then((_) {
      if (!abort.isCompleted) abort.complete();
    }),
  );
  RandomAccessFile? output;

  Future<void> discard() async {
    for (final file in [partial, metadata]) {
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.file) {
        await file.delete();
      }
    }
  }

  Future<File> promote() async {
    checkCancelled();
    final actual = await _backgroundDigest(partial.path);
    if (actual != expectedSha256) {
      await discard();
      throw const FormatException(
        'Downloaded content verification failed; original preserved.',
      );
    }
    checkCancelled();
    final result = await partial.rename(destination.path);
    try {
      if (await metadata.exists()) await metadata.delete();
    } on FileSystemException {
      /* no media left in partial */
    }
    return result;
  }

  try {
    checkCancelled();
    for (final file in [partial, metadata]) {
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        throw FileSystemException(
          'Download partial is not a regular file',
          file.path,
        );
      }
    }
    var offset = 0;
    String? etag;
    int? oldTotal;
    try {
      final saved = jsonDecode(await metadata.readAsString());
      final stat = await partial.stat();
      if (saved is Map &&
          saved['source'] == source.toString() &&
          saved['sha256'] == expectedSha256 &&
          stat.type == FileSystemEntityType.file &&
          stat.size > 0 &&
          DateTime.now().difference(stat.modified) <= stalePartialAge &&
          (saved['total'] == null ||
              (saved['total'] is int && stat.size <= saved['total']))) {
        offset = stat.size;
        oldTotal = saved['total'] as int?;
        final tag = saved['etag'];
        if (tag is String && tag.startsWith('"') && tag.endsWith('"')) {
          etag = tag;
        }
      }
    } on FileSystemException {
      // First attempt, or incomplete bookkeeping before any bytes were saved.
    } on FormatException {
      // A damaged sidecar is never trusted for byte-range concatenation.
    }
    if (offset == 0) await discard();
    checkCancelled();
    final request = http.AbortableRequest(
      'GET',
      source,
      abortTrigger: abort.future,
    );
    request.headers['Accept-Encoding'] = 'identity';
    if (offset > 0) {
      request.headers['Range'] = 'bytes=$offset-';
      if (etag != null) request.headers['If-Range'] = etag;
    }
    final response = await client.send(request).timeout(connectionTimeout);
    if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
        offset > 0) {
      final complete = RegExp(
        r'^bytes \*/([0-9]+)$',
      ).firstMatch(response.headers['content-range'] ?? '');
      if (complete != null &&
          int.tryParse(complete.group(1)!) == offset &&
          (oldTotal == null || oldTotal == offset)) {
        return await promote();
      }
    }
    int? total;
    if (response.statusCode == HttpStatus.partialContent && offset > 0) {
      final range = RegExp(
        r'^bytes ([0-9]+)-([0-9]+)/([0-9]+)$',
      ).firstMatch(response.headers['content-range'] ?? '');
      final start = range == null ? -1 : int.parse(range.group(1)!);
      final end = range == null ? -1 : int.parse(range.group(2)!);
      total = range == null ? -1 : int.parse(range.group(3)!);
      if (start != offset ||
          end < start ||
          end >= total ||
          (response.contentLength != null &&
              response.contentLength != end - start + 1)) {
        await discard();
        throw const FormatException(
          'Invalid Content-Range; partial discarded.',
        );
      }
    } else if (response.statusCode == HttpStatus.ok) {
      // Range unsupported or validator changed: replace only the partial.
      offset = 0;
      total = response.contentLength;
    } else {
      throw HttpException(
        'Download failed with HTTP ${response.statusCode}.',
        uri: source,
      );
    }
    checkCancelled();
    final fileHandle = await partial.open(
      mode: offset == 0 ? FileMode.write : FileMode.append,
    );
    output = fileHandle;
    await fileHandle.flush();
    final tag = response.headers['etag'];
    final strongTag = tag != null && tag.startsWith('"') && tag.endsWith('"')
        ? tag
        : null;
    await atomicFileStore.writeString(
      metadata,
      jsonEncode({
        'source': source.toString(),
        'sha256': expectedSha256,
        'total': total,
        'etag': strongTag,
      }),
    );
    var received = 0;
    await for (final bytes in response.stream.timeout(idleTimeout)) {
      checkCancelled();
      if (bytes.isEmpty) continue;
      await fileHandle.writeFrom(bytes);
      received += bytes.length;
      if (total != null && offset + received > total) {
        await fileHandle.close();
        output = null;
        await discard();
        throw const FormatException('Download exceeds declared size.');
      }
    }
    await fileHandle.flush();
    await fileHandle.close();
    output = null;
    if (offset + received == 0 ||
        (response.contentLength != null &&
            received != response.contentLength) ||
        (total != null && offset + received != total)) {
      throw const FileSystemException(
        'Download incomplete; partial retained for retry.',
      );
    }
    return await promote();
  } finally {
    if (!abort.isCompleted) abort.complete();
    if (output != null) {
      try {
        await output.close();
      } on FileSystemException {
        /* keep original failure */
      }
    }
  }
}
