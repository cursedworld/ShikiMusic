import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'local_music_catalog.dart';

const _maxId3 = 8 * 1024 * 1024;
const _maxSyncSearch = 64 * 1024;

class Mp3Metadata {
  const Mp3Metadata({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.trackNumber,
    this.discNumber,
    required this.duration,
    this.coverJpeg,
  });
  final String title, artist, album;
  final int duration;
  final int? trackNumber, discNumber;
  final Uint8List? coverJpeg;
}

/// Reads bounded ID3 and a short MPEG Layer III sample, never the whole MP3.
/// Run in a worker isolate: attached artwork may require decoding.
Future<Mp3Metadata> readMp3Metadata(
  String path, {
  bool readArtwork = true,
}) async {
  final reader = await File(path).open();
  try {
    final length = await reader.length();
    final header = await reader.read(10);
    final fields = <String, String>{};
    Uint8List? picture;
    var offset = 0;
    if (header.length == 10 &&
        _ascii(header, 0, 3) == 'ID3' &&
        header[3] >= 2 &&
        header[3] <= 4) {
      final version = header[3];
      final flags = header[5];
      final size = _synchsafe(header, 6);
      if (size != null && size <= length - 10) {
        offset = 10 + size + (version == 4 && flags & 16 != 0 ? 10 : 0);
        if (size <= _maxId3 && (version != 2 || flags & 64 == 0)) {
          var tag = await reader.read(size);
          final unsynced = flags & 128 != 0;
          if (version < 4 && unsynced) tag = _deunsync(tag);
          var start = 0;
          if (version == 3 && flags & 64 != 0 && tag.length >= 4) {
            start = 4 + _int(tag, 0, 4);
          } else if (version == 4 && flags & 64 != 0 && tag.length >= 4) {
            start = _synchsafe(tag, 0) ?? tag.length;
            if (start < 6) start = tag.length;
          }
          var pictureType = -1;
          final frameHeader = version == 2 ? 6 : 10;
          while (start + frameHeader <= tag.length) {
            if (tag[start] == 0) break;
            final id = _ascii(tag, start, version == 2 ? 3 : 4);
            final size = version == 4
                ? _synchsafe(tag, start + 4)
                : _int(
                    tag,
                    start + (version == 2 ? 3 : 4),
                    version == 2 ? 3 : 4,
                  );
            final format = version == 2 ? 0 : tag[start + 9];
            final body = start + frameHeader;
            if (size == null || size <= 0 || size > tag.length - body) break;
            start = body + size;
            // Compressed and encrypted frames are optional.
            if ((version == 3 && format & 0xc0 != 0) ||
                (version == 4 && format & 0x0c != 0)) {
              continue;
            }
            final field = switch (id) {
              'TT2' || 'TIT2' => 'title',
              'TP1' || 'TPE1' => 'artist',
              'TAL' || 'TALB' => 'album',
              'TRK' || 'TRCK' => 'track',
              'TPA' || 'TPOS' => 'disc',
              _ => null,
            };
            final attached = id == 'PIC' || id == 'APIC';
            if (field == null && !attached) continue;
            if (size > (attached ? localArtworkMaxBytes : 8192)) continue;
            var content = Uint8List.sublistView(tag, body, start);
            if (version == 4 && (unsynced || format & 2 != 0)) {
              content = _deunsync(content);
            }
            final prefix = version == 4
                ? (format & 0x40 != 0 ? 1 : 0) + (format & 1 != 0 ? 4 : 0)
                : (format & 0x20 != 0 ? 1 : 0);
            if (prefix >= content.length) continue;
            content = Uint8List.sublistView(content, prefix);
            if (field != null) {
              final value = _tagText(content);
              if (value.isNotEmpty) fields.putIfAbsent(field, () => value);
            } else if (readArtwork && pictureType != 3) {
              final candidate = _picture(content, legacy: id == 'PIC');
              if (candidate != null &&
                  (candidate.type == 3 || picture == null)) {
                final decoded = normalizeEmbeddedCover(candidate.bytes);
                if (decoded != null) {
                  pictureType = candidate.type;
                  picture = decoded;
                }
              }
            }
          }
        }
      }
    }
    var end = length;
    if (length >= 128) {
      await reader.setPosition(length - 128);
      final tail = await reader.read(128);
      if (tail.length == 128 && _ascii(tail, 0, 3) == 'TAG') {
        end -= 128;
        void readV1(String field, int start) => fields.putIfAbsent(
          field,
          () => _clean(latin1.decode(tail.sublist(start, start + 30))),
        );
        readV1('title', 3);
        readV1('artist', 33);
        readV1('album', 63);
        if (tail[125] == 0 && tail[126] != 0) {
          fields.putIfAbsent('track', () => '${tail[126]}');
        }
      }
    }
    if (offset >= end) throw const FormatException('Incomplete MP3');
    await reader.setPosition(offset);
    final data = await reader.read(math.min(_maxSyncSearch, end - offset));
    final duration = _audioDuration(data, end - offset);
    int? index(String key) {
      final n = int.tryParse(fields[key]?.split('/').first.trim() ?? '');
      return n == null || n < 1 || n > 9999 ? null : n;
    }

    return Mp3Metadata(
      title: fields['title'] ?? '',
      artist: fields['artist'] ?? '',
      album: fields['album'] ?? '',
      trackNumber: index('track'),
      discNumber: index('disc'),
      duration: duration,
      coverJpeg: picture,
    );
  } finally {
    await reader.close();
  }
}

