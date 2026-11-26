import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../background_photo.dart';
import '../background_video.dart';
import '../custom_background.dart';

typedef BackgroundVideoOpener = Future<VideoPlayerController> Function(File);

class PlayerBackdrop extends StatelessWidget {
  const PlayerBackdrop({
    super.key,
    required this.directory,
    required this.name,
    required this.gradient,
    required this.allowMotion,
    required this.child,
    this.playlistPhoto,
    this.dimming = const AlwaysStoppedAnimation(defaultBackgroundDimming),
    this.openVideo = openBackgroundVideo,
  });

  final String directory;
  final String? name;
  final String? playlistPhoto;
  final Gradient gradient;
  final bool allowMotion;
  final Widget child;
  final ValueListenable<int> dimming;
  final BackgroundVideoOpener openVideo;

  @override
  Widget build(BuildContext context) {
    final photo = playlistPhoto;
    final usePlaylistPhoto =
        directory.isNotEmpty && isPlaylistBackgroundName(photo);
    return DecoratedBox(
      decoration: BoxDecoration(gradient: gradient),
      child: Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(
            child: ValueListenableBuilder<int>(
              valueListenable: dimming,
              builder: (context, percent, _) {
                final shade = Color.fromARGB(
                  (percent * 255 / 100).round(),
                  0,
                  0,
                  0,
                );
                return usePlaylistPhoto
                    ? Image.file(
                        File('$directory/$photo'),
                        fit: BoxFit.cover,
                        color: shade,
                        colorBlendMode: BlendMode.srcOver,
                        excludeFromSemantics: true,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => _globalMedia(shade),
                      )
                    : _globalMedia(shade);
              },
            ),
          ),
          child,
        ],
      ),
    );
  }

  Widget _globalMedia(Color shade) {
    final kind = directory.isEmpty ? null : savedBackgroundKind(name);
    final path = '$directory/$name';
    return switch (kind) {
      BackgroundKind.image => DecoratedBox(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: FileImage(File(path)),
            fit: BoxFit.cover,
            colorFilter: ColorFilter.mode(shade, BlendMode.srcOver),
            onError: (_, _) {},
          ),
        ),
      ),
      BackgroundKind.gif || BackgroundKind.video => RepaintBoundary(
        child: ExcludeSemantics(
          child: _MotionBackdrop(
            path: path,
            kind: kind!,
            allowMotion: allowMotion,
            openVideo: openVideo,
            shade: shade,
          ),
        ),
      ),
      null => const SizedBox.shrink(),
    };
  }
}

bool _backgroundVisible(AppLifecycleState? state) => switch (state) {
  AppLifecycleState.hidden ||
  AppLifecycleState.paused ||
  AppLifecycleState.detached => false,
  _ => true,
};

class _MotionBackdrop extends StatelessWidget {
  const _MotionBackdrop({
    required this.path,
    required this.kind,
    required this.allowMotion,
    required this.openVideo,
    required this.shade,
  });

  final String path;
  final BackgroundKind kind;
  final bool allowMotion;
  final BackgroundVideoOpener openVideo;
  final Color shade;

  @override
  Widget build(BuildContext context) {
    final active =
        allowMotion &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context);
    if (kind == BackgroundKind.video) {
      return _VideoBackdrop(
        path: path,
        active: active,
        openVideo: openVideo,
        shade: shade,
      );
    }
    if (!active) return const SizedBox.shrink();
    return _GifBackdrop(key: ValueKey(path), path: path, shade: shade);
  }
}

class _GifBackdrop extends StatefulWidget {
  const _GifBackdrop({super.key, required this.path, required this.shade});

  final String path;
  final Color shade;

  @override
  State<_GifBackdrop> createState() => _GifBackdropState();
}

class _GifBackdropState extends State<_GifBackdrop>
    with WidgetsBindingObserver {
  late final FileImage _image = FileImage(File(widget.path));
  late bool _appVisible;

  @override
  void initState() {
    super.initState();
    final binding = WidgetsBinding.instance;
    _appVisible = _backgroundVisible(binding.lifecycleState);
    binding.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = _backgroundVisible(state);
    if (_appVisible == visible) return;
    if (!visible) unawaited(_image.evict());
    setState(() => _appVisible = visible);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_image.evict());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !_appVisible
      ? const SizedBox.shrink()
      : Image(
          image: _image,
          fit: BoxFit.cover,
          color: widget.shade,
          colorBlendMode: BlendMode.srcOver,
          excludeFromSemantics: true,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        );
}

class _VideoBackdrop extends StatefulWidget {
  const _VideoBackdrop({
    required this.path,
    required this.active,
    required this.openVideo,
    required this.shade,
  });

  final String path;
  final bool active;
  final BackgroundVideoOpener openVideo;
  final Color shade;

  @override
  State<_VideoBackdrop> createState() => _VideoBackdropState();
}

class _VideoBackdropState extends State<_VideoBackdrop>
    with WidgetsBindingObserver {
  VideoPlayerController? _playing;
  Future<void> _work = Future<void>.value();
  int _revision = 0;
  late bool _appVisible;

  @override
  void initState() {
    super.initState();
    final binding = WidgetsBinding.instance;
    _appVisible = _backgroundVisible(binding.lifecycleState);
    binding.addObserver(this);
    _changeVideo();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = _backgroundVisible(state);
    if (visible == _appVisible) return;
    _appVisible = visible;
    // Frames may already be suspended. Release the native player now, rather
    // than waiting for a rebuild of the hidden route.
    setState(_changeVideo);
  }

  @override
  void didUpdateWidget(covariant _VideoBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active || oldWidget.path != widget.path) {
      _changeVideo();
    }
  }

  void _changeVideo() {
    final revision = ++_revision;
    final old = _detachVideo();
    _work = _work.then((_) async {
      if (old != null) await closeBackgroundVideo(old);
      if (!_wantsVideo(revision)) return;

      VideoPlayerController? candidate;
      try {
        candidate = await widget.openVideo(File(widget.path));
        if (!_wantsVideo(revision)) return;
        await candidate.play().timeout(const Duration(seconds: 3));
        if (!_wantsVideo(revision) || candidate.value.hasError) return;
        candidate.addListener(_checkError);
        setState(() => _playing = candidate);
      } catch (_) {
        // The normal theme stays visible if this device cannot play the file.
      } finally {
        if (candidate != null && !identical(candidate, _playing)) {
          await closeBackgroundVideo(candidate);
        }
      }
    });
  }

  bool _wantsVideo(int revision) =>
      mounted && revision == _revision && widget.active && _appVisible;

  VideoPlayerController? _detachVideo() {
    final controller = _playing;
    controller?.removeListener(_checkError);
    _playing = null;
    return controller;
  }

  void _checkError() {
    if (_playing?.value.hasError != true) return;
    final old = _detachVideo()!;
    setState(() {});
    _work = _work.then((_) => closeBackgroundVideo(old));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _revision++;
    final old = _detachVideo();
    if (old != null) unawaited(_work.then((_) => closeBackgroundVideo(old)));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _playing;
    if (controller == null) return const SizedBox.shrink();
    final size = controller.value.size;
    return Stack(
      fit: StackFit.expand,
      children: [
        FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: VideoPlayer(controller),
          ),
        ),
        ColoredBox(color: widget.shade),
      ],
    );
  }
}
