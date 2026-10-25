import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../globals.dart' show LyricLine;
import '../mobile_motion.dart';

/// Reserves each cue's highlighted height so text never clips as it grows.
/// Layout is measured only when lyrics, available width or text settings change.
class SyncedLyricsView extends StatefulWidget {
  const SyncedLyricsView({
    super.key,
    required this.lines,
    required this.activeIndex,
    required this.onSeek,
  });

  final List<LyricLine> lines;
  final int activeIndex;
  final ValueChanged<Duration> onSeek;

  @override
  State<SyncedLyricsView> createState() => _SyncedLyricsViewState();
}

class _SyncedLyricsViewState extends State<SyncedLyricsView> {
  final _controller = ScrollController();
  List<LyricLine>? _measuredLines;
  double? _measuredWidth;
  TextScaler? _measuredScaler;
  TextDirection? _measuredDirection;
  TextStyle? _measuredStyle;
  Locale? _measuredLocale;
  final List<double> _heights = [], _offsets = [];
  bool _scrollScheduled = false, _jumpOnLayout = true;

  @override
  void didUpdateWidget(covariant SyncedLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lines, widget.lines)) _jumpOnLayout = true;
    if (oldWidget.activeIndex != widget.activeIndex ||
        !identical(oldWidget.lines, widget.lines)) {
      _scheduleScroll();
    }
  }

  void _scheduleScroll() {
    if (_scrollScheduled) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!mounted || !_controller.hasClients) return;
      final index = widget.activeIndex;
      if (index < 0 || index >= _heights.length) return;
      final target = (_offsets[index] + _heights[index] / 2).clamp(
        0.0,
        _controller.position.maxScrollExtent,
      );
      if (_jumpOnLayout || MediaQuery.disableAnimationsOf(context)) {
        _controller.jumpTo(target);
      } else {
        _controller.animateTo(
          target,
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeOutCubic,
        );
      }
      _jumpOnLayout = false;
    });
  }

  void _measure(double width, TextStyle style) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);
    if (identical(_measuredLines, widget.lines) &&
        _measuredWidth == width &&
        _measuredScaler == scaler &&
        _measuredDirection == direction &&
        _measuredStyle == style &&
        _measuredLocale == locale) {
      return;
    }
    _measuredLines = widget.lines;
    _measuredWidth = width;
    _measuredScaler = scaler;
    _measuredDirection = direction;
    _measuredStyle = style;
    _measuredLocale = locale;
    _heights.clear();
    _offsets.clear();
    var offset = 0.0;
    final painter = TextPainter(
      textDirection: direction,
      textScaler: scaler,
      locale: locale,
      textAlign: TextAlign.center,
    );
    try {
      for (final line in widget.lines) {
        painter.text = TextSpan(text: line.txt, style: style);
        painter.layout(maxWidth: width);
        final height = math.max(80.0, painter.height.ceilToDouble() + 24);
        _offsets.add(offset);
        _heights.add(height);
        offset += height;
      }
    } finally {
      painter.dispose();
    }
    _jumpOnLayout = true;
    _scheduleScroll();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const horizontal = 20.0;
      final highlighted = Theme.of(context).textTheme.bodyMedium!.copyWith(
        fontSize: 32,
        height: 1.3,
        fontWeight: FontWeight.w700,
        color: Colors.white,
      );
      _measure(math.max(1, constraints.maxWidth - horizontal * 2), highlighted);
      final reducedMotion = MediaQuery.disableAnimationsOf(context);
      return ListView.builder(
        key: const ValueKey('mobile_synced_lyrics'),
        controller: _controller,
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.symmetric(
          horizontal: horizontal,
          vertical: constraints.maxHeight / 2,
        ),
        itemExtentBuilder: (index, _) => _heights[index],
        itemCount: widget.lines.length,
        itemBuilder: (context, index) {
          final active = index == widget.activeIndex;
          return GestureDetector(
            key: ValueKey('lyric_cue_$index'),
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onSeek(widget.lines[index].time),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: AnimatedDefaultTextStyle(
                  duration: reducedMotion
                      ? Duration.zero
                      : mobileLyricsTransition,
                  curve: Curves.easeOutCubic,
                  style: active
                      ? highlighted
                      : highlighted.copyWith(
                          fontSize: 20,
                          fontWeight: FontWeight.normal,
                          color: Colors.white38,
                        ),
                  textAlign: TextAlign.center,
                  child: Text(
                    widget.lines[index].txt,
                    textAlign: TextAlign.center,
                    softWrap: true,
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );
}
