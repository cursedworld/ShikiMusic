import 'dart:ui' show ImageFilter, TileMode;

import 'package:flutter/material.dart';

class LyricsBackdrop extends StatelessWidget {
  const LyricsBackdrop({super.key, required this.blur, required this.artwork});

  final int blur;
  final Widget artwork;

  static Widget coverImage(ImageProvider cover) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black,
      image: DecorationImage(
        image: cover,
        fit: BoxFit.cover,
        colorFilter: const ColorFilter.mode(
          Color(0x66000000),
          BlendMode.darken,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    // 50% keeps the original sigma of 25. Filter only the artwork, not the scene.
    // https://api.flutter.dev/flutter/widgets/ImageFiltered-class.html
    final sigma = blur / 2;
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ImageFiltered(
            enabled: blur > 0,
            imageFilter: ImageFilter.blur(
              sigmaX: sigma,
              sigmaY: sigma,
              tileMode: TileMode.clamp,
            ),
            child: artwork,
          ),
          const ColoredBox(
            color: Color.from(alpha: 0.25, red: 0, green: 0, blue: 0),
          ),
        ],
      ),
    );
  }
}
