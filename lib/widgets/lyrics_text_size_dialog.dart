import 'package:flutter/material.dart';

import '../localization.dart';
import '../lyrics_text_size.dart';

class LyricsTextSizeDialog extends StatefulWidget {
  const LyricsTextSizeDialog({
    super.key,
    required this.initialSize,
    required this.backgroundColor,
    required this.previewColor,
  });

  final LyricsTextSize initialSize;
  final Color backgroundColor;
  final Color previewColor;

  @override
  State<LyricsTextSizeDialog> createState() => _LyricsTextSizeDialogState();
}

class _LyricsTextSizeDialogState extends State<LyricsTextSizeDialog> {
  final _optionFocus = {
    for (final size in LyricsTextSize.values) size: FocusNode(),
  };
  late LyricsTextSize _draft = widget.initialSize;

  void _select(LyricsTextSize? size) {
    if (size == null) return;
    // Clicking a radio tile changes the value without moving keyboard focus.
    // https://api.flutter.dev/flutter/material/RadioListTile/focusNode.html
    _optionFocus[size]!.requestFocus();
    setState(() => _draft = size);
  }

  @override
  void dispose() {
    for (final node in _optionFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: widget.backgroundColor,
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
    scrollable: true,
    title: Text(tr('lyrics_text_size')),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RadioGroup<LyricsTextSize>(
            groupValue: _draft,
            onChanged: _select,
            child: Column(
              children: [
                for (final size in LyricsTextSize.values)
                  RadioListTile<LyricsTextSize>(
                    key: ValueKey('lyrics_text_size_option_${size.name}'),
                    value: size,
                    focusNode: _optionFocus[size],
                    autofocus: size == widget.initialSize,
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr('lyrics_text_size_${size.name}')),
                  ),
              ],
            ),
          ),
          const Divider(height: 24),
          Text(
            key: const ValueKey('lyrics_text_size_preview'),
            tr('lyrics_text_size_sample'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: widget.previewColor,
              fontSize: _draft.activeFontSize,
              fontWeight: FontWeight.bold,
              height: 1.3,
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr('cancel')),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, _draft),
        child: Text(tr('lyrics_text_size_apply')),
      ),
    ],
  );
}
