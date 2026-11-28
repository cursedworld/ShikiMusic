import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../localization.dart';
import '../player_shortcuts.dart';

/// Draws one video surface. Playback owns the controller and quality changes.
class ClipPreview extends StatefulWidget {
  const ClipPreview({
    super.key,
    required this.controller,
    required this.cover,
    required this.onExpanded,
  });

  final ValueListenable<VideoPlayerController?> controller;
  final Widget cover;
  final ValueChanged<bool> onExpanded;

  @override
  State<ClipPreview> createState() => _ClipPreviewState();
}

class _ClipPreviewState extends State<ClipPreview> {
  DialogRoute<void>? _viewer;

  void _open() {
    if (_viewer != null ||
        widget.controller.value?.value.isInitialized != true) {
      return;
    }
    final controller = widget.controller;
    // A non-opaque dialog keeps the playback screen's TickerMode enabled.
    // https://api.flutter.dev/flutter/widgets/PopupRoute/opaque.html
    final route = DialogRoute<void>(
      context: context,
      barrierColor: Colors.black87,
      barrierLabel: tr('close'),
      builder: (_) => _ClipDialog(controller: controller),
    );
    setState(() => _viewer = route);
    unawaited(Navigator.of(context, rootNavigator: true).push(route));
    widget.onExpanded(true);
    // Do not draw the round preview while the dialog is still fading out.
    // https://api.flutter.dev/flutter/widgets/TransitionRoute/completed.html
    unawaited(
      route.completed.then((_) {
        if (mounted && identical(_viewer, route)) {
          setState(() => _viewer = null);
          widget.onExpanded(false);
        }
      }),
    );
  }

  void _dismissAfterFrame() {
    final route = _viewer;
    if (route == null) return;
    // Track changes may unmount the preview during a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = route.navigator;
      if (route.isActive && navigator != null && navigator.mounted) {
        navigator.removeRoute(route);
      }
    });
  }

  @override
  void dispose() {
    _dismissAfterFrame();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: widget.controller,
    child: widget.cover,
    builder: (context, controller, cover) {
      if (_viewer != null ||
          controller == null ||
          !controller.value.isInitialized ||
          controller.value.size.isEmpty) {
        return cover!;
      }
      return PlaybackShortcutScope(
        child: Stack(
          fit: StackFit.expand,
          children: [
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox.fromSize(
                size: controller.value.size,
                child: VideoPlayer(controller),
              ),
            ),
            Material(
              type: MaterialType.transparency,
              child: Semantics(
                button: true,
                label: tr('expand_clip'),
                child: InkWell(onTap: _open),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _ClipDialog extends StatelessWidget {
  const _ClipDialog({required this.controller});

  final ValueListenable<VideoPlayerController?> controller;

  @override
  Widget build(BuildContext context) {
    final window = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: window.width * .04,
        vertical: window.height * .05,
      ),
      constraints: const BoxConstraints(),
      backgroundColor: Colors.black,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
      child: SizedBox.expand(
        key: const ValueKey('expanded_clip_frame'),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: ValueListenableBuilder(
                valueListenable: controller,
                builder: (context, clip, _) {
                  if (clip == null) {
                    return CircularProgressIndicator(
                      color: Colors.white70,
                      strokeWidth: 2,
                      semanticsLabel: tr('clip_loading'),
                    );
                  }
                  return AspectRatio(
                    aspectRatio: clip.value.aspectRatio,
                    child: VideoPlayer(clip),
                  );
                },
              ),
            ),
            PositionedDirectional(
              top: 8,
              end: 8,
              child: Semantics(
                container: true,
                label: tr('close'),
                child: IconButton.filled(
                  autofocus: true,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black87,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
