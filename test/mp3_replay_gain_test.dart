import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/mp3_metadata.dart';

import 'fixtures/local_mp3.dart';

void main() {
  late Directory fixtures;
  setUp(
    () async =>
        fixtures = await Directory.systemTemp.createTemp('shiki-replaygain-'),
  );
  tearDown(() async {
    final file = File('${fixtures.path}/track.mp3');
    if (await file.exists()) await file.delete();
    await fixtures.delete();
  });

  Future<double> read(Uint8List bytes) async {
    final file = await File('${fixtures.path}/track.mp3').writeAsBytes(bytes);
    return readMp3TrackGain(file.path);
  }

  for (final version in [2, 3, 4]) {
    test('track gain in ID3v2.$version, case-insensitive descriptor', () async {
      const value = 'replaygain_track_gain\u0000-6.0206 dB';
      final tag = switch (version) {
        2 => utf16Tag('TXX', value),
        3 => utf16Tag('TXXX', value),
        _ => utf8Tag('TXXX', value),
      };
      expect(
        await read(fixtureMp3(version: version, tags: [tag])),
        closeTo(0.5, 1e-6),
      );
    });
  }

  test(
    'seeks past artwork to the track tag, ignoring the album gain',
    () async {
      final value = await read(
        fixtureMp3(
          tags: [
            utf8Tag('TXXX', 'REPLAYGAIN_ALBUM_GAIN\u0000-12.0 dB'),
            (id: 'APIC', bytes: Uint8List(2 * 1024 * 1024)),
            utf8Tag('TXXX', 'REPLAYGAIN_TRACK_GAIN\u0000-6.0206 dB'),
          ],
        ),
      );
      expect(value, closeTo(0.5, 1e-6));
    },
  );

  test(
    'missing, positive, implausible and malformed tags are neutral',
    () async {
      expect(await read(fixtureMp3()), 1);
      expect(await readMp3TrackGain('${fixtures.path}/missing.mp3'), 1);
      for (final invalid in [
        '+6 dB',
        'NaN dB',
        '-9999 dB',
        '-6 text',
        '-3.2.1 dB',
      ]) {
        expect(
          await read(
            fixtureMp3(
              tags: [utf8Tag('TXXX', 'REPLAYGAIN_TRACK_GAIN\u0000$invalid')],
            ),
          ),
          1,
          reason: invalid,
        );
      }
      final cut = fixtureMp3(
        tags: [utf8Tag('TXXX', 'REPLAYGAIN_TRACK_GAIN\u0000-10 dB')],
      );
      expect(await read(Uint8List.sublistView(cut, 0, 21)), 1);
    },
  );
}
