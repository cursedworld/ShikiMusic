import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_discord_rpc/flutter_discord_rpc.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audio_service/audio_service.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_media_session/flutter_media_session.dart' as fms;
import 'package:image/image.dart' as img;
import 'package:video_player/video_player.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';

import '../app_paths.dart';
import '../async_task_limiter.dart';
import '../atomic_file_store.dart';
import '../globals.dart';
import '../localization.dart';
import '../media_file_downloader.dart';
import '../perf/frame_metrics.dart';
import '../safe_file_migration.dart';
import '../server_config.dart';
import 'lyrics_screen.dart';
import 'settings_screen.dart';

// ── Custom scroll behavior ─────────────────────────────────────────────────
// Replaces the default Android "glow" overscroll with iOS-style bouncing for
// a smoother, more polished feel on both platforms.

class _SmoothScrollBehavior extends ScrollBehavior {
  const _SmoothScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child; // no glow
  }
}

class _VideoRequest {
  const _VideoRequest({required this.trackId, required this.videoUrl});

  factory _VideoRequest.from(dynamic trackData) {
    if (trackData is! Map) {
      return const _VideoRequest(trackId: null, videoUrl: null);
    }
    final rawTrackId = trackData['id'];
    final trackId = rawTrackId is int
        ? rawTrackId
        : int.tryParse(rawTrackId?.toString() ?? '');
    final rawVideoUrl = trackData['video_file']?.toString().trim();
    return _VideoRequest(
      trackId: trackId,
      videoUrl: rawVideoUrl == null || rawVideoUrl.isEmpty ? null : rawVideoUrl,
    );
  }

  final int? trackId;
  final String? videoUrl;
}

class _VideoOperation {
  final Completer<void> _cancellation = Completer<void>();

  bool get isCanceled => _cancellation.isCompleted;
  Future<void> get whenCanceled => _cancellation.future;

  void cancel() {
    if (!_cancellation.isCompleted) {
      _cancellation.complete();
    }
  }
}

class _SharedClipGeneration {
  _SharedClipGeneration({required this.transportOperation});

  final _VideoOperation transportOperation;
  late final Future<http.Response> response;
  int subscribers = 0;
  bool completed = false;
  bool transportStarted = false;
}

class _ClipGenerationCancelledException implements Exception {
  const _ClipGenerationCancelledException();
}

bool _linuxVideoBackendInitialized = false;

void _ensureLinuxVideoBackendInitialized() {
  if (!Platform.isLinux || _linuxVideoBackendInitialized) return;
  VideoPlayerMediaKit.ensureInitialized(linux: true);
  _linuxVideoBackendInitialized = true;
}

// ═══════════════════════════════════════════════════════════════════════════
//  MainAppScreen
// ═══════════════════════════════════════════════════════════════════════════

class MainAppScreen extends StatefulWidget {
  const MainAppScreen({super.key});

  @override
  State<MainAppScreen> createState() => MainAppScreenState();
}

