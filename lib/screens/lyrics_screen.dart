import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../globals.dart';
import '../localization.dart';
import '../lyric_timing.dart';
import '../music_import.dart';
import '../player_shortcuts.dart';
import '../widgets/lyric_timing_controls.dart';
import '../widgets/synced_lyrics_view.dart';

/// Full-screen lyrics overlay with synced scrolling and blurred background.
class PresentationOverlay extends StatefulWidget {
  const PresentationOverlay({
    super.key,
    required this.onSeekRequested,
    this.timing,
  });

  final ValueChanged<Duration> onSeekRequested;
  final ValueListenable<LyricTimingSession?>? timing;

  @override
  State<PresentationOverlay> createState() => _PresentationOverlayState();
}

class _PresentationOverlayState extends State<PresentationOverlay> {
  int localSyncIndex = -1;
  List<LyricLine>? _lastLyrics;
  String? _lastPlainLyrics;
  bool? _wasLoading;
  LyricTimingSession? _editing;
  bool _saving = false;
  bool _saveFailed = false;

  @override
  void initState() {
    super.initState();
    uiSignal.addListener(updateTick);
    widget.timing?.addListener(_timingChanged);
    localSyncIndex = currentLine;
    _lastLyrics = List<LyricLine>.unmodifiable(globalLyrics);
    _lastPlainLyrics = noLrcData;
    _wasLoading = lrcLoading;
  }

  void updateTick() {
    if (!mounted) return;
    final lyricsChanged = !listEquals(_lastLyrics, globalLyrics);
    if (lyricsChanged) {
      _lastLyrics = List<LyricLine>.unmodifiable(globalLyrics);
    }
    if (localSyncIndex != currentLine) {
      setState(() => localSyncIndex = currentLine);
    } else if (lyricsChanged ||
        _lastPlainLyrics != noLrcData ||
        _wasLoading != lrcLoading) {
      setState(() {});
    }
    _lastPlainLyrics = noLrcData;
    _wasLoading = lrcLoading;
  }

  @override
  void didUpdateWidget(covariant PresentationOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.timing == widget.timing) return;
    oldWidget.timing?.removeListener(_timingChanged);
    widget.timing?.addListener(_timingChanged);
    _timingChanged();
  }

  void _timingChanged() {
    setState(() {
      if (!identical(_editing, widget.timing?.value)) {
        _editing = null;
        _saving = false;
        _saveFailed = false;
      }
    });
  }

  void _toggleTiming(LyricTimingSession timing) {
    if (_editing != null) {
      _cancelTiming();
    } else if (timing.isCurrent) {
      setState(() => _editing = timing);
    }
  }

  void _cancelTiming() {
    final editing = _editing;
    if (_saving || editing == null) return;
    setState(() {
      _editing = null;
      _saveFailed = false;
    });
    editing.cancelPreview();
  }

  void _adjustTiming(int advanceMilliseconds) {
    if (_saving) return;
    setState(() => _saveFailed = false);
    _editing?.preview(advanceMilliseconds);
  }

  Future<void> _saveTiming() async {
    final editing = _editing;
    if (_saving || editing == null) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    var failed = false;
    try {
      await editing.savePreview();
    } catch (error) {
      failed = true;
      debugPrint('Could not save lyric timing: ${error.runtimeType}');
    }
    if (!mounted || !identical(_editing, editing)) {
      if (failed) editing.cancelPreview();
      return;
    }
    setState(() {
      _saving = false;
      _saveFailed = failed;
      if (!failed) _editing = null;
    });
  }

  @override
  void dispose() {
    uiSignal.removeListener(updateTick);
    widget.timing?.removeListener(_timingChanged);
    final editing = _editing;
    if (editing != null && !_saving) {
      // A parent can remove the route without calling its close button.
      scheduleMicrotask(editing.cancelPreview);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      if (_editing != null)
        const SingleActivator(LogicalKeyboardKey.escape): _cancelTiming,
    },
    child: PopScope(
      canPop: _editing == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancelTiming();
      },
      child: _buildLyrics(),
    ),
  );

  Widget _buildLyrics() {
    return ValueListenableBuilder<dynamic>(
      valueListenable: activeTrackNotifier,
      builder: (context, trackData, child) {
        if (trackData == null) {
          return const Scaffold(backgroundColor: Colors.black);
        }

        final timing = widget.timing?.value;
        final editing = _editing;
        return Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              // ── Blurred album art background (close and immersive) ──
              Container(
                decoration: BoxDecoration(
                  image: DecorationImage(
                    image: getPictureProvider(trackData),
                    fit: BoxFit.cover,
                    colorFilter: ColorFilter.mode(
                      Colors.black.withValues(alpha: 0.4),
                      BlendMode.darken,
                    ),
                  ),
                ),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
                  child: Container(color: Colors.black.withValues(alpha: 0.25)),
                ),
              ),

              // ── Content ──
              SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Header ──
                    Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: tr('close'),
                            icon: const Icon(
                              Icons.keyboard_arrow_down,
                              color: Colors.white,
                              size: 40,
                            ),
                            onPressed: _saving
                                ? null
                                : () {
                                    _cancelTiming();
                                    Navigator.pop(context);
                                  },
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  trackData['title'],
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  trackArtistLabel(trackData),
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 16,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          if (timing != null && timing.isCurrent) ...[
                            const SizedBox(width: 8),
                            PlaybackShortcutScope(
                              child: IconButton(
                                key: const ValueKey('lyric_timing_toggle'),
                                tooltip: tr('lyric_timing'),
                                isSelected: editing != null,
                                style: IconButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  backgroundColor: editing == null
                                      ? null
                                      : Colors.white12,
                                ),
                                icon: const Icon(Icons.tune_rounded, size: 22),
                                onPressed: _saving
                                    ? null
                                    : () => _toggleTiming(timing),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),

                    if (editing != null && editing.isCurrent)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: 392,
                              maxHeight:
                                  MediaQuery.sizeOf(context).height * 0.45,
                            ),
                            child: PlaybackShortcutScope(
                              child: LyricTimingControls(
                                advanceMilliseconds:
                                    editing.advanceMilliseconds,
                                saving: _saving,
                                saveFailed: _saveFailed,
                                onAdjust: _adjustTiming,
                                onCancel: _cancelTiming,
                                onSave: _saveTiming,
                              ),
                            ),
                          ),
                        ),
                      ),

                    // ── Lyrics body ──
                    Expanded(
                      child: lrcLoading
                          ? const Center(
                              child: CircularProgressIndicator(
                                color: Colors.white,
                              ),
                            )
                          : globalLyrics.isNotEmpty
                          ? SyncedLyricsView(
                              lines: _lastLyrics!,
                              activeIndex: localSyncIndex,
                              onSeek: widget.onSeekRequested,
                            )
                          : SingleChildScrollView(
                              physics: const BouncingScrollPhysics(),
                              padding: const EdgeInsets.all(40.0),
                              child: Align(
                                alignment: Alignment.center,
                                child: Text(
                                  noLrcData.isNotEmpty
                                      ? noLrcData
                                      : tr('no_lyrics'),
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 24,
                                    height: 1.5,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
