import 'package:image/image.dart' as img;

List<int> testGif() {
  final encoder = img.GifEncoder();
  encoder.addFrame(
    img.Image(width: 32, height: 16)..clear(img.ColorRgb8(240, 10, 20)),
  );
  encoder.addFrame(
    img.Image(width: 32, height: 16)..clear(img.ColorRgb8(10, 20, 240)),
  );
  return encoder.finish()!;
}