String _clean(String text) => String.fromCharCodes(
  text.split('\u0000').first.trim().runes.take(512),
).replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();

String _ascii(Uint8List bytes, int offset, int length) =>
    String.fromCharCodes(Uint8List.sublistView(bytes, offset, offset + length));

int _int(Uint8List bytes, int offset, int count) {
  var value = 0;
  for (var i = offset; i < offset + count; i++) {
    value = value * 256 + bytes[i];
  }
  return value;
}

int? _synchsafe(Uint8List bytes, int offset) {
  var value = 0;
  for (var i = offset; i < offset + 4; i++) {
    if (bytes[i] >= 128) return null;
    value = value * 128 + bytes[i];
  }
  return value;
}

Uint8List _deunsync(Uint8List bytes) {
  final result = Uint8List(bytes.length);
  var pos = 0;
  for (var i = 0; i < bytes.length; i++) {
    result[pos++] = bytes[i];
    if (bytes[i] == 255 && i + 1 < bytes.length && bytes[i + 1] == 0) i++;
  }
  return Uint8List.sublistView(result, 0, pos);
}

String _tagText(Uint8List value) {
  if (value.length < 2) return '';
  return _clean(switch (value.first) {
    0 => latin1.decode(Uint8List.sublistView(value, 1)),
    1 => decodeLocalUtf16(value, start: 1, little: false),
    2 => decodeLocalUtf16(value, start: 1, little: false),
    3 => utf8.decode(Uint8List.sublistView(value, 1), allowMalformed: true),
    _ => '',
  });
}

String decodeLocalUtf16(
  Uint8List bytes, {
  required int start,
  required bool little,
}) {
  if (start + 1 < bytes.length) {
    final marker = _int(bytes, start, 2);
    if (marker == 0xfeff || marker == 0xfffe) {
      little = marker == 0xfffe;
      start += 2;
    }
  }
  final units = <int>[];
  for (var i = start; i + 1 < bytes.length; i += 2) {
    units.add(little ? bytes[i] + 256 * bytes[i + 1] : _int(bytes, i, 2));
  }
  return String.fromCharCodes(units);
}

({int type, Uint8List bytes})? _picture(
  Uint8List data, {
  required bool legacy,
}) {
  if (data.length < 6 || data[0] > 3) return null;
  var i = legacy ? 4 : data.indexOf(0, 1) + 1;
  if (i <= 0 || i == data.length) return null;
  final type = data[i++];
  final wide = data[0] == 1 || data[0] == 2;
  while (i < data.length) {
    if (data[i] == 0 && (!wide || (i + 1 < data.length && data[i + 1] == 0))) {
      final start = i + (wide ? 2 : 1);
      return start < data.length
          ? (type: type, bytes: Uint8List.sublistView(data, start))
          : null;
    }
    i += wide ? 2 : 1;
  }
  return null;
}

