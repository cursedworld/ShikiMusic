import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../globals.dart';
import '../localization.dart';
import '../playlist_artwork.dart';

Future<CroppedPlaylistArtwork?> showPlaylistCropDialog(
  BuildContext context,
  String sourcePath,
) => showDialog<CroppedPlaylistArtwork>(
  context: context,
  builder: (_) => PlaylistCropDialog(sourcePath: sourcePath),
);

class PlaylistCropDialog extends StatefulWidget {
  const PlaylistCropDialog({super.key, required this.sourcePath});
  final String sourcePath;

  @override
  State<PlaylistCropDialog> createState() => _PlaylistCropDialogState();
}

class _PlaylistCropDialogState extends State<PlaylistCropDialog> {
  final _transform = TransformationController();
  PlaylistArtworkPreview? _preview;
  MemoryImage? _image;
  String? _error;
  bool _busy = false;
  double _side = 0;
  double _sceneWidth = 0;
  double _sceneHeight = 0;
  double _zoom = 1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final preview = await compute(
        loadPlaylistArtworkPreview,
        widget.sourcePath,
      );
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _image = MemoryImage(preview.bytes);
      });
    } catch (_) {
      if (mounted) setState(() => _error = tr('playlist_image_failed'));
    }
  }

  @override
  void dispose() {
    _transform.dispose();
    final image = _image;
    if (image != null) unawaited(image.evict());
    super.dispose();
  }

  void _setTransform(double zoom, Offset center) {
    _zoom = zoom.clamp(1, 5);
    final x = (_side / 2 - center.dx * _zoom).clamp(
      _side - _sceneWidth * _zoom,
      0.0,
    );
    final y = (_side / 2 - center.dy * _zoom).clamp(
      _side - _sceneHeight * _zoom,
      0.0,
    );
    _transform.value = Matrix4.diagonal3Values(_zoom, _zoom, 1)
      ..setTranslationRaw(x, y, 0);
  }

  void _resizeViewport(double side) {
    if (_side == side) return;
    final center = _side == 0
        ? const Offset(0.5, 0.5)
        : Offset(
            _transform.toScene(Offset(_side / 2, _side / 2)).dx / _sceneWidth,
            _transform.toScene(Offset(_side / 2, _side / 2)).dy / _sceneHeight,
          );
    _side = side;
    final preview = _preview!;
    final scale = side / math.min(preview.width, preview.height);
    _sceneWidth = preview.width * scale;
    _sceneHeight = preview.height * scale;
    _setTransform(
      _zoom,
      Offset(center.dx * _sceneWidth, center.dy * _sceneHeight),
    );
  }

  void _setZoom(double value) => setState(() {
    _setTransform(value, _transform.toScene(Offset(_side / 2, _side / 2)));
  });

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (_preview == null || _busy || event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final delta = switch (key) {
      LogicalKeyboardKey.arrowLeft => const Offset(-12, 0),
      LogicalKeyboardKey.arrowRight => const Offset(12, 0),
      LogicalKeyboardKey.arrowUp => const Offset(0, -12),
      LogicalKeyboardKey.arrowDown => const Offset(0, 12),
      _ => null,
    };
    if (delta != null) {
      final center = _transform.toScene(Offset(_side / 2, _side / 2) - delta);
      _setTransform(_zoom, center);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _apply() async {
    if (_preview == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final origin = _transform.toScene(Offset.zero);
    final selection = PlaylistCropSelection(
      sourcePath: widget.sourcePath,
      left: (origin.dx / _sceneWidth).clamp(0, 1),
      top: (origin.dy / _sceneHeight).clamp(0, 1),
      side: (1 / _transform.value.getMaxScaleOnAxis()).clamp(0, 1),
    );
    try {
      final artwork = await compute(cropPlaylistArtwork, selection);
      if (mounted) Navigator.pop(context, artwork);
    } catch (_) {
      if (mounted) setState(() => _error = tr('playlist_image_failed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dialogWidth = math.min(360.0, size.width - 72).clamp(120.0, 360.0);
    final side = math
        .min(320.0, math.min(dialogWidth, size.height - 360))
        .clamp(120.0, 320.0);
    if (_preview != null) _resizeViewport(side);
    return AlertDialog(
      backgroundColor: const Color(0xFF1A0000),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      contentPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(15),
        side: const BorderSide(color: Colors.white10),
      ),
      title: Text(
        tr('playlist_crop_title'),
        style: const TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tr('playlist_crop_hint'),
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 12),
              if (_image != null) ...[
                Focus(
                  autofocus: true,
                  onKeyEvent: _handleKey,
                  child: Semantics(
                    label: tr('playlist_crop_hint'),
                    child: SizedBox(
                      width: side,
                      height: side,
                      child: Stack(
                        children: [
                          AbsorbPointer(
                            absorbing: _busy,
                            child: InteractiveViewer(
                              key: const ValueKey('playlist_crop_viewport'),
                              transformationController: _transform,
                              constrained: false,
                              alignment: Alignment.topLeft,
                              minScale: 1,
                              maxScale: 5,
                              onInteractionUpdate: (_) {
                                final zoom = _transform.value
                                    .getMaxScaleOnAxis();
                                if (zoom != _zoom) setState(() => _zoom = zoom);
                              },
                              child: Image(
                                image: _image!,
                                width: _sceneWidth,
                                height: _sceneHeight,
                                fit: BoxFit.fill,
                              ),
                            ),
                          ),
                          const Positioned.fill(
                            child: IgnorePointer(
                              child: CustomPaint(painter: _CircleCropPainter()),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    const Icon(Icons.zoom_in, color: Colors.white70),
                    Expanded(
                      child: Slider(
                        key: const ValueKey('playlist_crop_zoom'),
                        value: _zoom.clamp(1, 5),
                        min: 1,
                        max: 5,
                        label: '${(_zoom * 100).round()}%',
                        semanticFormatterCallback: (value) =>
                            '${(value * 100).round()}%',
                        activeColor: accentColorNotifier.value,
                        onChanged: _busy ? null : _setZoom,
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('playlist_crop_reset'),
                      tooltip: tr('playlist_crop_reset'),
                      onPressed: _busy
                          ? null
                          : () => setState(
                              () => _setTransform(
                                1,
                                Offset(_sceneWidth / 2, _sceneHeight / 2),
                              ),
                            ),
                      icon: const Icon(
                        Icons.restart_alt,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ] else if (_error == null)
                const SizedBox(
                  height: 100,
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('cancel')),
        ),
        TextButton(
          key: const ValueKey('playlist_crop_apply'),
          onPressed: _preview == null || _busy ? null : _apply,
          child: Text(
            tr('playlist_crop_apply'),
            style: TextStyle(color: accentColorNotifier.value),
          ),
        ),
      ],
    );
  }
}

class _CircleCropPainter extends CustomPainter {
  const _CircleCropPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(rect)
      ..addOval(rect);
    canvas.drawPath(
      path,
      Paint()..color = Colors.black.withValues(alpha: 0.65),
    );
    canvas.drawOval(
      rect.deflate(1),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_CircleCropPainter oldDelegate) => false;
}
