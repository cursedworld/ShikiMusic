import 'package:flutter/material.dart';

import '../globals.dart' show languageNotifier;
import '../localization.dart';
import '../lyric_timing.dart';

/// Sits above the scrolling lyrics so the adjustment can be heard and seen.
class LyricTimingControls extends StatelessWidget {
  const LyricTimingControls({
    super.key,
    required this.advanceMilliseconds,
    required this.saving,
    required this.saveFailed,
    required this.onAdjust,
    required this.onCancel,
    required this.onSave,
  });

  final int advanceMilliseconds;
  final bool saving;
  final bool saveFailed;
  final ValueChanged<int> onAdjust;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  String get _readout {
    if (advanceMilliseconds == 0) return tr('lyric_timing_no_offset');
    var seconds = (advanceMilliseconds.abs() / 1000).toStringAsFixed(1);
    if (languageNotifier.value == 'ru') seconds = seconds.replaceAll('.', ',');
    return tr(
      advanceMilliseconds > 0
          ? 'lyric_timing_advanced'
          : 'lyric_timing_delayed',
    ).replaceFirst('{seconds}', seconds);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final actionStyle = TextButton.styleFrom(foregroundColor: Colors.white70);
    return Material(
      color: const Color(0xFF242124),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Colors.white12),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _readout,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            Wrap(
              spacing: 4,
              children: [
                TextButton.icon(
                  style: actionStyle,
                  onPressed: !saving && advanceMilliseconds < lyricTimingLimit
                      ? () => onAdjust(advanceMilliseconds + lyricTimingStep)
                      : null,
                  icon: const Icon(Icons.chevron_left_rounded, size: 18),
                  label: Text(tr('lyric_timing_earlier')),
                ),
                TextButton.icon(
                  style: actionStyle,
                  onPressed: !saving && advanceMilliseconds > -lyricTimingLimit
                      ? () => onAdjust(advanceMilliseconds - lyricTimingStep)
                      : null,
                  label: Text(tr('lyric_timing_later')),
                  icon: const Icon(Icons.chevron_right_rounded, size: 18),
                  iconAlignment: IconAlignment.end,
                ),
              ],
            ),
            const Divider(height: 5, color: Colors.white12),
            if (saveFailed)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    tr('lyric_timing_save_error'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              children: [
                TextButton(
                  style: actionStyle,
                  onPressed: !saving && advanceMilliseconds != 0
                      ? () => onAdjust(0)
                      : null,
                  child: Text(tr('lyric_timing_reset')),
                ),
                TextButton(
                  style: actionStyle,
                  onPressed: saving ? null : onCancel,
                  child: Text(tr('cancel')),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF242124),
                  ),
                  onPressed: saving ? null : onSave,
                  child: Text(tr('lyric_timing_done')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
