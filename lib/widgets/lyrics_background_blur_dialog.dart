import 'package:flutter/material.dart';

import '../localization.dart';
import '../lyrics_background_blur.dart';
import 'lyrics_backdrop.dart';

class LyricsBackgroundBlurDialog extends StatefulWidget {
  const LyricsBackgroundBlurDialog({
    super.key,
    required this.initialBlur,
    required this.backgroundColor,
    this.cover,
  });

  final int initialBlur;
  final Color backgroundColor;
  final ImageProvider? cover;

  @override
  State<LyricsBackgroundBlurDialog> createState() =>
      _LyricsBackgroundBlurDialogState();
}

class _LyricsBackgroundBlurDialogState
    extends State<LyricsBackgroundBlurDialog> {
  static const _sampleArtwork = DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF632634), Color(0xFF183D4A), Color(0xFF58332E)],
        stops: [0.3, 0.3, 0.8],
      ),
    ),
  );

  late int _draft = widget.initialBlur;
  late final _artwork = widget.cover == null
      ? _sampleArtwork
      : LyricsBackdrop.coverImage(widget.cover!);

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: widget.backgroundColor,
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
    scrollable: true,
    title: Text(tr('lyrics_background_blur')),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('$_draft%', textAlign: TextAlign.end),
          Slider(
            key: const ValueKey('lyrics_background_blur_slider'),
            autofocus: true,
            max: 100,
            divisions: 20,
            value: _draft.toDouble(),
            onChanged: (value) => setState(() => _draft = value.round()),
            semanticFormatterCallback: (value) =>
                '${tr('lyrics_background_blur')}: ${value.round()}%',
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  LyricsBackdrop(blur: _draft, artwork: _artwork),
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        tr('lyrics_background_blur_sample'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _draft == defaultLyricsBackgroundBlur
            ? null
            : () => setState(() => _draft = defaultLyricsBackgroundBlur),
        child: Text(tr('lyrics_background_blur_reset')),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr('cancel')),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, _draft),
        child: Text(tr('settings_apply')),
      ),
    ],
  );
}
