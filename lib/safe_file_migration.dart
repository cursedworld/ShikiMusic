import 'dart:io';

enum SafeFileMigrationResult { copied, skipped }

/// Copies a legacy file into a new location without moving or deleting source.
///
/// A non-empty destination always wins. Concurrent callers cooperate through a
/// persistent destination lock and recheck the destination before promotion.
class SafeFileMigration {
  static const int _copyBufferSize = 64 * 1024;
  static int _temporarySequence = 0;

  Future<SafeFileMigrationResult> migrate({
    required File source,
    required File destination,
    bool requireNonEmpty = true,
  }) async {
    final normalizedSource = _absoluteNormalizedFile(source);
    final normalizedDestination = _absoluteNormalizedFile(destination);

    if (_pathKey(normalizedSource.path) ==
        _pathKey(normalizedDestination.path)) {
      throw ArgumentError('Source and destination must be different files.');
    }
    if (await _hasNonEmptyContents(normalizedDestination)) {
      return SafeFileMigrationResult.skipped;
    }

    await normalizedDestination.parent.create(recursive: true);

    final lockFile = File('${normalizedDestination.path}.lock');
    File? temporary;
    RandomAccessFile? input;
    RandomAccessFile? output;
    RandomAccessFile? lockHandle;
    var lockAcquired = false;
    var promoted = false;

    try {
      input = await normalizedSource.open(mode: FileMode.read);
      final expectedLength = await input.length();
      temporary = await _createUniqueTemporary(normalizedDestination);
      output = await temporary.open(mode: FileMode.write);

      var copiedLength = 0;
      while (true) {
        final chunk = await input.read(_copyBufferSize);
        if (chunk.isEmpty) break;
        await output.writeFrom(chunk);
        copiedLength += chunk.length;
      }

      await output.flush();
      await output.close();
      output = null;
      await input.close();
      input = null;

      final temporaryLength = await temporary.length();
      if (copiedLength != expectedLength || temporaryLength != expectedLength) {
        throw FileSystemException(
          'Source changed while it was being copied.',
          normalizedSource.path,
        );
      }
      if (requireNonEmpty && copiedLength == 0) {
        throw FileSystemException(
          'Source file is empty.',
          normalizedSource.path,
        );
      }

      lockHandle = await lockFile.open(mode: FileMode.append);
      await lockHandle.lock(FileLock.blockingExclusive);
      lockAcquired = true;

      if (await _hasNonEmptyContents(normalizedDestination)) {
        return SafeFileMigrationResult.skipped;
      }

      await temporary.rename(normalizedDestination.path);
      promoted = true;
      return SafeFileMigrationResult.copied;
    } finally {
      if (input != null) {
        try {
          await input.close();
        } on FileSystemException {
          // Preserve original copy error.
        }
      }
      if (output != null) {
        try {
          await output.close();
        } on FileSystemException {
          // Preserve original copy error.
        }
      }
      if (!promoted && temporary != null) {
        try {
          if (await temporary.exists()) {
            await temporary.delete();
          }
        } on FileSystemException {
          // Best-effort cleanup of this call's temporary file only.
        }
      }
      if (lockHandle != null) {
        if (lockAcquired) {
          try {
            await lockHandle.unlock();
          } on FileSystemException {
            // Lock handle close below still releases OS resources.
          }
        }
        try {
          await lockHandle.close();
        } on FileSystemException {
          // Migration result already decided.
        }
      }
    }
  }

  static Future<bool> _hasNonEmptyContents(File file) async {
    if (!await file.exists()) return false;
    return await file.length() > 0;
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
    return '$destinationPath.part.$pid.$timestamp.$sequence';
  }

  static Future<File> _createUniqueTemporary(File destination) async {
    while (true) {
      final temporary = File(_temporaryPath(destination.path));
      try {
        await temporary.create(exclusive: true);
        return temporary;
      } on FileSystemException {
        if (!await temporary.exists()) rethrow;
      }
    }
  }
}

final SafeFileMigration safeFileMigration = SafeFileMigration();