class MainAppScreenState extends State<MainAppScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final AudioPlayer audioPlayer;

  // ── flutter_media_session for Media3 notification ────────────────────────
  fms.FlutterMediaSession? _mediaSession;
  bool _mediaSessionActive = false;

  /// Request notification permission on Android 13+ so background audio notification works.
  Future<void> _requestNotificationPermission() async {
    if (isDesktop) return;
    try {
      final status = await Permission.notification.status;
      if (status.isDenied) {
        await Permission.notification.request();
      }
    } catch (e) {
      debugPrint('Error requesting notification permission: $e');
    }
  }

  /// Initialize Media3 MediaSession for lock screen + notification.
  Future<void> _initMediaSession() async {
    if (isDesktop) return;
    try {
      _mediaSession = fms.FlutterMediaSession();
      await _mediaSession!.activate();
      _mediaSessionActive = true;

      // Handle notification button presses
      _mediaSession!.setActionHandler(
        onPlay: () {
          if (!isPlaying) pauseTrack();
        },
        onPause: () {
          if (isPlaying) pauseTrack();
        },
        onSkipToNext: () {
          nextTrack();
        },
        onSkipToPrevious: () {
          prevTrack();
        },
        onStop: () {
          if (isPlaying) pauseTrack();
        },
        onSeekTo: (pos) {
          seekTo(pos);
        },
      );
    } catch (e) {
      debugPrint('FlutterMediaSession init failed: $e');
      _mediaSessionActive = false;
    }
  }

  /// Sync current track metadata to Media3 notification.
  void _syncMediaSessionMetadata() {
    if (!_mediaSessionActive || _mediaSession == null) return;
    if (playingQueue.isEmpty) return;
    final track = playingQueue[playingIndex];
    final dur = trackDurations[track['id']];
    // flutter_media_session 2.x has no audioplayers adapter yet.
    // ignore: deprecated_member_use
    _mediaSession!.updateMetadata(
      fms.MediaMetadata(
        title: track['title']?.toString() ?? 'Unknown',
        artist: track['album']?['artist']?['name']?.toString() ?? 'Unknown',
        album: track['album']?['title']?.toString(),
        artworkUri: getArtUri(track).toString(),
        duration: dur != null ? Duration(seconds: dur) : Duration.zero,
      ),
    );
  }

  /// Sync playback state (playing/paused, position) to Media3.
  void _syncMediaSessionPlayback() {
    if (!_mediaSessionActive || _mediaSession == null) return;
    // flutter_media_session 2.x has no audioplayers adapter yet.
    // ignore: deprecated_member_use
    _mediaSession!.updatePlaybackState(
      fms.PlaybackState(
        status: isPlaying
            ? fms.PlaybackStatus.playing
            : fms.PlaybackStatus.paused,
        position: currentPositionNotifier.value,
        speed: 1.0,
      ),
    );
  }

  /// Checks if the local cover file exists, is not empty, and is a valid square image.
  Future<bool> _isCoverValidAndSquare(File file) async {
    if (!await file.exists()) return false;
    try {
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return false;
      final image = img.decodeImage(bytes);
      return image != null && image.width == image.height;
    } catch (_) {
      return false;
    }
  }

  /// Download and crop cover to a perfect square to prevent system widget distortion
  Future<bool> _downloadAndCropCover(String url, File file) async {
    final absolutePath = file.absolute.path;
    final key = Platform.isWindows ? absolutePath.toLowerCase() : absolutePath;
    final pending = _coverDownloads[key];
    if (pending != null) return pending;

    final operation = _downloadAndCropCoverOnce(url, file);
    _coverDownloads[key] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_coverDownloads[key], operation)) {
        _coverDownloads.remove(key);
      }
    }
  }

  Future<bool> _downloadAndCropCoverOnce(String url, File file) async {
    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final bytes = res.bodyBytes;
        final image = img.decodeImage(bytes);
        if (image != null) {
          final size = min(image.width, image.height);
          final x = (image.width - size) ~/ 2;
          final y = (image.height - size) ~/ 2;
          final cropped = img.copyCrop(
            image,
            x: x,
            y: y,
            width: size,
            height: size,
          );
          final resized = img.copyResize(cropped, width: 600, height: 600);
          final jpegBytes = img.encodeJpg(resized);
          await atomicFileStore.writeBytes(file, jpegBytes);
          return true;
        }
      }
    } catch (e) {
      debugPrint('Error downloading or cropping cover: $e');
    }
    return false;
  }

  /// Asynchronously download cover art to local storage for the lock screen widget
  Future<void> _ensureCoverDownloaded(dynamic track) async {
    if (isDesktop || localPath.isEmpty) return;
    final id = track['id'];
    final coverFile = File('$localPath/cover_$id.jpg');

    if (await _isCoverValidAndSquare(coverFile)) return;

    final success = await _downloadAndCropCover(
      track['album']['cover'].toString(),
      coverFile,
    );
    if (success) {
      _syncMediaSessionMetadata();
    }
  }

  // ── Player state ─────────────────────────────────────────────────────────
  int dummyVar = 0;
  bool isPremium = true;
  int playCount = 0;
  List<dynamic> cachedTracks = [];
  bool isLoading = true;
  bool isPlaying = false;
  List<dynamic> playingQueue = [];
  int playingIndex = 0;
  int? discordStart;
  LoopMode loopMode = LoopMode.off;
  int navId = 0;
  double volume = 0.5;
  double _savedVolume = 0.5; // for mute toggle
  bool _isMuted = false;

  // Shuffle
  bool isShuffled = false;
  List<dynamic> _unshuffledQueue = [];

  Timer? backgroundPollingTimer;
  Timer? rpcThrottleTimer;
  DateTime? lastRpcTime;
  bool _discordConnected = false;
  // ignore: unused_field
  int _syncTicks = 0;

  // ── Vinyl rotation animation (desktop) ───────────────────────────────────
  late AnimationController _vinylController;
  bool _vinylUserStopped = false;

  VideoPlayerController? _videoController;
  VideoPlayerController? _initializingVideoController;
  bool _isVideoInitialized = false;
  Duration? _lastBenchmarkVideoPosition;
  final MediaFileDownloader _mediaFileDownloader = MediaFileDownloader();
  MediaFileDownloader? _foregroundVideoDownloader;
  final AsyncTaskLimiter _downloadTaskLimiter = AsyncTaskLimiter(2);
  final AsyncTaskLimiter _clipTaskLimiter = AsyncTaskLimiter(1);
  final AsyncTaskLimiter _foregroundClipTaskLimiter = AsyncTaskLimiter(1);
  final AsyncTaskLimiter _clipTransportLimiter = AsyncTaskLimiter(2);
  final Map<int, _SharedClipGeneration> _clipGenerationRequests =
      <int, _SharedClipGeneration>{};
  http.Client? _clipHttpClient;
  Future<void> _audioWork = Future<void>.value();
  Future<void> _videoWork = Future<void>.value();
  Timer? _videoReleaseTimer;
  Timer? _videoTrackSwitchTimer;
  int _videoRevision = 0;
  _VideoOperation? _videoOperation;
  int? _videoTrackId;
  bool _videoLifecycleVisible = true;
  bool _videoSurfaceAvailable = false;
  bool _stateDisposing = false;
  int _trackRevision = 0;
  int _transportRevision = 0;
  int _seekRevision = 0;
  int _databaseSyncRevision = 0;
  int? _audioSourceTrackId;
  int _settledTrackRevision = -1;
  int _lyricsRevision = 0;
  StreamSubscription<Duration>? _audioDurationSubscription;
  StreamSubscription<Duration>? _audioPositionSubscription;
  StreamSubscription<void>? _audioCompleteSubscription;
  final Set<String> _downloadedVideoSources = <String>{};
  final Set<String> _blockedVideoSources = <String>{};
  static const Duration _clipFetchDebounce = Duration(milliseconds: 500);
  static const Duration _videoTrackSwitchDebounce = Duration(milliseconds: 300);
  static const Duration _clipGenerationTimeout = Duration(minutes: 10);
  final Map<String, Future<bool>> _coverDownloads = <String, Future<bool>>{};
  final Expando<bool> _disposedVideoControllers = Expando<bool>();

  final ValueNotifier<Duration> fullDurationNotifier = ValueNotifier(
    Duration.zero,
  );
  final ValueNotifier<Duration> currentPositionNotifier = ValueNotifier(
    Duration.zero,
  );

  String localPath = "";
  Set<int> downloadQueue = {};
  Set<int> favs = {};

  List<Map<String, dynamic>> myPlaylists = [];

  final TextEditingController searchInput = TextEditingController();
  final FocusNode searchFocusNode = FocusNode();
  String searchQuery = "";
  bool isSearchLoading = false;

  // ═══════════════════════════════════════════════════════════════════════════
  //  Lifecycle
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _videoLifecycleVisible = !_isVideoHiddenLifecycle(
      WidgetsBinding.instance.lifecycleState,
    );

    // React to vinyl rotation toggle changes from Settings
    vinylRotationNotifier.addListener(_onVinylRotationChanged);

    // Synchronize video player actions
    activeTrackNotifier.addListener(_onActiveTrackChanged);
    isPlayingNotifier.addListener(_syncVideoPlayState);
    playVideoClipNotifier.addListener(_onVideoSettingChanged);
    uiSignal.addListener(_syncVideoDrift);

    // Create a single AudioPlayer and share it with AudioPlayerHandler
    audioPlayer = AudioPlayer();
    if (isAudioServiceActive) {
      audioHandler.attachPlayer(audioPlayer);
    }

    // Configure audio context for Android background playback
    if (!isDesktop) {
      audioPlayer.setAudioContext(
        AudioContext(
          android: AudioContextAndroid(
            isSpeakerphoneOn: false,
            audioMode: AndroidAudioMode.normal,
            stayAwake: true,
            contentType: AndroidContentType.music,
            usageType: AndroidUsageType.media,
            audioFocus: AndroidAudioFocus.gain,
          ),
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.playback,
            options: {AVAudioSessionOptions.mixWithOthers},
          ),
        ),
      );
    }

    _vinylController = AnimationController(
      duration: const Duration(seconds: 10),
      vsync: this,
    );

    if (PerformanceFrameMonitor.enabled) {
      unawaited(_runBenchmarkScenario(startData));
    } else {
      unawaited(_startDataSafely());
    }

    // Request notification permission for background media controls on Android 13+
    _requestNotificationPermission();

    // Initialize Media3 session for notification/lock screen
    _initMediaSession();

    HardwareKeyboard.instance.addHandler(_handleGlobalKeys);

    if (isDesktop && !PerformanceFrameMonitor.enabled) {
      unawaited(_connectDiscordRpc());
    }

    if (isAudioServiceActive) {
      audioHandler.onNext = nextTrack;
      audioHandler.onPrev = prevTrack;
      audioHandler.onPlayCustom = () {
        _setPlaying(true);
        discordStart =
            DateTime.now().millisecondsSinceEpoch -
            currentPositionNotifier.value.inMilliseconds;
        updateRPC(force: true);
        _saveState();
      };
      audioHandler.onPauseCustom = () {
        _setPlaying(false);
        updateRPC(force: true);
        _saveState();
      };
    }

    audioPlayer.setVolume(volume);
    _audioDurationSubscription = audioPlayer.onDurationChanged.listen((d) {
      // Cache track duration for playlist stats
      final sourceTrackId = _audioSourceTrackId;
      if (sourceTrackId != null) {
        trackDurations[sourceTrackId] = d.inSeconds;
      }
      if (_settledTrackRevision == _trackRevision &&
          sourceTrackId == activeTrackNotifier.value?['id']) {
        fullDurationNotifier.value = d;
        _syncMediaSessionMetadata();
      }
    });
    _audioPositionSubscription = audioPlayer.onPositionChanged.listen((p) {
      if (mounted &&
          _settledTrackRevision == _trackRevision &&
          _audioSourceTrackId == activeTrackNotifier.value?['id']) {
        currentPositionNotifier.value = p;
      }
    });

    _audioCompleteSubscription = audioPlayer.onPlayerComplete.listen((event) {
      if (_settledTrackRevision != _trackRevision ||
          _audioSourceTrackId != activeTrackNotifier.value?['id']) {
        return;
      }
      if (loopMode == LoopMode.one) {
        _playIndex(playingIndex);
      } else {
        nextTrack();
      }
    });

    backgroundPollingTimer = Timer.periodic(
      const Duration(milliseconds: 1000),
      (_) async {
        if (!isPlaying ||
            globalLyrics.isEmpty ||
            _settledTrackRevision != _trackRevision ||
            _audioSourceTrackId != activeTrackNotifier.value?['id']) {
          return;
        }
        final pos = await audioPlayer.getCurrentPosition();
        if (pos != null) {
          checkLyrics(pos);
          _syncTicks++;
          if (_syncTicks >= 10) {
            _saveState();
            _syncTicks = 0;
          }
        }
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final surfaceAvailable = MediaQuery.sizeOf(context).width >= 800;
    if (_videoSurfaceAvailable != surfaceAvailable) {
      _videoSurfaceAvailable = surfaceAvailable;
      _initializeVideo(activeTrackNotifier.value);
    }
  }

  @override
  void dispose() {
    _stateDisposing = true;
    _trackRevision += 1;
    _transportRevision += 1;
    _seekRevision += 1;
    _databaseSyncRevision += 1;
    _videoRevision += 1;
    _lyricsRevision += 1;
    _videoOperation?.cancel();
    _videoOperation = null;
    _videoReleaseTimer?.cancel();
    _videoTrackSwitchTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    vinylRotationNotifier.removeListener(_onVinylRotationChanged);
    activeTrackNotifier.removeListener(_onActiveTrackChanged);
    isPlayingNotifier.removeListener(_syncVideoPlayState);
    playVideoClipNotifier.removeListener(_onVideoSettingChanged);
    uiSignal.removeListener(_syncVideoDrift);
    final videoController = _videoController;
    final initializingVideoController = _initializingVideoController;
    _videoController = null;
    _initializingVideoController = null;
    _isVideoInitialized = false;
    _videoTrackId = null;
    if (videoController != null) {
      unawaited(_disposeVideoController(videoController));
    }
    if (initializingVideoController != null) {
      unawaited(_disposeVideoController(initializingVideoController));
    }
    _downloadTaskLimiter.close();
    for (final request in _clipGenerationRequests.values.toSet()) {
      request.transportOperation.cancel();
    }
    _clipGenerationRequests.clear();
    _clipTaskLimiter.close();
    _foregroundClipTaskLimiter.close();
    _clipTransportLimiter.close();
    _clipHttpClient?.close();
    unawaited(_mediaFileDownloader.close());
    unawaited(_foregroundVideoDownloader?.close());
    unawaited(_audioDurationSubscription?.cancel());
    unawaited(_audioPositionSubscription?.cancel());
    unawaited(_audioCompleteSubscription?.cancel());
    HardwareKeyboard.instance.removeHandler(_handleGlobalKeys);
    searchInput.dispose();
    searchFocusNode.dispose();
    backgroundPollingTimer?.cancel();
    rpcThrottleTimer?.cancel();
    if (_mediaSessionActive) {
      _mediaSession?.deactivate();
    }
    fullDurationNotifier.dispose();
    currentPositionNotifier.dispose();
    _vinylController.dispose();

    if (isDesktop) {
      unawaited(_disposeDiscordRpc());
    } else {
      WakelockPlus.disable();
    }

    audioPlayer.dispose();
    super.dispose();
  }

  bool _isVideoHiddenLifecycle(AppLifecycleState? state) =>
      state == AppLifecycleState.hidden ||
      state == AppLifecycleState.paused ||
      state == AppLifecycleState.detached;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final restoredWithoutActivation =
        isDesktop &&
        state == AppLifecycleState.inactive &&
        !_videoLifecycleVisible;
    if (state == AppLifecycleState.resumed || restoredWithoutActivation) {
      _videoLifecycleVisible = true;
      _videoReleaseTimer?.cancel();
      _videoReleaseTimer = null;
      if (isPlaying && vinylRotationNotifier.value && !_vinylUserStopped) {
        _vinylController.repeat();
      }
      _initializeVideo(activeTrackNotifier.value);
      return;
    }
    if (state == AppLifecycleState.inactive) {
      return;
    }
    if (!_isVideoHiddenLifecycle(state)) {
      return;
    }

    final wasVisible = _videoLifecycleVisible;
    _videoLifecycleVisible = false;
    if (!wasVisible && state != AppLifecycleState.detached) {
      return;
    }
    _vinylController.stop();
    _videoTrackSwitchTimer?.cancel();
    _videoRevision += 1;
    _videoOperation?.cancel();
    _videoOperation = null;
    _videoReleaseTimer?.cancel();
    final controller = _videoController;
    final initializingController = _initializingVideoController;
    if (controller != null) {
      unawaited(_pauseVideoController(controller));
    }
    if (initializingController != null) {
      _initializingVideoController = null;
      unawaited(_disposeVideoController(initializingController));
    }
    _enqueueVideoWork(() async {
      final current = _videoController;
      if (!_videoLifecycleVisible && current != null) {
        await _pauseVideoController(current);
      }
    });

    if (state == AppLifecycleState.detached) {
      _initializeVideo(activeTrackNotifier.value);
      return;
    }
    _videoReleaseTimer = Timer(const Duration(milliseconds: 500), () {
      if (!_stateDisposing && !_videoLifecycleVisible) {
        _initializeVideo(activeTrackNotifier.value);
      }
    });
  }

  Future<void> _connectDiscordRpc() async {
    try {
      await FlutterDiscordRPC.instance.connect();
      _discordConnected = true;
      if (mounted && playingQueue.isNotEmpty) {
        updateRPC(force: true);
      }
    } catch (error) {
      _discordConnected = false;
      debugPrint('Discord RPC connect failed: $error');
    }
  }

  Future<void> _disposeDiscordRpc() async {
    try {
      if (_discordConnected) {
        await FlutterDiscordRPC.instance.disconnect();
      }
      _discordConnected = false;
      await FlutterDiscordRPC.instance.dispose();
    } catch (error) {
      debugPrint('Discord RPC dispose failed: $error');
    }
  }

  Future<void> _setDiscordActivity(RPCActivity activity) async {
    if (!_discordConnected) return;
    try {
      await FlutterDiscordRPC.instance.setActivity(activity: activity);
    } catch (error) {
      debugPrint('Discord RPC activity failed: $error');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Helpers
  // ═══════════════════════════════════════════════════════════════════════════

  void _onActiveTrackChanged() {
    if (!mounted) return;
    _videoTrackSwitchTimer?.cancel();
    _suspendVideoForTrackTransition();
    final scheduledTrackId = activeTrackNotifier.value?['id'];
    _videoTrackSwitchTimer = Timer(_videoTrackSwitchDebounce, () {
      _videoTrackSwitchTimer = null;
      if (mounted && activeTrackNotifier.value?['id'] == scheduledTrackId) {
        _initializeVideo(activeTrackNotifier.value);
      }
    });
  }

  void _suspendVideoForTrackTransition() {
    _videoOperation?.cancel();
    _videoOperation = null;
    _videoRevision += 1;
    _lastBenchmarkVideoPosition = null;
    final controller = _videoController;
    if (_isVideoInitialized) {
      _isVideoInitialized = false;
      if (mounted) setState(() {});
    }
    if (controller != null) {
      _enqueueVideoWork(() async {
        if (identical(_videoController, controller) && !_isVideoInitialized) {
          await _pauseVideoController(controller);
        }
      });
    }
  }

  void _syncVideoPlayState() {
    _enqueueVideoWork(() async {
      final controller = _videoController;
      if (controller == null || !_isVideoInitialized) return;
      await _applyVideoPlaybackState(controller);
    });
  }

  void _onVideoSettingChanged() {
    if (mounted) {
      _videoTrackSwitchTimer?.cancel();
      _videoTrackSwitchTimer = null;
      _initializeVideo(activeTrackNotifier.value);
    }
  }

  String _resolveAbsoluteUrl(String url) {
    return resolveConfiguredMediaUrl(url);
  }

  void _syncVideoDrift() {
    _enqueueVideoWork(() async {
      final controller = _videoController;
      if (controller == null || !_isVideoInitialized || !mounted) return;
      final audioPos = currentPositionNotifier.value;
      final videoPos = controller.value.position;
      final diff = (audioPos.inMilliseconds - videoPos.inMilliseconds).abs();
      if (diff > 1200) {
        await controller.seekTo(audioPos);
      }
    });
  }

  void _reportBenchmarkVideoFrame() {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    final currentPosition = controller.value.position;
    final previousPosition = _lastBenchmarkVideoPosition;
    _lastBenchmarkVideoPosition = currentPosition;
    if (previousPosition != null) {
      PerformanceFrameMonitor.recordVideoProgress(
        previousPosition: previousPosition,
        position: currentPosition,
        duration: controller.value.duration,
        isPlaying: controller.value.isPlaying,
        isBuffering: controller.value.isBuffering,
      );
    }
    if (!PerformanceFrameMonitor.canAcceptVideoFrame ||
        !controller.value.isPlaying ||
        controller.value.isBuffering ||
        previousPosition == null ||
        (currentPosition - previousPosition).abs() <
            const Duration(milliseconds: 10)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (PerformanceFrameMonitor.canAcceptVideoFrame) {
        PerformanceFrameMonitor.markVideoFramePresented();
      }
    });
  }

  Future<void> _fetchAndDownloadClip(
    int trackId,
    int revision,
    _VideoOperation operation,
  ) async {
    try {
      await Future<void>.delayed(_clipFetchDebounce);
      final res = await _foregroundClipTaskLimiter.run<http.Response?>(
        () async {
          final activeTrack = activeTrackNotifier.value;
          if (!_isCurrentVideoOperation(revision, operation) ||
              !_videoLifecycleVisible ||
              !_videoSurfaceAvailable ||
              !playVideoClipNotifier.value ||
              activeTrack?['id'] != trackId) {
            return null;
          }
          return _requestClipGeneration(
            trackId,
            abortTrigger: operation.whenCanceled,
          );
        },
      );
      if (res == null) return;
      if (res.statusCode != HttpStatus.ok) return;

      final data = json.decode(res.body);
      final rawVideoUrl = data['video_url']?.toString().trim();
      if (rawVideoUrl == null ||
          rawVideoUrl.isEmpty ||
          !_isCurrentVideoOperation(revision, operation)) {
        return;
      }
      final videoUrl = _resolveAbsoluteUrl(rawVideoUrl);
      final requestStillCurrent =
          _isCurrentVideoOperation(revision, operation) &&
          _videoLifecycleVisible &&
          _videoSurfaceAvailable &&
          playVideoClipNotifier.value &&
          activeTrackNotifier.value?['id'] == trackId;
      var changed = false;
      for (var i = 0; i < playingQueue.length; i++) {
        if (playingQueue[i]['id'] == trackId) {
          playingQueue[i]['video_file'] = videoUrl;
          changed = true;
        }
      }
      final currentActiveTrack = activeTrackNotifier.value;
      if (currentActiveTrack?['id'] == trackId) {
        currentActiveTrack['video_file'] = videoUrl;
        changed = true;
      }
      for (var i = 0; i < cachedTracks.length; i++) {
        if (cachedTracks[i]['id'] == trackId) {
          cachedTracks[i]['video_file'] = videoUrl;
          changed = true;
        }
      }
      if (changed && mounted && requestStillCurrent) setState(() {});

      if (requestStillCurrent && currentActiveTrack?['id'] == trackId) {
        _initializeVideo(currentActiveTrack);
      }

      await _persistOfflineTracks();
    } catch (e) {
      if (!operation.isCanceled && !_stateDisposing) {
        debugPrint('Error fetching video clip background: $e');
      }
    }
  }

  Future<http.Response> _postClipGenerationRequest(
    int trackId,
    _VideoOperation operation,
  ) async {
    final request = http.AbortableRequest(
      'POST',
      configuredServerUri('/api/tracks/$trackId/download_clip/'),
      abortTrigger: operation.whenCanceled,
    );
    try {
      final streamedResponse = await (_clipHttpClient ??= http.Client())
          .send(request)
          .timeout(_clipGenerationTimeout);
      return await http.Response.fromStream(
        streamedResponse,
      ).timeout(_clipGenerationTimeout);
    } on TimeoutException {
      operation.cancel();
      rethrow;
    }
  }

  Future<http.Response> _requestClipGeneration(
    int trackId, {
    Future<void>? abortTrigger,
  }) async {
    var shared = _clipGenerationRequests[trackId];
    if (shared == null) {
      final transportOperation = _VideoOperation();
      final created = _SharedClipGeneration(
        transportOperation: transportOperation,
      );
      created.response = _clipTransportLimiter.run(
        () {
          created.transportStarted = true;
          return _postClipGenerationRequest(trackId, transportOperation);
        },
        abortTrigger: transportOperation.whenCanceled,
        cancellationError: const _ClipGenerationCancelledException(),
      );
      shared = created;
      _clipGenerationRequests[trackId] = shared;
      unawaited(
        created.response.then<void>(
          (_) {
            created.completed = true;
            _releaseClipGenerationIfUnused(trackId, created);
          },
          onError: (Object _, StackTrace _) {
            created.completed = true;
            _releaseClipGenerationIfUnused(trackId, created);
          },
        ),
      );
    }

    shared.subscribers += 1;
    try {
      if (abortTrigger == null) {
        return await shared.response;
      }
      return await Future.any<http.Response>([
        shared.response,
        abortTrigger.then<http.Response>(
          (_) => throw const _ClipGenerationCancelledException(),
        ),
      ]);
    } finally {
      shared.subscribers -= 1;
      _releaseClipGenerationIfUnused(trackId, shared);
    }
  }

  void _releaseClipGenerationIfUnused(
    int trackId,
    _SharedClipGeneration request,
  ) {
    if (request.subscribers != 0) return;
    if (request.completed &&
        identical(_clipGenerationRequests[trackId], request)) {
      _clipGenerationRequests.remove(trackId);
    } else if (!request.transportStarted) {
      request.transportOperation.cancel();
      if (identical(_clipGenerationRequests[trackId], request)) {
        _clipGenerationRequests.remove(trackId);
      }
    }
  }

  String? _knownVideoUrlForTrack(int trackId, dynamic primaryTrack) {
    String? match(dynamic track) {
      final request = _VideoRequest.from(track);
      return request.trackId == trackId ? request.videoUrl : null;
    }

    final primaryUrl = match(primaryTrack);
    if (primaryUrl != null) return primaryUrl;
    final activeUrl = match(activeTrackNotifier.value);
    if (activeUrl != null) return activeUrl;
    for (final track in playingQueue) {
      final url = match(track);
      if (url != null) return url;
    }
    for (final track in cachedTracks) {
      final url = match(track);
      if (url != null) return url;
    }
    return null;
  }

  void _initializeVideo(dynamic trackData) {
    final request = _VideoRequest.from(trackData);
    _videoOperation?.cancel();
    final operation = _VideoOperation();
    _videoOperation = operation;
    final revision = ++_videoRevision;
    _enqueueVideoWork(() => _applyVideoRequest(request, revision, operation));
  }

  void _enqueueVideoWork(Future<void> Function() work) {
    final previous = _videoWork;
    _videoWork = _runVideoWork(previous, work);
  }

  Future<void> _enqueueAudioWork(Future<void> Function() work) {
    final previous = _audioWork;
    final scheduled = _runAudioWork(previous, work);
    _audioWork = scheduled;
    return scheduled;
  }

  Future<void> _runAudioWork(
    Future<void> previous,
    Future<void> Function() work,
  ) async {
    try {
      await previous;
    } catch (error) {
      debugPrint('Previous audio operation failed: $error');
    }
    if (_stateDisposing) return;
    try {
      await work();
    } catch (error, stackTrace) {
      debugPrint('Audio operation failed: $error\n$stackTrace');
    }
  }

  bool _isCurrentTrackRevision(int revision) {
    return !_stateDisposing && revision == _trackRevision;
  }

  Future<void> _runVideoWork(
    Future<void> previous,
    Future<void> Function() work,
  ) async {
    try {
      await previous;
    } catch (error) {
      debugPrint('Previous video operation failed: $error');
    }
    if (_stateDisposing) return;
    try {
      await work();
    } catch (error, stackTrace) {
      debugPrint('Video operation failed: $error\n$stackTrace');
    }
  }

  bool _isCurrentVideoRequest(int revision) =>
      !_stateDisposing && revision == _videoRevision;

  bool _isCurrentVideoOperation(int revision, _VideoOperation operation) =>
      _isCurrentVideoRequest(revision) &&
      identical(_videoOperation, operation) &&
      !operation.isCanceled;

  bool _shouldRunVideo(_VideoRequest request) =>
      _videoLifecycleVisible &&
      _videoSurfaceAvailable &&
      playVideoClipNotifier.value &&
      request.trackId != null;

  Future<void> _applyVideoRequest(
    _VideoRequest request,
    int revision,
    _VideoOperation operation,
  ) async {
    if (!_isCurrentVideoOperation(revision, operation)) return;
    final shouldRun = _shouldRunVideo(request);
    final current = _videoController;
    if (shouldRun &&
        current != null &&
        _videoTrackId == request.trackId &&
        current.value.isInitialized) {
      await _synchronizeVideoController(current);
      if (!_isCurrentVideoOperation(revision, operation) ||
          !_shouldRunVideo(request)) {
        return;
      }
      _isVideoInitialized = true;
      _lastBenchmarkVideoPosition = null;
      if (mounted) setState(() {});
      return;
    }

    await _disposeCurrentVideo();
    if (!_isCurrentVideoOperation(revision, operation)) return;
    if (!shouldRun) {
      if (_videoLifecycleVisible &&
          _videoSurfaceAvailable &&
          playVideoClipNotifier.value &&
          request.trackId != null &&
          request.videoUrl == null) {
        unawaited(_fetchAndDownloadClip(request.trackId!, revision, operation));
      }
      return;
    }

    final trackId = request.trackId!;
    final localVideoFile = File('$localPath/video_$trackId.mp4');
    final hasLocalVideo = await _hasNonEmptyFile(localVideoFile);
    if (!_isCurrentVideoOperation(revision, operation)) return;
    if (!hasLocalVideo) {
      final videoFileUrl = request.videoUrl;
      if (videoFileUrl == null) {
        unawaited(_fetchAndDownloadClip(trackId, revision, operation));
        return;
      }
      if (_blockedVideoSources.contains(_videoSourceKey(request))) return;
      unawaited(
        _downloadVideoForPlayback(
          request: request,
          revision: revision,
          operation: operation,
          destination: localVideoFile,
        ),
      );
      return;
    }

    _ensureLinuxVideoBackendInitialized();
    final controller = VideoPlayerController.file(localVideoFile);
    _initializingVideoController = controller;
    var installed = false;
    var initializationCompleted = false;
    try {
      if (PerformanceFrameMonitor.enabled) {
        controller.addListener(_reportBenchmarkVideoFrame);
      }
      await controller.initialize().timeout(const Duration(seconds: 3));
      initializationCompleted = true;
      if (!_isCurrentVideoOperation(revision, operation) ||
          !_shouldRunVideo(request)) {
        return;
      }

      await controller.setVolume(0.0);
      await controller.setLooping(true);
      await controller.seekTo(currentPositionNotifier.value);
      if (!_isCurrentVideoOperation(revision, operation) ||
          !_shouldRunVideo(request)) {
        return;
      }
      await _applyVideoPlaybackState(controller);
      if (!_isCurrentVideoOperation(revision, operation) ||
          !_shouldRunVideo(request)) {
        return;
      }

      _videoController = controller;
      if (identical(_initializingVideoController, controller)) {
        _initializingVideoController = null;
      }
      _videoTrackId = trackId;
      _isVideoInitialized = true;
      _lastBenchmarkVideoPosition = null;
      _blockedVideoSources.remove(_videoSourceKey(request));
      installed = true;
      if (mounted) setState(() {});
    } catch (error) {
      await _disposeVideoController(controller);
      await _handleLocalVideoInitializationFailure(
        request: request,
        revision: revision,
        operation: operation,
        localVideoFile: localVideoFile,
        error: error,
        initializationCompleted: initializationCompleted,
      );
    } finally {
      if (identical(_initializingVideoController, controller)) {
        _initializingVideoController = null;
      }
      if (!installed) {
        await _disposeVideoController(controller);
      }
    }
  }

  Future<bool> _hasNonEmptyFile(File file) async {
    try {
      return await file.exists() && await file.length() > 0;
    } on FileSystemException {
      return false;
    }
  }

  String _videoSourceKey(_VideoRequest request) {
    final rawSource = request.videoUrl;
    final source = rawSource == null
        ? '<local-without-url>'
        : _resolveAbsoluteUrl(rawSource);
    return '${request.trackId}|$source';
  }

  Future<void> _handleLocalVideoInitializationFailure({
    required _VideoRequest request,
    required int revision,
    required _VideoOperation operation,
    required File localVideoFile,
    required Object error,
    required bool initializationCompleted,
  }) async {
    if (initializationCompleted || error is TimeoutException) {
      if (!operation.isCanceled && !_stateDisposing) {
        debugPrint('Local video initialization failed: $error');
      }
      return;
    }
    if (!_isCurrentVideoOperation(revision, operation) ||
        !_shouldRunVideo(request)) {
      return;
    }

    final sourceKey = _videoSourceKey(request);
    final downloadedThisSession = _downloadedVideoSources.contains(sourceKey);
    if (!await _quarantineInvalidVideo(localVideoFile)) return;
    if (!_isCurrentVideoOperation(revision, operation)) return;

    if (downloadedThisSession) {
      _blockedVideoSources.add(sourceKey);
      debugPrint(
        'Downloaded video cannot be decoded; automatic retry blocked for '
        'this source: $error',
      );
      return;
    }

    final source = request.videoUrl;
    if (source == null) {
      unawaited(_fetchAndDownloadClip(request.trackId!, revision, operation));
      return;
    }
    unawaited(
      _downloadVideoForPlayback(
        request: request,
        revision: revision,
        operation: operation,
        destination: localVideoFile,
      ),
    );
  }

  Future<bool> _quarantineInvalidVideo(File file) async {
    try {
      if (!await _hasNonEmptyFile(file)) return false;
      final timestamp = DateTime.now().microsecondsSinceEpoch;
      final quarantine = File('${file.path}.invalid.$timestamp');
      await file.rename(quarantine.path);
      return true;
    } on FileSystemException catch (error) {
      debugPrint(
        'Invalid video could not be preserved for replacement: $error',
      );
      return false;
    }
  }

  Future<void> _downloadVideoForPlayback({
    required _VideoRequest request,
    required int revision,
    required _VideoOperation operation,
    required File destination,
  }) async {
    final source = request.videoUrl;
    if (source == null) return;
    try {
      if (!_isCurrentVideoOperation(revision, operation) ||
          !_shouldRunVideo(request) ||
          activeTrackNotifier.value?['id'] != request.trackId) {
        return;
      }
      final downloader = _foregroundVideoDownloader ??= MediaFileDownloader(
        maxConcurrent: 1,
      );
      await downloader.download(
        source: Uri.parse(_resolveAbsoluteUrl(source)),
        destination: destination,
        abortTrigger: operation.whenCanceled,
      );
      if (!await _hasNonEmptyFile(destination)) {
        throw FileSystemException(
          'Downloaded video is empty.',
          destination.path,
        );
      }
      _downloadedVideoSources.add(_videoSourceKey(request));
      if (_isCurrentVideoOperation(revision, operation) &&
          activeTrackNotifier.value?['id'] == request.trackId) {
        _initializeVideo(activeTrackNotifier.value);
      }
    } catch (error) {
      if (!operation.isCanceled && !_stateDisposing) {
        debugPrint('Local video download failed: $error');
      }
    }
  }

  Future<void> _synchronizeVideoController(
    VideoPlayerController controller,
  ) async {
    final targetPosition = currentPositionNotifier.value;
    final drift =
        (targetPosition.inMilliseconds -
                controller.value.position.inMilliseconds)
            .abs();
    if (drift > 1200) {
      await controller.seekTo(targetPosition);
    }
    await _applyVideoPlaybackState(controller);
  }

  Future<void> _applyVideoPlaybackState(
    VideoPlayerController controller,
  ) async {
    if (!_videoLifecycleVisible || !isPlayingNotifier.value) {
      await controller.pause();
    } else {
      await controller.play();
    }
  }

  Future<void> _pauseVideoController(VideoPlayerController controller) async {
    try {
      if (controller.value.isInitialized) {
        await controller.pause();
      }
    } catch (error) {
      debugPrint('Video pause failed: $error');
    }
  }

  Future<void> _disposeCurrentVideo() async {
    final controller = _videoController;
    _videoController = null;
    _videoTrackId = null;
    _isVideoInitialized = false;
    _lastBenchmarkVideoPosition = null;
    if (controller == null) {
      PerformanceFrameMonitor.markVideoControllerReleased();
      return;
    }
    if (mounted && !_stateDisposing) setState(() {});
    await _disposeVideoController(controller);
    PerformanceFrameMonitor.markVideoControllerReleased();
  }

  Future<void> _disposeVideoController(VideoPlayerController controller) async {
    if (_disposedVideoControllers[controller] == true) return;
    _disposedVideoControllers[controller] = true;
    if (PerformanceFrameMonitor.enabled) {
      try {
        controller.removeListener(_reportBenchmarkVideoFrame);
      } catch (_) {}
    }
    try {
      await controller.dispose();
    } catch (error) {
      debugPrint('Video dispose failed: $error');
    }
  }

  /// Centralized setter for [isPlaying] that also drives the vinyl animation
  /// and syncs the global [isPlayingNotifier].
  /// React when the user toggles vinyl rotation from Settings.
  void _onVinylRotationChanged() {
    final enabled = vinylRotationNotifier.value;
    if (!enabled) {
      _vinylController.stop();
      _vinylController.value = 0.0;
      _vinylUserStopped = true;
    } else if (isPlaying && !_vinylUserStopped && _videoLifecycleVisible) {
      _vinylController.repeat();
    }
  }

  void _setPlaying(bool value) {
    if (mounted) setState(() => isPlaying = value);
    isPlayingNotifier.value = value;
    if (value &&
        !_vinylUserStopped &&
        vinylRotationNotifier.value &&
        _videoLifecycleVisible) {
      _vinylController.repeat();
    } else if (!value || !vinylRotationNotifier.value) {
      _vinylController.stop();
      if (!vinylRotationNotifier.value) _vinylController.value = 0.0;
    }
    // Wakelock: keep CPU alive while playing on mobile
    if (!isDesktop) {
      if (value) {
        WakelockPlus.enable();
      } else {
        WakelockPlus.disable();
      }
    }
  }

  /// Cycle through loop modes and sync the global notifier.
  void toggleLoopMode() {
    setState(() {
      if (loopMode == LoopMode.off) {
        loopMode = LoopMode.list;
      } else if (loopMode == LoopMode.list) {
        loopMode = LoopMode.one;
      } else {
        loopMode = LoopMode.off;
      }
    });
    loopModeNotifier.value = loopMode;
    _saveState();
  }

  /// Build dark gradient colors from accent color via HSL.
  /// For the black theme, returns pure black background.
  List<Color> _gradientFromAccent(Color accent) {
    // Pure black theme — all #000000
    if (accent.r < 0.24 && accent.g < 0.24 && accent.b < 0.24) {
      return [
        const Color(0xFF0A0A0A),
        const Color(0xFF000000),
        const Color(0xFF000000),
      ];
    }
    final hsl = HSLColor.fromColor(accent);
    return [
      hsl.withLightness(0.18).withSaturation(0.6).toColor(),
      hsl.withLightness(0.08).withSaturation(0.5).toColor(),
      hsl.withLightness(0.03).withSaturation(0.3).toColor(),
    ];
  }

  /// Compute playlist statistics (track count + total duration).
  /// Uses ONLY the server-provided 'duration' field from API response.
  String _getPlaylistStats(List<dynamic> tracks) {
    final count = tracks.length;
    String countText = '$count ${_pluralTracks(count)}';

    // Sum server-provided durations only (no local cache fallback)
    int totalSeconds = 0;
    for (var track in tracks) {
      final dur = track['duration'];
      if (dur != null && dur is num && dur.toInt() > 0) {
        totalSeconds += dur.toInt();
      }
    }

    if (totalSeconds > 0) {
      final hours = totalSeconds ~/ 3600;
      final minutes = (totalSeconds % 3600) ~/ 60;
      if (hours > 0) {
        return '$countText \u2022 $hours${tr('hours_short')} $minutes${tr('minutes_short')}';
      } else {
        return '$countText \u2022 $minutes${tr('minutes_short')}';
      }
    }

    return countText;
  }

  String _pluralTracks(int count) {
    final lang = languageNotifier.value;
    if (lang == 'en' || lang == 'ja') return tr('tracks_count');
    if (count % 10 == 1 && count % 100 != 11) return tr('track_one');
    if (count % 10 >= 2 &&
        count % 10 <= 4 &&
        (count % 100 < 12 || count % 100 > 14)) {
      return tr('track_few');
    }
    return tr('track_many');
  }

  bool _handleGlobalKeys(KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.space) {
      if (searchFocusNode.hasFocus) return false;
      pauseTrack();
      return true;
    }
    return false;
  }

  String formatDuration(Duration d) {
    return "${d.inMinutes.remainder(60).toString().padLeft(2, '0')}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}";
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Data / persistence
  // ═══════════════════════════════════════════════════════════════════════════

  static const int _benchmarkVideo30TrackId = 62030;
  static const int _benchmarkVideo60TrackId = 62060;
  static const int _benchmarkDownloadTrackId = 62070;

  Future<void> _runBenchmarkScenario(
    Future<void> Function() startApplicationData,
  ) async {
    BenchmarkScenarioCommand? command;
    try {
      final commandFuture = PerformanceFrameMonitor.waitForScenarioCommand();
      if (configuredServerBaseUrl != benchmarkServerBaseUrl) {
        command = await commandFuture;
        throw StateError('Benchmark server isolation configuration mismatch.');
      }
      final startup = startApplicationData();
      command = await commandFuture;
      await startup;
      if (command == null) {
        throw StateError('Benchmark control command was not received.');
      }
      _assertBenchmarkRunActive(command.runId);
      if (!_sameBenchmarkPath(localPath, command.dataDirectory)) {
        throw StateError(
          'Benchmark data path mismatch: app=$localPath, '
          'collector=${command.dataDirectory}.',
        );
      }

      if (command.scenario == 'cold-start-server-offline' ||
          command.scenario == 'idle-home-five-minutes') {
        await PerformanceFrameMonitor.markScenarioReady(
          command.runId,
          0,
          dataDirectory: localPath,
          serverBaseUrl: configuredServerBaseUrl,
        );
      } else if (command.scenario == 'audio-only-ten-minutes') {
        await _prepareBenchmarkAudio(command.runId, _benchmarkVideo30TrackId);
        await _markBenchmarkReadyAndComplete(command);
      } else if (command.scenario == 'local-video-30fps-ten-minutes') {
        await _prepareBenchmarkVideo(command.runId, _benchmarkVideo30TrackId);
        await _markBenchmarkReadyAndComplete(command);
      } else if (command.scenario == 'local-video-60fps-ten-minutes') {
        await _prepareBenchmarkVideo(command.runId, _benchmarkVideo60TrackId);
        await _markBenchmarkReadyAndComplete(command);
      } else if (command.scenario == 'minimize-video-five-minutes-restore') {
        await _prepareBenchmarkVideo(command.runId, _benchmarkVideo60TrackId);
        await PerformanceFrameMonitor.markScenarioReady(
          command.runId,
          command.expectedActions,
          dataDirectory: localPath,
          serverBaseUrl: configuredServerBaseUrl,
        );
      } else if (command.scenario == 'large-mp3-mp4-download') {
        await _runBenchmarkDownload(command);
      } else if (command.scenario == 'rapid-track-switch-20') {
        await _runBenchmarkTrackSwitches(command);
      } else if (command.scenario == 'lyrics-blur-five-minutes') {
        await _runBenchmarkLyrics(command);
      } else if (command.scenario == 'video-enable-disable-30') {
        await _runBenchmarkVideoToggles(command);
      } else {
        throw StateError('Unknown benchmark scenario: ${command.scenario}.');
      }
    } catch (error, stackTrace) {
      debugPrint('Benchmark scenario failed: $error\n$stackTrace');
      final runId = command?.runId;
      if (runId != null &&
          PerformanceFrameMonitor.isCurrentBenchmarkRun(runId)) {
        await PerformanceFrameMonitor.markScenarioActionFailed(runId, error);
      }
    }
  }

  Future<void> _markBenchmarkReadyAndComplete(
    BenchmarkScenarioCommand command,
  ) async {
    await PerformanceFrameMonitor.markScenarioReady(
      command.runId,
      command.expectedActions,
      dataDirectory: localPath,
      serverBaseUrl: configuredServerBaseUrl,
    );
    await PerformanceFrameMonitor.markScenarioActionComplete(
      command.runId,
      command.expectedActions,
    );
  }

  Future<void> _runBenchmarkDownload(BenchmarkScenarioCommand command) async {
    final track = _benchmarkTrack(_benchmarkDownloadTrackId);
    final audioFile = File('$localPath/track_$_benchmarkDownloadTrackId.mp3');
    final videoFile = File('$localPath/video_$_benchmarkDownloadTrackId.mp4');
    if (await audioFile.exists() || await videoFile.exists()) {
      throw StateError('Download fixture destination was not reset.');
    }
    await PerformanceFrameMonitor.markScenarioReady(
      command.runId,
      command.expectedActions,
      dataDirectory: localPath,
      serverBaseUrl: configuredServerBaseUrl,
    );
    await _waitForBenchmarkCapture(command);
    PerformanceFrameMonitor.markScenarioActionPerformed(command.runId);
    await downloadMediaFile(track);
    _assertBenchmarkRunActive(command.runId);
    if (!await audioFile.exists() ||
        await audioFile.length() == 0 ||
        !await videoFile.exists() ||
        await videoFile.length() == 0) {
      throw StateError('MP3/MP4 fixture download did not complete.');
    }
    await PerformanceFrameMonitor.markScenarioActionComplete(
      command.runId,
      command.expectedActions,
    );
  }

  Future<void> _runBenchmarkTrackSwitches(
    BenchmarkScenarioCommand command,
  ) async {
    final queue = await _prepareBenchmarkVideo(
      command.runId,
      _benchmarkVideo30TrackId,
    );
    await PerformanceFrameMonitor.markScenarioReady(
      command.runId,
      command.expectedActions,
      dataDirectory: localPath,
      serverBaseUrl: configuredServerBaseUrl,
    );
    await _waitForBenchmarkCapture(command);
    final cadence = command.actionCadence;
    if (cadence <= Duration.zero) {
      throw StateError('Rapid-switch action cadence must be positive.');
    }
    final actionSchedule = Stopwatch()..start();
    for (var action = 0; action < command.expectedActions; action += 1) {
      await _waitForBenchmarkActionDeadline(
        command.runId,
        actionSchedule,
        cadence * action,
      );
      _assertBenchmarkRunActive(command.runId);
      _playIndex((action + 1) % queue.length);
      PerformanceFrameMonitor.markScenarioActionPerformed(command.runId);
    }
    actionSchedule.stop();
    await Future<void>.delayed(const Duration(seconds: 2));
    await _waitForBenchmarkCondition(
      command.runId,
      'final rapid-switch state',
      () =>
          playingIndex == 0 &&
          activeTrackNotifier.value?['id'] == _benchmarkVideo30TrackId &&
          audioPlayer.state == PlayerState.playing &&
          _isVideoInitialized &&
          _videoController?.value.isPlaying == true &&
          globalLyrics.isNotEmpty,
      timeout: const Duration(seconds: 10),
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    _assertBenchmarkRunActive(command.runId);
    if (playingIndex != 0 ||
        activeTrackNotifier.value?['id'] != _benchmarkVideo30TrackId ||
        audioPlayer.state != PlayerState.playing ||
        !_isVideoInitialized ||
        _videoController?.value.isPlaying != true ||
        globalLyrics.isEmpty) {
      throw StateError('Rapid-switch final state did not remain stable.');
    }
    await PerformanceFrameMonitor.markScenarioActionComplete(
      command.runId,
      command.expectedActions,
    );
  }

  Future<void> _runBenchmarkLyrics(BenchmarkScenarioCommand command) async {
    await _prepareBenchmarkAudio(command.runId, _benchmarkVideo30TrackId);
    await _waitForBenchmarkCondition(
      command.runId,
      'local lyrics',
      () => !lrcLoading && globalLyrics.isNotEmpty,
    );
    _assertBenchmarkRunActive(command.runId);
    showLyricsScreen();
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _markBenchmarkReadyAndComplete(command);
  }

  Future<void> _runBenchmarkVideoToggles(
    BenchmarkScenarioCommand command,
  ) async {
    await _prepareBenchmarkVideo(command.runId, _benchmarkVideo60TrackId);
    await PerformanceFrameMonitor.markScenarioReady(
      command.runId,
      command.expectedActions,
      dataDirectory: localPath,
      serverBaseUrl: configuredServerBaseUrl,
    );
    await _waitForBenchmarkCapture(command);
    final cadence = command.actionCadence;
    if (cadence <= Duration.zero) {
      throw StateError('Video-toggle action cadence must be positive.');
    }
    final actionSchedule = Stopwatch()..start();
    for (var action = 0; action < command.expectedActions; action += 1) {
      await _waitForBenchmarkActionDeadline(
        command.runId,
        actionSchedule,
        cadence * action,
      );
      _assertBenchmarkRunActive(command.runId);
      playVideoClipNotifier.value = action.isOdd;
      PerformanceFrameMonitor.markScenarioActionPerformed(command.runId);
    }
    actionSchedule.stop();
    await _waitForBenchmarkCondition(
      command.runId,
      'final video-toggle state',
      () =>
          playVideoClipNotifier.value &&
          _isVideoInitialized &&
          _videoController?.value.isPlaying == true,
      timeout: const Duration(seconds: 15),
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    _assertBenchmarkRunActive(command.runId);
    if (!playVideoClipNotifier.value ||
        !_isVideoInitialized ||
        _videoController?.value.isPlaying != true) {
      throw StateError('Video-toggle final state did not remain stable.');
    }
    await PerformanceFrameMonitor.markScenarioActionComplete(
      command.runId,
      command.expectedActions,
    );
  }

  Future<List<dynamic>> _prepareBenchmarkAudio(
    String runId,
    int trackId,
  ) async {
    final track30 = _benchmarkTrack(_benchmarkVideo30TrackId);
    final track60 = _benchmarkTrack(_benchmarkVideo60TrackId);
    final queue = <dynamic>[track30, track60];
    final index = trackId == _benchmarkVideo30TrackId ? 0 : 1;
    await _requireBenchmarkLocalMedia(trackId, video: false);
    playVideoClipNotifier.value = false;
    startPlayback(queue, index);
    await _waitForBenchmarkCondition(
      runId,
      'local audio playback',
      () =>
          playingIndex == index &&
          activeTrackNotifier.value?['id'] == trackId &&
          audioPlayer.state == PlayerState.playing,
    );
    return queue;
  }

  Future<List<dynamic>> _prepareBenchmarkVideo(
    String runId,
    int trackId,
  ) async {
    await _requireBenchmarkLocalMedia(trackId, video: true);
    final queue = await _prepareBenchmarkAudio(runId, trackId);
    _assertBenchmarkRunActive(runId);
    playVideoClipNotifier.value = true;
    final expectedVideo = File('$localPath/video_$trackId.mp4').absolute.path;
    try {
      await _waitForBenchmarkCondition(runId, 'local video playback', () {
        final controller = _videoController;
        return controller != null &&
            _isVideoInitialized &&
            controller.value.isInitialized &&
            controller.value.isPlaying &&
            _sameBenchmarkPath(controller.dataSource, expectedVideo);
      }, timeout: const Duration(seconds: 15));
    } on TimeoutException {
      final controller = _videoController;
      throw StateError(
        'Local video did not become ready: controller=${controller != null}, '
        'screenInitialized=$_isVideoInitialized, '
        'valueInitialized=${controller?.value.isInitialized}, '
        'playing=${controller?.value.isPlaying}, '
        'buffering=${controller?.value.isBuffering}, '
        'source=${controller?.dataSource}, expected=$expectedVideo, '
        'error=${controller?.value.errorDescription}.',
      );
    }
    return queue;
  }

  dynamic _benchmarkTrack(int trackId) {
    for (final track in [...playingQueue, ...cachedTracks]) {
      if (track is Map && track['id'] == trackId) {
        return track;
      }
    }
    throw StateError('Benchmark track $trackId is missing from seed data.');
  }

  Future<void> _requireBenchmarkLocalMedia(
    int trackId, {
    required bool video,
  }) async {
    final audioFile = File('$localPath/track_$trackId.mp3');
    if (!await audioFile.exists() || await audioFile.length() == 0) {
      throw StateError('Local benchmark MP3 is missing for track $trackId.');
    }
    if (video) {
      final videoFile = File('$localPath/video_$trackId.mp4');
      if (!await videoFile.exists() || await videoFile.length() == 0) {
        throw StateError('Local benchmark MP4 is missing for track $trackId.');
      }
    }
  }

  Future<void> _waitForBenchmarkCapture(
    BenchmarkScenarioCommand command,
  ) async {
    if (command.awaitCapture) {
      await PerformanceFrameMonitor.waitForCapture(command.runId);
    }
    _assertBenchmarkRunActive(command.runId);
    if (command.actionDelay > Duration.zero) {
      await Future<void>.delayed(command.actionDelay);
      _assertBenchmarkRunActive(command.runId);
    }
  }

  Future<void> _waitForBenchmarkActionDeadline(
    String runId,
    Stopwatch schedule,
    Duration deadline,
  ) async {
    final remaining = deadline - schedule.elapsed;
    if (remaining > Duration.zero) {
      await Future<void>.delayed(remaining);
    }
    _assertBenchmarkRunActive(runId);
  }

  Future<void> _waitForBenchmarkCondition(
    String runId,
    String description,
    bool Function() predicate, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      _assertBenchmarkRunActive(runId);
      if (predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException('Timed out waiting for $description.');
  }

  void _assertBenchmarkRunActive(String runId) {
    if (!mounted || !PerformanceFrameMonitor.isCurrentBenchmarkRun(runId)) {
      throw StateError('Benchmark run $runId is no longer active.');
    }
  }

  bool _sameBenchmarkPath(String first, String second) {
    String normalize(String value) {
      final path = value.startsWith('file:')
          ? File.fromUri(Uri.parse(value)).path
          : value;
      final normalized = File(path).absolute.path.replaceAll('/', '\\');
      return Platform.isWindows ? normalized.toLowerCase() : normalized;
    }

    return normalize(first) == normalize(second);
  }

  Future<void> startData() async {
    final appDir = await getShikiDataDirectory();
    if (_stateDisposing) return;

    // Migrate existing tracks, covers, and config files from root Documents directory
    if (!hasAppDataDirectoryOverride) {
      try {
        final docsDir = await getDocumentsRootDirectory();
        final entities = docsDir.listSync();
        for (final entity in entities) {
          if (entity is File) {
            final name = entity.path.split(Platform.pathSeparator).last;
            final isTemporary =
                name.contains('.part.') ||
                name.contains('.tmp.') ||
                name.endsWith('.lock');
            if (!isTemporary &&
                (name.startsWith('track_') ||
                    name.startsWith('video_') ||
                    name.startsWith('cover_') ||
                    name == 'liked_tracks.json' ||
                    name == 'my_playlists.json' ||
                    name == 'offline_tracks.json' ||
                    name == 'app_state.json' ||
                    name == 'shiki_settings.json')) {
              final newPath = '${appDir.path}/$name';
              try {
                final result = await safeFileMigration.migrate(
                  source: entity,
                  destination: File(newPath),
                );
                if (result == SafeFileMigrationResult.copied) {
                  debugPrint('Copied legacy file: $name -> $newPath');
                }
              } catch (e) {
                debugPrint('Legacy file copy failed for $name: $e');
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Migration failed: $e');
      }
    }

    if (_stateDisposing) return;
    localPath = appDir.path;
    globalLocalPath = localPath;
    await readFavorites();
    if (_stateDisposing) return;
    await readPlaylists();
    if (_stateDisposing) return;
    await _loadOfflineTrackCache();
    if (_stateDisposing) return;
    await _loadState();
    if (_stateDisposing) return;
    unawaited(syncDatabase());
  }

  Future<void> _startDataSafely() async {
    try {
      await startData();
    } catch (error, stackTrace) {
      debugPrint('Startup data load failed: $error\n$stackTrace');
    }
  }

  Future<void> _saveState() async {
    if (localPath.isEmpty) return;
    try {
      final f = File('$localPath/app_state.json');
      final data = {
        'volume': volume,
        'loopMode': loopMode.index,
        'playingIndex': playingIndex,
        'playingQueue': playingQueue,
        'position': currentPositionNotifier.value.inMilliseconds,
        'isShuffled': isShuffled,
        'unshuffledQueue': _unshuffledQueue,
      };
      await atomicFileStore.writeString(f, json.encode(data));
    } catch (e) {
      debugPrint(e.toString());
    }
  }

  Future<void> _loadState() async {
    if (localPath.isEmpty) return;
    final revisionBeforeRead = _trackRevision;
    try {
      final f = File('$localPath/app_state.json');
      if (await f.exists()) {
        final decoded = json.decode(await f.readAsString());
        if (decoded is! Map) return;
        final data = Map<String, dynamic>.from(decoded);

        if (data['volume'] != null) {
          volume = (data['volume'] as num).toDouble();
          await audioPlayer.setVolume(volume);
        }
        final savedLoopMode = data['loopMode'];
        if (savedLoopMode is int &&
            savedLoopMode >= 0 &&
            savedLoopMode < LoopMode.values.length) {
          loopMode = LoopMode.values[savedLoopMode];
        }
        if (data['isShuffled'] is bool) {
          isShuffled = data['isShuffled'] as bool;
        }
        if (data['unshuffledQueue'] is List) {
          _unshuffledQueue = List<dynamic>.from(data['unshuffledQueue']);
        }

        final savedQueue = data['playingQueue'];
        if (revisionBeforeRead != _trackRevision ||
            savedQueue is! List ||
            savedQueue.isEmpty) {
          return;
        }
        playingQueue = List<dynamic>.from(savedQueue);
        final savedIndex = data['playingIndex'];
        playingIndex = savedIndex is int
            ? savedIndex.clamp(0, playingQueue.length - 1)
            : 0;

        final targetTrack = playingQueue[playingIndex];
        final trackRevision = ++_trackRevision;
        _transportRevision += 1;
        _seekRevision += 1;
        activeTrackNotifier.value = targetTrack;

        if (isAudioServiceActive) {
          final dur = trackDurations[targetTrack['id']];
          audioHandler.mediaItem.add(
            MediaItem(
              id: targetTrack['id'].toString(),
              title: targetTrack['title'].toString(),
              artist: targetTrack['album']['artist']['name'].toString(),
              album: targetTrack['album']['title']?.toString(),
              artUri: getArtUri(targetTrack),
              duration: dur != null ? Duration(seconds: dur) : null,
            ),
          );
        }

        final savedPosition = data['position'];
        final position = Duration(
          milliseconds: savedPosition is num
              ? max(0, savedPosition.toInt())
              : 0,
        );
        currentPositionNotifier.value = position;
        unawaited(fetchLyrics(targetTrack));
        if (mounted) setState(() {});

        await _enqueueAudioWork(
          () => _restoreTrackSource(
            targetTrack: targetTrack,
            trackRevision: trackRevision,
            position: position,
          ),
        );
        if (_isCurrentTrackRevision(trackRevision)) {
          _syncMediaSessionMetadata();
          _syncMediaSessionPlayback();
          updateRPC(force: true);
        }
      }
    } catch (e) {
      debugPrint(e.toString());
    }
  }

  Future<void> readFavorites() async {
    final favFile = File('$localPath/liked_tracks.json');
    if (await favFile.exists()) {
      try {
        final list = json.decode(await favFile.readAsString());
        final loaded = Set<int>.from(list);
        if (mounted) {
          setState(() => favs = loaded);
        } else {
          favs = loaded;
        }
      } catch (e) {
        debugPrint(e.toString());
      }
    }
  }

  Future<void> readPlaylists() async {
    final f = File('$localPath/my_playlists.json');
    if (await f.exists()) {
      try {
        final list = json.decode(await f.readAsString());
        final loaded = List<Map<String, dynamic>>.from(
          list.map((e) => Map<String, dynamic>.from(e)),
        );
        if (mounted) {
          setState(() => myPlaylists = loaded);
        } else {
          myPlaylists = loaded;
        }
      } catch (e) {
        debugPrint(e.toString());
      }
    }
  }

  Future<void> savePlaylists() async {
    try {
      final f = File('$localPath/my_playlists.json');
      final snapshot = json.encode(myPlaylists);
      await atomicFileStore.writeString(f, snapshot);
    } catch (error) {
      debugPrint('Playlist save failed: $error');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Network
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _persistOfflineTracks() {
    if (localPath.isEmpty) return Future<void>.value();
    final snapshot = json.encode(cachedTracks);
    return atomicFileStore.writeString(
      File('$localPath/offline_tracks.json'),
      snapshot,
    );
  }

  void _applyTracks(List<dynamic> tracks) {
    if (_stateDisposing) return;
    if (mounted) {
      setState(() {
        cachedTracks = tracks;
        isLoading = false;
      });
    } else {
      cachedTracks = tracks;
      isLoading = false;
    }
  }

  Future<List<dynamic>?> _readOfflineTrackCache() async {
    if (localPath.isEmpty) return null;
    final file = File('$localPath/offline_tracks.json');
    if (!await file.exists()) return null;
    try {
      final decoded = json.decode(await file.readAsString());
      if (decoded is List) return List<dynamic>.from(decoded);
      debugPrint('Offline track cache must contain a JSON list.');
    } catch (error) {
      debugPrint('Offline track cache read failed: $error');
    }
    return null;
  }

  Future<void> _loadOfflineTrackCache() async {
    final tracks = await _readOfflineTrackCache();
    if (tracks != null) _applyTracks(tracks);
  }

  bool _isCurrentDatabaseSync(int revision) =>
      !_stateDisposing && revision == _databaseSyncRevision;

  Future<void> syncDatabase() async {
    final revision = ++_databaseSyncRevision;
    final tracksUri = configuredServerUri('/api/tracks/');

    try {
      final res = await http.get(tracksUri).timeout(const Duration(seconds: 5));
      if (res.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Track sync failed with HTTP ${res.statusCode}.',
          uri: tracksUri,
        );
      }
      final decoded = json.decode(utf8.decode(res.bodyBytes));
      if (decoded is! List) {
        throw const FormatException('Track response must be a JSON list.');
      }
      if (!_isCurrentDatabaseSync(revision)) return;
      _applyTracks(List<dynamic>.from(decoded));
      try {
        await _persistOfflineTracks();
      } catch (error) {
        debugPrint('Offline track cache write failed: $error');
      }
    } catch (e) {
      if (!_isCurrentDatabaseSync(revision)) return;
      if (cachedTracks.isEmpty) {
        final offlineTracks = await _readOfflineTrackCache();
        if (!_isCurrentDatabaseSync(revision)) return;
        _applyTracks(offlineTracks ?? <dynamic>[]);
      }
      // Show a snackbar only when the user might care (i.e. we had no cache)
      if (mounted && cachedTracks.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Сервер недоступен. Работаем оффлайн.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  }

  Future<void> downloadFromNetwork() async {
    if (searchQuery.isEmpty) return;
    setState(() => isSearchLoading = true);
    try {
      final queryEndpoint = configuredServerUri(
        '/api/smart_search/',
        queryParameters: <String, Object?>{'q': searchQuery},
      );
      final res = await http
          .get(queryEndpoint)
          .timeout(const Duration(seconds: 60));
      if (res.statusCode == 200) {
        await syncDatabase();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Контент успешно индексирован сервером.'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        final errData = json.decode(utf8.decode(res.bodyBytes));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Сбой API: ${errData['error']}'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Таймаут соединения.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
    setState(() => isSearchLoading = false);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Downloads
  // ═══════════════════════════════════════════════════════════════════════════

  bool isTrackLocal(int id) {
    if (localPath.isEmpty) return false;
    final file = File('$localPath/track_$id.mp3');
    try {
      return file.existsSync() && file.lengthSync() > 0;
    } on FileSystemException {
      return false;
    }
  }

  bool isTrackDownloadComplete(dynamic track) {
    if (localPath.isEmpty || track is! Map) return false;
    final rawTrackId = track['id'];
    final trackId = rawTrackId is int
        ? rawTrackId
        : int.tryParse(rawTrackId?.toString() ?? '');
    if (trackId == null) return false;
    final audioFile = File('$localPath/track_$trackId.mp3');
    final videoFile = File('$localPath/video_$trackId.mp4');
    try {
      return audioFile.existsSync() &&
          audioFile.lengthSync() > 0 &&
          videoFile.existsSync() &&
          videoFile.lengthSync() > 0;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> downloadMediaFile(dynamic mediaObj) async {
    final trackId = mediaObj['id'];
    if (downloadQueue.contains(trackId)) return;
    if (mounted) {
      setState(() => downloadQueue.add(trackId));
    } else {
      downloadQueue.add(trackId);
    }
    try {
      await _downloadTaskLimiter.run(() async {
        final audioFile = File('$localPath/track_$trackId.mp3');
        final coverFile = File(
          '$localPath/cover_${trackId}_${getCoverFileName(mediaObj)}',
        );
        final lrcFile = File('$localPath/track_$trackId.lrc');

        if (!await _hasNonEmptyFile(audioFile)) {
          await _mediaFileDownloader.download(
            source: Uri.parse(mediaObj['audio_file'].toString()),
            destination: audioFile,
          );
        }
        if (!await _isCoverValidAndSquare(coverFile)) {
          await _downloadAndCropCover(
            mediaObj['album']['cover'].toString(),
            coverFile,
          );
        }
        if (!await lrcFile.exists() &&
            mediaObj['lyrics'] != null &&
            mediaObj['lyrics'].toString().trim().isNotEmpty) {
          await atomicFileStore.writeString(
            lrcFile,
            mediaObj['lyrics'].toString(),
          );
        }

        // Check if clip exists or download it on the server first
        final parsedTrackId = trackId is int
            ? trackId
            : int.tryParse(trackId.toString());
        var videoFileUrl = parsedTrackId == null
            ? mediaObj['video_file']?.toString()
            : _knownVideoUrlForTrack(parsedTrackId, mediaObj);
        if ((videoFileUrl == null || videoFileUrl.trim().isEmpty) &&
            parsedTrackId != null) {
          try {
            videoFileUrl = await _clipTaskLimiter.run<String?>(() async {
              final knownUrl = _knownVideoUrlForTrack(parsedTrackId, mediaObj);
              if (knownUrl != null) return knownUrl;
              final res = await _requestClipGeneration(parsedTrackId);
              if (res.statusCode != HttpStatus.ok) return null;
              final data = json.decode(res.body);
              return data['video_url']?.toString();
            });
            if (videoFileUrl != null) {
              videoFileUrl = _resolveAbsoluteUrl(videoFileUrl);
              // Save to memory lists
              for (var i = 0; i < playingQueue.length; i++) {
                if (_VideoRequest.from(playingQueue[i]).trackId ==
                    parsedTrackId) {
                  playingQueue[i]['video_file'] = videoFileUrl;
                }
              }
              final activeTrack = activeTrackNotifier.value;
              if (_VideoRequest.from(activeTrack).trackId == parsedTrackId) {
                activeTrack['video_file'] = videoFileUrl;
              }
              for (var i = 0; i < cachedTracks.length; i++) {
                if (_VideoRequest.from(cachedTracks[i]).trackId ==
                    parsedTrackId) {
                  cachedTracks[i]['video_file'] = videoFileUrl;
                }
              }
              await _persistOfflineTracks();
            }
          } catch (_) {}
        }

        if (videoFileUrl != null && videoFileUrl.trim().isNotEmpty) {
          final videoFile = File('$localPath/video_$trackId.mp4');
          if (!await _hasNonEmptyFile(videoFile)) {
            final resolvedUrl = _resolveAbsoluteUrl(videoFileUrl);
            await _mediaFileDownloader.download(
              source: Uri.parse(resolvedUrl),
              destination: videoFile,
            );
            _downloadedVideoSources.add(
              _videoSourceKey(
                _VideoRequest(trackId: parsedTrackId, videoUrl: resolvedUrl),
              ),
            );
          }
        }
      });
    } catch (e) {
      debugPrint(e.toString());
    } finally {
      if (mounted) {
        setState(() => downloadQueue.remove(trackId));
      } else {
        downloadQueue.remove(trackId);
      }
    }
  }

  Future<void> downloadAllTracks(List<dynamic> tracksToDownload) async {
    for (var track in tracksToDownload) {
      final trackId = track['id'];
      if (!isTrackDownloadComplete(track) && !downloadQueue.contains(trackId)) {
        downloadMediaFile(track);
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Треки добавлены в очередь скачивания!'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> clearAllCache() async {
    clearCoverCache();
    final cacheDirectory = Directory(localPath);
    if (await cacheDirectory.exists()) {
      for (var f in cacheDirectory.listSync()) {
        if (f.path.endsWith('.jpg') ||
            f.path.endsWith('.mp3') ||
            f.path.endsWith('.lrc')) {
          try {
            f.deleteSync();
          } catch (e) {
            debugPrint(e.toString());
          }
        }
      }
    }
    setState(() {
      cachedTracks.clear();
      isLoading = true;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Системный кэш успешно очищен.')),
      );
    }
    await syncDatabase();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Favorites / playlists
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> toggleFavorite(int id) async {
    setState(() {
      if (favs.contains(id)) {
        favs.remove(id);
      } else {
        favs.add(id);
      }
    });
    final favFile = File('$localPath/liked_tracks.json');
    final snapshot = json.encode(favs.toList());
    try {
      await atomicFileStore.writeString(favFile, snapshot);
    } catch (error) {
      debugPrint('Favorite save failed: $error');
    }
  }

  ImageProvider getPlaylistImage(String pathOrUrl) {
    if (pathOrUrl.startsWith('http')) return NetworkImage(pathOrUrl);
    return FileImage(File(pathOrUrl));
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Playback
  // ═══════════════════════════════════════════════════════════════════════════

  void startPlayback(List<dynamic> targetQueue, int index) {
    if (targetQueue.isEmpty || index < 0 || index >= targetQueue.length) return;
    if (isPremium) playCount++;

    setState(() {
      playingQueue = List.from(targetQueue);
      playingIndex = index;
    });
    // Reset shuffle when starting fresh from a list tap
    isShuffled = false;
    _unshuffledQueue = [];

    final targetTrack = playingQueue[playingIndex];
    _activateTrackForPlayback(targetTrack);
  }

  void pauseTrack() {
    if (playingQueue.isEmpty) return;
    final shouldPlay = !isPlaying;
    final revision = ++_transportRevision;
    _setPlaying(shouldPlay);
    _syncMediaSessionPlayback();
    unawaited(_saveState());
    unawaited(
      _enqueueAudioWork(() async {
        if (_stateDisposing || revision != _transportRevision) return;
        try {
          if (shouldPlay) {
            await audioPlayer.resume();
          } else {
            await audioPlayer.pause();
          }
        } catch (_) {
          if (!_stateDisposing && revision == _transportRevision) {
            _setPlaying(!shouldPlay);
            _syncMediaSessionPlayback();
          }
          rethrow;
        }
        if (_stateDisposing || revision != _transportRevision) return;
        if (shouldPlay) {
          discordStart =
              DateTime.now().millisecondsSinceEpoch -
              currentPositionNotifier.value.inMilliseconds;
        }
        updateRPC(force: true);
        _syncMediaSessionPlayback();
        unawaited(_saveState());
      }),
    );
  }

  void nextTrack() {
    if (playingQueue.isEmpty) return;
    if (playingIndex < playingQueue.length - 1) {
      _playIndex(playingIndex + 1);
    } else {
      if (loopMode == LoopMode.list || loopMode == LoopMode.one) {
        _playIndex(0);
      } else {
        _stopPlaybackAtQueueEnd();
      }
    }
  }

  void prevTrack() {
    if (playingQueue.isEmpty) return;
    if (currentPositionNotifier.value.inSeconds > 3) {
      seekTo(Duration.zero);
    } else {
      if (playingIndex > 0) {
        _playIndex(playingIndex - 1);
      } else {
        if (loopMode == LoopMode.list || loopMode == LoopMode.one) {
          _playIndex(playingQueue.length - 1);
        } else {
          seekTo(Duration.zero);
        }
      }
    }
  }

  /// Internal: play a specific index within the *current* queue (preserves
  /// shuffle state).
  void _playIndex(int index) {
    if (playingQueue.isEmpty || index < 0 || index >= playingQueue.length) {
      return;
    }

    setState(() => playingIndex = index);

    final targetTrack = playingQueue[playingIndex];
    _activateTrackForPlayback(targetTrack);
  }

  void _activateTrackForPlayback(dynamic targetTrack) {
    final trackRevision = ++_trackRevision;
    final transportRevision = ++_transportRevision;
    _seekRevision += 1;
    _setPlaying(true);
    discordStart = null;
    activeTrackNotifier.value = targetTrack;
    currentPositionNotifier.value = Duration.zero;
    fullDurationNotifier.value = Duration.zero;
    unawaited(_ensureCoverDownloaded(targetTrack));

    if (isAudioServiceActive) {
      final dur = trackDurations[targetTrack['id']];
      audioHandler.mediaItem.add(
        MediaItem(
          id: targetTrack['id'].toString(),
          title: targetTrack['title'].toString(),
          artist: targetTrack['album']['artist']['name'].toString(),
          album: targetTrack['album']['title']?.toString(),
          artUri: getArtUri(targetTrack),
          duration: dur != null ? Duration(seconds: dur) : null,
        ),
      );
      // playbackState is now auto-managed by AudioPlayerHandler listeners
    }

    unawaited(fetchLyrics(targetTrack));
    _syncMediaSessionMetadata();
    _syncMediaSessionPlayback();
    unawaited(_saveState());
    unawaited(
      _enqueueAudioWork(
        () => _playTrackSource(
          targetTrack: targetTrack,
          trackRevision: trackRevision,
          transportRevision: transportRevision,
        ),
      ),
    );
  }

  Future<void> _playTrackSource({
    required dynamic targetTrack,
    required int trackRevision,
    required int transportRevision,
  }) async {
    if (!_isCurrentTrackRevision(trackRevision)) return;
    final trackId = targetTrack['id'] as int;
    final localTrackPath = File('$localPath/track_$trackId.mp3');
    final hasLocalTrack = await _hasNonEmptyFile(localTrackPath);
    if (!_isCurrentTrackRevision(trackRevision)) return;

    _audioSourceTrackId = null;
    _settledTrackRevision = -1;
    try {
      if (hasLocalTrack) {
        await audioPlayer.setSource(DeviceFileSource(localTrackPath.path));
      } else {
        await audioPlayer.setSource(
          UrlSource(targetTrack['audio_file'].toString()),
        );
      }
    } catch (_) {
      if (_isCurrentTrackRevision(trackRevision) &&
          transportRevision == _transportRevision) {
        _setPlaying(false);
        _syncMediaSessionPlayback();
      }
      rethrow;
    }
    if (!_isCurrentTrackRevision(trackRevision)) return;

    _audioSourceTrackId = trackId;
    _settledTrackRevision = trackRevision;
    try {
      final duration = await audioPlayer.getDuration();
      if (!_isCurrentTrackRevision(trackRevision)) return;
      if (duration != null) {
        trackDurations[trackId] = duration.inSeconds;
        fullDurationNotifier.value = duration;
      }

      if (isPlaying) {
        await audioPlayer.resume();
      } else {
        await audioPlayer.pause();
      }
    } catch (_) {
      if (_isCurrentTrackRevision(trackRevision) &&
          transportRevision == _transportRevision) {
        _setPlaying(false);
        _syncMediaSessionPlayback();
      }
      rethrow;
    }
    if (!_isCurrentTrackRevision(trackRevision)) return;

    discordStart = isPlaying ? DateTime.now().millisecondsSinceEpoch : null;
    updateRPC(force: true);
    _syncMediaSessionMetadata();
    _syncMediaSessionPlayback();
    unawaited(_saveState());
  }

  Future<void> _restoreTrackSource({
    required dynamic targetTrack,
    required int trackRevision,
    required Duration position,
  }) async {
    if (!_isCurrentTrackRevision(trackRevision)) return;
    final trackId = targetTrack['id'] as int;
    final localTrackPath = File('$localPath/track_$trackId.mp3');
    final hasLocalTrack = await _hasNonEmptyFile(localTrackPath);
    if (!_isCurrentTrackRevision(trackRevision)) return;

    _audioSourceTrackId = null;
    _settledTrackRevision = -1;
    if (hasLocalTrack) {
      await audioPlayer.setSource(DeviceFileSource(localTrackPath.path));
    } else {
      await audioPlayer.setSource(
        UrlSource(targetTrack['audio_file'].toString()),
      );
    }
    if (!_isCurrentTrackRevision(trackRevision)) return;

    _audioSourceTrackId = trackId;
    _settledTrackRevision = trackRevision;
    final duration = await audioPlayer.getDuration();
    if (!_isCurrentTrackRevision(trackRevision)) return;
    if (duration != null) {
      trackDurations[trackId] = duration.inSeconds;
      fullDurationNotifier.value = duration;
    }
    if (position > Duration.zero) {
      final targetPosition = duration != null && position > duration
          ? duration
          : position;
      await audioPlayer.seek(targetPosition);
      if (_isCurrentTrackRevision(trackRevision)) {
        currentPositionNotifier.value = targetPosition;
      }
    }
  }

  void _stopPlaybackAtQueueEnd() {
    final revision = ++_transportRevision;
    _setPlaying(false);
    _syncMediaSessionPlayback();
    updateRPC(force: true);
    unawaited(_saveState());
    unawaited(
      _enqueueAudioWork(() async {
        if (_stateDisposing || revision != _transportRevision) return;
        await audioPlayer.stop();
        if (_stateDisposing || revision != _transportRevision) return;
        _audioSourceTrackId = null;
      }),
    );
  }

  // ── Shuffle ──────────────────────────────────────────────────────────────

  void toggleShuffle() {
    if (playingQueue.isEmpty) return;
    setState(() {
      if (isShuffled) {
        // Restore original order
        final currentTrack = playingQueue[playingIndex];
        playingQueue = List.from(_unshuffledQueue);
        playingIndex = playingQueue.indexWhere(
          (t) => t['id'] == currentTrack['id'],
        );
        if (playingIndex < 0) playingIndex = 0;
        isShuffled = false;
      } else {
        // Save original, then shuffle keeping current track at front
        _unshuffledQueue = List.from(playingQueue);
        final currentTrack = playingQueue[playingIndex];
        playingQueue.removeAt(playingIndex);
        playingQueue.shuffle(Random());
        playingQueue.insert(0, currentTrack);
        playingIndex = 0;
        isShuffled = true;
      }
    });
    isShuffledNotifier.value = isShuffled;
    _saveState();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Lyrics
  // ═══════════════════════════════════════════════════════════════════════════

  void checkLyrics(Duration pos) {
    if (!isPlaying || globalLyrics.isEmpty) return;

    int resolvedIndex = -1;
    for (int i = 0; i < globalLyrics.length; i++) {
      if (pos >= globalLyrics[i].time) {
        resolvedIndex = i;
      } else {
        break;
      }
    }

    if (resolvedIndex != currentLine && resolvedIndex != -1) {
      currentLine = resolvedIndex;
      updateRPC();
      uiSignal.value++;
    }
  }

  void seekTo(Duration pos) {
    final trackRevision = _trackRevision;
    final seekRevision = ++_seekRevision;
    currentPositionNotifier.value = pos;
    discordStart = DateTime.now().millisecondsSinceEpoch - pos.inMilliseconds;
    checkLyrics(pos);
    _syncMediaSessionPlayback();
    unawaited(_saveState());
    unawaited(
      _enqueueAudioWork(() async {
        if (!_isCurrentTrackRevision(trackRevision) ||
            seekRevision != _seekRevision) {
          return;
        }
        await audioPlayer.seek(pos);
        if (!_isCurrentTrackRevision(trackRevision) ||
            seekRevision != _seekRevision) {
          return;
        }

        // Serialize video seek with initialize/dispose. Audio stays authoritative.
        _enqueueVideoWork(() async {
          if (!_isCurrentTrackRevision(trackRevision) ||
              seekRevision != _seekRevision) {
            return;
          }
          final controller = _videoController;
          if (controller != null &&
              _isVideoInitialized &&
              identical(controller, _videoController)) {
            await controller.seekTo(pos);
          }
        });
      }),
    );
  }

  Future<void> fetchLyrics(dynamic trackObj) async {
    final revision = ++_lyricsRevision;
    globalLyrics.clear();
    noLrcData = "";
    currentLine = -1;
    lrcLoading = true;
    uiSignal.value++;

    final artistName = trackObj['album']['artist']['name'].toString();
    final trackTitle = trackObj['title'].toString();
    final trackId = trackObj['id'] as int;

    List<LyricLine> parseLrcString(String lrcContent) {
      final parsed = <LyricLine>[];
      final RegExp rx = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');
      for (var lineStr in lrcContent.split('\n')) {
        final matchData = rx.firstMatch(lineStr);
        if (matchData != null) {
          final min = int.parse(matchData.group(1)!);
          final sec = int.parse(matchData.group(2)!);
          final msString = matchData.group(3)!;
          final ms = msString.length == 2
              ? int.parse(msString) * 10
              : int.parse(msString);
          final txt = matchData.group(4)!.trim();

          if (txt.isNotEmpty) {
            parsed.add(
              LyricLine(
                Duration(minutes: min, seconds: sec, milliseconds: ms),
                txt,
                txt,
              ),
            );
          }
        }
      }
      return parsed;
    }

    final localLrc = File('$localPath/track_$trackId.lrc');
    try {
      if (await _hasNonEmptyFile(localLrc)) {
        final fileContent = await localLrc.readAsString();
        _commitLyrics(
          revision: revision,
          trackId: trackId,
          lyrics: parseLrcString(fileContent),
          plainText: fileContent,
        );
        return;
      }
    } catch (error) {
      debugPrint('Local lyrics read failed: $error');
    }
    if (!_isCurrentLyricsRequest(revision, trackId)) return;

    if (trackObj['lyrics'] != null &&
        trackObj['lyrics'].toString().trim().isNotEmpty) {
      final dbLyrics = trackObj['lyrics'].toString();
      _commitLyrics(
        revision: revision,
        trackId: trackId,
        lyrics: parseLrcString(dbLyrics),
        plainText: dbLyrics,
      );
      unawaited(_writeLyricsFile(localLrc, dbLyrics));
      return;
    }

    try {
      final parsedUrl = Uri.parse(
        'https://lrclib.net/api/get?artist_name=${Uri.encodeComponent(artistName)}&track_name=${Uri.encodeComponent(trackTitle)}',
      );
      final res = await http
          .get(parsedUrl)
          .timeout(const Duration(seconds: 15));
      if (!_isCurrentLyricsRequest(revision, trackId)) return;
      if (res.statusCode == HttpStatus.ok) {
        final jsonData = json.decode(utf8.decode(res.bodyBytes));
        final syncedText = jsonData['syncedLyrics'];
        final plainText = jsonData['plainLyrics'];

        if (syncedText != null && syncedText.toString().isNotEmpty) {
          final contents = syncedText.toString();
          _commitLyrics(
            revision: revision,
            trackId: trackId,
            lyrics: parseLrcString(contents),
            plainText: contents,
          );
          unawaited(_writeLyricsFile(localLrc, contents));
          unawaited(_saveLyricsToServer(trackId, contents));
          return;
        } else if (plainText != null && plainText.toString().isNotEmpty) {
          final contents = plainText.toString();
          _commitLyrics(
            revision: revision,
            trackId: trackId,
            lyrics: const <LyricLine>[],
            plainText: contents,
          );
          unawaited(_writeLyricsFile(localLrc, contents));
          unawaited(_saveLyricsToServer(trackId, contents));
          return;
        }
      }
    } catch (e) {
      debugPrint("error $e");
    }

    _commitLyrics(
      revision: revision,
      trackId: trackId,
      lyrics: const <LyricLine>[],
      plainText: '',
    );
  }

  bool _isCurrentLyricsRequest(int revision, int trackId) {
    return !_stateDisposing &&
        revision == _lyricsRevision &&
        activeTrackNotifier.value?['id'] == trackId;
  }

  void _commitLyrics({
    required int revision,
    required int trackId,
    required List<LyricLine> lyrics,
    required String plainText,
  }) {
    if (!_isCurrentLyricsRequest(revision, trackId)) return;
    globalLyrics
      ..clear()
      ..addAll(lyrics);
    noLrcData = lyrics.isEmpty ? plainText : '';
    lrcLoading = false;
    uiSignal.value++;
    updateRPC(force: true);
  }

  Future<void> _writeLyricsFile(File file, String contents) async {
    try {
      await atomicFileStore.writeString(file, contents);
    } catch (error) {
      debugPrint('Lyrics cache write failed: $error');
    }
  }

  Future<void> _saveLyricsToServer(int trackId, String lyricsText) async {
    try {
      final url = configuredServerUri('/api/tracks/$trackId/update_lyrics/');
      final res = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'lyrics': lyricsText}),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        debugPrint('Lyrics updated on server for track $trackId');

        // Update local cachedTracks in memory
        for (var track in cachedTracks) {
          if (track['id'] == trackId) {
            track['lyrics'] = lyricsText;
            break;
          }
        }
        // Also update offline_tracks.json
        await _persistOfflineTracks();
      } else {
        debugPrint('Failed to update lyrics on server: ${res.body}');
      }
    } catch (e) {
      debugPrint('Error updating lyrics on server: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Discord RPC
  // ═══════════════════════════════════════════════════════════════════════════

  final Map<int, String> _publicCoverCache = {};
  final Map<int, Future<String?>> _publicCoverRequests = {};
  final Map<int, DateTime> _publicCoverMisses = {};
  static const Duration _publicCoverMissTtl = Duration(minutes: 30);

  String _transliterate(String input) {
    const rus = [
      'а',
      'б',
      'в',
      'г',
      'д',
      'е',
      'ё',
      'ж',
      'з',
      'и',
      'й',
      'к',
      'л',
      'м',
      'н',
      'о',
      'п',
      'р',
      'с',
      'т',
      'у',
      'ф',
      'х',
      'ц',
      'ч',
      'ш',
      'щ',
      'ъ',
      'ы',
      'ь',
      'э',
      'ю',
      'я',
    ];
    const eng = [
      'a',
      'b',
      'v',
      'g',
      'd',
      'e',
      'e',
      'zh',
      'z',
      'i',
      'y',
      'k',
      'l',
      'm',
      'n',
      'o',
      'p',
      'r',
      's',
      't',
      'u',
      'f',
      'h',
      'ts',
      'ch',
      'sh',
      'sh',
      '',
      'y',
      '',
      'e',
      'yu',
      'ya',
    ];

    String result = input.toLowerCase();
    for (int i = 0; i < rus.length; i++) {
      result = result.replaceAll(rus[i], eng[i]);
    }
    return result;
  }

  bool _isArtistMatch(String originalArtist, String resultArtist) {
    final cleanOriginal = originalArtist.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9а-яё]'),
      '',
    );
    final cleanResult = resultArtist.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9а-яё]'),
      '',
    );

    if (cleanOriginal.isEmpty || cleanResult.isEmpty) return false;

    if (cleanOriginal.contains(cleanResult) ||
        cleanResult.contains(cleanOriginal)) {
      return true;
    }

    final translitOriginal = _transliterate(cleanOriginal);
    final translitResult = _transliterate(cleanResult);
    if (translitOriginal.contains(translitResult) ||
        translitResult.contains(translitOriginal)) {
      return true;
    }

    return false;
  }

  Future<String?> _getPublicCoverUrl(dynamic trackData) async {
    final id = trackData['id'] as int;
    final cached = _publicCoverCache[id];
    if (cached != null) return cached;

    final now = DateTime.now();
    final missedAt = _publicCoverMisses[id];
    if (missedAt != null && now.difference(missedAt) < _publicCoverMissTtl) {
      return null;
    }
    _publicCoverMisses.remove(id);

    final inFlight = _publicCoverRequests[id];
    if (inFlight != null) return inFlight;

    final request = _fetchPublicCoverUrl(trackData);
    _publicCoverRequests[id] = request;
    try {
      final result = await request;
      if (result == null) {
        _publicCoverMisses[id] = DateTime.now();
      } else {
        _publicCoverMisses.remove(id);
      }
      return result;
    } finally {
      if (identical(_publicCoverRequests[id], request)) {
        _publicCoverRequests.remove(id);
      }
    }
  }

  Future<String?> _fetchPublicCoverUrl(dynamic trackData) async {
    final id = trackData['id'] as int;

    final title = trackData['title']?.toString() ?? '';
    final artist = trackData['album']?['artist']?['name']?.toString() ?? '';
    if (title.isEmpty) return null;

    // 1. Try iTunes Search API (extremely fast, clean square covers)
    try {
      final itunesUrl =
          'https://itunes.apple.com/search?term=${Uri.encodeComponent('$artist $title')}&entity=song&limit=1';
      final res = await http
          .get(Uri.parse(itunesUrl))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final results = data['results'] as List<dynamic>?;
        if (results != null && results.isNotEmpty) {
          final first = results[0];
          final resArtist = first['artistName']?.toString() ?? '';
          if (_isArtistMatch(artist, resArtist)) {
            String? cover = first['artworkUrl100']?.toString();
            if (cover != null && cover.isNotEmpty) {
              // Convert to higher resolution
              cover = cover.replaceAll('100x100bb.jpg', '600x600bb.jpg');
              _publicCoverCache[id] = cover;
              return cover;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error in iTunes search: $e');
    }

    // 2. Try Last.fm track.getInfo to get exact album cover
    try {
      final infoRes = await http
          .get(
            Uri.parse(
              'https://ws.audioscrobbler.com/2.0/?method=track.getInfo&artist=${Uri.encodeComponent(artist)}&track=${Uri.encodeComponent(title)}&api_key=b25b959554ed76058ac220b7b2e0a026&format=json',
            ),
          )
          .timeout(const Duration(seconds: 3));

      if (infoRes.statusCode == 200) {
        final data = json.decode(infoRes.body);
        final track = data['track'];
        if (track != null) {
          final album = track['album'];
          if (album != null) {
            final images = album['image'] as List<dynamic>?;
            if (images != null && images.isNotEmpty) {
              String? coverUrl;
              for (var img in images) {
                if (img['size'] == 'extralarge') {
                  coverUrl = img['#text']?.toString();
                }
              }
              coverUrl ??= images.last['#text']?.toString();
              if (coverUrl != null &&
                  coverUrl.isNotEmpty &&
                  !coverUrl.contains('2a96cbd8b46e442fc41c2b86b821562f') &&
                  !coverUrl.contains('182879f0815c4de88b3f2f24c0843114') &&
                  !coverUrl.contains('noimage')) {
                _publicCoverCache[id] = coverUrl;
                return coverUrl;
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error in track.getInfo: $e');
    }

    // 3. Try Last.fm track.search as a fallback
    try {
      final searchRes = await http
          .get(
            Uri.parse(
              'https://ws.audioscrobbler.com/2.0/?method=track.search&artist=${Uri.encodeComponent(artist)}&track=${Uri.encodeComponent(title)}&api_key=b25b959554ed76058ac220b7b2e0a026&format=json',
            ),
          )
          .timeout(const Duration(seconds: 3));

      if (searchRes.statusCode == 200) {
        final data = json.decode(searchRes.body);
        final results = data['results'];
        if (results != null) {
          final trackmatches = results['trackmatches'];
          if (trackmatches != null) {
            final trackList = trackmatches['track'] as List<dynamic>;
            if (trackList.isNotEmpty) {
              final firstTrack = trackList[0];
              final resultArtist = firstTrack['artist']?.toString() ?? '';

              if (_isArtistMatch(artist, resultArtist)) {
                final images = firstTrack['image'] as List<dynamic>;
                if (images.isNotEmpty) {
                  String? coverUrl;
                  for (var img in images) {
                    if (img['size'] == 'extralarge') {
                      coverUrl = img['#text']?.toString();
                    }
                  }
                  coverUrl ??= images.last['#text']?.toString();
                  if (coverUrl != null &&
                      coverUrl.isNotEmpty &&
                      !coverUrl.contains('2a96cbd8b46e442fc41c2b86b821562f') &&
                      !coverUrl.contains('182879f0815c4de88b3f2f24c0843114') &&
                      !coverUrl.contains('noimage')) {
                    _publicCoverCache[id] = coverUrl;
                    return coverUrl;
                  }
                }
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error fetching public cover from Last.fm: $e');
    }

    return null;
  }

  void updateRPC({bool force = false}) {
    if (PerformanceFrameMonitor.enabled || !isDesktop || playingQueue.isEmpty) {
      return;
    }

    Future<void> sendToDiscord() async {
      lastRpcTime = DateTime.now();
      final trackData = playingQueue[playingIndex];
      final trackId = trackData['id'] as int;
      final title = trackData['title'];
      final art = trackData['album']['artist']['name'];

      String coverUrl = trackData['album']?['cover']?.toString() ?? '';
      if (coverUrl.contains('192.168.') ||
          coverUrl.contains('localhost') ||
          coverUrl.contains('127.0.0.1')) {
        final publicUrl = await _getPublicCoverUrl(trackData);
        if (playingQueue.isEmpty ||
            playingIndex >= playingQueue.length ||
            playingQueue[playingIndex]['id'] != trackId) {
          return;
        }
        if (publicUrl != null) {
          coverUrl = publicUrl;
        }
      }

      final dur = trackData['duration'];
      int? durationMs;
      if (dur != null && dur is num && dur.toInt() > 0) {
        durationMs = dur.toInt() * 1000;
      }

      final largeImg =
          (coverUrl.startsWith('http') &&
              !coverUrl.contains('192.168.') &&
              !coverUrl.contains('localhost') &&
              !coverUrl.contains('127.0.0.1'))
          ? coverUrl
          : 'https://cdn.discordapp.com/app-icons/1480246072042590219/36573ffd3ca304580ed8968517090b0e.png';

      if (isPlaying) {
        String p1 = '🎵 $title — $art';
        String p2 = '🎧 Слушает музыку';

        if (globalLyrics.isNotEmpty) {
          if (currentLine >= 0 && currentLine < globalLyrics.length) {
            p2 = '🎤 ${globalLyrics[currentLine].txt}';
          } else if (currentLine == -1) {
            p2 = '🎶 Вступление...';
          }
        }

        await _setDiscordActivity(
          RPCActivity(
            details: p1,
            state: p2,
            activityType: ActivityType.listening,
            assets: RPCAssets(largeImage: largeImg),
            timestamps: discordStart != null
                ? RPCTimestamps(
                    start: discordStart!,
                    end: durationMs != null
                        ? (discordStart! + durationMs)
                        : null,
                  )
                : null,
            buttons: [
              const RPCButton(
                label: "GitHub",
                url: "https://github.com/cursedworld/ShikiMusic",
              ),
            ],
          ),
        );
      } else {
        await _setDiscordActivity(
          RPCActivity(
            details: '⏸ На паузе',
            state: '$title — $art',
            activityType: ActivityType.listening,
            assets: RPCAssets(largeImage: largeImg),
            buttons: [
              const RPCButton(
                label: "GitHub",
                url: "https://github.com/cursedworld/ShikiMusic",
              ),
            ],
          ),
        );
      }
    }

    if (force) {
      rpcThrottleTimer?.cancel();
      sendToDiscord();
      return;
    }

    final now = DateTime.now();
    if (lastRpcTime == null ||
        now.difference(lastRpcTime!) >= const Duration(milliseconds: 1500)) {
      rpcThrottleTimer?.cancel();
      sendToDiscord();
    } else {
      if (rpcThrottleTimer?.isActive ?? false) return;
      final wait =
          const Duration(milliseconds: 1500) - now.difference(lastRpcTime!);
      rpcThrottleTimer = Timer(wait, sendToDiscord);
    }
  }

  void showLyricsScreen() {
    if (playingQueue.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PresentationOverlay(onSeekRequested: seekTo),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Dialogs
  // ═══════════════════════════════════════════════════════════════════════════

  void showPlaylistContextMenu(
    BuildContext context,
    Offset position,
    int index,
  ) {
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      color: const Color(0xFF1A0000),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Colors.white10),
      ),
      items: [
        const PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
              SizedBox(width: 10),
              Text(
                'Удалить плейлист',
                style: TextStyle(
                  color: Colors.redAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == 'delete') {
        setState(() {
          if (navId == index + 3) {
            navId = 0;
          } else if (navId > index + 3) {
            navId--;
          }
          myPlaylists.removeAt(index);
          savePlaylists();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Плейлист удален'),
              backgroundColor: Colors.orange,
            ),
          );
        });
      }
    });
  }

  void showCreatePlaylistDialog() {
    String pName = "";
    String pImg = "";
    bool useLocalImage = false;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1A0000),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
                side: const BorderSide(color: Colors.white10),
              ),
              title: Text(
                tr('create_playlist'),
                style: const TextStyle(color: Colors.white),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: "Название",
                      hintStyle: TextStyle(color: Colors.white54),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.redAccent),
                      ),
                    ),
                    onChanged: (v) => pName = v,
                  ),
                  const SizedBox(height: 25),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        FilePickerResult? result = await FilePicker.platform
                            .pickFiles(type: FileType.image);
                        if (result != null &&
                            result.files.single.path != null) {
                          setStateDialog(() {
                            pImg = result.files.single.path!;
                            useLocalImage = true;
                          });
                        }
                      },
                      icon: const Icon(Icons.folder_open),
                      label: Text(
                        useLocalImage
                            ? "Картинка выбрана ✓"
                            : "Выбрать картинку",
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: useLocalImage
                            ? Colors.green.withValues(alpha: 0.5)
                            : Colors.white10,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        elevation: 0,
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text(
                    "Отмена",
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    if (pName.isNotEmpty) {
                      setState(() {
                        myPlaylists.add({
                          "id": DateTime.now().millisecondsSinceEpoch,
                          "name": pName,
                          "image": pImg,
                          "tracks": [],
                        });
                      });
                      savePlaylists();
                      Navigator.pop(ctx);
                    }
                  },
                  child: const Text(
                    "Создать",
                    style: TextStyle(
                      color: Colors.redAccent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  UI Builders
  // ═══════════════════════════════════════════════════════════════════════════

  Widget buildDownloadButton() {
    if (playingQueue.isEmpty) return const SizedBox(width: 24);
    final trackId = playingQueue[playingIndex]['id'];
    final isDownloaded = isTrackDownloadComplete(playingQueue[playingIndex]);
    final isDownloading = downloadQueue.contains(trackId);

    if (isDownloading) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(color: Colors.white54, strokeWidth: 2),
      );
    } else if (isDownloaded) {
      return const Icon(
        Icons.download_done,
        color: Colors.greenAccent,
        size: 24,
      );
    } else {
      return IconButton(
        icon: const Icon(Icons.download, color: Colors.white54, size: 24),
        onPressed: () => downloadMediaFile(playingQueue[playingIndex]),
      );
    }
  }

  Widget buildSearchField({bool isMobile = false}) {
    return Container(
      width: isMobile ? double.infinity : 250,
      height: 40,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: TextField(
        controller: searchInput,
        focusNode: searchFocusNode,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: tr('search_hint_senpai'),
          hintStyle: const TextStyle(color: Colors.white54),
          prefixIcon: const Icon(Icons.search, color: Colors.white54),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 10,
          ),
          suffixIcon: searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(
                    Icons.clear,
                    color: Colors.white54,
                    size: 18,
                  ),
                  onPressed: () {
                    searchInput.clear();
                    setState(() => searchQuery = "");
                  },
                )
              : null,
        ),
        onChanged: (val) => setState(() => searchQuery = val),
      ),
    );
  }

  Widget buildSidebar({bool isMobile = false}) {
    if (isMobile) return _buildMobileSidebar();
    return _buildDesktopSidebar();
  }

  Widget _buildDesktopSidebar() {
    return Container(
      width: 70,
      color: Colors.black.withValues(alpha: 0.4),
      child: Column(
        children: [
          const SizedBox(height: 30),
          Icon(Icons.graphic_eq, color: accentColorNotifier.value, size: 30),
          const SizedBox(height: 40),
          IconButton(
            icon: Icon(
              Icons.library_music,
              color: navId == 0 ? Colors.white : Colors.white54,
            ),
            tooltip: tr('sidebar_home'),
            onPressed: () => setState(() => navId = 0),
          ),
          const SizedBox(height: 20),
          IconButton(
            icon: Icon(
              Icons.favorite,
              color: navId == 1 ? accentColorNotifier.value : Colors.white54,
            ),
            tooltip: tr('sidebar_favorites'),
            onPressed: () => setState(() => navId = 1),
          ),
          const SizedBox(height: 20),
          IconButton(
            icon: Icon(
              Icons.offline_pin,
              color: navId == 2 ? Colors.white : Colors.white54,
            ),
            tooltip: tr('sidebar_downloaded'),
            onPressed: () => setState(() => navId = 2),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 15),
            child: Divider(color: Colors.white24, indent: 15, endIndent: 15),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: myPlaylists.length,
              itemBuilder: (ctx, i) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 15),
                  child: Tooltip(
                    message: myPlaylists[i]['name'],
                    child: GestureDetector(
                      onTap: () => setState(() => navId = i + 3),
                      onSecondaryTapDown: (details) => showPlaylistContextMenu(
                        context,
                        details.globalPosition,
                        i,
                      ),
                      onLongPressStart: (details) => showPlaylistContextMenu(
                        context,
                        details.globalPosition,
                        i,
                      ),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: CircleAvatar(
                          backgroundColor: Colors.white10,
                          backgroundImage:
                              myPlaylists[i]['image']?.isNotEmpty == true
                              ? getPlaylistImage(myPlaylists[i]['image'])
                              : null,
                          radius: navId == i + 3 ? 18 : 14,
                          child: myPlaylists[i]['image']?.isNotEmpty != true
                              ? const Icon(
                                  Icons.music_note,
                                  color: Colors.white54,
                                  size: 16,
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add_box, color: Colors.white54),
            tooltip: tr('create_playlist'),
            onPressed: showCreatePlaylistDialog,
          ),
          const SizedBox(height: 10),
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white54),
            tooltip: tr('settings'),
            onPressed: _openSettings,
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _buildMobileSidebar() {
    final accent = accentColorNotifier.value;
    return Container(
      color: Colors.black.withValues(alpha: 0.95),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
            child: Row(
              children: [
                Icon(Icons.graphic_eq, color: accent, size: 28),
                const SizedBox(width: 10),
                const Text(
                  'ShikiMusic',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          // ── Navigation ──
          _mobileNavTile(Icons.library_music, tr('sidebar_home'), 0, accent),
          _mobileNavTile(Icons.favorite, tr('sidebar_favorites'), 1, accent),
          _mobileNavTile(
            Icons.offline_pin,
            tr('sidebar_downloaded'),
            2,
            accent,
          ),
          if (myPlaylists.isNotEmpty) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                tr('playlists'),
                style: TextStyle(
                  color: Colors.white24,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ],
          // ── Playlists ──
          Expanded(
            child: ListView.builder(
              physics: const BouncingScrollPhysics(),
              itemCount: myPlaylists.length,
              itemBuilder: (ctx, i) {
                final pl = myPlaylists[i];
                final plTracks = cachedTracks
                    .where((t) => (pl['tracks'] as List).contains(t['id']))
                    .toList();
                final isActive = navId == i + 3;
                return ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                  leading: CircleAvatar(
                    backgroundColor: Colors.white10,
                    backgroundImage: pl['image']?.isNotEmpty == true
                        ? getPlaylistImage(pl['image'])
                        : null,
                    radius: 16,
                    child: pl['image']?.isNotEmpty != true
                        ? const Icon(
                            Icons.music_note,
                            color: Colors.white54,
                            size: 14,
                          )
                        : null,
                  ),
                  title: Text(
                    pl['name'],
                    style: TextStyle(
                      color: isActive ? accent : Colors.white,
                      fontWeight: isActive
                          ? FontWeight.bold
                          : FontWeight.normal,
                      fontSize: 14,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${plTracks.length} ${_pluralTracks(plTracks.length)}',
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                  onTap: () {
                    setState(() => navId = i + 3);
                    Navigator.pop(context);
                  },
                  onLongPress: () {
                    final RenderBox? box =
                        context.findRenderObject() as RenderBox?;
                    if (box != null) {
                      showPlaylistContextMenu(
                        context,
                        box.localToGlobal(Offset.zero),
                        i,
                      );
                    }
                  },
                );
              },
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          // ── Bottom actions ──
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: Icon(Icons.add_box, color: accent, size: 22),
            title: Text(
              tr('create_playlist'),
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            onTap: () {
              Navigator.pop(context);
              showCreatePlaylistDialog();
            },
          ),
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: const Icon(
              Icons.settings,
              color: Colors.white54,
              size: 22,
            ),
            title: Text(
              tr('settings'),
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            onTap: () {
              Navigator.pop(context);
              _openSettings();
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _mobileNavTile(IconData icon, String label, int id, Color accent) {
    final isActive = navId == id;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      leading: Icon(icon, color: isActive ? accent : Colors.white54, size: 22),
      title: Text(
        label,
        style: TextStyle(
          color: isActive ? Colors.white : Colors.white70,
          fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
          fontSize: 15,
        ),
      ),
      onTap: () {
        setState(() => navId = id);
        Navigator.pop(context);
      },
    );
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsScreen(onClearCache: clearAllCache),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  // ── Mobile mini-player ───────────────────────────────────────────────────

  Widget buildMobileMiniPlayer() {
    return SafeArea(
      top: false,
      child: GestureDetector(
        onTap: showLyricsScreen,
        // Swipe left → next, swipe right → prev
        onHorizontalDragEnd: (details) {
          if (details.primaryVelocity != null) {
            if (details.primaryVelocity! < -300) nextTrack();
            if (details.primaryVelocity! > 300) prevTrack();
          }
        },
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xE6000000),
            border: const Border(top: BorderSide(color: Colors.white10)),
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  // Cover art
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image(
                      image: getPictureProvider(playingQueue[playingIndex]),
                      width: 52,
                      height: 52,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 14),
                  // Title + Artist
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          playingQueue[playingIndex]['title'],
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          playingQueue[playingIndex]['album']['artist']['name'],
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  // Favorite
                  IconButton(
                    icon: Icon(
                      favs.contains(playingQueue[playingIndex]['id'])
                          ? Icons.favorite
                          : Icons.favorite_border,
                      color: favs.contains(playingQueue[playingIndex]['id'])
                          ? Colors.redAccent
                          : Colors.white38,
                      size: 22,
                    ),
                    onPressed: () =>
                        toggleFavorite(playingQueue[playingIndex]['id']),
                    visualDensity: VisualDensity.compact,
                  ),
                  // Skip prev
                  IconButton(
                    icon: const Icon(
                      Icons.skip_previous_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                    onPressed: prevTrack,
                    visualDensity: VisualDensity.compact,
                  ),
                  // Play / pause
                  IconButton(
                    icon: Icon(
                      isPlaying
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_fill,
                      color: Colors.white,
                      size: 40,
                    ),
                    onPressed: pauseTrack,
                    visualDensity: VisualDensity.compact,
                  ),
                  // Skip next
                  IconButton(
                    icon: const Icon(
                      Icons.skip_next_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                    onPressed: nextTrack,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              // Thin progress bar
              ValueListenableBuilder<Duration>(
                valueListenable: currentPositionNotifier,
                builder: (context, currPos, child) {
                  return ValueListenableBuilder<Duration>(
                    valueListenable: fullDurationNotifier,
                    builder: (context, fullDur, child) {
                      final maxVal = fullDur.inSeconds.toDouble() > 0
                          ? fullDur.inSeconds.toDouble()
                          : 1.0;
                      return SizedBox(
                        height: 16,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 2.0,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 0.0,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 0.0,
                            ),
                            trackShape: const RectangularSliderTrackShape(),
                          ),
                          child: Slider(
                            value: currPos.inSeconds.toDouble().clamp(
                              0.0,
                              maxVal,
                            ),
                            min: 0.0,
                            max: maxVal,
                            onChanged: (v) =>
                                seekTo(Duration(seconds: v.toInt())),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Desktop player panel ─────────────────────────────────────────────────

  Widget buildDesktopPlayer() {
    return Container(
      width: 360,
      color: Colors.black.withValues(alpha: 0.6),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: playingQueue.isEmpty
          ? const SizedBox()
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // ── Vinyl-style spinning cover art ──
                // Tap to stop/resume, double-tap to reset to 0°.
                GestureDetector(
                  onTap: vinylRotationNotifier.value
                      ? () {
                          setState(() {
                            if (_vinylController.isAnimating) {
                              _vinylController.stop();
                              _vinylUserStopped = true;
                            } else if (isPlaying) {
                              _vinylController.repeat();
                              _vinylUserStopped = false;
                            }
                          });
                        }
                      : null,
                  onDoubleTap: vinylRotationNotifier.value
                      ? () {
                          _vinylController.stop();
                          _vinylController.value = 0.0;
                          _vinylUserStopped = true;
                          setState(() {});
                        }
                      : null,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: RepaintBoundary(
                      child: RotationTransition(
                        turns: _vinylController,
                        child: Container(
                          width: 240,
                          height: 240,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.5),
                                blurRadius: 20,
                                offset: const Offset(0, 10),
                              ),
                            ],
                            border: Border.all(color: Colors.white12, width: 3),
                          ),
                          child: ClipOval(
                            child:
                                _isVideoInitialized &&
                                    _videoController != null &&
                                    playVideoClipNotifier.value
                                ? SizedBox.expand(
                                    child: FittedBox(
                                      fit: BoxFit.cover,
                                      child: SizedBox(
                                        width:
                                            _videoController!.value.size.width,
                                        height:
                                            _videoController!.value.size.height,
                                        child: VideoPlayer(_videoController!),
                                      ),
                                    ),
                                  )
                                : Image(
                                    image: getPictureProvider(
                                      playingQueue[playingIndex],
                                    ),
                                    fit: BoxFit.cover,
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 30),
                Text(
                  playingQueue[playingIndex]['title'],
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 5),
                Text(
                  playingQueue[playingIndex]['album']['artist']['name'],
                  style: const TextStyle(fontSize: 16, color: Colors.white54),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          if (_isMuted) {
                            _isMuted = false;
                            volume = _savedVolume > 0 ? _savedVolume : 0.5;
                          } else {
                            _savedVolume = volume;
                            _isMuted = true;
                            volume = 0;
                          }
                        });
                        audioPlayer.setVolume(volume);
                        _saveState();
                      },
                      child: Icon(
                        _isMuted || volume == 0
                            ? Icons.volume_off
                            : volume < 0.5
                            ? Icons.volume_down
                            : Icons.volume_up,
                        color: _isMuted ? Colors.redAccent : Colors.white54,
                        size: 20,
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        value: volume,
                        min: 0.0,
                        max: 1.0,
                        activeColor: Colors.white54,
                        thumbColor: Colors.white,
                        onChanged: (v) {
                          setState(() {
                            volume = v;
                            _isMuted = v == 0;
                          });
                          audioPlayer.setVolume(v);
                        },
                        onChangeEnd: (v) => _saveState(),
                      ),
                    ),
                  ],
                ),
                ValueListenableBuilder<Duration>(
                  valueListenable: currentPositionNotifier,
                  builder: (context, currPos, child) {
                    return ValueListenableBuilder<Duration>(
                      valueListenable: fullDurationNotifier,
                      builder: (context, fullDur, child) {
                        return Column(
                          children: [
                            Slider(
                              value: currPos.inSeconds.toDouble().clamp(
                                0.0,
                                fullDur.inSeconds.toDouble() > 0
                                    ? fullDur.inSeconds.toDouble()
                                    : 1.0,
                              ),
                              min: 0.0,
                              max: fullDur.inSeconds.toDouble() > 0
                                  ? fullDur.inSeconds.toDouble()
                                  : 1.0,
                              onChanged: (v) =>
                                  seekTo(Duration(seconds: v.toInt())),
                              onChangeEnd: (v) => _saveState(),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10.0,
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    formatDuration(currPos),
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 12,
                                    ),
                                  ),
                                  Text(
                                    formatDuration(fullDur),
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
                const SizedBox(height: 10),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      buildDownloadButton(),
                      const SizedBox(width: 10),
                      IconButton(
                        icon: const Icon(
                          Icons.skip_previous,
                          color: Colors.white,
                          size: 36,
                        ),
                        onPressed: () => prevTrack(),
                      ),
                      const SizedBox(width: 10),
                      IconButton(
                        iconSize: 64,
                        color: Colors.white,
                        icon: Icon(
                          isPlaying
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_fill,
                        ),
                        onPressed: pauseTrack,
                      ),
                      const SizedBox(width: 10),
                      IconButton(
                        icon: const Icon(
                          Icons.skip_next,
                          color: Colors.white,
                          size: 36,
                        ),
                        onPressed: () => nextTrack(),
                      ),
                      const SizedBox(width: 10),
                      IconButton(
                        icon: const Icon(
                          Icons.mic,
                          color: Colors.white54,
                          size: 24,
                        ),
                        onPressed: showLyricsScreen,
                      ),
                      const SizedBox(width: 5),
                      // Shuffle button
                      IconButton(
                        icon: Icon(
                          Icons.shuffle,
                          color: isShuffled ? Colors.redAccent : Colors.white54,
                          size: 24,
                        ),
                        tooltip: isShuffled
                            ? 'Выключить перемешивание'
                            : 'Перемешать',
                        onPressed: toggleShuffle,
                      ),
                      const SizedBox(width: 5),
                      IconButton(
                        icon: Icon(
                          loopMode == LoopMode.one
                              ? Icons.repeat_one
                              : Icons.repeat,
                          color: loopMode != LoopMode.off
                              ? Colors.redAccent
                              : Colors.white54,
                          size: 24,
                        ),
                        onPressed: toggleLoopMode,
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Build
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    bool isMobile = MediaQuery.of(context).size.width < 800;

    List<dynamic> finalListToRender;
    String headText = "";

    if (navId == 0) {
      finalListToRender = cachedTracks;
      headText = tr('nav_home');
    } else if (navId == 1) {
      finalListToRender = cachedTracks
          .where((t) => favs.contains(t['id']))
          .toList();
      headText = tr('nav_favorites');
    } else if (navId == 2) {
      finalListToRender = cachedTracks
          .where((t) => isTrackLocal(t['id']))
          .toList();
      headText = tr('nav_downloaded');
    } else {
      int pIndex = navId - 3;
      if (pIndex >= 0 && pIndex < myPlaylists.length) {
        List<dynamic> pTracks = myPlaylists[pIndex]['tracks'];
        finalListToRender = cachedTracks
            .where((t) => pTracks.contains(t['id']))
            .toList();
        headText = myPlaylists[pIndex]['name'];
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => navId = 0);
        });
        finalListToRender = cachedTracks;
        headText = tr('nav_home');
      }
    }

    List<dynamic> finalList = finalListToRender.where((n) {
      if (searchQuery.isEmpty) return true;
      final queryLower = searchQuery.toLowerCase();
      final nodeTitle = n['title'].toString().toLowerCase();
      final nodeArtist = n['album']['artist']['name'].toString().toLowerCase();
      final nodeAlbum = n['album']['title'].toString().toLowerCase();
      return nodeTitle.contains(queryLower) ||
          nodeArtist.contains(queryLower) ||
          nodeAlbum.contains(queryLower);
    }).toList();

    Widget mainContent = Expanded(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: isMobile ? 15.0 : 30.0,
          vertical: 20.0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            isMobile
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        headText,
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      if (finalList.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            _getPlaylistStats(finalList),
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      const SizedBox(height: 15),
                      if (finalList.isNotEmpty)
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            icon: const Icon(
                              Icons.download_for_offline,
                              size: 18,
                            ),
                            label: Text(tr('download_all')),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white10,
                              foregroundColor: Colors.white,
                              elevation: 0,
                            ),
                            onPressed: () => downloadAllTracks(finalList),
                          ),
                        ),
                      const SizedBox(height: 10),
                      buildSearchField(isMobile: true),
                    ],
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            headText,
                            style: const TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          if (finalList.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                _getPlaylistStats(finalList),
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                        ],
                      ),
                      Row(
                        children: [
                          if (finalList.isNotEmpty)
                            ElevatedButton.icon(
                              icon: const Icon(
                                Icons.download_for_offline,
                                size: 18,
                              ),
                              label: Text(tr('download_all')),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white10,
                                foregroundColor: Colors.white,
                                elevation: 0,
                              ),
                              onPressed: () => downloadAllTracks(finalList),
                            ),
                          const SizedBox(width: 15),
                          buildSearchField(),
                        ],
                      ),
                    ],
                  ),
            const SizedBox(height: 20),
            Expanded(
              child: isLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: Colors.redAccent),
                    )
                  : finalList.isEmpty
                  ? Center(
                      child: isSearchLoading
                          ? const Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                CircularProgressIndicator(
                                  color: Colors.redAccent,
                                ),
                                SizedBox(height: 20),
                                Text(
                                  "Ожидайте скачки секунд 5-10 если песня найдется в интернете",
                                  style: TextStyle(
                                    color: Colors.white54,
                                    fontSize: 16,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  searchQuery.isNotEmpty
                                      ? "Нет совпадений по '$searchQuery'"
                                      : navId == 1
                                      ? "Поставь сердечко на любимую песенку и она окажется тут!"
                                      : navId >= 3
                                      ? "Плейлист пока пуст. Добавь сюда треки через плюсик!"
                                      : "Нет данных",
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 16,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                if (searchQuery.isNotEmpty) ...[
                                  const SizedBox(height: 20),
                                  ElevatedButton.icon(
                                    onPressed: downloadFromNetwork,
                                    icon: const Icon(Icons.cloud_sync),
                                    label: const Text("Поискать в интернете?"),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.redAccent,
                                      foregroundColor: Colors.white,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                    )
                  // ── Track list with smooth scroll ──
                  : ListView.builder(
                      physics: const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(),
                      ),
                      cacheExtent: 500,
                      itemCount: finalList.length,
                      itemBuilder: (ctx, idx) {
                        final currentObject = finalList[idx];
                        final trackId = currentObject['id'];
                        final isActiveTrack =
                            (playingQueue.isNotEmpty &&
                                playingIndex < playingQueue.length)
                            ? currentObject['id'] ==
                                  playingQueue[playingIndex]['id']
                            : false;
                        final isDownloaded = isTrackDownloadComplete(
                          currentObject,
                        );
                        final isDownloading = downloadQueue.contains(trackId);
                        final isFavorited = favs.contains(trackId);

                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          decoration: BoxDecoration(
                            color: isActiveTrack
                                ? Colors.white.withValues(alpha: 0.1)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image(
                                image: getPictureProvider(currentObject),
                                width: 50,
                                height: 50,
                                fit: BoxFit.cover,
                              ),
                            ),
                            title: Text(
                              currentObject['title'],
                              style: TextStyle(
                                color: isActiveTrack
                                    ? Colors.redAccent
                                    : Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              currentObject['album']['artist']['name'],
                              style: const TextStyle(color: Colors.white54),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (navId >= 3)
                                    IconButton(
                                      icon: const Icon(
                                        Icons.remove_circle_outline,
                                        color: Colors.white54,
                                      ),
                                      onPressed: () {
                                        setState(() {
                                          myPlaylists[navId - 3]['tracks']
                                              .remove(trackId);
                                          savePlaylists();
                                        });
                                      },
                                    )
                                  else if (myPlaylists.isNotEmpty)
                                    PopupMenuButton<int>(
                                      icon: const Icon(
                                        Icons.add_circle_outline,
                                        color: Colors.white54,
                                      ),
                                      color: const Color(0xFF1A0000),
                                      onSelected: (pId) {
                                        setState(() {
                                          final pl = myPlaylists.firstWhere(
                                            (p) => p['id'] == pId,
                                          );
                                          if (!pl['tracks'].contains(trackId)) {
                                            pl['tracks'].add(trackId);
                                            savePlaylists();
                                          }
                                        });
                                      },
                                      itemBuilder: (ctx) => myPlaylists
                                          .map(
                                            (p) => PopupMenuItem<int>(
                                              value: p['id'],
                                              child: Text(
                                                p['name'],
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ),
                                          )
                                          .toList(),
                                    ),
                                  IconButton(
                                    icon: Icon(
                                      isFavorited
                                          ? Icons.favorite
                                          : Icons.favorite_border,
                                      color: isFavorited
                                          ? Colors.redAccent
                                          : Colors.white54,
                                    ),
                                    onPressed: () => toggleFavorite(trackId),
                                  ),
                                  if (isDownloading)
                                    const SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(
                                        color: Colors.white54,
                                        strokeWidth: 2,
                                      ),
                                    )
                                  else if (isDownloaded)
                                    const Icon(
                                      Icons.download_done,
                                      color: Colors.greenAccent,
                                      size: 24,
                                    )
                                  else
                                    IconButton(
                                      icon: const Icon(
                                        Icons.download,
                                        color: Colors.white54,
                                      ),
                                      onPressed: () =>
                                          downloadMediaFile(currentObject),
                                    ),
                                  const SizedBox(width: 15),
                                  isActiveTrack && isPlaying
                                      ? const Icon(
                                          Icons.graphic_eq,
                                          color: Colors.redAccent,
                                        )
                                      : const Icon(
                                          Icons.play_arrow,
                                          color: Colors.white54,
                                        ),
                                ],
                              ),
                            ),
                            onTap: () => startPlayback(finalList, idx),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );

    return ScrollConfiguration(
      behavior: const _SmoothScrollBehavior(),
      child: Scaffold(
        appBar: isMobile
            ? AppBar(
                backgroundColor: Colors.black,
                title: const Text("ShikiMusic"),
                elevation: 0,
              )
            : null,
        drawer: isMobile
            ? Drawer(
                width: 270,
                backgroundColor: Colors.black,
                child: SafeArea(child: buildSidebar(isMobile: true)),
              )
            : null,
        body: ValueListenableBuilder<String?>(
          valueListenable: customBackgroundNotifier,
          builder: (context, customBg, _) {
            return Container(
              decoration: customBg != null && globalLocalPath.isNotEmpty
                  ? BoxDecoration(
                      image: DecorationImage(
                        image: FileImage(File('$globalLocalPath/$customBg')),
                        fit: BoxFit.cover,
                        colorFilter: ColorFilter.mode(
                          Colors.black.withValues(alpha: 0.65),
                          BlendMode.srcOver,
                        ),
                      ),
                    )
                  : BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: _gradientFromAccent(accentColorNotifier.value),
                      ),
                    ),
              child: isMobile
                  ? Column(
                      children: [
                        mainContent,
                        if (playingQueue.isNotEmpty) buildMobileMiniPlayer(),
                      ],
                    )
                  : Row(
                      children: [
                        buildSidebar(),
                        mainContent,
                        if (playingQueue.isNotEmpty) buildDesktopPlayer(),
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }
}
