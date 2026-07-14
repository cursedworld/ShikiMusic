import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Writes files through a flushed, same-directory temporary file.
///
/// Writes targeting the same normalized absolute path run in invocation order,
/// even when they come from different [AtomicFileStore] instances. A failed
/// write does not block later writes queued for that path.
class AtomicFileStore {
  static final Map<String, Future<void>> _pathTails = <String, Future<void>>{};
  static int _temporarySequence = 0;

  Future<void> writeString(
    File destination,
    String contents, {
    Encoding encoding = utf8,
  }) {
    final target = _absoluteNormalizedFile(destination);
    final captured = Uint8List.fromList(encoding.encode(contents));
    return _enqueue(target, () => _writeCaptured(target, captured));
  }

  Future<void> writeBytes(File destination, List<int> bytes) {
    final target = _absoluteNormalizedFile(destination);
    final captured = Uint8List.fromList(bytes);
    return _enqueue(target, () => _writeCaptured(target, captured));
  }

  /// Produces contents only after earlier writes for [destination] finish.
  ///
  /// Prefer [writeString] when contents already exist. This variant is useful
  /// when the newest state must be captured at the write's FIFO turn.
  Future<void> writeStringLazy(
    File destination,
    FutureOr<String> Function() producer, {
    Encoding encoding = utf8,
  }) {
    final target = _absoluteNormalizedFile(destination);
    return _enqueue(target, () async {
      final contents = await producer();
      final captured = Uint8List.fromList(encoding.encode(contents));
      await _writeCaptured(target, captured);
    });
  }

  /// Produces bytes only after earlier writes for [destination] finish.
  Future<void> writeBytesLazy(
    File destination,
    FutureOr<List<int>> Function() producer,
  ) {
    final target = _absoluteNormalizedFile(destination);
    return _enqueue(target, () async {
      final bytes = await producer();
      final captured = Uint8List.fromList(bytes);
      await _writeCaptured(target, captured);
    });
  }

  Future<void> _enqueue(File destination, Future<void> Function() operation) {
    final key = _pathKey(destination.path);
    final previous = _pathTails[key] ?? Future<void>.value();
    final result = previous.then((_) => operation());
    final tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );

    _pathTails[key] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_pathTails[key], tail)) {
          _pathTails.remove(key);
        }
      }),
    );
    return result;
  }

  Future<void> _writeCaptured(File destination, Uint8List bytes) async {
    await destination.parent.create(recursive: true);

    final temporary = File(_temporaryPath(destination.path));
    RandomAccessFile? output;
    var promoted = false;

    try {
      output = await temporary.open(mode: FileMode.write);
      await output.writeFrom(bytes);
      await output.flush();
      await output.close();
      output = null;

      await temporary.rename(destination.path);
      promoted = true;
    } finally {
      if (output != null) {
        try {
          await output.close();
        } on FileSystemException {
          // Preserve the original write error.
        }
      }
      if (!promoted) {
        try {
          if (await temporary.exists()) {
            await temporary.delete();
          }
        } on FileSystemException {
          // Best-effort cleanup of this write's temporary file only.
        }
      }
    }
  }

  static File _absoluteNormalizedFile(File file) {
    final absolute = file.absolute.path;
    final normalized = Uri.file(
      absolute,
      windows: Platform.isWindows,
    ).normalizePath().toFilePath(windows: Platform.isWindows);
    return File(normalized);
  }

  static String _pathKey(String normalizedAbsolutePath) {
    return Platform.isWindows
        ? normalizedAbsolutePath.toLowerCase()
        : normalizedAbsolutePath;
  }

  static String _temporaryPath(String destinationPath) {
    final sequence = _temporarySequence++;
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    return '$destinationPath.tmp.$pid.$timestamp.$sequence';
  }
}

final AtomicFileStore atomicFileStore = AtomicFileStore();
