import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../globals.dart';
import '../localization.dart';
import '../lyric_timing.dart';
import '../lyric_timing_proposals.dart';
import '../lyrics_text_size.dart';
import '../music_import.dart';
import '../player_shortcuts.dart';
import '../widgets/lyric_line_edit_dialog.dart';
import '../widgets/lyric_timing_controls.dart';
import '../widgets/synced_lyrics_view.dart';

/// Full-screen lyrics overlay with synced scrolling and blurred background.
class PresentationOverlay extends StatefulWidget {
  const PresentationOverlay({
    super.key,
    required this.onSeekRequested,
    this.timing,
    this.proposals,
  });

  final ValueChanged<Duration> onSeekRequested;
  final ValueListenable<LyricTimingSession?>? timing;
  final LyricTimingProposalClient? proposals;

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
  int _editorRevision = 0;
  bool _supportsProposals = false;
  bool _proposing = false;
  LyricTimingProposalResult? _proposalResult;
  bool _lineEditorOpen = false;

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
        _resetProposalState();
      }
    });
  }

  void _toggleTiming(LyricTimingSession timing) {
    if (_editing != null) {
      _cancelTiming();
    } else if (timing.isCurrent) {
      setState(() {
        _editing = timing;
        _resetProposalState();
      });
      final proposals = widget.proposals;
      if (timing.isServerTrack && proposals != null) {
        final revision = _editorRevision;
        unawaited(() async {
          final supported = await proposals.supportsProposals();
          if (supported && _isEditorCurrent(timing, revision)) {
            setState(() => _supportsProposals = true);
          }
        }());
      }
    }
  }

  void _resetProposalState() {
    _editorRevision++;
    _supportsProposals = false;
    _proposing = false;
    _proposalResult = null;
  }

  bool _isEditorCurrent(LyricTimingSession timing, int revision) =>
      mounted &&
      identical(_editing, timing) &&
      _editorRevision == revision &&
      timing.isCurrent;

  int? get _activeSourceLine {
    final lines = _lastLyrics;
    final index = localSyncIndex;
    return lines != null && index >= 0 && index < lines.length
        ? lines[index].sourceLine
        : null;
  }

  Future<void> _editLine(LyricTimingSession session, int sourceLine) async {
    final timing = widget.timing;
    final original = session.originalLine(sourceLine);
    final text = session.lineText(sourceLine);
    if (_lineEditorOpen || timing == null || original == null || text == null) {
      return;
    }
    _lineEditorOpen = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => ValueListenableBuilder<LyricTimingSession?>(
          valueListenable: timing,
          builder: (context, current, _) => PlaybackShortcutScope(
            child: LyricLineEditDialog(
              session: session,
              sourceLine: sourceLine,
              original: original,
              initial: text,
              active: identical(current, session),
              proposals: widget.proposals,
            ),
          ),
        ),
      );
    } finally {
      _lineEditorOpen = false;
    }
  }

  void _cancelTiming() {
    final editing = _editing;
    if (_saving || editing == null) return;
    setState(() {
      _editing = null;
      _saveFailed = false;
      _resetProposalState();
    });
    editing.cancelPreview();
  }

  void _adjustTiming(int advanceMilliseconds) {
    if (_saving) return;
    setState(() {
      _saveFailed = false;
      _proposalResult = null;
    });
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
      if (!failed) {
        _editing = null;
        _resetProposalState();
      }
    });
  }

  Future<void> _proposeTiming() async {
    final editing = _editing;
    final proposals = widget.proposals;
    if (_saving ||
        _proposing ||
        !_supportsProposals ||
        proposals == null ||
        editing == null ||
        editing.advanceMilliseconds == 0) {
      return;
    }
    final revision = _editorRevision;
    setState(() {
      _saving = true;
      _saveFailed = false;
      _proposalResult = null;
    });
    try {
      // Sending is explicit. First make the same durable local save as Done.
      await editing.savePreview();
    } catch (_) {
      if (_isEditorCurrent(editing, revision)) {
        setState(() {
          _saving = false;
          _saveFailed = true;
        });
      }
      return;
    }
    if (!_isEditorCurrent(editing, revision)) return;
    final correction = editing.savedCorrection;
    setState(() {
      _saving = false;
      _proposing = correction != null;
    });
    if (correction == null) return;
    final result = await proposals.submit(correction);
    if (!_isEditorCurrent(editing, revision)) return;
    setState(() {
      _proposing = false;
      if (editing.advanceMilliseconds == correction.advanceMilliseconds) {
        _proposalResult = result;
      }
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
        final sourceLine = _activeSourceLine;
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
                                onEditLine:
                                    editing.canEditText && sourceLine != null
                                    ? () => _editLine(editing, sourceLine)
                                    : null,
                                onPropose: _supportsProposals
                                    ? _proposeTiming
                                    : null,
                                proposing: _proposing,
                                proposalResult: _proposalResult,
                              ),
                            ),
                          ),
                        ),
                      ),

                    // ── Lyrics body ──
                    Expanded(child: _buildLyricsBody()),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLyricsBody() {
    if (lrcLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    return ValueListenableBuilder<LyricsTextSize>(
      valueListenable: lyricsTextSizeNotifier,
      builder: (context, size, _) {
        final lines = _lastLyrics!;
        if (lines.isNotEmpty) {
          return SyncedLyricsView(
            lines: lines,
            activeIndex: localSyncIndex,
            onSeek: widget.onSeekRequested,
            textSize: size,
          );
        }
        final hasLyrics = noLrcData.isNotEmpty;
        return SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.all(40.0),
          child: Align(
            alignment: Alignment.center,
            child: Text(
              hasLyrics ? noLrcData : tr('no_lyrics'),
              style: TextStyle(
                color: Colors.white70,
                fontSize: hasLyrics ? size.plainFontSize : 24,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        );
      },
    );
  }
}
