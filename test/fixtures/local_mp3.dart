import 'dart:convert';
import 'dart:typed_data';

/// Short MPEG Layer III silence frames, with optional ID3v2 frames.
/// The independently generated FFmpeg samples are used for the native probe.
Uint8List fixtureMp3({
  int version = 4,
  List<({String id, List<int> bytes})> tags = const [],
  int variation = 0,
  int frames = 5,
}) {
  List<int> number(int n, int shift) => [
    for (var i = 3; i >= 0; i--) (n >> (i * shift)) & ((1 << shift) - 1),
  ];
  final payload = [
    for (final tag in tags) ...[
      ...ascii.encode(tag.id),
      ...number(tag.bytes.length, version == 4 ? 7 : 8),
      0,
      0,
      ...tag.bytes,
    ],
  ];
  final audio = Uint8List(417 * frames);
  for (var i = 0; i < frames; i++) {
    audio.setRange(417 * i, 417 * i + 4, [0xff, 0xfb, 0x90, 0]);
  }
  audio[audio.length - 1] = variation;
  return Uint8List.fromList([
    if (payload.isNotEmpty) ...[
      ...ascii.encode('ID3'),
      version,
      0,
      0,
      ...number(payload.length, 7),
      ...payload,
    ],
    ...audio,
  ]);
}

({String id, List<int> bytes}) utf8Tag(String id, String text) =>
    (id: id, bytes: [3, ...utf8.encode(text)]);

({String id, List<int> bytes}) utf16Tag(String id, String text) => (
  id: id,
  bytes: [
    1,
    0xff,
    0xfe,
    for (final code in text.codeUnits) ...[code & 255, code >> 8],
  ],
);
