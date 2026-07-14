import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/atomic_file_store.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'atomic_file_store_test_',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('serializes 100 same-path writes and keeps the last value', () async {
    final firstStore = AtomicFileStore();
    final secondStore = AtomicFileStore();
    final destination = File('${temporaryDirectory.path}/state.json');

    final writes = <Future<void>>[];
    for (var index = 0; index < 100; index++) {
      final store = index.isEven ? firstStore : secondStore;
      writes.add(store.writeString(destination, '{"version":$index}'));
    }

    await Future.wait(writes);

    expect(await destination.readAsString(), '{"version":99}');
    expect(
      temporaryDirectory.listSync().where(
        (entry) => entry.path.contains('.tmp.'),
      ),
      isEmpty,
    );
  });

  test('captures mutable byte input at invocation', () async {
    final store = AtomicFileStore();
    final destination = File('${temporaryDirectory.path}/bytes.bin');
    final bytes = <int>[1, 2, 3];

    final write = store.writeBytes(destination, bytes);
    bytes
      ..clear()
      ..addAll(<int>[9, 9, 9]);
    await write;

    expect(await destination.readAsBytes(), <int>[1, 2, 3]);
  });

  test('preserves old file when producer fails', () async {
    final store = AtomicFileStore();
    final destination = File('${temporaryDirectory.path}/preserved.txt');
    await destination.writeAsString('old');

    await expectLater(
      store.writeStringLazy(destination, () {
        throw StateError('producer failed');
      }),
      throwsA(isA<StateError>()),
    );

    expect(await destination.readAsString(), 'old');
    expect(
      temporaryDirectory.listSync().where(
        (entry) => entry.path.contains('.tmp.'),
      ),
      isEmpty,
    );
  });

  test('continues same-path queue after a failure', () async {
    final store = AtomicFileStore();
    final destination = File('${temporaryDirectory.path}/recover.txt');

    final failed = store.writeBytesLazy(destination, () {
      throw StateError('expected failure');
    });
    final recovered = store.writeString(destination, 'recovered');

    await expectLater(failed, throwsA(isA<StateError>()));
    await recovered;

    expect(await destination.readAsString(), 'recovered');
  });

  test('different paths do not share a queue', () async {
    final store = AtomicFileStore();
    final blockedDestination = File('${temporaryDirectory.path}/blocked.txt');
    final independentDestination = File(
      '${temporaryDirectory.path}/independent.txt',
    );
    final producerStarted = Completer<void>();
    final releaseProducer = Completer<void>();

    final blocked = store.writeStringLazy(blockedDestination, () async {
      producerStarted.complete();
      await releaseProducer.future;
      return 'unblocked';
    });
    await producerStarted.future;

    await store
        .writeString(independentDestination, 'independent')
        .timeout(const Duration(seconds: 2));
    expect(await independentDestination.readAsString(), 'independent');

    releaseProducer.complete();
    await blocked;
    expect(await blockedDestination.readAsString(), 'unblocked');
  });

  test('promotes new contents over an existing file', () async {
    final store = AtomicFileStore();
    final destination = File('${temporaryDirectory.path}/replace.txt');
    await destination.writeAsString('old');

    await store.writeString(destination, 'new');

    expect(await destination.readAsString(), 'new');
  });
}
