import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'dart:ui';

import '../globals.dart';
import '../localization.dart';
import '../music_import.dart';
import '../widgets/synced_lyrics_view.dart';

/// Full-screen lyrics overlay with synced scrolling and blurred background.
/// Keeps it simple — just lyrics to enjoy, no playback controls.
class PresentationOverlay extends StatefulWidget {
  final Function(Duration) onSeekRequested;
  const PresentationOverlay({super.key, required this.onSeekRequested});

  @override
  State<PresentationOverlay> createState() => _PresentationOverlayState();
}

class _PresentationOverlayState extends State<PresentationOverlay> {
  int localSyncIndex = -1;
  List<LyricLine>? _lastLyrics;
  String? _lastPlainLyrics;
  bool? _wasLoading;

  @override
  void initState() {
    super.initState();
    uiSignal.addListener(updateTick);
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
  void dispose() {
    uiSignal.removeListener(updateTick);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<dynamic>(
      valueListenable: activeTrackNotifier,
      builder: (context, trackData, child) {
        if (trackData == null) {
          return const Scaffold(backgroundColor: Colors.black);
        }

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
                            icon: const Icon(
                              Icons.keyboard_arrow_down,
                              color: Colors.white,
                              size: 40,
                            ),
                            onPressed: () => Navigator.pop(context),
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
                        ],
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
