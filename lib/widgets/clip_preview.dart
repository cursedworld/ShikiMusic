import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../localization.dart';
import '../player_shortcuts.dart';

/// Changes where the existing clip is drawn. Its controller belongs to playback.
class ClipPreview extends StatefulWidget {
  const ClipPreview({super.key, required this.controller, required this.cover});

  final VideoPlayerController controller;
  final Widget cover;

  @override
  State<ClipPreview> createState() => _ClipPreviewState();
}

class _ClipPreviewState extends State<ClipPreview> {
  DialogRoute<void>? _viewer;

  void _open() {
    final controller = widget.controller;
    if (_viewer != null || !controller.value.isInitialized) return;
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
    // Do not draw the round preview while the dialog is still fading out.
    // https://api.flutter.dev/flutter/widgets/TransitionRoute/completed.html
    unawaited(
      route.completed.then((_) {
        if (mounted && identical(_viewer, route)) {
          setState(() => _viewer = null);
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
  void didUpdateWidget(covariant ClipPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.controller, oldWidget.controller)) {
      _dismissAfterFrame();
    }
  }

  @override
  void dispose() {
    _dismissAfterFrame();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.controller.value;
    if (!value.isInitialized || value.size.isEmpty) return widget.cover;

    return PlaybackShortcutScope(
      child: Stack(
        fit: StackFit.expand,
        children: [
          _viewer == null
              ? FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox.fromSize(
                    size: value.size,
                    child: VideoPlayer(widget.controller),
                  ),
                )
              : widget.cover,
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
  }
}

class _ClipDialog extends StatelessWidget {
  const _ClipDialog({required this.controller});

  final VideoPlayerController controller;

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
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: VideoPlayer(controller),
              ),
            ),
            PositionedDirectional(
              top: 8,
              end: 8,
              child: IconButton.filled(
                tooltip: tr('close'),
                autofocus: true,
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black87,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
