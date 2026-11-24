import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'local_music_catalog.dart';

const _maxId3 = 8 * 1024 * 1024;
const _maxSyncSearch = 64 * 1024;
const _maxReplayGainFrames = 256;

typedef _Id3Tag = ({int version, int flags, int size});
typedef _Id3Frame = ({String id, int size, int format});

_Id3Tag? _id3Header(Uint8List bytes, int fileLength) {
  if (bytes.length != 10 ||
      _ascii(bytes, 0, 3) != 'ID3' ||
      bytes[3] < 2 ||
      bytes[3] > 4) {
    return null;
  }
  final size = _synchsafe(bytes, 6);
  return size == null || size > fileLength - 10
      ? null
      : (version: bytes[3], flags: bytes[5], size: size);
}

bool _canReadTag(_Id3Tag tag) =>
    tag.size <= _maxId3 && (tag.version != 2 || tag.flags & 64 == 0);

bool _legacyUnsynced(_Id3Tag tag) => tag.version < 4 && tag.flags & 128 != 0;

int? _id3FramesStart(_Id3Tag tag, Uint8List prefix) {
  if (tag.version == 2 || tag.flags & 64 == 0) return 0;
  if (prefix.length < 4) return null;
  if (tag.version == 3) return 4 + _int(prefix, 0, 4);
  final size = _synchsafe(prefix, 0);
  return size != null && size >= 6 ? size : null;
}

int _id3FrameHeaderSize(_Id3Tag tag) => tag.version == 2 ? 6 : 10;

_Id3Frame? _id3FrameHeader(_Id3Tag tag, Uint8List bytes, int start) {
  final length = _id3FrameHeaderSize(tag);
  if (start + length > bytes.length || bytes[start] == 0) return null;
  final idLength = tag.version == 2 ? 3 : 4;
  final size = tag.version == 4
      ? _synchsafe(bytes, start + idLength)
      : _int(bytes, start + idLength, idLength);
  if (size == null || size <= 0) return null;
  return (
    id: _ascii(bytes, start, idLength),
    size: size,
    format: tag.version == 2 ? 0 : bytes[start + 9],
  );
}

bool _canReadFrame(_Id3Tag tag, _Id3Frame frame) =>
    (tag.version != 3 || frame.format & 0xc0 == 0) &&
    (tag.version != 4 || frame.format & 0x0c == 0);

