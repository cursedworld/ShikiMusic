import 'package:flutter/material.dart';
import 'dart:ui';

import '../globals.dart';
import '../localization.dart';

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
  final ScrollController scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    uiSignal.addListener(updateTick);
    localSyncIndex = currentLine;
  }

  void updateTick() {
    if (!mounted) return;
    if (localSyncIndex != currentLine) {
      setState(() => localSyncIndex = currentLine);
      if (scrollController.hasClients && localSyncIndex >= 0) {
        scrollController.animateTo(
          localSyncIndex * 80.0,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOut,
        );
      }
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    uiSignal.removeListener(updateTick);
    scrollController.dispose();
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
                                  trackData['album']['artist']['name'],
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
                              ? ListView.builder(
                                  controller: scrollController,
                                  physics: const BouncingScrollPhysics(),
                                  padding: EdgeInsets.symmetric(
                                    vertical:
                                        MediaQuery.of(context).size.height /
                                            2 -
                                            40,
                                  ),
                                  itemExtent: 80.0,
                                  itemCount: globalLyrics.length,
                                  itemBuilder: (ctx, idx) {
                                    final isHighlighted =
                                        idx == localSyncIndex;
                                    return GestureDetector(
                                      onTap: () => widget.onSeekRequested(
                                        globalLyrics[idx].time,
                                      ),
                                      child: Container(
                                        alignment: Alignment.center,
                                        child: AnimatedDefaultTextStyle(
                                          duration: const Duration(
                                            milliseconds: 300,
                                          ),
                                          style: TextStyle(
                                            fontSize:
                                                isHighlighted ? 32 : 20,
                                            fontWeight: isHighlighted
                                                ? FontWeight.bold
                                                : FontWeight.normal,
                                            color: isHighlighted
                                                ? Colors.white
                                                : Colors.white38,
                                          ),
                                          textAlign: TextAlign.center,
                                          child: Text(
                                            globalLyrics[idx].txt,
                                            textAlign: TextAlign.center,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ),
                                    );
                                  },
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
