import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;
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
import 'package:video_player/video_player.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';
import 'package:crypto/crypto.dart';

import '../app_paths.dart';
import '../async_task_limiter.dart';
import '../atomic_file_store.dart';
import '../cover_processing.dart';
import '../disposable_cache.dart';
import '../discord_artwork.dart';
import '../discord_cover.dart';
import '../discord_status.dart';
import '../download_batch.dart';
import '../globals.dart';
import '../localization.dart';
import '../lrc_parser.dart';
import '../listening_statistics.dart';
import '../statistics_store.dart';
import '../media_file_downloader.dart';
import '../music_import.dart';
import '../clip_retry_gate.dart';
import '../perf/frame_metrics.dart';
import '../playlist_artwork.dart';
import '../playlist_tracks.dart';
import '../player_shortcuts.dart';
import '../safe_file_migration.dart';
import '../server_config.dart';
import '../track_updates.dart';
import '../widgets/track_updates_dialog.dart';
import '../widgets/track_metadata_dialog.dart';
import '../widgets/playlist_crop_dialog.dart';
import 'artist_screen.dart';
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
  bool forceRequested = false;
  bool forceSent = false;
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
        artist: trackArtistLabel(track),
        album: track['album']?['title']?.toString(),
        artworkUri: getArtUri(track)?.toString(),
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
    try {
      return await compute(isSquareCoverFile, file.path);
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
        final jpegBytes = await compute(cropCoverBytes, res.bodyBytes);
        if (jpegBytes != null) {
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
      invalidateTrackCover(track['id'] as int);
      _syncMediaSessionMetadata();
    }
  }

  // ── Player state ─────────────────────────────────────────────────────────
  int dummyVar = 0;
  bool isPremium = true;
  int playCount = 0;
  List<dynamic> cachedTracks = [];
  List<dynamic> cachedArtists = [];
  bool _isSyncingArtists = false;
  bool _isRefreshingArtistPhotos = false;
  final Map<int, Map> _artistPhotoQueue = {};
  final http.Client _artistArtworkClient = http.Client();
  bool _isRefreshingArtwork = false;
  final ValueNotifier<int> _artistLibraryChanges = ValueNotifier<int>(0);
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
  int _discordActivityRevision = 0;
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
  TrackUpdateMonitor? _trackUpdates;
  String _lastUpdateNotice = '';
  bool _updateDialogOpen = false;
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
  String? _videoSourcePath;
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
  StreamSubscription<PlayerState>? _statisticsStateSubscription;
  ListeningStatistics? _statistics;
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
  final Map<int, Future<TrackDownloadResult>> _mediaDownloadTasks = {};
  final Map<int, String> _unavailableVideoSignatures = {};
  final ClipRetryGate _clipRetryGate = ClipRetryGate();
  bool _bulkDownloadActive = false;
  Completer<void>? _bulkDownloadFinished;
  Set<int> favs = {};

  List<Map<String, dynamic>> myPlaylists = [];

  final TextEditingController searchInput = TextEditingController();
  final FocusNode searchFocusNode = FocusNode();
  String searchQuery = "";
  bool isSearchLoading = false;
  String? _albumImportProgress;
  bool _importErrorsOpen = false;

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
    discordShowGitHubButtonNotifier.addListener(_onDiscordSettingChanged);
    discordLyricsStatusNotifier.addListener(_onDiscordSettingChanged);

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
      audioHandler.onSeekStateChanged = (seeking) => _statistics?.setSeeking(seeking);
    }

    _statisticsStateSubscription = audioPlayer.onPlayerStateChanged.listen((state) {
      if (!_stateDisposing) _statistics?.setPlaying(state == PlayerState.playing);
    });
    audioPlayer.setVolume(volume);
    _audioDurationSubscription = audioPlayer.onDurationChanged.listen((d) {
      // Cache track duration for playlist stats
      final sourceTrackId = _audioSourceTrackId;
      if (sourceTrackId != null) {
        trackDurations[sourceTrackId] = d.inSeconds;
      }
      if (_settledTrackRevision == _trackRevision &&
          sourceTrackId == activeTrackNotifier.value?['id']) {
        _statistics?.setDuration(d);
        fullDurationNotifier.value = d;
        _syncMediaSessionMetadata();
      }
    });
    _audioPositionSubscription = audioPlayer.onPositionChanged.listen((p) {
      if (mounted &&
          _settledTrackRevision == _trackRevision &&
          _audioSourceTrackId == activeTrackNotifier.value?['id']) {
        _statistics?.position(p);
        currentPositionNotifier.value = p;
      }
    });

    _audioCompleteSubscription = audioPlayer.onPlayerComplete.listen((event) {
      if (_settledTrackRevision != _trackRevision ||
          _audioSourceTrackId != activeTrackNotifier.value?['id']) {
        return;
      }
      _statistics?.endTrack();
      if (loopMode == LoopMode.one) {
        _playIndex(playingIndex);
      } else {
        nextTrack();
      }
    });

    backgroundPollingTimer = Timer.periodic(
      const Duration(milliseconds: 1000),
      (_) async {
        _statistics?.tick();
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
    unawaited(_statisticsStateSubscription?.cancel());
    unawaited(_statistics?.close().catchError((Object error) {
      debugPrint('Listening statistics close failed: $error');
    }));
    if (isAudioServiceActive) audioHandler.onSeekStateChanged = null;
    _discordArtwork?.dispose();
    _discordCovers?.dispose();
    _artistArtworkClient.close();
    _artistPhotoQueue.clear();
    _trackUpdates?.offers.removeListener(_onTrackUpdates);
    _trackUpdates?.dispose();
    _trackRevision += 1;
    _transportRevision += 1;
    _seekRevision += 1;
    _databaseSyncRevision += 1;
    _videoRevision += 1;
    _lyricsRevision += 1;
    _discordActivityRevision += 1;
    _videoOperation?.cancel();
    _videoOperation = null;
    _videoReleaseTimer?.cancel();
    _videoTrackSwitchTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    vinylRotationNotifier.removeListener(_onVinylRotationChanged);
    discordShowGitHubButtonNotifier.removeListener(_onDiscordSettingChanged);
    discordLyricsStatusNotifier.removeListener(_onDiscordSettingChanged);
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
    _artistLibraryChanges.dispose();

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
    _statistics?.setForeground(state == AppLifecycleState.resumed);
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

  Future<void> _clearDiscordActivity() async {
    if (!_discordConnected) return;
    try {
      await FlutterDiscordRPC.instance.clearActivity();
    } catch (error) {
      debugPrint('Discord RPC clear failed: $error');
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
    String? signature;
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
          signature = _videoAvailabilitySignature(activeTrack as Map);
          if (!_clipRetryGate.canRequest(trackId, signature!)) return null;
          return _requestClipGeneration(
            trackId,
            abortTrigger: operation.whenCanceled,
          );
        },
      );
      if (res == null) return;
      if (res.statusCode != HttpStatus.ok) {
        if (signature != null) {
          _recordClipFailure(trackId, signature!, res);
        }
        return;
      }
      _clipRetryGate.clear(trackId);
      _unavailableVideoSignatures.remove(trackId);

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
        if (signature != null) {
          _clipRetryGate.recordFailure(
            trackId,
            signature!,
            const Duration(minutes: 1),
          );
        }
        debugPrint('Error fetching video clip background: $e');
      }
    }
  }

  Future<http.Response> _postClipGenerationRequest(
    int trackId,
    _VideoOperation operation, {
    bool force = false,
  }) async {
    final request = http.AbortableRequest(
      'POST',
      configuredServerUri('/api/tracks/$trackId/download_clip/'),
      abortTrigger: operation.whenCanceled,
    );
    if (force) {
      request.headers['Content-Type'] = 'application/json';
      request.body = json.encode({'force': true});
    }
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
    bool force = false,
  }) async {
    var shared = _clipGenerationRequests[trackId];
    if (force && shared != null && shared.completed && !shared.forceSent) {
      shared = null;
    }
    if (shared == null) {
      final transportOperation = _VideoOperation();
      final created = _SharedClipGeneration(
        transportOperation: transportOperation,
      );
      created.forceRequested = force;
      created.response = _clipTransportLimiter.run(
        () {
          created.transportStarted = true;
          created.forceSent = created.forceRequested;
          return _postClipGenerationRequest(
            trackId,
            transportOperation,
            force: created.forceSent,
          );
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
    if (force && !shared.transportStarted) shared.forceRequested = true;

    shared.subscribers += 1;
    late http.Response response;
    try {
      if (abortTrigger == null) {
        response = await shared.response;
      } else {
        response = await Future.any<http.Response>([
          shared.response,
          abortTrigger.then<http.Response>(
            (_) => throw const _ClipGenerationCancelledException(),
          ),
        ]);
      }
    } finally {
      shared.subscribers -= 1;
      _releaseClipGenerationIfUnused(trackId, shared);
    }
    if (force && !shared.forceSent && response.statusCode != HttpStatus.ok) {
      shared.completed = true;
      return _requestClipGeneration(
        trackId,
        force: true,
        abortTrigger: abortTrigger,
      );
    }
    return response;
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
        _videoSourcePath == _localVideoFile(request.trackId!).path &&
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
    final localVideoFile = _localVideoFile(trackId);
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
      _videoSourcePath = localVideoFile.path;
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
      final downloadedTrack = cachedTracks
          .where((track) => track is Map && track['id'] == request.trackId)
          .firstOrNull;
      if (downloadedTrack is Map && !_stateDisposing) {
        await _trackUpdates?.registerDownload(downloadedTrack);
      }
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
      try {
        await controller.setVolume(0.0);
      } catch (_) {}
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
    _videoSourcePath = null;
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

  void _onDiscordSettingChanged() {
    updateRPC(force: true);
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

  bool _handleGlobalKeys(KeyEvent event) =>
      handlePlaybackSpace(event, onToggle: pauseTrack);

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
    if (!PerformanceFrameMonitor.enabled) {
      _statistics ??= ListeningStatistics(
        StatisticsStore('$localPath/listening_statistics.sqlite'),
        foreground: WidgetsBinding.instance.lifecycleState == null ||
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      );
    }
    if (isDesktop && !PerformanceFrameMonitor.enabled) {
      _discordCovers = DiscordCoverLookup(
        onResolved: (trackKey) {
          if (!_stateDisposing &&
              playingIndex >= 0 &&
              playingIndex < playingQueue.length &&
              DiscordCoverLookup.trackKey(playingQueue[playingIndex]) ==
                  trackKey) {
            updateRPC();
          }
        },
      );
      _discordArtwork = DiscordAnimatedArtwork(
        cacheFile: File('$localPath/discord_artwork_cache.json'),
        onAvailable: (albumKey) {
          if (!_stateDisposing &&
              playingIndex >= 0 &&
              playingIndex < playingQueue.length &&
              DiscordAnimatedArtwork.albumKey(playingQueue[playingIndex]) ==
                  albumKey) {
            updateRPC();
          }
        },
      );
    }
    if (!PerformanceFrameMonitor.enabled) {
      final monitor = TrackUpdateMonitor(
        directory: appDir,
        tracks: () => cachedTracks,
        onCatalogChanged: _refreshLiveCatalog,
      );
      _trackUpdates = monitor;
      await monitor.load();
      if (_stateDisposing) return;
      monitor.offers.addListener(_onTrackUpdates);
    }
    await readFavorites();
    if (_stateDisposing) return;
    await readPlaylists();
    if (_stateDisposing) return;
    await _loadOfflineTrackCache();
    if (_stateDisposing) return;
    await _loadOfflineArtistsCache();
    if (_stateDisposing) return;
    await _loadState();
    if (_stateDisposing) return;
    unawaited(() async {
      await syncDatabase();
      if (!_stateDisposing) _trackUpdates?.start();
    }());
    unawaited(_syncArtistsCache());
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
              artist: trackArtistLabel(targetTrack),
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
    final freshById = {
      for (final track in tracks)
        if (track is Map) track['id']: track,
    };
    // Metadata only: keep the current source and loaded lyrics untouched.
    for (final track in playingQueue) {
      if (track is! Map) continue;
      final fresh = freshById[track['id']];
      if (fresh == null) continue;
      for (final key in [
        'title',
        'album',
        'artists',
        'duration',
        'audio_file',
        'video_file',
        'lyrics',
        'content_versions',
      ]) {
        track[key] = fresh[key];
      }
    }
    if (mounted) {
      setState(() {
        cachedTracks = tracks;
        isLoading = false;
      });
    } else {
      cachedTracks = tracks;
      isLoading = false;
    }
    _notifyArtistLibraryChanged();
    if (activeTrackNotifier.value != null) {
      uiSignal.value++;
      _syncMediaSessionMetadata();
      updateRPC(force: true);
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

  Future<void> _loadOfflineArtistsCache() async {
    if (localPath.isEmpty) return;
    try {
      final file = File('$localPath/offline_artists.json');
      if (await file.exists()) {
        final decoded = json.decode(await file.readAsString());
        if (decoded is List) {
          if (_stateDisposing) return;
          if (mounted) {
            setState(() {
              cachedArtists = List<dynamic>.from(decoded);
            });
          } else {
            cachedArtists = List<dynamic>.from(decoded);
          }
        }
      }
    } catch (e) {
      debugPrint('Failed to load offline artists cache: $e');
    }
  }

  Future<void> _syncArtistsCache({bool reportFailure = false}) async {
    if (_isSyncingArtists) {
      if (reportFailure) {
        throw StateError('Artist catalog refresh still running');
      }
      return;
    }
    if (localPath.isEmpty || _stateDisposing) return;
    _isSyncingArtists = true;
    try {
      final uri = configuredServerUri('/api/artists/');
      final res = await http.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode == HttpStatus.ok) {
        final decoded = json.decode(utf8.decode(res.bodyBytes));
        if (decoded is List) {
          final artistsList = List<dynamic>.from(decoded);
          final previous = {
            for (final artist in cachedArtists)
              if (artist is Map) artist['id']: artist,
          };
          cachedArtists = artistsList;
          await atomicFileStore.writeString(
            File('$localPath/offline_artists.json'),
            json.encode(artistsList),
          );
          if (mounted && !_stateDisposing) setState(() {});

          // The list already contains name, bio and photo. No eager detail HTTP
          // request per artist; full albums are loaded only when the page opens.
          for (final artist in artistsList) {
            if (_stateDisposing) break;
            if (artist is! Map) continue;
            final artistId = artist['id'];
            if (artistId == null) continue;

            final old = previous[artistId];
            final detailFile = File('$localPath/artist_details_$artistId.json');
            final detailsChanged =
                old == null ||
                [
                  'name',
                  'bio',
                  'photo',
                  'photo_version',
                ].any((key) => old[key] != artist[key]);
            try {
              if (detailsChanged || !await detailFile.exists()) {
                var details = <String, dynamic>{};
                if (await detailFile.exists()) {
                  final oldDetails = json.decode(
                    await detailFile.readAsString(),
                  );
                  if (oldDetails is Map) {
                    details = Map<String, dynamic>.from(oldDetails);
                  }
                }
                await atomicFileStore.writeString(
                  detailFile,
                  json.encode({...details, ...artist}),
                );
              }
            } catch (_) {}

            if (artistId is int &&
                (artist['photo']?.toString().isNotEmpty ?? false)) {
              _artistPhotoQueue[artistId] = artist;
            }
          }
          unawaited(_refreshArtistPhotos());

          if (mounted && !_stateDisposing) setState(() {});
          _notifyArtistLibraryChanged();
        }
      } else if (reportFailure) {
        throw HttpException('Artist catalog: HTTP ${res.statusCode}');
      }
    } catch (e) {
      if (reportFailure) rethrow;
      debugPrint('Artists cache sync notice (working offline): $e');
    } finally {
      _isSyncingArtists = false;
    }
  }

  Future<void> _refreshArtistPhotos() async {
    if (_isRefreshingArtistPhotos || _stateDisposing) return;
    _isRefreshingArtistPhotos = true;
    try {
      // One worker, deduplicated IDs. Optional photos never hold revision polling.
      while (_artistPhotoQueue.isNotEmpty && !_stateDisposing) {
        final id = _artistPhotoQueue.keys.first;
        final artist = _artistPhotoQueue.remove(id)!;
        final url = artist['photo'].toString();
        final version = artist['photo_version']?.toString();
        final suffix =
            version != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(version)
            ? '_$version'
            : '';
        final file = File('$localPath/artist_$id$suffix.jpg');
        try {
          if (await _hasNonEmptyFile(file)) continue;
          final response = await _artistArtworkClient
              .get(Uri.parse(_resolveAbsoluteUrl(url)))
              .timeout(const Duration(seconds: 10));
          if (_stateDisposing) return;
          if (response.statusCode == HttpStatus.ok &&
              response.bodyBytes.length > 500) {
            await atomicFileStore.writeBytes(file, response.bodyBytes);
            invalidateArtistPhoto(id);
            if (mounted && !_stateDisposing) {
              setState(() {});
              _notifyArtistLibraryChanged();
            }
          }
        } catch (_) {
          // Retry on a later catalog/navigation refresh; retain the offline photo.
        }
      }
    } finally {
      _isRefreshingArtistPhotos = false;
    }
  }

  bool _isCurrentDatabaseSync(int revision) =>
      !_stateDisposing && revision == _databaseSyncRevision;

  Future<void> _refreshLiveCatalog() async {
    await syncDatabase(reportFailure: true, refreshArtists: false);
    if (_stateDisposing) return;
    await _syncArtistsCache(reportFailure: true);
    unawaited(_refreshCachedArtwork());
  }

  Future<void> _refreshCachedArtwork() async {
    if (_isRefreshingArtwork || localPath.isEmpty) return;
    _isRefreshingArtwork = true;
    try {
      final snapshot = List<dynamic>.from(cachedTracks);
      for (final track in snapshot) {
        if (_stateDisposing || track is! Map || track['id'] is! int) continue;
        final id = track['id'] as int;
        final name = getVersionedCoverName(track);
        final url = track['album']?['cover']?.toString();
        if (name == null || url == null || url.isEmpty) continue;
        final destination = File('$localPath/$name');
        if (await _hasNonEmptyFile(destination)) continue;
        final old = File('$localPath/cover_${id}_${getCoverFileName(track)}');
        final fallback = File('$localPath/cover_$id.jpg');
        if (!isTrackLocal(id) &&
            activeTrackNotifier.value?['id'] != id &&
            !await old.exists() &&
            !await fallback.exists()) {
          continue;
        }
        try {
          if (await _downloadAndCropCover(
            _resolveAbsoluteUrl(url),
            destination,
          )) {
            invalidateTrackCover(id);
          }
        } catch (error) {
          debugPrint('Artwork refresh deferred: $error');
        }
      }
      if (mounted && !_stateDisposing) {
        setState(() {});
        uiSignal.value++;
        _syncMediaSessionMetadata();
      }
    } finally {
      _isRefreshingArtwork = false;
    }
  }

  Future<void> syncDatabase({
    bool reportFailure = false,
    bool refreshArtists = true,
  }) async {
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
      if (refreshArtists) unawaited(_syncArtistsCache());
    } catch (e) {
      if (!_isCurrentDatabaseSync(revision)) return;
      if (reportFailure) rethrow;
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
    final query = searchQuery.trim();
    if (query.isEmpty || isSearchLoading || _stateDisposing) return;
    if (isSupportedAlbumLink(query)) {
      await _importAlbum(query);
      return;
    }
    setState(() => isSearchLoading = true);
    try {
      final queryEndpoint = configuredServerUri(
        '/api/smart_search/',
        queryParameters: <String, Object?>{'q': query},
      );
      final res = await http
          .get(queryEndpoint)
          .timeout(const Duration(minutes: 5));
      final response = _decodeApiResponse(res);
      if (res.statusCode == HttpStatus.ok) {
        await syncDatabase();
        if (mounted && !_stateDisposing) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(tr('import_complete')),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        throw HttpException(
          response['error']?.toString() ?? 'HTTP ${res.statusCode}',
        );
      }
    } catch (error) {
      if (mounted && !_stateDisposing) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${tr('search_failed')}: ${_downloadError(error)}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted && !_stateDisposing) setState(() => isSearchLoading = false);
    }
  }

  Map<String, dynamic> _decodeApiResponse(http.Response response) {
    try {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on FormatException {
      // A proxy/Django error page is not JSON; preserve its HTTP status.
    }
    throw HttpException('HTTP ${response.statusCode}: invalid server response');
  }

  Future<void> _showAlbumImport() async {
    if (isSearchLoading || !mounted) return;
    final url = await showDialog<String>(
      context: context,
      builder: (_) => AlbumImportDialog(
        initialUrl: isSupportedAlbumLink(searchQuery) ? searchQuery.trim() : '',
      ),
    );
    if (url != null && url.isNotEmpty && mounted && !_stateDisposing) {
      await _importAlbum(url);
    }
  }

  Future<void> _importAlbum(String url) async {
    if (isSearchLoading || _stateDisposing) return;
    if (!isSupportedAlbumLink(url)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('invalid_album_link'))));
      return;
    }
    setState(() => isSearchLoading = true);
    try {
      final res = await http
          .post(
            configuredServerUri('/api/import_album/'),
            headers: const {'Content-Type': 'application/json'},
            body: json.encode({'url': url, 'limit': 100}),
          )
          .timeout(const Duration(seconds: 15));
      var response = _decodeApiResponse(res);
      if (res.statusCode != HttpStatus.ok &&
          res.statusCode != HttpStatus.accepted) {
        throw HttpException(
          response['error']?.toString() ?? 'HTTP ${res.statusCode}',
        );
      }
      if (res.statusCode == HttpStatus.accepted) {
        final jobId = response['job_id']?.toString() ?? '';
        if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(jobId)) {
          throw const FormatException('Invalid import job');
        }
        while (!_stateDisposing) {
          await Future<void>.delayed(const Duration(seconds: 2));
          if (_stateDisposing) return;
          final status = await http
              .get(configuredServerUri('/api/import_jobs/$jobId/'))
              .timeout(const Duration(seconds: 10));
          response = _decodeApiResponse(status);
          if (status.statusCode != HttpStatus.ok) {
            throw HttpException(
              response['error']?.toString() ?? 'HTTP ${status.statusCode}',
            );
          }
          if (mounted && !_stateDisposing) {
            setState(
              () => _albumImportProgress =
                  '${response['processed_count'] ?? 0} / ${response['total_count'] ?? '?'}',
            );
          }
          final state = response['status'];
          if (state == 'completed' || state == 'failed') break;
          if (state != 'queued' && state != 'running') {
            throw const FormatException('Invalid import job status');
          }
        }
      }
      if (_stateDisposing) return;
      final imported = response['tracks'];
      final tracks = imported is List
          ? imported.where((track) => downloadTrackId(track) != null).toList()
          : <dynamic>[];
      final errors = response['errors'] is List
          ? List<dynamic>.from(response['errors'] as List)
          : <dynamic>[];
      for (final entry in errors.whereType<Map>()) {
        final metadata = entry['metadata'];
        if (metadata is Map &&
            (metadata['album']?.toString().trim().isEmpty ?? true)) {
          metadata['album'] = response['album_title']?.toString() ?? '';
        }
      }
      if (response['status'] == 'failed' && errors.isEmpty) {
        errors.add({
          'error': response['error']?.toString() ?? tr('import_failed'),
        });
      }
      await syncDatabase(reportFailure: true);
      if (_stateDisposing || !mounted) return;
      if (errors.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${tr('import_partial')}: ${tracks.length} / ${tracks.length + errors.length}',
            ),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 12),
            action: SnackBarAction(
              label: tr('download_details'),
              onPressed: () => _showImportErrors(errors),
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${tr('import_complete')}: ${tracks.length}'),
            backgroundColor: Colors.green,
          ),
        );
      }
      if (tracks.isNotEmpty) await downloadAllTracks(tracks);
    } catch (error) {
      if (mounted && !_stateDisposing) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${tr('import_failed')}: ${_downloadError(error)}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted && !_stateDisposing) {
        setState(() {
          isSearchLoading = false;
          _albumImportProgress = null;
        });
      }
    }
  }

  Future<void> _showImportErrors(List<dynamic> errors) async {
    if (!mounted || _stateDisposing || _importErrorsOpen) return;
    _importErrorsOpen = true;
    final remaining = List<dynamic>.from(errors);
    try {
      while (remaining.isNotEmpty && mounted && !_stateDisposing) {
        if (!mounted) return;
        final selected = await showDialog<Map>(
          context: context,
          builder: (_) => AlbumImportErrorsDialog(errors: remaining),
        );
        if (selected == null || _stateDisposing || !mounted) break;
        if (await _confirmAlbumTrack(selected)) remaining.remove(selected);
      }
    } finally {
      _importErrorsOpen = false;
    }
  }

  Future<bool> _confirmAlbumTrack(Map entry) async {
    final metadata = Map<String, dynamic>.from(entry['metadata'] as Map);
    final confirmed = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => TrackMetadataDialog(metadata: metadata),
    );
    if (confirmed == null || _stateDisposing || !mounted) return false;
    try {
      final response = await http
          .post(
            configuredServerUri('/api/smart_search/'),
            headers: const {'Content-Type': 'application/json'},
            body: json.encode({
              ...confirmed,
              'q': confirmed['source_url'],
              'confirm_metadata': true,
            }),
          )
          .timeout(const Duration(minutes: 5));
      final data = _decodeApiResponse(response);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          data['error']?.toString() ?? 'HTTP ${response.statusCode}',
        );
      }
      await syncDatabase(reportFailure: true);
      if (_stateDisposing || !mounted) return true;
      final id = downloadTrackId({'id': data['track_id']});
      final imported = cachedTracks
          .where((track) => downloadTrackId(track) == id)
          .toList();
      if (imported.isNotEmpty) await downloadAllTracks(imported);
      return true;
    } catch (error) {
      if (mounted && !_stateDisposing) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${tr('import_failed')}: ${_downloadError(error)}'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Downloads
  // ═══════════════════════════════════════════════════════════════════════════

  bool isTrackLocal(int id) {
    if (localPath.isEmpty) return false;
    final file = _localAudioFile(id);
    try {
      return file.existsSync() && file.lengthSync() > 0;
    } on FileSystemException {
      return false;
    }
  }

  File _localAudioFile(int id) =>
      _trackUpdates?.audioFile(id) ?? File('$localPath/track_$id.mp3');

  File _localVideoFile(int id) =>
      _trackUpdates?.videoFile(id) ?? File('$localPath/video_$id.mp4');

  void _onTrackUpdates() {
    if (_stateDisposing || !mounted) return;
    final offers = _trackUpdates?.offers.value ?? const <TrackUpdateOffer>[];
    setState(() {});
    final signature = offers.map((offer) => offer.signature).join('|');
    if (offers.isEmpty || signature == _lastUpdateNotice || _updateDialogOpen) {
      return;
    }
    _lastUpdateNotice = signature;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${tr('track_updates')} (${offers.length})'),
        backgroundColor: Colors.black87,
        duration: const Duration(seconds: 12),
        action: SnackBarAction(
          label: tr('review_updates'),
          onPressed: _showTrackUpdates,
        ),
      ),
    );
  }

  Future<void> _showTrackUpdates() async {
    final monitor = _trackUpdates;
    if (monitor == null || _updateDialogOpen || !mounted) return;
    _updateDialogOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (_) => TrackUpdatesDialog(
          monitor: monitor,
          onUpdate: (offer) async {
            if (downloadQueue.contains(offer.id)) {
              throw StateError('Track is being downloaded');
            }
            setState(() => downloadQueue.add(offer.id));
            _notifyArtistLibraryChanged();
            try {
              final track = await monitor.updateTrack(offer);
              if (_stateDisposing) return;
              final updated = cachedTracks
                  .map((old) => old['id'] == offer.id ? track : old)
                  .toList();
              if (!updated.any((item) => item['id'] == offer.id)) {
                updated.add(track);
              }
              _applyTracks(updated);
              // Leave current lyrics in place; the versioned LRC is read on next start.
              for (final queued in playingQueue) {
                if (queued['id'] == offer.id) {
                  queued['lyrics'] = track['lyrics'];
                }
              }
              await _persistOfflineTracks();
            } finally {
              downloadQueue.remove(offer.id);
              if (!_stateDisposing && mounted) {
                setState(() {});
                _notifyArtistLibraryChanged();
              }
            }
          },
        ),
      );
    } finally {
      _updateDialogOpen = false;
    }
  }

  Widget _buildTrackUpdatesButton() =>
      (_trackUpdates?.offers.value.isNotEmpty ?? false)
      ? IconButton(
          tooltip: tr('track_updates'),
          onPressed: _showTrackUpdates,
          icon: Icon(Icons.system_update_alt, color: accentColorNotifier.value),
        )
      : const SizedBox.shrink();

  bool isTrackDownloadComplete(dynamic track) {
    if (localPath.isEmpty || track is! Map) return false;
    final rawTrackId = track['id'];
    final trackId = rawTrackId is int
        ? rawTrackId
        : int.tryParse(rawTrackId?.toString() ?? '');
    if (trackId == null) return false;
    final audioFile = _localAudioFile(trackId);
    try {
      return audioFile.existsSync() && audioFile.lengthSync() > 0;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> deleteDownloadedTrack(dynamic track) async {
    if (track is! Map || localPath.isEmpty) return;
    final rawTrackId = track['id'];
    final trackId = rawTrackId is int
        ? rawTrackId
        : int.tryParse(rawTrackId?.toString() ?? '');
    if (trackId == null) return;
    if (downloadQueue.contains(trackId)) return;

    try {
      final resolvedVideo = _localVideoFile(trackId);
      await _trackUpdates?.forget(trackId);
      final audioFile = File('$localPath/track_$trackId.mp3');
      if (await audioFile.exists()) {
        await audioFile.delete();
      }
      final lrcFile = File('$localPath/track_$trackId.lrc');
      if (await lrcFile.exists()) {
        await lrcFile.delete();
      }
      final videoFile = resolvedVideo;
      if (await videoFile.exists()) {
        await videoFile.delete();
      }
      final fallbackCover = File('$localPath/cover_$trackId.jpg');
      if (await fallbackCover.exists()) {
        await fallbackCover.delete();
      }

      final dir = Directory(localPath);
      if (await dir.exists()) {
        final prefix = 'cover_${trackId}_';
        final versioned = RegExp(
          '^track_${trackId}_[a-f0-9]{64}\\.(mp3|lrc)\$',
        );
        final versionedVideo = RegExp('^video_${trackId}_[a-f0-9]{64}\\.mp4\$');
        await for (final entity in dir.list()) {
          if (entity is File &&
              (entity.uri.pathSegments.last.startsWith(prefix) ||
                  versioned.hasMatch(entity.uri.pathSegments.last) ||
                  versionedVideo.hasMatch(entity.uri.pathSegments.last))) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }

      invalidateTrackCover(trackId);
      if (mounted) {
        setState(() {});
        _notifyArtistLibraryChanged();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('track_deleted_from_storage')),
            backgroundColor: Colors.black87,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error deleting track files: $e');
    }
  }

  void _openArtistScreen(int artistId, String artistName) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => ArtistScreen(
          artistId: artistId,
          artistName: artistName,
          getAllTracks: () => cachedTracks,
          onPlayTrack: (queue, idx) => startPlayback(queue, idx),
          onToggleFavorite: (id) => toggleFavorite(id),
          onDownloadTrack: (t) => downloadMediaFile(t),
          onDownloadAlbum: (tracks) => downloadAllTracks(tracks),
          onDeleteDownloadedTrack: (t) => deleteDownloadedTrack(t),
          isTrackDownloaded: (t) => isTrackDownloadComplete(t),
          isTrackFavorited: (id) => favs.contains(id),
          isDownloading: (id) => downloadQueue.contains(id),
          libraryChanges: _artistLibraryChanges,
        ),
      ),
    );
  }

  void _notifyArtistLibraryChanged() {
    if (!_stateDisposing) _artistLibraryChanges.value++;
  }

  Future<void> downloadMediaFile(dynamic mediaObj) async {
    final result = await _downloadMedia(mediaObj, retryUnavailableVideo: true);
    if (mounted && !_stateDisposing) {
      _showDownloadSummary(DownloadBatchResult(results: [result]), [mediaObj]);
    }
  }

  Future<TrackDownloadResult> _downloadMedia(
    dynamic mediaObj, {
    bool retryUnavailableVideo = false,
  }) {
    final id = downloadTrackId(mediaObj);
    final title = mediaObj is Map ? mediaObj['title']?.toString() ?? '$id' : '';
    if (id == null || localPath.isEmpty || _stateDisposing) {
      return Future.value(
        TrackDownloadResult(
          id: id ?? 0,
          title: title,
          audioReady: false,
          videoReady: false,
          errors: {
            DownloadComponent.library: tr(
              localPath.isEmpty ? 'library_not_ready' : 'invalid_track',
            ),
          },
        ),
      );
    }
    final pending = _mediaDownloadTasks[id];
    if (pending != null) return pending;
    if (downloadQueue.contains(id)) {
      return Future.value(
        TrackDownloadResult(
          id: id,
          title: title,
          audioReady: isTrackDownloadComplete(mediaObj),
          videoReady: false,
          errors: {DownloadComponent.library: tr('updating_track')},
        ),
      );
    }
    final operation = _downloadMediaOnce(
      Map<String, dynamic>.from(mediaObj as Map),
      id,
      retryUnavailableVideo: retryUnavailableVideo,
    );
    _mediaDownloadTasks[id] = operation;
    unawaited(
      operation.then<void>((_) {
        if (identical(_mediaDownloadTasks[id], operation)) {
          _mediaDownloadTasks.remove(id);
        }
      }),
    );
    return operation;
  }

  Future<TrackDownloadResult> _downloadMediaOnce(
    Map<String, dynamic> track,
    int id, {
    bool retryUnavailableVideo = false,
  }) async {
    final errors = <DownloadComponent, String>{};
    var audioReady = false;
    var videoReady = false;
    var videoUnavailable = false;
    final audioFile = _localAudioFile(id);
    final videoFile = _localVideoFile(id);
    final lrcFile =
        _trackUpdates?.lyricsFile(id) ?? File('$localPath/track_$id.lrc');
    final coverFile = File('$localPath/cover_${id}_${getCoverFileName(track)}');
    final hasCover =
        (track['album']?['cover']?.toString().trim().isNotEmpty ?? false);
    final hasLyrics = (track['lyrics']?.toString().trim().isNotEmpty ?? false);
    Future<String?>
    generateVideoUrl() => _clipTaskLimiter.run<String?>(() async {
      final signature = _videoAvailabilitySignature(track);
      if (!_clipRetryGate.canRequest(
        id,
        signature,
        force: retryUnavailableVideo,
      )) {
        videoUnavailable = _unavailableVideoSignatures[id] == signature;
        if (videoUnavailable) return null;
        throw const HttpException(
          'Повторный поиск клипа временно отложен. Можно повторить скачивание вручную.',
        );
      }
      final res = await _requestClipGeneration(
        id,
        force: retryUnavailableVideo,
      );
      if (res.statusCode != HttpStatus.ok) {
        _recordClipFailure(id, signature, res);
      } else {
        _clipRetryGate.clear(id);
      }
      if (res.statusCode == HttpStatus.notFound) {
        videoUnavailable = true;
        return null;
      }
      final data = _decodeApiResponse(res);
      if (res.statusCode != HttpStatus.ok) {
        throw HttpException(
          data['error']?.toString() ?? 'HTTP ${res.statusCode}',
        );
      }
      final url = data['video_url']?.toString().trim();
      if (url == null || url.isEmpty) videoUnavailable = true;
      return url;
    });
    final audioAlreadyReady = await _hasNonEmptyFile(audioFile);
    final videoAlreadyReady = await _hasNonEmptyFile(videoFile);
    final videoKnownUnavailable =
        !retryUnavailableVideo && _isVideoUnavailable(id, track);
    if (audioAlreadyReady &&
        (videoAlreadyReady || videoKnownUnavailable) &&
        (!hasCover || await _hasNonEmptyFile(coverFile)) &&
        (!hasLyrics || await _hasNonEmptyFile(lrcFile))) {
      return TrackDownloadResult(
        id: id,
        title: track['title']?.toString() ?? '$id',
        audioReady: true,
        videoReady: videoAlreadyReady,
        videoUnavailable: videoKnownUnavailable,
      );
    }
    if (mounted && !_stateDisposing) {
      setState(() => downloadQueue.add(id));
    } else {
      downloadQueue.add(id);
    }
    _notifyArtistLibraryChanged();
    try {
      await _downloadTaskLimiter.run(() async {
        if (_stateDisposing) return;
        // Optional components must not prevent a valid MP3 from being saved.
        try {
          if (!await _hasNonEmptyFile(audioFile)) {
            final audioUrl = track['audio_file']?.toString().trim() ?? '';
            if (audioUrl.isEmpty) throw StateError(tr('invalid_track'));
            await _mediaFileDownloader.download(
              source: Uri.parse(_resolveAbsoluteUrl(audioUrl)),
              destination: audioFile,
            );
          }
          audioReady = await _hasNonEmptyFile(audioFile);
          if (!audioReady) {
            throw const FileSystemException('Downloaded audio is empty');
          }
        } catch (error) {
          errors[DownloadComponent.audio] = _downloadError(error);
        }
        if (!audioReady || _stateDisposing) return;

        try {
          final coverUrl = track['album']?['cover']?.toString().trim() ?? '';
          if (coverUrl.isNotEmpty && !await _isCoverValidAndSquare(coverFile)) {
            if (!await _downloadAndCropCover(
              _resolveAbsoluteUrl(coverUrl),
              coverFile,
            )) {
              throw const FileSystemException('Cover download failed');
            }
            invalidateTrackCover(id);
          }
        } catch (error) {
          errors[DownloadComponent.cover] = _downloadError(error);
        }
        try {
          final lyrics = track['lyrics']?.toString() ?? '';
          if (!await _hasNonEmptyFile(lrcFile) && lyrics.trim().isNotEmpty) {
            await atomicFileStore.writeString(lrcFile, lyrics);
          }
        } catch (error) {
          errors[DownloadComponent.lyrics] = _downloadError(error);
        }
        try {
          await _trackUpdates?.registerDownload(track);
        } catch (error) {
          errors[DownloadComponent.library] = _downloadError(error);
        }

        // Existing local video remains usable even when the server is offline.
        videoReady = await _hasNonEmptyFile(videoFile);
        if (videoReady || _stateDisposing) return;
        final signature = _videoAvailabilitySignature(track);
        if (!retryUnavailableVideo && _isVideoUnavailable(id, track)) {
          videoUnavailable = true;
          return;
        }
        try {
          var videoUrl = _knownVideoUrlForTrack(id, track);
          videoUrl ??= await generateVideoUrl();
          if (videoUrl != null && videoUrl.trim().isNotEmpty) {
            var resolvedUrl = _resolveAbsoluteUrl(videoUrl);
            try {
              await _mediaFileDownloader.download(
                source: Uri.parse(resolvedUrl),
                destination: videoFile,
              );
            } on HttpException catch (error) {
              // A DB URL may outlive its server file. Regenerate once, retaining
              // the downloaded audio and any previous local video on failure.
              if (error.message !=
                  'Download failed with HTTP ${HttpStatus.notFound}.') {
                rethrow;
              }
              final replacement = await generateVideoUrl();
              if (replacement == null || replacement.isEmpty) {
                if (videoUnavailable) {
                  _unavailableVideoSignatures[id] = signature;
                }
                return;
              }
              resolvedUrl = _resolveAbsoluteUrl(replacement);
              await _mediaFileDownloader.download(
                source: Uri.parse(resolvedUrl),
                destination: videoFile,
              );
            }
            videoReady = await _hasNonEmptyFile(videoFile);
            if (!videoReady) {
              throw const FileSystemException('Downloaded video is empty');
            }
            _downloadedVideoSources.add(
              _videoSourceKey(
                _VideoRequest(trackId: id, videoUrl: resolvedUrl),
              ),
            );
            track['video_file'] = resolvedUrl;
            for (final item in [...playingQueue, ...cachedTracks]) {
              if (_VideoRequest.from(item).trackId == id) {
                item['video_file'] = resolvedUrl;
              }
            }
            final active = activeTrackNotifier.value;
            if (_VideoRequest.from(active).trackId == id) {
              active['video_file'] = resolvedUrl;
            }
            await _persistOfflineTracks();
            await _trackUpdates?.registerDownload(track);
            _unavailableVideoSignatures.remove(id);
          }
          if (videoUnavailable) _unavailableVideoSignatures[id] = signature;
        } catch (error) {
          errors[DownloadComponent.video] = _downloadError(error);
        }
      });
    } catch (error) {
      errors[DownloadComponent.library] = _downloadError(error);
    } finally {
      downloadQueue.remove(id);
      if (mounted && !_stateDisposing) setState(() {});
      _notifyArtistLibraryChanged();
    }
    return TrackDownloadResult(
      id: id,
      title: track['title']?.toString() ?? '$id',
      audioReady: audioReady,
      videoReady: videoReady,
      videoUnavailable: videoUnavailable,
      errors: errors,
    );
  }

  String _downloadError(Object error) {
    if (error is TimeoutException) return tr('connection_timeout');
    if (error is SocketException) return tr('server_unavailable');
    if (error is HttpException) {
      return error.message.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');
    }
    if (error is FileSystemException) return error.message;
    return error.toString();
  }

  String _videoAvailabilitySignature(Map track) => json.encode([
    track['title'],
    track['album']?['artist']?['id'],
    track['album']?['artist']?['name'],
    track['artists'],
    track['duration'],
    track['video_file'],
    track['content_versions']?['video'],
    track['content_versions']?['metadata'],
  ]);

  void _recordClipFailure(int id, String signature, http.Response response) {
    final data = _decodeApiResponse(response);
    final retry = int.tryParse(data['retry_after']?.toString() ?? '');
    final fallback = response.statusCode == HttpStatus.notFound
        ? 21600
        : response.statusCode == HttpStatus.tooManyRequests
        ? 5
        : 900;
    final seconds = (retry ?? fallback).clamp(5, 21600);
    _clipRetryGate.recordFailure(id, signature, Duration(seconds: seconds));
    if (response.statusCode == HttpStatus.notFound) {
      _unavailableVideoSignatures[id] = signature;
    } else {
      _unavailableVideoSignatures.remove(id);
    }
  }

  bool _isVideoUnavailable(int id, Map track) {
    final signature = _videoAvailabilitySignature(track);
    if (_unavailableVideoSignatures[id] != signature) return false;
    if (_clipRetryGate.canRequest(id, signature)) {
      _unavailableVideoSignatures.remove(id);
      return false;
    }
    return true;
  }

  Future<void> downloadAllTracks(
    List<dynamic> tracksToDownload, {
    bool retryUnavailableVideo = false,
  }) async {
    while (_bulkDownloadActive && !_stateDisposing) {
      await _bulkDownloadFinished?.future;
    }
    if (_stateDisposing || !mounted) return;
    final tracks = tracksToDownload
        .where((track) => downloadTrackId(track) != null)
        .toList();
    if (tracks.isEmpty) return;
    setState(() => _bulkDownloadActive = true);
    final finished = _bulkDownloadFinished = Completer<void>();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${tr('download_started')}: ${tracks.length}')),
    );
    try {
      final result = await runDownloadBatch<dynamic>(
        tracks: tracks,
        trackId: downloadTrackId,
        title: (track) => track['title']?.toString() ?? '',
        download: (track) =>
            _downloadMedia(track, retryUnavailableVideo: retryUnavailableVideo),
        isCancelled: () => _stateDisposing,
      );
      if (mounted && !_stateDisposing) _showDownloadSummary(result, tracks);
    } finally {
      _bulkDownloadActive = false;
      if (mounted && !_stateDisposing) setState(() {});
      if (!finished.isCompleted) finished.complete();
      if (identical(_bulkDownloadFinished, finished)) {
        _bulkDownloadFinished = null;
      }
    }
  }

  void _showDownloadSummary(DownloadBatchResult result, List<dynamic> tracks) {
    final retryIds = result.incomplete.map((item) => item.id).toSet();
    final retry = tracks
        .where((track) => retryIds.contains(downloadTrackId(track)))
        .toList();
    final label = result.incomplete.isEmpty
        ? 'download_complete'
        : result.audioReady == 0
        ? 'download_failed'
        : 'download_partial';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${tr(label)}. ${tr('download_audio')}: ${result.audioReady}/${result.results.length}, ${tr('download_video')}: ${result.videoReady}/${result.results.length}',
        ),
        backgroundColor: result.incomplete.isEmpty
            ? Colors.green
            : Colors.orange,
        duration: Duration(seconds: result.incomplete.isEmpty ? 4 : 12),
        action: result.incomplete.isEmpty
            ? null
            : SnackBarAction(
                label: tr('download_details'),
                onPressed: () => _showDownloadErrors(result, retry),
              ),
      ),
    );
  }

  Future<void> _showDownloadErrors(
    DownloadBatchResult result,
    List<dynamic> retry,
  ) async {
    if (!mounted || _stateDisposing) return;
    final retryRequested = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF202020),
        title: Text(tr('download_partial')),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Text(
              result.incomplete
                  .map((item) {
                    final failures = item.errors.entries
                        .map(
                          (error) =>
                              '${tr('download_${error.key.name}')}: ${error.value}',
                        )
                        .toList();
                    if (item.videoUnavailable) {
                      failures.add(tr('video_not_found'));
                    }
                    return '${item.title}\n${failures.join('\n')}';
                  })
                  .join('\n\n'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('close')),
          ),
          if (retry.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('download_retry')),
            ),
        ],
      ),
    );
    if (retryRequested == true && mounted && !_stateDisposing) {
      await downloadAllTracks(retry, retryUnavailableVideo: true);
    }
  }

  Future<bool> clearAllCache() async {
    if (downloadQueue.isNotEmpty || _coverDownloads.isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('wait_for_downloads'))));
      }
      return false;
    }
    if (localPath.isEmpty) return false;
    final protectedTracks = <int>{};
    final protectedArtists = <int>{};
    for (final track in [...cachedTracks, ...playingQueue]) {
      if (track is! Map || track['id'] is! int) continue;
      final id = track['id'] as int;
      final localLyrics =
          _trackUpdates?.lyricsFile(id) ?? File('$localPath/track_$id.lrc');
      if (isTrackDownloadComplete(track) ||
          playingQueue.any((playing) => playing['id'] == id) ||
          await (_trackUpdates?.videoFile(id) ??
                  File('$localPath/video_$id.mp4'))
              .exists() ||
          await localLyrics.exists()) {
        protectedTracks.add(id);
        final albumArtistId = track['album']?['artist']?['id'];
        if (albumArtistId is int) protectedArtists.add(albumArtistId);
        for (final artist in track['artists'] as List? ?? const []) {
          if (artist is Map && artist['id'] is int) {
            protectedArtists.add(artist['id'] as int);
          }
        }
      }
    }
    for (final artist in cachedArtists) {
      if (artist is Map && artist['id'] is int) {
        protectedArtists.add(artist['id'] as int);
      }
    }
    await clearDisposableArtwork(
      Directory(localPath),
      protectedTrackIds: protectedTracks,
      protectedArtistIds: protectedArtists,
    );
    clearCoverCache();
    PaintingBinding.instance.imageCache.clear();
    if (mounted) {
      setState(() {});
      _notifyArtistLibraryChanged();
    }
    return true;
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
    _notifyArtistLibraryChanged();
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
    return FileImage(resolvePlaylistArtwork(Directory(localPath), pathOrUrl));
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
        } else {
          discordStart = null;
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
    _statistics?.endTrack();
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
          artist: trackArtistLabel(targetTrack),
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
    final localTrackPath = _localAudioFile(trackId);
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

      _statistics?.beginTrack(targetTrack as Map, duration: duration);
      _statistics?.setPlaying(audioPlayer.state == PlayerState.playing);
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
    final localTrackPath = _localAudioFile(trackId);
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
    if (_isCurrentTrackRevision(trackRevision)) {
      _statistics?.beginTrack(targetTrack as Map, duration: duration);
      _statistics?.setPlaying(audioPlayer.state == PlayerState.playing);
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
    if (globalLyrics.isEmpty) return;
    final resolvedIndex = lyricLineIndexAt(globalLyrics, pos);

    if (resolvedIndex != currentLine) {
      currentLine = resolvedIndex;
      if (isPlaying) updateRPC();
      uiSignal.value++;
    }
  }

  void seekTo(Duration pos) {
    final trackRevision = _trackRevision;
    final seekRevision = ++_seekRevision;
    currentPositionNotifier.value = pos;
    discordStart = isPlaying
        ? (DateTime.now().millisecondsSinceEpoch - pos.inMilliseconds)
        : null;
    checkLyrics(pos);
    updateRPC(force: true);
    _syncMediaSessionPlayback();
    unawaited(_saveState());
    unawaited(
      _enqueueAudioWork(() async {
        if (!_isCurrentTrackRevision(trackRevision) ||
            seekRevision != _seekRevision) {
          return;
        }
        _statistics?.setSeeking(true);
        try {
          await audioPlayer.seek(pos);
        } finally {
          _statistics?.setSeeking(false);
        }
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
    final artistCredits = trackArtistLabel(trackObj);
    final trackTitle = trackObj['title'].toString();
    final trackId = trackObj['id'] as int;
    final recordingDuration =
        int.tryParse(trackObj['duration']?.toString() ?? '') ?? 0;
    // Capture before LRCLib/network awaits; the catalog map may change meanwhile.
    final originalLyrics = trackObj['lyrics']?.toString() ?? '';
    final expectedLyricsVersion = sha256
        .convert(utf8.encode(originalLyrics))
        .toString();

    final localLrc =
        _trackUpdates?.lyricsFile(trackId) ??
        File('$localPath/track_$trackId.lrc');
    try {
      if (await _hasNonEmptyFile(localLrc) ||
          ((_trackUpdates?.hasManagedLyrics(trackId) ?? false) &&
              await localLrc.exists())) {
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
      final parsedUrl = Uri.https('lrclib.net', '/api/get', {
        'artist_name': artistName,
        'track_name': trackTitle,
        if (recordingDuration > 0) 'duration': '$recordingDuration',
      });
      final res = await http
          .get(parsedUrl)
          .timeout(const Duration(seconds: 15));
      if (!_isCurrentLyricsRequest(revision, trackId)) return;
      if (res.statusCode == HttpStatus.ok) {
        final jsonData = json.decode(utf8.decode(res.bodyBytes));
        final metadataUnchanged = lyricsLookupUnchanged(
          trackObj,
          artists: artistCredits,
          title: trackTitle,
          duration: recordingDuration,
          originalLyrics: originalLyrics,
        );
        final contents = metadataUnchanged
            ? validatedLyricsText(
                jsonData,
                artists: artistCredits,
                title: trackTitle,
                duration: recordingDuration,
              )
            : '';
        if (contents.trim().isNotEmpty) {
          _commitLyrics(
            revision: revision,
            trackId: trackId,
            lyrics: parseLrcString(contents),
            plainText: contents,
          );
          unawaited(_writeLyricsFile(localLrc, contents));
          unawaited(
            _saveLyricsToServer(trackId, contents, expectedLyricsVersion),
          );
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

  Future<void> _saveLyricsToServer(
    int trackId,
    String lyricsText,
    String expectedLyricsVersion,
  ) async {
    try {
      final url = configuredServerUri('/api/tracks/$trackId/update_lyrics/');
      final res = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'lyrics': lyricsText,
              'expected_lyrics_version': expectedLyricsVersion,
            }),
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
        await _trackUpdates?.acknowledgeLocalLyrics(trackId, lyricsText);
      } else if (res.statusCode == HttpStatus.conflict) {
        // A manual edit wins. Keep its server content and let normal polling offer it.
        unawaited(_trackUpdates?.checkNow());
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

  DiscordAnimatedArtwork? _discordArtwork;
  DiscordCoverLookup? _discordCovers;

  void updateRPC({bool force = false}) {
    if (PerformanceFrameMonitor.enabled ||
        !isDesktop ||
        _stateDisposing ||
        playingQueue.isEmpty ||
        playingIndex < 0 ||
        playingIndex >= playingQueue.length) {
      return;
    }
    final activityRevision = ++_discordActivityRevision;

    Future<void> sendToDiscord() async {
      if (_stateDisposing ||
          activityRevision != _discordActivityRevision ||
          playingQueue.isEmpty ||
          playingIndex < 0 ||
          playingIndex >= playingQueue.length) {
        return;
      }
      lastRpcTime = DateTime.now();
      final trackData = playingQueue[playingIndex];
      final title = trackData['title'];
      final art = trackData['album']['artist']['name'];

      final publicCover = _discordCovers?.imageFor(trackData);
      String? animatedCover;
      // Animation is a fallback, never an override of iTunes/Deezer/Last.fm.
      if (_discordCovers?.isResolved(trackData) == true &&
          publicCover?.isTrackCover != true) {
        animatedCover = _discordArtwork?.imageFor(trackData);
      }
      final coverUrl = selectDiscordCoverImage(
        discovered: publicCover,
        stored: trackData['album']?['cover']?.toString(),
        animated: animatedCover,
      );

      final dur = trackData['duration'];
      int? durationMs;
      if (dur != null && dur is num && dur.toInt() > 0) {
        durationMs = dur.toInt() * 1000;
      }

      final largeImg = coverUrl ??
          'https://cdn.discordapp.com/app-icons/1480246072042590219/36573ffd3ca304580ed8968517090b0e.png';

      if (_stateDisposing || activityRevision != _discordActivityRevision) {
        return;
      }

      final currentLyric = currentLine >= 0 && currentLine < globalLyrics.length
          ? globalLyrics[currentLine].txt
          : null;
      final statusDisplayType = resolveDiscordStatusDisplayType(
        showLyrics: discordLyricsStatusNotifier.value,
        isPlaying: isPlaying,
        currentLyric: currentLyric,
      );

      if (isPlaying) {
        String p1 = '$title — $art';
        String p2 = 'Слушает музыку';

        if (globalLyrics.isNotEmpty) {
          if (currentLine >= 0 && currentLine < globalLyrics.length) {
            p2 = globalLyrics[currentLine].txt;
          } else if (currentLine == -1) {
            p2 = 'Вступление...';
          }
        }

        await _setDiscordActivity(
          RPCActivity(
            details: p1,
            state: p2,
            activityType: ActivityType.listening,
            statusDisplayType: statusDisplayType,
            assets: RPCAssets(largeImage: largeImg),
            timestamps: discordStart != null
                ? RPCTimestamps(
                    start: discordStart!,
                    end: durationMs != null
                        ? (discordStart! + durationMs)
                        : null,
                  )
                : null,
            buttons: discordShowGitHubButtonNotifier.value
                ? [
                    const RPCButton(
                      label: "GitHub",
                      url: "https://github.com/cursedworld/ShikiMusic",
                    ),
                  ]
                : null,
          ),
        );
      } else {
        await _clearDiscordActivity();
        if (_stateDisposing || activityRevision != _discordActivityRevision) {
          return;
        }
        final currentPos = currentPositionNotifier.value;
        final totalDur = fullDurationNotifier.value > Duration.zero
            ? fullDurationNotifier.value
            : (durationMs != null ? Duration(milliseconds: durationMs) : null);
        final posStr = formatDuration(currentPos);
        final durStr = totalDur != null && totalDur > Duration.zero
            ? ' / ${formatDuration(totalDur)}'
            : '';

        await _setDiscordActivity(
          RPCActivity(
            details: '$title — $art',
            state: 'На паузе ($posStr$durStr)',
            activityType: ActivityType.listening,
            statusDisplayType: statusDisplayType,
            assets: RPCAssets(largeImage: largeImg),
            buttons: discordShowGitHubButtonNotifier.value
                ? [
                    const RPCButton(
                      label: "GitHub",
                      url: "https://github.com/cursedworld/ShikiMusic",
                    ),
                  ]
                : null,
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
      rpcThrottleTimer?.cancel();
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
    CroppedPlaylistArtwork? selectedArtwork;
    bool selectingImage = false;
    bool saving = false;

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
                    key: const ValueKey('playlist_name'),
                    autofocus: true,
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
                  if (selectedArtwork != null) ...[
                    CircleAvatar(
                      radius: 32,
                      backgroundImage: MemoryImage(selectedArtwork!.bytes),
                    ),
                    const SizedBox(height: 12),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: selectingImage || saving ? null : () async {
                        setStateDialog(() => selectingImage = true);
                        try {
                          final result = await FilePicker.platform
                              .pickFiles(type: FileType.image);
                          final path = result?.files.single.path;
                          if (path == null || !ctx.mounted) return;
                          final artwork = await showPlaylistCropDialog(ctx, path);
                          if (artwork == null || !ctx.mounted) return;
                          setStateDialog(() => selectedArtwork = artwork);
                        } catch (_) {
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(tr('playlist_image_failed'))),
                            );
                          }
                        } finally {
                          if (ctx.mounted) setStateDialog(() => selectingImage = false);
                        }
                      },
                      icon: const Icon(Icons.folder_open),
                      label: Text(
                        selectedArtwork != null
                            ? "Картинка выбрана ✓"
                            : "Выбрать картинку",
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: selectedArtwork != null
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
                  onPressed: saving || selectingImage ? null : () async {
                    if (pName.trim().isNotEmpty) {
                      setStateDialog(() => saving = true);
                      final playlistId = DateTime.now().microsecondsSinceEpoch;
                      var image = '';
                      if (selectedArtwork != null) {
                        try {
                          image = await saveCroppedPlaylistArtwork(
                            Directory(localPath),
                            selectedArtwork!,
                            playlistId,
                          );
                        } catch (error) {
                          if (ctx.mounted) {
                            setStateDialog(() => saving = false);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(tr('playlist_image_failed')),
                              ),
                            );
                          }
                          return;
                        }
                      }
                      if (!mounted || !ctx.mounted) return;
                      setState(() {
                        myPlaylists.add({
                          "id": playlistId,
                          "name": pName.trim(),
                          "image": image,
                          "tracks": [],
                        });
                      });
                      await savePlaylists();
                      if (!ctx.mounted) return;
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
      return IconButton(
        icon: const Icon(
          Icons.download_done,
          color: Colors.greenAccent,
          size: 24,
        ),
        tooltip: tr('delete_downloaded_track'),
        onPressed: () => deleteDownloadedTrack(playingQueue[playingIndex]),
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
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (searchQuery.isNotEmpty)
                IconButton(
                  icon: const Icon(
                    Icons.clear,
                    color: Colors.white54,
                    size: 18,
                  ),
                  onPressed: () {
                    searchInput.clear();
                    setState(() => searchQuery = "");
                  },
                ),
              IconButton(
                key: const ValueKey('import_album_link'),
                tooltip: _albumImportProgress == null
                    ? tr('import_album')
                    : '${tr('import_album')}: $_albumImportProgress',
                onPressed: isSearchLoading ? null : _showAlbumImport,
                icon: isSearchLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(
                        Icons.album_outlined,
                        color: Colors.white54,
                        size: 18,
                      ),
              ),
            ],
          ),
        ),
        onChanged: (val) => setState(() => searchQuery = val),
        onSubmitted: (_) => downloadFromNetwork(),
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
          const SizedBox(height: 20),
          IconButton(
            icon: Icon(
              Icons.people_alt_outlined,
              color: navId == -1 ? Colors.white : Colors.white54,
            ),
            tooltip: tr('sidebar_artists'),
            onPressed: () {
              setState(() => navId = -1);
              unawaited(_syncArtistsCache());
            },
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
                        // ListView gives the row a tight width; keep the image
                        // square so BoxFit.cover does not crop it a second time.
                        child: Center(
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
          _mobileNavTile(
            Icons.people_alt_outlined,
            tr('sidebar_artists'),
            -1,
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
                final plTracks = playlistTracksInOrder(
                  cachedTracks,
                  pl['tracks'] as List,
                );
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
        if (id == -1) {
          unawaited(_syncArtistsCache());
        }
      },
    );
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsScreen(onClearCache: clearAllCache, statistics: _statistics, statisticsTracks: cachedTracks, statisticsArtists: cachedArtists),
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
                      image: coverThumbnail(
                        context,
                        getPictureProvider(playingQueue[playingIndex]),
                        52,
                      ),
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
                          trackArtistLabel(playingQueue[playingIndex]),
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
                  trackArtistLabel(playingQueue[playingIndex]),
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

  Widget _buildArtistsView(bool isMobile) {
    final accent = accentColorNotifier.value;

    final Map<String, Map<String, dynamic>> artistMap = {};

    // 1. Populate from cachedArtists (offline_artists.json or server API)
    for (final a in cachedArtists) {
      if (a == null || a['name'] == null) continue;
      final name = a['name'].toString().trim();
      if (name.isEmpty) continue;
      final key = name.toLowerCase();
      artistMap[key] = {
        'id': a['id'] ?? 0,
        'name': name,
        'photo': a['photo'],
        'bio': a['bio'] ?? '',
        'tracks_count': a['tracks_count'] ?? 0,
        'albums_count': a['albums_count'] ?? 0,
        'tracks': <dynamic>[],
        'albums': <String>{},
      };
    }

    // 2. Associate cached tracks and any extra offline tracks
    for (final t in cachedTracks) {
      final trackArtists = t['artists'] as List<dynamic>?;
      final mainArtist = t['album']?['artist'];
      final albumId = t['album']?['id'];
      final albumKey = albumId != null
          ? 'id:$albumId'
          : 'title:${t['album']?['title'] ?? ''}';

      final List<dynamic> artistsToProcess = [];
      if (mainArtist != null) artistsToProcess.add(mainArtist);
      if (trackArtists != null && trackArtists.isNotEmpty) {
        artistsToProcess.addAll(trackArtists);
      }

      for (final a in artistsToProcess) {
        if (a == null || a['name'] == null) continue;
        final name = a['name'].toString().trim();
        if (name.isEmpty) continue;
        final key = name.toLowerCase();

        if (!artistMap.containsKey(key)) {
          artistMap[key] = {
            'id': a['id'] ?? 0,
            'name': name,
            'photo': a['photo'],
            'bio': a['bio'] ?? '',
            'tracks_count': 0,
            'albums_count': 0,
            'tracks': [t],
            'albums': {albumKey},
          };
        } else {
          final existing = artistMap[key]!;
          if ((existing['photo'] == null ||
                  existing['photo'].toString().isEmpty) &&
              a['photo'] != null) {
            existing['photo'] = a['photo'];
          }
          if (a['id'] != null && existing['id'] == 0) {
            existing['id'] = a['id'];
          }
          final tracksList = existing['tracks'] as List;
          if (!tracksList.any((item) => item['id'] == t['id'])) {
            tracksList.add(t);
          }
          if (albumId != null || t['album']?['title'] != null) {
            (existing['albums'] as Set).add(albumKey);
          }
        }
      }
    }

    var artists = artistMap.values.toList();
    if (searchQuery.isNotEmpty) {
      final q = searchQuery.toLowerCase();
      artists = artists
          .where((a) => a['name'].toString().toLowerCase().contains(q))
          .toList();
    }

    if (artists.isEmpty) {
      return Center(
        child: Text(
          tr('no_data'),
          style: const TextStyle(color: Colors.white38, fontSize: 18),
        ),
      );
    }

    return GridView.builder(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: const EdgeInsets.symmetric(vertical: 10),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: isMobile ? 2 : 4,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        childAspectRatio: 0.85,
      ),
      itemCount: artists.length,
      itemBuilder: (ctx, idx) {
        final artist = artists[idx];
        final aId = artist['id'] is int ? artist['id'] as int : 0;
        final aName = artist['name'] as String;
        final aTracks = artist['tracks'] as List;
        final aAlbums = artist['albums'] as Set;
        final tracksCount =
            artist['tracks_count'] is int && artist['tracks_count'] > 0
            ? artist['tracks_count'] as int
            : aTracks.length;
        final albumsCount =
            artist['albums_count'] is int && artist['albums_count'] > 0
            ? artist['albums_count'] as int
            : aAlbums.length;

        final photoProvider = getArtistPhotoProvider(artist);

        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => _openArtistScreen(aId, aName),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white12),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 90,
                    height: 90,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white10,
                      border: Border.all(
                        color: accent.withValues(alpha: 0.5),
                        width: 2,
                      ),
                      image: photoProvider != null
                          ? DecorationImage(
                              image: photoProvider,
                              fit: BoxFit.cover,
                            )
                          : null,
                    ),
                    child: photoProvider == null
                        ? const Icon(
                            Icons.person,
                            size: 48,
                            color: Colors.white54,
                          )
                        : null,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    aName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$tracksCount ${tr('artist_tracks_count')} • $albumsCount ${tr('artist_albums_count')}',
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        );
      },
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

    if (navId == -1) {
      finalListToRender = [];
      headText = tr('sidebar_artists');
    } else if (navId == 0) {
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
        finalListToRender = playlistTracksInOrder(cachedTracks, pTracks);
        headText = myPlaylists[pIndex]['name'];
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => navId = 0);
        });
        finalListToRender = cachedTracks;
        headText = tr('nav_home');
      }
    }

    List<dynamic> finalList = finalListToRender
        .where((track) => matchesTrackSearch(track, searchQuery))
        .toList();

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
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              headText,
                              style: const TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          _buildTrackUpdatesButton(),
                        ],
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
                            onPressed: _bulkDownloadActive
                                ? null
                                : () => downloadAllTracks(finalList),
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
                          _buildTrackUpdatesButton(),
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
                              onPressed: _bulkDownloadActive
                                  ? null
                                  : () => downloadAllTracks(finalList),
                            ),
                          const SizedBox(width: 15),
                          buildSearchField(),
                        ],
                      ),
                    ],
                  ),
            const SizedBox(height: 20),
            Expanded(
              child: navId == -1
                  ? _buildArtistsView(isMobile)
                  : isLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: Colors.redAccent),
                    )
                  : finalList.isEmpty
                  ? Center(
                      child: isSearchLoading
                          ? Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const CircularProgressIndicator(
                                  color: Colors.redAccent,
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  _albumImportProgress != null
                                      ? '${tr('import_album')}: $_albumImportProgress'
                                      : tr('import_progress'),
                                  style: const TextStyle(
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
                                image: coverThumbnail(
                                  context,
                                  getPictureProvider(currentObject),
                                  50,
                                ),
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
                            subtitle: MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                onTap: () {
                                  final a = currentObject['album']?['artist'];
                                  final aId = a?['id'] is int
                                      ? a['id'] as int
                                      : 0;
                                  final aName = a?['name']?.toString() ?? '';
                                  if (aName.isNotEmpty) {
                                    _openArtistScreen(aId, aName);
                                  }
                                },
                                child: Text(
                                  trackArtistLabel(currentObject),
                                  style: const TextStyle(color: Colors.white54),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
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
                                    IconButton(
                                      icon: const Icon(
                                        Icons.download_done,
                                        color: Colors.greenAccent,
                                        size: 24,
                                      ),
                                      tooltip: tr('delete_downloaded_track'),
                                      onPressed: () =>
                                          deleteDownloadedTrack(currentObject),
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
