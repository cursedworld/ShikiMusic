import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/safe_file_migration.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'safe_file_migration_test_',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('copies exact bytes and preserves source', () async {
    final source = File('${temporaryDirectory.path}/legacy.bin');
    final destination = File('${temporaryDirectory.path}/current/data.bin');
    final bytes = List<int>.generate(150000, (index) => index % 251);
    await source.writeAsBytes(bytes);

    final result = await SafeFileMigration().migrate(
      source: source,
      destination: destination,
    );

    expect(result, SafeFileMigrationResult.copied);
    expect(await source.exists(), isTrue);
    expect(await source.readAsBytes(), bytes);
    expect(await destination.readAsBytes(), bytes);
    expect(_partFilesFor(destination), isEmpty);
  });

  test('keeps a non-empty destination and creates no temporary file', () async {
    final source = File('${temporaryDirectory.path}/legacy.txt');
    final destination = File('${temporaryDirectory.path}/current.txt');
    await source.writeAsString('legacy');
    await destination.writeAsString('current');

    final result = await SafeFileMigration().migrate(
      source: source,
      destination: destination,
    );

    expect(result, SafeFileMigrationResult.skipped);
    expect(await source.readAsString(), 'legacy');
    expect(await destination.readAsString(), 'current');
    expect(_partFilesFor(destination), isEmpty);
    expect(await File('${destination.path}.lock').exists(), isFalse);
  });

  test('concurrent migrations promote one complete source only', () async {
    final firstSource = File('${temporaryDirectory.path}/first.bin');
    final secondSource = File('${temporaryDirectory.path}/second.bin');
    final destination = File('${temporaryDirectory.path}/shared.bin');
    final firstBytes = List<int>.filled(180000, 1);
    final secondBytes = List<int>.filled(180000, 2);
    await firstSource.writeAsBytes(firstBytes);
    await secondSource.writeAsBytes(secondBytes);

    final results = await Future.wait(<Future<SafeFileMigrationResult>>[
      SafeFileMigration().migrate(
        source: firstSource,
        destination: destination,
      ),
      SafeFileMigration().migrate(
        source: secondSource,
        destination: destination,
      ),
    ]);

    expect(
      results.where((result) => result == SafeFileMigrationResult.copied),
      hasLength(1),
    );
    expect(
      results.where((result) => result == SafeFileMigrationResult.skipped),
      hasLength(1),
    );
    final destinationBytes = await destination.readAsBytes();
    expect(destinationBytes, anyOf(equals(firstBytes), equals(secondBytes)));
    expect(await firstSource.readAsBytes(), firstBytes);
    expect(await secondSource.readAsBytes(), secondBytes);
    expect(_partFilesFor(destination), isEmpty);
  });

  test(
    'promotion failure preserves source and destination without part',
    () async {
      final source = File('${temporaryDirectory.path}/legacy.bin');
      final destinationDirectory = Directory(
        '${temporaryDirectory.path}/occupied',
      );
      final destination = File(destinationDirectory.path);
      final marker = File('${destinationDirectory.path}/marker.txt');
      await source.writeAsBytes(<int>[1, 2, 3]);
      await destinationDirectory.create();
      await marker.writeAsString('preserve');

      await expectLater(
        SafeFileMigration().migrate(source: source, destination: destination),
        throwsA(isA<FileSystemException>()),
      );

      expect(await source.readAsBytes(), <int>[1, 2, 3]);
      expect(await destinationDirectory.exists(), isTrue);
      expect(await marker.readAsString(), 'preserve');
      expect(_partFilesFor(destination), isEmpty);
    },
  );

  test('empty source cannot replace an existing empty destination', () async {
    final source = File('${temporaryDirectory.path}/empty-source.bin');
    final destination = File('${temporaryDirectory.path}/empty-target.bin');
    await source.create();
    await destination.create();

    await expectLater(
      SafeFileMigration().migrate(source: source, destination: destination),
      throwsA(isA<FileSystemException>()),
    );

    expect(await source.exists(), isTrue);
    expect(await source.length(), 0);
    expect(await destination.exists(), isTrue);
    expect(await destination.length(), 0);
    expect(_partFilesFor(destination), isEmpty);
  });
}

List<File> _partFilesFor(File destination) {
  String normalize(String path) {
    final absolute = File(path).absolute.path.replaceAll('/', '\\');
    return Platform.isWindows ? absolute.toLowerCase() : absolute;
  }

  final prefix = '${normalize(destination.path)}.part.';
  return destination.parent
      .listSync()
      .whereType<File>()
      .where((file) => normalize(file.path).startsWith(prefix))
      .toList(growable: false);
}