Uint8List? _id3Payload(_Id3Tag tag, _Id3Frame frame, Uint8List bytes) {
  if (tag.version == 4 && (tag.flags & 128 != 0 || frame.format & 2 != 0)) {
    bytes = _deunsync(bytes);
  }
  final prefix = tag.version == 4
      ? (frame.format & 0x40 != 0 ? 1 : 0) + (frame.format & 1 != 0 ? 4 : 0)
      : (frame.format & 0x20 != 0 ? 1 : 0);
  return prefix >= bytes.length ? null : Uint8List.sublistView(bytes, prefix);
}

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
    final id3 = _id3Header(header, length);
    if (id3 != null) {
      offset =
          10 + id3.size + (id3.version == 4 && id3.flags & 16 != 0 ? 10 : 0);
      if (_canReadTag(id3)) {
        var tag = await reader.read(id3.size);
        if (_legacyUnsynced(id3)) tag = _deunsync(tag);
        var start = _id3FramesStart(id3, tag) ?? tag.length;
        var pictureType = -1;
        final frameHeader = _id3FrameHeaderSize(id3);
        while (start + frameHeader <= tag.length) {
          final frame = _id3FrameHeader(id3, tag, start);
          final body = start + frameHeader;
          if (frame == null || frame.size > tag.length - body) break;
          start = body + frame.size;
          if (!_canReadFrame(id3, frame)) continue;
          final field = switch (frame.id) {
            'TT2' || 'TIT2' => 'title',
            'TP1' || 'TPE1' => 'artist',
            'TAL' || 'TALB' => 'album',
            'TRK' || 'TRCK' => 'track',
            'TPA' || 'TPOS' => 'disc',
            _ => null,
          };
          final attached = frame.id == 'PIC' || frame.id == 'APIC';
          if (field == null && (!attached || !readArtwork)) continue;
          if (frame.size > (attached ? localArtworkMaxBytes : 8192)) continue;
          final content = _id3Payload(
            id3,
            frame,
            Uint8List.sublistView(tag, body, start),
          );
          if (content == null) continue;
          if (field != null) {
            final value = _tagText(content);
            if (value.isNotEmpty) fields.putIfAbsent(field, () => value);
          } else if (readArtwork && pictureType != 3) {
            final candidate = _picture(content, legacy: frame.id == 'PIC');
            if (candidate != null && (candidate.type == 3 || picture == null)) {
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

final _decibelTag = RegExp(
  r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:\s*dB)?$',
  caseSensitive: false,
);

/// Reads a local MP3's existing track gain, returning a factor in (0, 1].
/// No audio decoding or artwork read for ordinary tags; the legacy ID3
/// tag-wide unsync flag needs the existing bounded deunsynchronisation pass.
Future<double> readMp3TrackGain(String path) async {
  try {
    final reader = await File(path).open();
    try {
      final id3 = _id3Header(await reader.read(10), await reader.length());
      if (id3 == null || !_canReadTag(id3)) return 1;
      final legacy = _legacyUnsynced(id3)
          ? _deunsync(await reader.read(id3.size))
          : null;
      final length = legacy?.length ?? id3.size;

      FutureOr<Uint8List> readAt(int offset, int bytes) => legacy == null
          ? _readId3Bytes(reader, offset, bytes)
          : Uint8List.sublistView(legacy, offset, offset + bytes);

      final prefix = id3.version != 2 && id3.flags & 64 != 0
          ? await readAt(0, math.min(4, length))
          : Uint8List(0);
      final first = _id3FramesStart(id3, prefix);
      if (first == null) return 1;
      var start = first;
      final headerSize = _id3FrameHeaderSize(id3);
      for (
        var n = 0;
        n < _maxReplayGainFrames && start + headerSize <= length;
        n++
      ) {
        final frame = _id3FrameHeader(id3, await readAt(start, headerSize), 0);
        final body = start + headerSize;
        if (frame == null || frame.size > length - body) break;
        start = body + frame.size;
        if ((frame.id != 'TXXX' && frame.id != 'TXX') ||
            !_canReadFrame(id3, frame) ||
            frame.size > 1024) {
          continue;
        }
        final bytes = await readAt(body, frame.size);
        if (bytes.length != frame.size) break;
        final payload = _id3Payload(id3, frame, bytes);
        if (payload == null) continue;
        final fields = _decodeTagText(payload).split('\u0000');
        if (fields.length < 2 ||
            fields.first.trim().toUpperCase() != 'REPLAYGAIN_TRACK_GAIN') {
          continue;
        }
        final value = fields[1].trim();
        if (!_decibelTag.hasMatch(value)) continue;
        final db = double.tryParse(
          value.replaceFirst(RegExp(r'[dD][bB]$'), '').trim(),
        );
        if (db == null || !db.isFinite || db < -60 || db > 60) continue;
        return db >= 0 ? 1 : math.pow(10, db / 20).toDouble();
      }
    } finally {
      await reader.close();
    }
  } on FileSystemException {
    // Tag lookup is optional. Includes files removed during a source switch.
  }
  return 1;
}

Future<Uint8List> _readId3Bytes(
  RandomAccessFile reader,
  int offset,
  int count,
) async {
  await reader.setPosition(10 + offset);
  return reader.read(count);
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

String _tagText(Uint8List value) => _clean(_decodeTagText(value));

String _decodeTagText(Uint8List value) {
  if (value.length < 2) return '';
  return switch (value.first) {
    0 => latin1.decode(Uint8List.sublistView(value, 1)),
    1 => decodeLocalUtf16(value, start: 1, little: false),
    2 => decodeLocalUtf16(value, start: 1, little: false),
    3 => utf8.decode(Uint8List.sublistView(value, 1), allowMalformed: true),
    _ => '',
  };
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