Uint8List? normalizeEmbeddedCover(Uint8List bytes) {
  if (bytes.length < 4 || bytes.length > localArtworkMaxBytes) return null;
  try {
    final image.Decoder decoder = switch (bytes[0]) {
      255 => image.JpegDecoder(),
      137 => image.PngDecoder(),
      _ => throw const FormatException('Unsupported cover'),
    };
    final info = decoder.startDecode(bytes);
    if (info == null ||
        info.width < 1 ||
        info.height < 1 ||
        info.width > 4096 ||
        info.height > 4096 ||
        info.width * info.height > 8000000) {
      return null;
    }
    var frame = decoder.decodeFrame(0);
    if (frame == null) return null;
    if (frame.width > 1200 || frame.height > 1200) {
      frame = image.copyResize(
        frame,
        width: frame.width >= frame.height ? 1200 : null,
        height: frame.height > frame.width ? 1200 : null,
      );
    }
    return image.encodeJpg(frame, quality: 90);
  } catch (_) {
    // A broken optional image must not reject otherwise valid audio.
    return null;
  }
}

typedef _Frame = ({
  int version,
  int rate,
  int bitrate,
  int size,
  bool mono,
  bool crc,
});

_Frame? _frame(Uint8List data, int i) {
  if (i + 4 > data.length || data[i] != 255 || data[i + 1] & 224 != 224) {
    return null;
  }
  final version = (data[i + 1] >> 3) & 3;
  if (version == 1 || ((data[i + 1] >> 1) & 3) != 1) return null;
  final low = version != 3;
  const rates = [44100, 48000, 32000];
  const mpeg1 = [
    0,
    32,
    40,
    48,
    56,
    64,
    80,
    96,
    112,
    128,
    160,
    192,
    224,
    256,
    320,
    0,
  ];
  const mpeg2 = [
    0,
    8,
    16,
    24,
    32,
    40,
    48,
    56,
    64,
    80,
    96,
    112,
    128,
    144,
    160,
    0,
  ];
  final bitrate = (low ? mpeg2 : mpeg1)[data[i + 2] >> 4] * 1000;
  final rateIndex = (data[i + 2] >> 2) & 3;
  if (bitrate == 0 || rateIndex == 3) return null;
  final rate =
      rates[rateIndex] ~/
      (version == 0
          ? 4
          : low
          ? 2
          : 1);
  final frameSize =
      (low ? 72 : 144) * bitrate ~/ rate + ((data[i + 2] >> 1) & 1);
  return (
    version: version,
    rate: rate,
    bitrate: bitrate,
    size: frameSize,
    mono: data[i + 3] >> 6 == 3,
    crc: data[i + 1] & 1 == 0,
  );
}

int _audioDuration(Uint8List data, int length) {
  for (var i = 0; i + 4 <= data.length; i++) {
    final first = _frame(data, i);
    if (first == null || first.size < 4 || i + first.size > length) continue;
    final next = _frame(data, i + first.size);
    if (i + first.size != length &&
        (next == null ||
            next.version != first.version ||
            next.rate != first.rate ||
            i + first.size + next.size > length)) {
      continue;
    }
    final samples = first.version == 3 ? 1152 : 576;
    final sideInfo = first.version == 3
        ? (first.mono ? 17 : 32)
        : (first.mono ? 9 : 17);
    final xing = i + 4 + (first.crc ? 2 : 0) + sideInfo;
    if (xing + 12 <= math.min(data.length, i + first.size) &&
        const ['Xing', 'Info'].contains(_ascii(data, xing, 4)) &&
        _int(data, xing + 4, 4) & 1 != 0) {
      final frames = _int(data, xing + 8, 4);
      if (frames > 0 && frames <= length ~/ 4) {
        return math.max(1, (frames * samples / first.rate).round());
      }
    }
    return math.max(1, ((length - i) * 8 / first.bitrate).round());
  }
  throw const FormatException('No MPEG Layer III audio');
}
