import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show compute, listEquals, visibleForTesting;
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
import 'package:audio_session/audio_session.dart'
    show AudioInterruptionEvent, AudioInterruptionType;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_media_session/flutter_media_session.dart' as fms;
import 'package:video_player/video_player.dart';
import 'package:crypto/crypto.dart';

import '../app_paths.dart';
import '../android_playback_focus.dart';
import '../async_task_limiter.dart';
import '../atomic_file_store.dart';
import '../background_photo.dart';
import '../cover_processing.dart';
import '../catalog_sync.dart';
import '../disposable_cache.dart';
import '../discord_artwork.dart';
import '../discord_cover.dart';
import '../discord_presence.dart';
import '../discord_status.dart';
import '../download_batch.dart';
import '../downloaded_only.dart';
import '../globals.dart';
import '../localization.dart';
import '../lrc_parser.dart';
import '../lyric_text_edits.dart';
import '../lyric_timing.dart';
import '../lyric_timing_proposals.dart';
import '../lyrics_search.dart';
import '../listening_statistics.dart';
import '../local_download_remover.dart';
import '../local_music_catalog.dart';
import '../local_music_import.dart';
import '../local_music_metadata.dart';
import '../local_music_server_match.dart';
import '../local_video_backend.dart';
import '../linux_media_session.dart';
import '../statistics_store.dart';
import '../media_file_downloader.dart';
import '../music_import.dart';
import '../clip_preview_cache.dart';
import '../clip_retry_gate.dart';
import '../perf/frame_metrics.dart';
import '../playlist_artwork.dart';
import '../playlist_tracks.dart';
import '../player_shortcuts.dart';
import '../playback_deck.dart';
import '../playback_order.dart';
import '../playback_position.dart';
import '../platform_capabilities.dart';
import '../mobile_motion.dart';
import '../safe_file_migration.dart';
import '../server_config.dart';
import '../track_details.dart';
import '../track_fade.dart';
import '../track_crossfade.dart';
import '../track_transition_mode.dart';
import '../windows_taskbar_controls.dart';
import '../track_updates.dart';
import '../track_selection.dart';
import '../widgets/track_updates_dialog.dart';
import '../widgets/catalog_sync_button.dart';
import '../widgets/clip_preview.dart';
import '../widgets/desktop_player_panel.dart';
import '../widgets/player_backdrop.dart';
import '../widgets/local_music_import_dialog.dart';
import '../widgets/track_selection_bar.dart';
import '../widgets/mobile_playback_controls.dart';
import '../widgets/now_playing_artist.dart';
import '../widgets/play_next_panel.dart';
import '../widgets/track_details_dialog.dart';
import '../widgets/track_metadata_dialog.dart';
import '../widgets/playlist_crop_dialog.dart';
import '../widgets/playlist_name_dialog.dart';
import '../widgets/playlist_track_list.dart';
import '../widgets/artist_library_view.dart';
import 'artist_screen.dart';
import 'lyrics_screen.dart';
import 'settings_screen.dart';
import 'storage_screen.dart';

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
  const _VideoRequest({
    required this.trackId,
    required this.videoUrl,
    this.preview,
  });

  factory _VideoRequest.from(dynamic trackData) {
    if (trackData is! Map) {
      return const _VideoRequest(trackId: null, videoUrl: null);
    }
    final rawTrackId = trackData['id'];
    final trackId = rawTrackId is int
        ? rawTrackId
        : int.tryParse(rawTrackId?.toString() ?? '');
    final rawVideoUrl = trackData['video_file']?.toString().trim();
    // An owned MP3 never asks Django to search for a negative track ID.
    // It can use a clip once the verified catalog match has found one.
    if (isLocalMusic(trackData) &&
        (rawVideoUrl == null || rawVideoUrl.isEmpty)) {
      return const _VideoRequest(trackId: null, videoUrl: null);
    }
    final videoUrl = rawVideoUrl == null || rawVideoUrl.isEmpty
        ? null
        : rawVideoUrl;
    final catalogId = isLocalMusic(trackData)
        ? trackData['local_match_id']
        : trackId;
    return _VideoRequest(
      trackId: trackId,
      videoUrl: videoUrl,
      preview: catalogId is int
          ? ClipPreviewReference.fromAdvertisement(
              trackData['video_preview'],
              serverTrackId: catalogId,
              originalUrl: videoUrl,
              serverBaseUrl: configuredServerBaseUrl,
            )
          : null,
    );
  }

  final int? trackId;
  final String? videoUrl;
  final ClipPreviewReference? preview;
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
  late PlaybackDeck _audioDeck;
  AudioPlayer get audioPlayer => _audioDeck.player;
  TrackFade get _trackFade => _audioDeck.fade;
  TrackCrossfade<PlaybackDeck>? _crossfade;
  int? _closingAudioTrackId;
  Future<void>? _closingAudioWork;
  bool _androidDeckUsesSharedFocus = false;
  AndroidPlaybackFocus? _androidPlaybackFocus;
  int? _resumeAfterFocusRevision;
  int _benchmarkPositionEvents = 0;

  // ── flutter_media_session for Media3 notification ────────────────────────
  fms.FlutterMediaSession? _mediaSession;
  bool _mediaSessionActive = false;
  LinuxMediaSession? _linuxMediaSession;
  bool _linuxPlaybackStopped = false;

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

  /// System controls use this AudioPlayer on every supported platform.
  Future<void> _initMediaSession() async {
    // Diagnostic A/B only; eliminated from ordinary release builds.
    if (PerformanceFrameMonitor.enabled &&
        Platform.isWindows &&
        Platform.environment['SHIKI_PERF_DISABLE_SMTC'] == '1') {
      return;
    }
    if (Platform.isLinux) {
      final session = LinuxMediaSession(
        onAction: _onSystemMediaAction,
        onShuffle: (enabled) {
          if (isShuffled != enabled) toggleShuffle();
        },
        onRepeat: (mode) {
          final selected = switch (mode) {
            'Track' => LoopMode.one,
            'Playlist' => LoopMode.list,
            _ => LoopMode.off,
          };
          if (!mounted || _stateDisposing) return;
          setState(() => loopMode = selected);
          _crossfade?.cancel(allowRetry: true);
          loopModeNotifier.value = selected;
          _syncMediaSessionPlayback();
          unawaited(_saveState());
        },
        onVolume: (value) {
          if (!mounted || _stateDisposing) return;
          setState(() => volume = value);
          unawaited(_setPlaybackVolume(value));
          _syncLinuxMediaSession();
          unawaited(_saveState());
        },
      );
      _linuxMediaSession = session;
      _syncLinuxMediaSession();
      await session.start();
      if (_stateDisposing) await session.close();
      return;
    }
    if (isDesktop && !Platform.isWindows) return;
    try {
      _mediaSession = fms.FlutterMediaSession();
      await _mediaSession!.activate();
      if (_stateDisposing) {
        await _mediaSession!.deactivate();
        return;
      }
      _mediaSessionActive = true;

      // Handle notification button presses
      _mediaSession!.setActionHandler(
        onPlay: () {
          _onSystemMediaAction('play', null);
        },
        onPause: () {
          _onSystemMediaAction('pause', null);
        },
        onSkipToNext: () {
          _onSystemMediaAction('next', null);
        },
        onSkipToPrevious: () {
          _onSystemMediaAction('previous', null);
        },
        onStop: () {
          _onSystemMediaAction('stop', null);
        },
        onSeekTo: (pos) {
          _onSystemMediaAction('seek', pos);
        },
        onShuffle: toggleShuffle,
        onRepeat: toggleLoopMode,
      );
      _syncMediaSessionMetadata();
      _syncMediaSessionPlayback();
    } catch (e) {
      debugPrint('FlutterMediaSession init failed: $e');
      _mediaSessionActive = false;
    }
  }

  void _onSystemMediaAction(String action, Duration? position) {
    if (_stateDisposing || !mounted || playingQueue.isEmpty) return;
    switch (action) {
      case 'play':
        if (!isPlaying) pauseTrack();
      case 'pause':
        if (isPlaying) pauseTrack();
      case 'stop':
        if (Platform.isLinux) {
          _stopPlaybackAtQueueEnd();
          seekTo(Duration.zero);
        } else if (isPlaying) {
          pauseTrack();
        }
      case 'toggle':
        pauseTrack();
      case 'next':
        nextTrack();
      case 'previous':
        prevTrack();
      case 'seek':
        if (position != null) seekTo(position);
    }
  }

  void _syncLinuxMediaSession() {
    final session = _linuxMediaSession;
    if (session == null || _stateDisposing) return;
    final track = playingIndex >= 0 && playingIndex < playingQueue.length
        ? playingTrack
        : null;
    final artists = [
      for (final artist in track?['artists'] as List? ?? [])
        if (artist is Map && artist['name'] is String) artist['name'] as String,
    ];
    if (track != null && artists.isEmpty) artists.add(trackArtistLabel(track));
    session.update(
      id: track?['id'] as int?,
      localDigest: localTrackDigest(track),
      title: track?['title']?.toString() ?? '',
      artists: artists,
      album: track?['album']?['title']?.toString(),
      artwork: track == null ? null : getArtUri(track)?.toString(),
      duration: fullDurationNotifier.value,
      position: currentPositionNotifier.value,
      playing: isPlaying,
      stopped: _linuxPlaybackStopped,
      canNext: _canPlayNext,
      canPrevious: true,
      shuffled: isShuffled,
      loop: switch (loopMode) {
        LoopMode.off => 'None',
        LoopMode.list => 'Playlist',
        LoopMode.one => 'Track',
      },
      volume: volume,
    );
  }

  /// Sync current track metadata to Media3 notification.
  void _syncMediaSessionMetadata() {
    _syncLinuxMediaSession();
    if (!_mediaSessionActive || _mediaSession == null) return;
    if (playingQueue.isEmpty) return;
    final track = playingTrack;
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
    _syncLinuxMediaSession();
    if (!_mediaSessionActive || _mediaSession == null) return;
    // flutter_media_session 2.x has no audioplayers adapter yet.
    // ignore: deprecated_member_use
    _mediaSession!.updatePlaybackState(
      fms.PlaybackState(
        status: playingQueue.isEmpty
            ? fms.PlaybackStatus.idle
            : isPlaying
            ? fms.PlaybackStatus.playing
            : fms.PlaybackStatus.paused,
        position: currentPositionNotifier.value,
        speed: 1.0,
        repeatMode: switch (loopMode) {
          LoopMode.off => fms.MediaRepeatMode.none,
          LoopMode.list => fms.MediaRepeatMode.all,
          LoopMode.one => fms.MediaRepeatMode.one,
        },
        shuffleModeEnabled: isShuffled,
      ),
    );
    // No transport commands should be available with an empty queue.
    // ignore: deprecated_member_use
    _mediaSession!.updateAvailableActions(
      playingQueue.isEmpty
          ? {}
          : {
              fms.MediaAction.play,
              fms.MediaAction.pause,
              fms.MediaAction.stop,
              fms.MediaAction.seekTo,
              if (_canPlayNext) fms.MediaAction.skipToNext,
              fms.MediaAction.skipToPrevious,
            },
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
    if (downloadedOnly.value || _stateDisposing) return false;
    final revision = downloadedOnly.revision;
    final absolutePath = file.absolute.path;
    final path = Platform.isWindows ? absolutePath.toLowerCase() : absolutePath;
    final key = '$revision:$path';
    final pending = _coverDownloads[key];
    if (pending != null) return pending;

    final operation = _downloadAndCropCoverOnce(url, file, revision);
    _coverDownloads[key] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_coverDownloads[key], operation)) {
        _coverDownloads.remove(key);
      }
    }
  }

  Future<bool> _downloadAndCropCoverOnce(
    String url,
    File file,
    int revision,
  ) async {
    try {
      final res = await _serverClient
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200 && _catalogRequestCurrent(revision)) {
        final jpegBytes = await compute(cropCoverBytes, res.bodyBytes);
        if (jpegBytes != null && _catalogRequestCurrent(revision)) {
          await atomicFileStore.writeBytesLazy(file, () {
            if (!_catalogRequestCurrent(revision)) {
              throw http.RequestAbortedException();
            }
            return jpegBytes;
          });
          return _catalogRequestCurrent(revision);
        }
      }
    } catch (e) {
      if (_catalogRequestCurrent(revision)) {
        debugPrint('Error downloading or cropping cover: $e');
      }
    }
    return false;
  }

  /// Asynchronously download cover art to local storage for the lock screen widget
  Future<void> _ensureCoverDownloaded(dynamic track) async {
    if (isDesktop ||
        localPath.isEmpty ||
        isLocalMusic(track) ||
        downloadedOnly.value) {
      return;
    }
    final revision = downloadedOnly.revision;
    final id = track['id'];
    final coverFile = File('$localPath/cover_$id.jpg');

    if (await _isCoverValidAndSquare(coverFile)) return;
    if (!_catalogRequestCurrent(revision)) return;

    final success = await _downloadAndCropCover(
      track['album']['cover'].toString(),
      coverFile,
    );
    if (success && _catalogRequestCurrent(revision)) {
      invalidateTrackCover(track['id'] as int);
      _syncMediaSessionMetadata();
    }
  }

  // ── Player state ─────────────────────────────────────────────────────────
  int dummyVar = 0;
  bool isPremium = true;
  int playCount = 0;
  List<dynamic> cachedTracks = [];
  List<dynamic>? _serverTrackCache;
  List<dynamic> get _serverTracks => _serverTrackCache ?? cachedTracks;
  TrackDetailsStore? _trackDetails;
  List<LocalMusicEntry> _ownEntries = const [];
  Map<int, Map<String, Object?>> _ownTracks = const {};
  Set<int> _matchedLocalServerIds = const {};
  int _ownCatalogRevision = 0;
  bool _ownCatalogRead = false;
  bool _localImportOpen = false;
  bool _localRemovalOpen = false;
  LocalMusicServerMatchClient? _localMusicServer;
  Future<void> _localMatchTail = Future<void>.value();
  final _pendingLocalMatches = <String>{};
  List<dynamic> cachedArtists = [];
  WindowsTaskbarControls? _taskbarControls;
  int? _artistSyncRevision;
  bool _isRefreshingArtistPhotos = false;
  final Map<int, Map> _artistPhotoQueue = {};
  final http.Client _serverClient = downloadedOnly.client();
  bool _isRefreshingArtwork = false;
  final ValueNotifier<int> _artistLibraryChanges = ValueNotifier<int>(0);
  bool isLoading = true;
  bool isPlaying = false;
  final _playbackOrder = PlaybackOrder();
  final _playNextChanges = ValueNotifier<int>(0);
  List<dynamic> get playingQueue => _playbackOrder.baseTracks;
  int get playingIndex => _playbackOrder.baseIndex;
  dynamic get playingTrack => _playbackOrder.current?.track;
  set playingQueue(List<dynamic> value) => _playbackOrder.reset(value, 0);
  set playingIndex(int value) => _playbackOrder.jumpToBase(value);
  int? playingPlaylistId;
  Future<void> _playlistReorderTail = Future<void>.value();
  bool _pickingPlaylistBackground = false;
  int? discordStart;
  LoopMode loopMode = LoopMode.off;
  int navId = 0;
  final trackSelection = TrackSelection();
  Future<void> _favoritesTail = Future<void>.value();
  static const _defaultVolume = 0.5;
  double volume = _defaultVolume;
  double _volumeBeforeMute = _defaultVolume;
  bool get _isMuted => volume == 0;

  // Shuffle
  bool get isShuffled => _playbackOrder.shuffled;

  Timer? backgroundPollingTimer;
  DiscordPresencePublisher? _discordPresence;
  // ignore: unused_field
  int _syncTicks = 0;

  // ── Vinyl rotation animation (desktop) ───────────────────────────────────
  AnimationController? _vinylController;
  bool _vinylUserStopped = false;

  VideoPlayerController? _videoController;
  final _visibleClip = ValueNotifier<VideoPlayerController?>(null);
  late final _clipPreviewCache = ClipPreviewCache(Directory(localPath));
  final _clipPreviewGate = ClipRetryGate();
  int? _expandedClipTrack;
  VideoPlayerController? _initializingVideoController;
  bool _isVideoInitialized = false;
  Duration? _lastBenchmarkVideoPosition;
  late final MediaFileDownloader _mediaFileDownloader = MediaFileDownloader(
    client: _serverClient,
  );
  TrackUpdateMonitor? _trackUpdates;
  final catalogSyncStatus = CatalogSyncStatus();
  String _lastUpdateNotice = '';
  bool _updateDialogOpen = false;
  MediaFileDownloader? _foregroundVideoDownloader;
  final AsyncTaskLimiter _downloadTaskLimiter = AsyncTaskLimiter(2);
  final AsyncTaskLimiter _clipTaskLimiter = AsyncTaskLimiter(1);
  final AsyncTaskLimiter _foregroundClipTaskLimiter = AsyncTaskLimiter(1);
  final AsyncTaskLimiter _clipTransportLimiter = AsyncTaskLimiter(2);
  final Map<int, _SharedClipGeneration> _clipGenerationRequests =
      <int, _SharedClipGeneration>{};
  Future<void> _audioWork = Future<void>.value();
  Future<void> _videoWork = Future<void>.value();
  Timer? _videoReleaseTimer;
  Timer? _videoTrackSwitchTimer;
  int _videoRevision = 0;
  _VideoOperation? _videoOperation;
  int? _videoTrackId;
  String? _videoSourcePath;
  bool _videoLifecycleVisible = true;
  bool _videoRouteVisible = true;
  bool _videoSurfaceAvailable = false;
  bool get _videoVisible => _videoLifecycleVisible && _videoRouteVisible;
  bool _stateDisposing = false;
  int _trackRevision = 0;
  int _transportRevision = 0;
  int _seekRevision = 0;
  int? _fadeSeekRevision;
  int _databaseSyncRevision = 0;
  int? _audioSourceTrackId;
  bool _audioSourceLocal = false;
  bool _openingRemoteAudio = false;
  bool _resumeNeedsSource = false;
  int _settledTrackRevision = -1;
  int _lyricsRevision = 0;
  LyricTimingStore? _lyricTimingStore;
  LyricTextEditStore? _lyricTextEditStore;
  ({String contents, int trackId, int revision})? _pendingTimedLyrics;
  final _lyricTiming = ValueNotifier<LyricTimingSession?>(null);
  LyricTimingProposalClient? _lyricTimingProposals;
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
  final _videoDisposals = Expando<Future<void>>();

  final ValueNotifier<Duration> fullDurationNotifier = ValueNotifier(
    Duration.zero,
  );
  final ValueNotifier<Duration> currentPositionNotifier = ValueNotifier(
    Duration.zero,
  );

  String localPath = "";
  bool _loadingStorageProfile = false;
  bool _clearingArtwork = false;
  Set<int> downloadQueue = {};
  final Map<int, Future<TrackDownloadResult>> _mediaDownloadTasks = {};
  final Map<int, dynamic> _pendingDownloadRemovals = {};
  bool _drainingDownloadRemovals = false;
  bool _downloadRecoveryFailed = false;
  final Map<int, String> _unavailableVideoSignatures = {};
  final ClipRetryGate _clipRetryGate = ClipRetryGate();
  bool _bulkDownloadActive = false;
  Completer<void>? _bulkDownloadFinished;
  Set<int> favs = {};

  List<Map<String, dynamic>> myPlaylists = [];
  final Map<String, int> _playlistArtworkVersions = {};

  final TextEditingController searchInput = TextEditingController();
  final FocusNode searchFocusNode = FocusNode();
  String searchQuery = "";
  LyricsSearchIndex lyricsSearchIndex = LyricsSearchIndex();
  Timer? _lyricsSearchTimer;
  int _lyricsSearchQueryRevision = 0;
  bool _preparingLyricsSearch = false;
  bool isSearchLoading = false;
  bool _retryingAlbumTrack = false;
  String? _albumImportProgress;
  bool _importErrorsOpen = false;

  // ═══════════════════════════════════════════════════════════════════════════
  //  Lifecycle
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    downloadedOnly.addListener(_onDownloadedOnlyChanged);
    WidgetsBinding.instance.addObserver(this);
    _videoLifecycleVisible = !_isVideoHiddenLifecycle(
      WidgetsBinding.instance.lifecycleState,
    );

    // React to vinyl rotation toggle changes from Settings
    vinylRotationNotifier.addListener(_onVinylRotationChanged);
    if (isDesktop && !PerformanceFrameMonitor.enabled) {
      _discordPresence = DiscordPresencePublisher(
        canPublish: _canPublishDiscord,
        buildActivity: _buildDiscordActivity,
        cancelArtwork: () {
          _discordCovers?.cancelPending();
          _discordArtwork?.cancelPending();
        },
        connect: () => FlutterDiscordRPC.instance.connect(),
        setActivity: (activity) => FlutterDiscordRPC.instance.setActivity(
          activity: activity,
          reconnectOnBrokenPipe: false,
        ),
        clearActivity: () async {
          final rpc = FlutterDiscordRPC.instance;
          await rpc.clearActivity();
          return rpc.isConnected;
        },
        disconnect: () => FlutterDiscordRPC.instance.disconnect(),
        onError: (error) => debugPrint('Discord RPC: ${error.runtimeType}'),
      );
      discordPrivacyNotifier.addListener(_onDiscordSettingChanged);
      discordShowGitHubButtonNotifier.addListener(_onDiscordSettingChanged);
      discordLyricsStatusNotifier.addListener(_onDiscordSettingChanged);
    }

    // Synchronize video player actions
    activeTrackNotifier.addListener(_onActiveTrackChanged);
    isPlayingNotifier.addListener(_syncVideoPlayState);
    playVideoClipNotifier.addListener(_onVideoSettingChanged);
    uiSignal.addListener(_syncVideoDrift);

    _androidDeckUsesSharedFocus =
        Platform.isAndroid && _transitionMode == TrackTransitionMode.crossfade;
    _audioDeck = _newAudioDeck(sharedAndroidFocus: _androidDeckUsesSharedFocus);
    trackTransitionModeNotifier.addListener(_onTrackFadeChanged);
    replayGainEnabledNotifier.addListener(_onReplayGainChanged);
    _configureFadeTail();
    _subscribeToAudioDeck();
    if (isAudioServiceActive) {
      audioHandler.attachPlayer(audioPlayer);
    }
    if (Platform.isWindows && !PerformanceFrameMonitor.enabled) {
      _taskbarControls = WindowsTaskbarControls(onAction: _onTaskbarAction);
      activeTrackNotifier.addListener(_syncTaskbarControls);
      isPlayingNotifier.addListener(_syncTaskbarControls);
      languageNotifier.addListener(_syncTaskbarControls);
      _syncTaskbarControls();
    }

    if (supportsVinylRotation) {
      _vinylController = AnimationController(
        duration: const Duration(seconds: 10),
        vsync: this,
      );
    }

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
      audioHandler.onSeekStateChanged = (seeking) =>
          _statistics?.setSeeking(seeking);
    }

    unawaited(_setPlaybackVolume(volume));

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
        final revision = _trackRevision;
        final pos = _useLiveLyricPosition
            ? currentPositionNotifier.value
            : await audioPlayer.getCurrentPosition();
        if (pos != null && _isCurrentTrackRevision(revision)) {
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
    // Overlay disables TickerMode only below an opaque route. Dialogs and
    // transparent overlays must leave the still-visible video untouched.
    final routeVisible = TickerMode.valuesOf(context).enabled;
    final routeChanged = _videoRouteVisible != routeVisible;
    _videoRouteVisible = routeVisible;
    final surfaceAvailable = MediaQuery.sizeOf(context).width >= 800;
    if (_videoSurfaceAvailable != surfaceAvailable) {
      _videoSurfaceAvailable = surfaceAvailable;
      if (!surfaceAvailable) _expandedClipTrack = null;
      _initializeVideo(activeTrackNotifier.value);
    }
    if (routeChanged) _reconcileVideoVisibility();
  }

  @override
  void dispose() {
    _stateDisposing = true;
    downloadedOnly.removeListener(_onDownloadedOnlyChanged);
    trackTransitionModeNotifier.removeListener(_onTrackFadeChanged);
    replayGainEnabledNotifier.removeListener(_onReplayGainChanged);
    _crossfade?.cancel();
    unawaited(_androidPlaybackFocus?.dispose().catchError(_logAudioError));
    activeTrackNotifier.removeListener(_syncTaskbarControls);
    isPlayingNotifier.removeListener(_syncTaskbarControls);
    languageNotifier.removeListener(_syncTaskbarControls);
    _taskbarControls?.dispose();
    unawaited(_statisticsStateSubscription?.cancel());
    unawaited(
      _statistics?.close().catchError((Object error) {
        debugPrint('Listening statistics close failed: $error');
      }),
    );
    if (isAudioServiceActive) audioHandler.onSeekStateChanged = null;
    _discordArtwork?.dispose();
    _discordCovers?.dispose();
    _serverClient.close();
    _localMusicServer?.close();
    _artistPhotoQueue.clear();
    _trackUpdates?.offers.removeListener(_onTrackUpdates);
    _trackUpdates?.dispose();
    catalogSyncStatus.dispose();
    _trackRevision += 1;
    _transportRevision += 1;
    _seekRevision += 1;
    _databaseSyncRevision += 1;
    _videoRevision += 1;
    _lyricsRevision += 1;
    _lyricTiming.dispose();
    _playNextChanges.dispose();
    _lyricTimingProposals?.close();
    _videoOperation?.cancel();
    _videoOperation = null;
    _videoReleaseTimer?.cancel();
    _videoTrackSwitchTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    vinylRotationNotifier.removeListener(_onVinylRotationChanged);
    discordPrivacyNotifier.removeListener(_onDiscordSettingChanged);
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
    _visibleClip.dispose();
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
    unawaited(_mediaFileDownloader.close());
    unawaited(_foregroundVideoDownloader?.close());
    unawaited(_audioDurationSubscription?.cancel());
    unawaited(_audioPositionSubscription?.cancel());
    unawaited(_audioCompleteSubscription?.cancel());
    HardwareKeyboard.instance.removeHandler(_handleGlobalKeys);
    searchInput.dispose();
    _lyricsSearchTimer?.cancel();
    lyricsSearchIndex.dispose();
    searchFocusNode.dispose();
    backgroundPollingTimer?.cancel();
    if (_mediaSessionActive) {
      _mediaSession?.deactivate();
    }
    unawaited(_linuxMediaSession?.close());
    fullDurationNotifier.dispose();
    currentPositionNotifier.dispose();
    _vinylController?.dispose();
    _artistLibraryChanges.dispose();

    if (_discordPresence != null) {
      unawaited(_disposeDiscordRpc());
    } else if (!isDesktop) {
      WakelockPlus.disable();
    }

    unawaited(_audioDeck.dispose().catchError(_logAudioError));
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
      _updateCatalogActivity();
      if (isPlaying && vinylRotationNotifier.value && !_vinylUserStopped) {
        _vinylController?.repeat();
      }
      _reconcileVideoVisibility();
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
    _updateCatalogActivity();
    if (!wasVisible && state != AppLifecycleState.detached) {
      return;
    }
    _vinylController?.stop();
    _reconcileVideoVisibility(
      releaseImmediately: state == AppLifecycleState.detached,
    );
  }

  void _reconcileVideoVisibility({bool releaseImmediately = false}) {
    if (!supportsVideoClips) return;
    _videoReleaseTimer?.cancel();
    _videoReleaseTimer = null;
    if (_videoVisible) {
      _initializeVideo(activeTrackNotifier.value);
      return;
    }
    _videoTrackSwitchTimer?.cancel();
    _videoRevision += 1;
    _videoOperation?.cancel();
    _videoOperation = null;
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
      if (!_videoVisible && current != null) {
        await _pauseVideoController(current);
      }
    });

    if (releaseImmediately) {
      _initializeVideo(activeTrackNotifier.value);
      return;
    }
    _videoReleaseTimer = Timer(const Duration(milliseconds: 500), () {
      if (!_stateDisposing && !_videoVisible) {
        _initializeVideo(activeTrackNotifier.value);
      }
    });
  }

  Future<void> _disposeDiscordRpc() async {
    try {
      await _discordPresence?.close();
      await FlutterDiscordRPC.instance.dispose();
    } catch (error) {
      debugPrint('Discord RPC dispose failed: ${error.runtimeType}');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Helpers
  // ═══════════════════════════════════════════════════════════════════════════

  void _onActiveTrackChanged() {
    if (!mounted || !supportsVideoClips) return;
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
    _expandedClipTrack = null;
    _visibleClip.value = null;
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
    if (!supportsVideoClips) return;
    _enqueueVideoWork(() async {
      final controller = _videoController;
      if (controller == null || !_isVideoInitialized) return;
      await _applyVideoPlaybackState(controller);
    });
  }

  void _onVideoSettingChanged() {
    if (mounted && supportsVideoClips) {
      if (!playVideoClipNotifier.value) _expandedClipTrack = null;
      _crossfade?.cancel(allowRetry: true);
      _videoTrackSwitchTimer?.cancel();
      _videoTrackSwitchTimer = null;
      _initializeVideo(activeTrackNotifier.value);
    }
  }

  String _resolveAbsoluteUrl(String url) {
    return resolveConfiguredMediaUrl(url);
  }

  void _syncVideoDrift() {
    if (!supportsVideoClips) return;
    _enqueueVideoWork(() async {
      final controller = _videoController;
      if (controller == null ||
          !_isVideoInitialized ||
          !mounted ||
          !_videoVisible) {
        return;
      }
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
    if (downloadedOnly.value) return;
    String? signature;
    try {
      await Future<void>.delayed(_clipFetchDebounce);
      final res = await _foregroundClipTaskLimiter.run<http.Response?>(
        () async {
          final activeTrack = activeTrackNotifier.value;
          if (downloadedOnly.value ||
              !_isCurrentVideoOperation(revision, operation) ||
              !_videoVisible ||
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
      if (res == null ||
          downloadedOnly.value ||
          !_isCurrentVideoOperation(revision, operation)) {
        return;
      }
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
      final videoPreview = data['video_preview'];
      final requestStillCurrent =
          _isCurrentVideoOperation(revision, operation) &&
          _videoVisible &&
          _videoSurfaceAvailable &&
          playVideoClipNotifier.value &&
          activeTrackNotifier.value?['id'] == trackId;
      var changed = false;
      for (final track in _playbackOrder.retainedTracks) {
        if (track['id'] == trackId) {
          track['video_file'] = videoUrl;
          track['video_preview'] = videoPreview;
          changed = true;
        }
      }
      final currentActiveTrack = activeTrackNotifier.value;
      if (currentActiveTrack?['id'] == trackId) {
        currentActiveTrack['video_file'] = videoUrl;
        currentActiveTrack['video_preview'] = videoPreview;
        changed = true;
      }
      for (var i = 0; i < cachedTracks.length; i++) {
        if (cachedTracks[i]['id'] == trackId) {
          cachedTracks[i]['video_file'] = videoUrl;
          cachedTracks[i]['video_preview'] = videoPreview;
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
      final streamedResponse = await _serverClient
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
    for (final track in _playbackOrder.retainedTracks) {
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
    if (!supportsVideoClips) return;
    final request = _VideoRequest.from(trackData);
    _videoOperation?.cancel();
    final operation = _VideoOperation();
    _videoOperation = operation;
    final revision = ++_videoRevision;
    _enqueueVideoWork(() => _applyVideoRequest(request, revision, operation));
  }

  void _setClipExpanded(int trackId, bool expanded) {
    final track = activeTrackNotifier.value;
    if (_stateDisposing ||
        track?['id'] != trackId ||
        (!expanded && _expandedClipTrack != trackId)) {
      return;
    }
    setState(() => _expandedClipTrack = expanded ? trackId : null);
    if (_VideoRequest.from(track).preview != null) _initializeVideo(track);
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
      supportsVideoClips &&
      _videoVisible &&
      _videoSurfaceAvailable &&
      playVideoClipNotifier.value &&
      request.trackId != null;

  Future<void> _applyVideoRequest(
    _VideoRequest request,
    int revision,
    _VideoOperation operation,
  ) async {
    if (!_isCurrentVideoOperation(revision, operation)) return;
    if (!_shouldRunVideo(request)) {
      await _disposeCurrentVideo();
      return;
    }

    final trackId = request.trackId!;
    if (_videoTrackId != null && _videoTrackId != trackId) {
      await _disposeCurrentVideo();
      if (!_isCurrentVideoOperation(revision, operation)) return;
    }
    final original = _localVideoFile(trackId);
    final hasOriginal = await _hasNonEmptyFile(original);
    final reference = request.preview;
    final previewSignature = reference?.endpoint.toString();
    final allowPreview =
        previewSignature != null &&
        _clipPreviewGate.canRequest(trackId, previewSignature);
    final cachedPreview = allowPreview && reference != null
        ? await _clipPreviewCache.read(reference)
        : null;
    // A downloaded original can be an older edition the user chose to keep.
    final preview =
        cachedPreview == null ||
            (hasOriginal &&
                !await _clipPreviewCache.matchesOriginal(
                  cachedPreview,
                  original,
                ))
        ? null
        : cachedPreview;
    if (!_isCurrentVideoOperation(revision, operation)) return;
    final originalBlocked = _blockedVideoSources.contains(
      _videoSourceKey(request),
    );
    final originalReady = hasOriginal && (!originalBlocked || preview == null);
    final canDownload = !downloadedOnly.value && !_downloadRecoveryFailed;
    final plan = planClipPlayback(
      expanded: _expandedClipTrack == trackId,
      originalReady: originalReady,
      previewReady: preview != null,
      canFetchPreview: canDownload && allowPreview && cachedPreview == null,
      canFetchOriginal: canDownload && !originalBlocked,
    );
    if (plan.fetchPreview && reference != null) {
      unawaited(
        _downloadClipPreview(reference, trackId, original, revision, operation),
      );
    }
    if (plan.fetchOriginal) {
      final videoFileUrl = request.videoUrl;
      if (videoFileUrl == null) {
        unawaited(_fetchAndDownloadClip(trackId, revision, operation));
      } else {
        unawaited(
          _downloadVideoForPlayback(
            request: request,
            revision: revision,
            operation: operation,
            destination: original,
            expectedSha256: preview?.originalSha256,
          ),
        );
      }
    }

    final localVideoFile = plan.usePreview
        ? preview?.file
        : originalReady
        ? original
        : null;
    final current = _videoController;
    if (localVideoFile != null &&
        current != null &&
        _videoSourcePath == localVideoFile.path &&
        current.value.isInitialized) {
      await _synchronizeVideoController(current);
      if (_isCurrentVideoOperation(revision, operation) &&
          _shouldRunVideo(request)) {
        _isVideoInitialized = true;
        _visibleClip.value = current;
        _lastBenchmarkVideoPosition = null;
        if (mounted) setState(() {});
      }
      return;
    }

    await _disposeCurrentVideo();
    if (localVideoFile == null ||
        !_isCurrentVideoOperation(revision, operation)) {
      return;
    }

    ensureLocalVideoBackend();
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
      if (!plan.usePreview) {
        _blockedVideoSources.remove(_videoSourceKey(request));
      }
      installed = true;
      _visibleClip.value = controller;
      if (mounted) setState(() {});
    } catch (error) {
      await _disposeVideoController(controller);
      if (_isCurrentVideoOperation(revision, operation)) {
        if (plan.usePreview && previewSignature != null) {
          _clipPreviewGate.recordFailure(
            trackId,
            previewSignature,
            const Duration(minutes: 30),
          );
          _initializeVideo(activeTrackNotifier.value);
        } else if (preview != null && _expandedClipTrack == trackId) {
          // Preserve both files when the platform can play only the small one.
          _blockedVideoSources.add(_videoSourceKey(request));
          _initializeVideo(activeTrackNotifier.value);
        } else {
          await _handleLocalVideoInitializationFailure(
            request: request,
            revision: revision,
            operation: operation,
            localVideoFile: localVideoFile,
            error: error,
            initializationCompleted: initializationCompleted,
          );
        }
      }
    } finally {
      if (identical(_initializingVideoController, controller)) {
        _initializingVideoController = null;
      }
      if (!installed) {
        await _disposeVideoController(controller);
      }
    }
  }

  MediaFileDownloader get _playbackVideoDownloader =>
      _foregroundVideoDownloader ??= MediaFileDownloader(
        client: _serverClient,
        maxConcurrent: 1,
      );

  Future<void> _downloadClipPreview(
    ClipPreviewReference reference,
    int trackId,
    File original,
    int revision,
    _VideoOperation operation,
  ) async {
    ClipPreviewAsset? asset;
    try {
      asset = await _clipPreviewCache.fetch(
        reference,
        _serverClient,
        _playbackVideoDownloader,
        abort: operation.whenCanceled,
        acceptOriginal: (digest) async {
          if (!await _hasNonEmptyFile(original)) return !operation.isCanceled;
          return await _clipPreviewCache.matchesDigest(digest, original) &&
              !operation.isCanceled;
        },
      );
    } catch (error) {
      if (!operation.isCanceled) {
        debugPrint('Clip preview unavailable: ${error.runtimeType}');
      }
    }
    if (!_isCurrentVideoOperation(revision, operation)) return;
    if (asset == null) {
      _clipPreviewGate.recordFailure(
        trackId,
        reference.endpoint.toString(),
        const Duration(minutes: 2),
      );
    }
    _initializeVideo(activeTrackNotifier.value);
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
    String? expectedSha256,
  }) async {
    if (_downloadRecoveryFailed || downloadedOnly.value) return;
    final source = request.videoUrl;
    if (source == null) return;
    try {
      if (!_isCurrentVideoOperation(revision, operation) ||
          !_shouldRunVideo(request) ||
          activeTrackNotifier.value?['id'] != request.trackId) {
        return;
      }
      await _playbackVideoDownloader.download(
        source: Uri.parse(_resolveAbsoluteUrl(source)),
        destination: destination,
        abortTrigger: operation.whenCanceled,
        expectedSha256: expectedSha256,
      );
      if (!_isCurrentVideoOperation(revision, operation)) return;
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
      if (downloadedTrack is Map &&
          !isLocalMusic(downloadedTrack) &&
          !_stateDisposing) {
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
    if (!_videoVisible || !isPlayingNotifier.value) {
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
    _visibleClip.value = null;
    _lastBenchmarkVideoPosition = null;
    if (controller == null) {
      PerformanceFrameMonitor.markVideoControllerReleased();
      return;
    }
    if (mounted && !_stateDisposing) setState(() {});
    await _disposeVideoController(controller);
    unawaited(_drainDownloadRemovals());
    PerformanceFrameMonitor.markVideoControllerReleased();
  }

  Future<void> _disposeVideoController(VideoPlayerController controller) =>
      _videoDisposals[controller] ??= _releaseVideoController(controller);

  Future<void> _releaseVideoController(VideoPlayerController controller) async {
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
    final controller = _vinylController;
    if (controller == null) return;
    final enabled = vinylRotationNotifier.value;
    if (!enabled) {
      controller.stop();
      controller.value = 0.0;
      _vinylUserStopped = true;
    } else if (isPlaying && !_vinylUserStopped && _videoLifecycleVisible) {
      controller.repeat();
    }
  }

  void _onDiscordSettingChanged() {
    updateRPC(force: true);
  }

  void _syncTaskbarControls() {
    if (_stateDisposing || _taskbarControls == null) return;
    final hasTrack = playingIndex >= 0 && playingIndex < playingQueue.length;
    final favorite = hasTrack && favs.contains(playingTrack['id']);
    unawaited(
      _taskbarControls!.update(
        hasTrack: hasTrack,
        playing: isPlaying,
        favorite: favorite,
        favoriteTip: tr(
          favorite ? 'taskbar_favorite_remove' : 'taskbar_favorite_add',
        ),
        previousTip: tr('taskbar_previous'),
        playPauseTip: tr(isPlaying ? 'taskbar_pause' : 'taskbar_play'),
        nextTip: tr('taskbar_next'),
      ),
    );
  }

  Future<void> _onTaskbarAction(String action) async {
    if (!mounted ||
        _stateDisposing ||
        playingIndex < 0 ||
        playingIndex >= playingQueue.length) {
      return;
    }
    switch (action) {
      case 'favorite':
        await toggleFavorite(playingTrack['id'] as int);
      case 'previous':
        prevTrack();
      case 'toggle':
        pauseTrack();
      case 'next':
        nextTrack();
    }
  }

  void _setPlaying(bool value) {
    if (value) _linuxPlaybackStopped = false;
    if (mounted) setState(() => isPlaying = value);
    isPlayingNotifier.value = value;
    if (!value && discordPrivacyNotifier.value.hideOnPause) {
      updateRPC(force: true);
    }
    _updateCatalogActivity();
    if (value &&
        !_vinylUserStopped &&
        vinylRotationNotifier.value &&
        _videoLifecycleVisible) {
      _vinylController?.repeat();
    } else if (!value || !vinylRotationNotifier.value) {
      _vinylController?.stop();
      if (!vinylRotationNotifier.value) _vinylController?.value = 0.0;
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

  void _updateCatalogActivity() => _trackUpdates?.setActivity(
    visible: _videoLifecycleVisible,
    playing: isPlaying,
  );

  void _onDownloadedOnlyChanged() {
    final paused = downloadedOnly.value;
    _databaseSyncRevision++;
    catalogSyncStatus.reset();
    _trackUpdates?.setNetworkPaused(paused);
    if (paused) {
      _artistPhotoQueue.clear();
      _videoOperation?.cancel();
    }
    clearCoverCache();
    if (_videoVisible) _initializeVideo(activeTrackNotifier.value);
    final track = activeTrackNotifier.value;
    if (track != null && isAudioServiceActive) {
      final item = audioHandler.mediaItem.value;
      if (item != null) {
        audioHandler.mediaItem.add(item.copyWith(artUri: getArtUri(track)));
      }
    }
    _crossfade?.reconcileNextSource();
    _syncMediaSessionMetadata();
    _syncMediaSessionPlayback();
    _notifyPlayNext();
    updateRPC(force: true);
    if (mounted) setState(() {});
  }

  bool _showDownloadedOnlyNotice() {
    if (!downloadedOnly.value) return false;
    if (mounted) _playNextNotice(tr('downloaded_only_action'));
    return true;
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
    _crossfade?.cancel(allowRetry: true);
    loopModeNotifier.value = loopMode;
    _syncMediaSessionPlayback();
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
    if (trackSelection.isNotEmpty &&
        event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        ModalRoute.of(context)?.isCurrent == true) {
      clearTrackSelection();
      return true;
    }
    return handlePlaybackSpace(event, onToggle: pauseTrack);
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

      if (command.scenario.startsWith('focused-')) {
        await _runFocusedBenchmark(command);
      } else if (command.scenario == 'cold-start-server-offline' ||
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

  Future<void> _runFocusedBenchmark(BenchmarkScenarioCommand command) async {
    final video = command.scenario != 'focused-audio';
    if (!const {
      'focused-audio',
      'focused-video',
      'focused-settings',
      'focused-artist',
    }.contains(command.scenario)) {
      throw StateError('Unknown focused benchmark: ${command.scenario}');
    }
    if (video) {
      await _prepareBenchmarkVideo(command.runId, _benchmarkVideo60TrackId);
    } else {
      await _prepareBenchmarkAudio(command.runId, _benchmarkVideo30TrackId);
    }
    await _setPlaybackVolume(0);
    final covered =
        command.scenario == 'focused-settings' ||
        command.scenario == 'focused-artist';
    if (command.scenario == 'focused-settings') _openSettings();
    if (command.scenario == 'focused-artist') {
      _openArtistScreen(62000, 'Benchmark artist');
    }
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 750));
    await _markBenchmarkReadyAndComplete(command);
    await PerformanceFrameMonitor.waitForCapture(command.runId);
    final eventsBefore = _benchmarkPositionEvents;
    final audioBefore = await audioPlayer.getCurrentPosition();
    await PerformanceFrameMonitor.waitForCaptureEnd(command.runId);
    final events = _benchmarkPositionEvents - eventsBefore;
    final audioAfter = await audioPlayer.getCurrentPosition();
    final controllerAlive = _videoController != null;
    final videoPlaying = _videoController?.value.isPlaying ?? false;
    final audioPlaying = audioPlayer.state == PlayerState.playing;
    if (!audioPlaying ||
        audioBefore == null ||
        audioAfter == null ||
        audioAfter <= audioBefore) {
      throw StateError('Audio stopped or failed to advance during capture.');
    }
    double? restoreMs;
    if (covered) {
      if (!mounted) throw StateError('Benchmark screen was disposed.');
      final clock = Stopwatch()..start();
      Navigator.of(context).pop();
      await _waitForBenchmarkCondition(
        command.runId,
        'video after covered route',
        () =>
            _isVideoInitialized &&
            _videoController?.value.isPlaying == true &&
            _videoController?.value.isBuffering == false,
      );
      restoreMs = clock.elapsedMicroseconds / 1000;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (audioPlayer.state != PlayerState.playing) {
        throw StateError('Returning from route interrupted audio.');
      }
    }
    await _verifyFocusedPlaybackControls(command.runId, video: video);
    await File('$localPath/focused_${command.runId}.json').writeAsString(
      jsonEncode({
        'runId': command.runId,
        'scenario': command.scenario,
        'positionEvents': events,
        'audioAdvanceMs': (audioAfter - audioBefore).inMilliseconds,
        'audioPlaying': audioPlaying,
        'videoControllerAlive': controllerAlive,
        'videoPlaying': videoPlaying,
        'restoreVideoMs': restoreMs,
        'playbackControlsPassed': true,
        'imageCacheBytes': PaintingBinding.instance.imageCache.currentSizeBytes,
      }),
    );
  }

  Future<void> _verifyFocusedPlaybackControls(
    String runId, {
    required bool video,
  }) async {
    if (video) {
      if (!mounted) throw StateError('Benchmark screen was disposed.');
      final controller = _videoController;
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(content: Text('Benchmark dialog')),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 750));
      if (!identical(controller, _videoController) ||
          controller?.value.isPlaying != true) {
        throw StateError('A transparent dialog stopped visible video.');
      }
      if (!mounted) throw StateError('Benchmark screen was disposed.');
      Navigator.of(context).pop();
    }
    pauseTrack();
    await _audioWork;
    final paused = await audioPlayer.getCurrentPosition();
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final stillPaused = await audioPlayer.getCurrentPosition();
    if (audioPlayer.state != PlayerState.paused ||
        paused == null ||
        stillPaused == null ||
        (stillPaused - paused).abs() > const Duration(milliseconds: 100)) {
      throw StateError('Pause failed to freeze audio.');
    }
    seekTo(const Duration(seconds: 7));
    await _audioWork;
    await _videoWork;
    final seeked = await audioPlayer.getCurrentPosition();
    if (seeked == null ||
        (seeked - const Duration(seconds: 7)).abs() >
            const Duration(milliseconds: 300)) {
      throw StateError(
        'Explicit seek did not update native audio immediately.',
      );
    }
    pauseTrack();
    await _audioWork;
    await _waitForBenchmarkCondition(
      runId,
      'resume after pause/seek',
      () => audioPlayer.state == PlayerState.playing,
    );
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
    localPath = appDir.path;
    globalLocalPath = localPath;
    _lyricTimingStore = LyricTimingStore(appDir);
    _lyricTextEditStore = LyricTextEditStore(appDir);
    try {
      await LocalDownloadRemover(appDir).recover();
    } catch (error) {
      _downloadRecoveryFailed = true;
      debugPrint('Local download recovery needs retry: $error');
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _downloadRemovalNotice('download_recovery_failed'),
      );
    }
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
    if (!PerformanceFrameMonitor.enabled) {
      _statistics ??= ListeningStatistics(
        StatisticsStore('$localPath/listening_statistics.sqlite'),
        foreground:
            WidgetsBinding.instance.lifecycleState == null ||
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      );
    }
    if (isDesktop && !PerformanceFrameMonitor.enabled) {
      _discordCovers = DiscordCoverLookup(
        onResolved: (trackKey) {
          if (!_stateDisposing &&
              playingIndex >= 0 &&
              playingIndex < playingQueue.length &&
              DiscordCoverLookup.trackKey(playingTrack) == trackKey) {
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
              DiscordAnimatedArtwork.albumKey(playingTrack) == albumKey) {
            updateRPC();
          }
        },
      );
    }
    if (!PerformanceFrameMonitor.enabled) {
      final monitor = TrackUpdateMonitor(
        directory: appDir,
        tracks: () => _serverTracks,
        client: _serverClient,
        onCatalogChanged: _refreshLiveCatalog,
        onCheckSucceeded: catalogSyncStatus.succeeded,
        onCheckFailed: catalogSyncStatus.failed,
        includeVideo: supportsVideoClips,
      );
      _trackUpdates = monitor;
      monitor.setNetworkPaused(downloadedOnly.value);
      _updateCatalogActivity();
      await monitor.load();
      if (_stateDisposing) return;
      monitor.offers.addListener(_onTrackUpdates);
    }
    await readFavorites();
    if (_stateDisposing) return;
    await readPlaylists();
    if (_stateDisposing) return;
    final ownRevision = _ownCatalogRevision;
    try {
      final entries = await readLocalMusicCatalog(appDir);
      if (_ownCatalogRevision == ownRevision) {
        _setOwnTracks(entries);
        _projectOwnTracks(_serverTracks);
        _ownCatalogRead = true;
        await _pruneOwnTrackReferences(
          (id) => id < 0 && !_ownTracks.containsKey(id),
        );
      }
    } catch (error) {
      debugPrint('Local music catalog read failed: ${error.runtimeType}');
    }
    if (_stateDisposing) return;
    final trackDetails = TrackDetailsStore(
      appDir,
      server: configuredServerBaseUri,
    );
    _trackDetails = trackDetails;
    try {
      await trackDetails.load();
    } catch (error) {
      debugPrint('Track details read failed: ${error.runtimeType}');
    }
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
    _loadingStorageProfile = true;
    try {
      await startData();
    } catch (error, stackTrace) {
      debugPrint('Startup data load failed: $error\n$stackTrace');
    } finally {
      _loadingStorageProfile = false;
    }
  }

  Future<void> _saveState() async {
    if (localPath.isEmpty) return;
    try {
      final f = File('$localPath/app_state.json');
      final data = {
        'volume': volume,
        'volumeBeforeMute': _volumeBeforeMute,
        'loopMode': loopMode.index,
        'playingPlaylistId': playingPlaylistId,
        'position': currentPositionNotifier.value.inMilliseconds,
        ..._playbackOrder.snapshot(),
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

        final savedBeforeMute = data['volumeBeforeMute'];
        if (savedBeforeMute is num &&
            savedBeforeMute > 0 &&
            savedBeforeMute <= 1) {
          _volumeBeforeMute = savedBeforeMute.toDouble();
        }
        final savedVolume = data['volume'];
        if (savedVolume is num && savedVolume >= 0 && savedVolume <= 1) {
          volume = savedVolume.toDouble();
          await _setPlaybackVolume(volume);
        }
        final savedLoopMode = data['loopMode'];
        if (savedLoopMode is int &&
            savedLoopMode >= 0 &&
            savedLoopMode < LoopMode.values.length) {
          loopMode = LoopMode.values[savedLoopMode];
        }
        final savedQueue = data['playingQueue'];
        if (revisionBeforeRead != _trackRevision ||
            savedQueue is! List ||
            savedQueue.isEmpty) {
          return;
        }
        _playbackOrder.restore(data);
        final savedTrack = playingTrack;
        if (_ownCatalogRead) {
          _playbackOrder.removeTracks((track) {
            final digest = localTrackDigest(track);
            return digest != null &&
                digest != localTrackDigest(_ownTracks[track['id']]);
          });
          for (final track in _playbackOrder.retainedTracks) {
            final fresh = _ownTracks[track['id']];
            if (fresh != null) _updatePlaybackMetadata(track, fresh);
          }
        }
        for (final track in _playbackOrder.retainedTracks) {
          _trackDetails?.bind(track);
        }
        if (_playbackOrder.current == null) return;
        isShuffledNotifier.value = isShuffled;
        loopModeNotifier.value = loopMode;
        playingPlaylistId = data['playingPlaylistId'] is int
            ? data['playingPlaylistId'] as int
            : null;
        final targetTrack = playingTrack;
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

        final savedPosition = identical(savedTrack, targetTrack)
            ? data['position']
            : null;
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

  Future<bool> savePlaylists() async {
    try {
      final f = File('$localPath/my_playlists.json');
      final snapshot = json.encode(myPlaylists);
      await atomicFileStore.writeString(f, snapshot);
      return true;
    } catch (error) {
      debugPrint('Playlist save failed: $error');
      if (mounted && !_stateDisposing) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('playlist_save_failed'))));
      }
      return false;
    }
  }

  Future<bool> updatePlaylistDetails(
    int playlistId,
    Map<String, dynamic> changes,
  ) async {
    final index = myPlaylists.indexWhere((p) => p['id'] == playlistId);
    if (index < 0) return false;
    final previous = Map<String, dynamic>.from(myPlaylists[index]);
    final allowed = <String, dynamic>{
      if (changes['name'] is String &&
          (changes['name'] as String).trim().isNotEmpty)
        'name': (changes['name'] as String).trim(),
      if (changes['image'] is String) 'image': changes['image'],
      if (changes.containsKey('background') &&
          (changes['background'] == null ||
              isPlaylistBackgroundName(changes['background'])))
        'background': changes['background'],
    };
    if (allowed.isEmpty) return false;
    void apply() => myPlaylists[index] = {...previous, ...allowed};
    if (mounted) {
      setState(apply);
    } else {
      apply();
    }
    if (await savePlaylists()) {
      if (allowed.containsKey('background') &&
          previous['background'] != allowed['background']) {
        await _removeUnusedPlaylistBackground(previous['background']);
      }
      return true;
    }
    final current = myPlaylists.indexWhere((p) => p['id'] == playlistId);
    if (current >= 0) {
      void restore() {
        for (final key in allowed.keys) {
          if (myPlaylists[current][key] == allowed[key]) {
            myPlaylists[current][key] = previous[key];
          }
        }
      }

      if (mounted) {
        setState(restore);
      } else {
        restore();
      }
    }
    return false;
  }

  Future<bool> setPlaylistBackgroundPhoto(int playlistId, String path) async {
    if (localPath.isEmpty ||
        _stateDisposing ||
        !myPlaylists.any((p) => p['id'] == playlistId)) {
      return false;
    }
    final directory = localPath;
    final photo = await compute(processPlaylistBackgroundPhoto, path);
    if (photo == null) throw const FormatException('Invalid playlist photo');
    if (_stateDisposing || directory != localPath) return false;

    final name = newPlaylistBackgroundName();
    await atomicFileStore.writeBytes(File('$directory/$name'), photo);
    if (_stateDisposing ||
        !await updatePlaylistDetails(playlistId, {'background': name})) {
      await _removeUnusedPlaylistBackground(name);
      return false;
    }
    return true;
  }

  Future<void> _removeUnusedPlaylistBackground(Object? name) async {
    if (localPath.isEmpty ||
        !isPlaylistBackgroundName(name) ||
        myPlaylists.any((p) => p['background'] == name)) {
      return;
    }
    final file = File('$localPath/$name');
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.file) {
        await file.delete();
      }
    } on FileSystemException {
      // The playlist is already saved; an old copy may be in use on Windows.
    }
  }

  Future<bool> createPlaylist(
    String name, {
    Iterable<int> trackIds = const [],
    String image = '',
    int? playlistId,
  }) {
    final title = name.trim();
    if (title.isEmpty) return Future.value(false);
    // Snapshot before waiting: selection and catalog may change while saving.
    final ids = trackIds.where(_isLibraryTrackId).toSet().toList();
    final work = _playlistReorderTail.then((_) async {
      if (_stateDisposing) return false;
      var id = playlistId ?? DateTime.now().microsecondsSinceEpoch;
      while (myPlaylists.any((playlist) => playlist['id'] == id)) {
        id++;
      }
      final playlist = <String, dynamic>{
        'id': id,
        'name': title,
        'image': image,
        'tracks': ids,
      };
      void add() => myPlaylists.add(playlist);
      if (mounted) {
        setState(add);
      } else {
        add();
      }
      if (await savePlaylists()) return true;
      // Only undo this creation; never replace unrelated playlists or edits.
      void restore() => myPlaylists.removeWhere((p) => identical(p, playlist));
      if (mounted) {
        setState(restore);
      } else {
        restore();
      }
      return false;
    });
    _playlistReorderTail = work.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return work;
  }

  Future<bool> reorderPlaylist(
    int playlistId,
    List<int> visibleIds,
    int oldIndex,
    int newIndex,
  ) {
    final snapshot = List<int>.of(visibleIds);
    final result = _playlistReorderTail.then(
      (_) => _reorderPlaylist(playlistId, snapshot, oldIndex, newIndex),
    );
    _playlistReorderTail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return result;
  }

  Future<bool> _reorderPlaylist(
    int playlistId,
    List<int> visibleIds,
    int oldIndex,
    int newIndex,
  ) async {
    if (_stateDisposing) return false;
    final index = myPlaylists.indexWhere((p) => p['id'] == playlistId);
    if (index < 0) return false;
    final previous = List<dynamic>.from(myPlaylists[index]['tracks']);
    final reordered = reorderPlaylistTracks(
      previous,
      visibleIds,
      oldIndex,
      newIndex,
    );
    if (listEquals(previous, reordered)) return false;
    final expectedOrder = List<dynamic>.unmodifiable(reordered);
    void apply() => myPlaylists[index]['tracks'] = reordered;
    if (mounted) {
      setState(apply);
    } else {
      apply();
    }
    final saved = await savePlaylists();
    if (_stateDisposing) return saved;
    final current = myPlaylists.indexWhere((p) => p['id'] == playlistId);
    if (!saved) {
      // Do not overwrite a newer drag, rename, or membership edit.
      if (current >= 0 &&
          identical(myPlaylists[current]['tracks'], reordered) &&
          listEquals(myPlaylists[current]['tracks'] as List, expectedOrder)) {
        void restore() => myPlaylists[current]['tracks'] = previous;
        if (mounted) {
          setState(restore);
        } else {
          restore();
        }
      }
      return false;
    }
    if (current < 0 ||
        playingPlaylistId != playlistId ||
        playingQueue.isEmpty) {
      return true;
    }
    final order = List<dynamic>.from(myPlaylists[current]['tracks']);
    if (mounted) {
      setState(() => _playbackOrder.reorderBase(order));
    } else {
      _playbackOrder.reorderBase(order);
    }
    _crossfade?.reconcileNextSource();
    _syncMediaSessionPlayback();
    await _saveState();
    return true;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Network
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _persistOfflineTracks() {
    if (localPath.isEmpty) return Future<void>.value();
    final snapshot = json.encode(_serverTracks);
    return atomicFileStore.writeString(
      File('$localPath/offline_tracks.json'),
      snapshot,
    );
  }

  bool _isLibraryTrackId(int id) => id > 0 || _ownTracks.containsKey(id);

  void _setOwnTracks(List<LocalMusicEntry> entries) {
    _ownEntries = entries;
  }

  void _projectOwnTracks(List<dynamic> serverTracks) {
    if (_ownEntries.isEmpty) {
      _ownTracks = const {};
      return;
    }
    _ownTracks = projectLocalMusic(
      _ownEntries,
      serverTracks,
      server: configuredServerBaseUri,
      unknownArtist: tr('local_import_unknown_artist'),
      unknownAlbum: tr('local_import_unknown_album'),
    );
  }

  @visibleForTesting
  void publishLocalMusic(List<LocalMusicEntry> entries) {
    if (_stateDisposing) return;
    _ownCatalogRevision++;
    _ownCatalogRead = true;
    _setOwnTracks(entries);
    for (final entry in entries) {
      invalidateTrackCover(entry.id);
    }
    _applyTracks(_serverTracks);
  }

  Future<void> showLocalMusicImport() async {
    if (!mounted ||
        localPath.isEmpty ||
        _localImportOpen ||
        _localRemovalOpen ||
        _stateDisposing) {
      return;
    }
    _localImportOpen = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => LocalMusicImportDialog(
          desktop: isDesktop,
          onImport: (files, cancel, onProgress) async {
            final revision = downloadedOnly.revision;
            final result = await importLocalMusic(
              directory: Directory(localPath),
              files: files,
              cancel: cancel,
              lookForAdjacentLyrics: isDesktop,
              onProgress: onProgress,
            );
            if (mounted && !_stateDisposing) {
              publishLocalMusic(result.entries);
              if (_catalogRequestCurrent(revision)) {
                _queueOwnMusicMatch(result.matchEntries);
              }
            }
            return result;
          },
        ),
      );
    } finally {
      _localImportOpen = false;
    }
  }

  void _queueOwnMusicMatch(
    Iterable<LocalMusicEntry> entries, {
    bool manual = false,
  }) {
    if (downloadedOnly.value) return;
    final revision = downloadedOnly.revision;
    final batch = entries
        .where((entry) => _pendingLocalMatches.add(entry.digest))
        .toList();
    if (batch.isEmpty) return;
    final endpoint = configuredServerUri(localMusicMatchPath);
    final serverKey = localMusicServerKey(configuredServerBaseUri);
    _localMatchTail = _localMatchTail.then((_) async {
      try {
        if (!_catalogRequestCurrent(revision)) return;
        final service = _localMusicServer ??= LocalMusicServerMatchClient(
          client: _serverClient,
        );
        if (!await service.isAvailable(endpoint)) {
          if (manual && _catalogRequestCurrent(revision)) {
            _localMusicNotice(tr('local_match_unavailable'));
          }
          return;
        }
        final counts = <LocalMusicMatchOutcome, int>{};
        for (final entry in batch) {
          if (!_catalogRequestCurrent(revision)) return;
          if (localTrackDigest(_ownTracks[entry.id]) != entry.digest) continue;
          final result = await service.match(
            endpoint,
            entry,
            serverKey: serverKey,
          );
          if (!_catalogRequestCurrent(revision)) return;
          if (result.metadata case final metadata?) {
            final updated = await updateLocalMusicMetadata(
              directory: Directory(localPath),
              target: entry,
              metadata: metadata,
              isCurrent: () => _catalogRequestCurrent(revision),
            );
            if (updated != null &&
                mounted &&
                _catalogRequestCurrent(revision)) {
              publishLocalMusic(updated);
            }
          }
          counts.update(
            result.outcome,
            (value) => value + 1,
            ifAbsent: () => 1,
          );
        }
        if (!_catalogRequestCurrent(revision) || counts.isEmpty) return;
        if (counts.containsKey(LocalMusicMatchOutcome.existing)) {
          await syncDatabase();
        }
        if (!_catalogRequestCurrent(revision)) return;
        _localMusicNotice(
          [
            for (final result in LocalMusicMatchOutcome.values)
              if (counts[result] case final count?)
                tr(switch (result) {
                  LocalMusicMatchOutcome.queued => 'local_match_queued',
                  LocalMusicMatchOutcome.existing => 'local_match_existing',
                  LocalMusicMatchOutcome.metadata => 'local_match_metadata',
                  LocalMusicMatchOutcome.noMatch => 'local_match_no_match',
                  LocalMusicMatchOutcome.failed => 'local_match_failed',
                }).replaceFirst('{count}', '$count'),
          ].join(' · '),
        );
      } catch (error) {
        if (!_catalogRequestCurrent(revision)) return;
        debugPrint('Local recording lookup failed: ${error.runtimeType}');
        _localMusicNotice(
          tr('local_match_failed').replaceFirst('{count}', '1'),
        );
      } finally {
        for (final entry in batch) {
          _pendingLocalMatches.remove(entry.digest);
        }
      }
    });
  }

  Future<void> _matchOwnTrack(Map track) async {
    if (_showDownloadedOnlyNotice()) return;
    final revision = downloadedOnly.revision;
    final digest = localTrackDigest(track);
    if (_stateDisposing || localPath.isEmpty || digest == null) return;
    try {
      final entries = await readLocalMusicCatalog(Directory(localPath));
      if (!_catalogRequestCurrent(revision)) return;
      _queueOwnMusicMatch(
        entries.where((entry) => entry.digest == digest),
        manual: true,
      );
    } catch (error) {
      debugPrint('Local recording metadata read failed: ${error.runtimeType}');
      _localMusicNotice(tr('local_match_failed').replaceFirst('{count}', '1'));
    }
  }

  void _localMusicNotice(String message) {
    if (!mounted || _stateDisposing) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _confirmRemoveOwnTrack(Map track) async {
    if (!isLocalMusic(track) ||
        !mounted ||
        _stateDisposing ||
        localPath.isEmpty ||
        _localImportOpen ||
        _localRemovalOpen) {
      return;
    }
    _localRemovalOpen = true;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(tr('local_track_remove')),
          scrollable: true,
          content: Text(
            tr(
              'local_track_remove_confirm',
            ).replaceFirst('{title}', track['title']?.toString() ?? ''),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tr('cancel')),
            ),
            TextButton(
              key: const ValueKey('confirm_local_music_removal'),
              onPressed: () => Navigator.pop(dialogContext, true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(dialogContext).colorScheme.error,
              ),
              child: Text(tr('local_track_remove_action')),
            ),
          ],
        ),
      );
      if (confirmed == true) await deleteLocalTrack(track);
    } finally {
      _localRemovalOpen = false;
    }
  }

  Future<void> deleteLocalTrack(Map track) async {
    final digest = localTrackDigest(track);
    if (_stateDisposing || localPath.isEmpty || digest == null) return;
    final id = track['id'] as int;
    try {
      var referencesSaved = true;
      final outcome = await removeLocalMusic(
        directory: Directory(localPath),
        id: id,
        digest: digest,
        onRemoved: (entries) async {
          if (_stateDisposing) return;
          final release = _removeOwnTrackFromPlayback(id, digest);
          invalidateTrackCover(id);
          trackDurations.remove(id);
          publishLocalMusic(entries);
          referencesSaved = await _pruneOwnTrackReferences(
            (value) => value == id,
          );
          await release;
        },
      );
      if (outcome.removed) {
        _localMusicNotice(
          tr(
            outcome.cleanupComplete && referencesSaved
                ? 'local_track_removed'
                : 'local_track_remove_incomplete',
          ),
        );
      }
    } catch (error) {
      debugPrint('Local recording removal failed: ${error.runtimeType}');
      _localMusicNotice(tr('local_track_remove_failed'));
    }
  }

  Future<bool> _pruneOwnTrackReferences(bool Function(int) remove) async {
    await _favoritesTail;
    await _playlistReorderTail;
    if (_stateDisposing) return false;
    final liked = favs.any(remove);
    if (liked) favs.removeWhere(remove);
    var playlistsChanged = false;
    for (final playlist in myPlaylists) {
      final tracks = playlist['tracks'];
      if (tracks is List && tracks.whereType<int>().any(remove)) {
        playlist['tracks'] = tracks
            .where((id) => id is! int || !remove(id))
            .toList();
        playlistsChanged = true;
      }
    }
    if ((liked || playlistsChanged) && mounted) {
      setState(() {});
      _syncTaskbarControls();
      _notifyArtistLibraryChanged();
    }
    final saved = await Future.wait([
      if (liked) saveFavorites(),
      if (playlistsChanged) savePlaylists(),
    ]);
    return saved.every((value) => value);
  }

  Future<void> _removeOwnTrackFromPlayback(int id, String digest) async {
    final wasCurrent = localTrackDigest(playingTrack) == digest;
    final heldSource = _audioSourceTrackId == id;
    Future<void>? videoRelease;
    if (supportsVideoClips && (wasCurrent || _videoTrackId == id)) {
      _videoTrackSwitchTimer?.cancel();
      _suspendVideoForTrackTransition();
      _enqueueVideoWork(_disposeCurrentVideo);
      videoRelease = _videoWork;
    }
    final changed = _playbackOrder.removeTracks(
      (track) => localTrackDigest(track) == digest,
    );
    final crossfadeRelease = _crossfade?.releaseTrack(id);
    final outgoingRelease = _closingAudioTrackId == id
        ? _closingAudioWork
        : null;
    Future<void>? sourceRelease;
    if (wasCurrent || heldSource) {
      final deck = _audioDeck;
      sourceRelease = _enqueueAudioWork(() async {
        if (!wasCurrent && _audioSourceTrackId != id) return;
        await deck.player.release();
        deck.localAudio = null;
        _audioSourceTrackId = null;
        _audioSourceLocal = false;
        await _androidPlaybackFocus?.release();
      });
    }
    if (changed) {
      isShuffledNotifier.value = isShuffled;
      if (!wasCurrent) {
        _savePlayNextEdit();
      } else if (playingTrack != null) {
        _activateTrackForPlayback(playingTrack, play: false);
      } else {
        _trackRevision++;
        _transportRevision++;
        _seekRevision++;
        _lyricsRevision++;
        _statistics?.endTrack();
        _crossfade?.cancel();
        _trackFade.hold();
        _linuxPlaybackStopped = true;
        playingPlaylistId = null;
        discordStart = null;
        _setPlaying(false);
        activeTrackNotifier.value = null;
        currentPositionNotifier.value = Duration.zero;
        fullDurationNotifier.value = Duration.zero;
        _pendingTimedLyrics = null;
        _lyricTiming.value = null;
        globalLyrics.clear();
        currentLine = -1;
        lrcLoading = false;
        _notifyPlayNext();
        _syncMediaSessionPlayback();
        updateRPC(force: true);
        unawaited(_saveState());
      }
    }
    await Future.wait([
      ?sourceRelease,
      ?crossfadeRelease,
      ?outgoingRelease,
      ?videoRelease,
    ]);
  }

  void _localMusicMissing() {
    if (!mounted || _stateDisposing) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(tr('local_import_missing')),
        action: SnackBarAction(
          label: tr('local_import'),
          onPressed: () => unawaited(showLocalMusicImport()),
        ),
      ),
    );
  }

  Widget _buildLocalMusicButton() => IconButton(
    key: const ValueKey('open_local_music_import'),
    tooltip: tr('local_import'),
    onPressed: localPath.isEmpty
        ? null
        : () => unawaited(showLocalMusicImport()),
    icon: const Icon(
      Icons.library_add_outlined,
      color: Colors.white70,
      size: 22,
    ),
  );

  void _applyTracks(List<dynamic> serverTracks) {
    if (_stateDisposing) return;
    _serverTrackCache = serverTracks;
    _projectOwnTracks(serverTracks);
    final tracks = _ownTracks.isEmpty
        ? serverTracks
        : [...serverTracks, ..._ownTracks.values];
    for (final track in tracks) {
      _trackDetails?.bind(track);
    }
    _matchedLocalServerIds = {
      for (final track in _ownTracks.values)
        if (track['local_match_id'] case final int id)
          if (isTrackDownloadComplete(track)) id,
    };
    final freshById = {
      for (final track in tracks)
        if (track is Map) track['id']: track,
    };
    trackSelection.retain(freshById.keys.whereType<int>());
    final current = activeTrackNotifier.value;
    final currentIsOwn = isLocalMusic(current);
    final previousLyrics = currentIsOwn ? current['lyrics'] : null;
    final previousVideo = currentIsOwn ? current['video_file'] : null;
    final previousPreview = current?['video_preview'];
    // Never replace the source of an already playing MP3.
    for (final track in _playbackOrder.retainedTracks) {
      final fresh = freshById[track['id']];
      if (fresh == null || identical(fresh, track)) continue;
      _updatePlaybackMetadata(track, fresh);
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
    if (searchQuery.trim().isNotEmpty) _scheduleLyricsSearch();
    if (currentIsOwn && mounted) {
      if (previousLyrics != current['lyrics']) unawaited(fetchLyrics(current));
    }
    if (mounted &&
        supportsVideoClips &&
        playVideoClipNotifier.value &&
        (previousPreview != current?['video_preview'] ||
            (currentIsOwn && previousVideo != current['video_file']))) {
      _initializeVideo(current);
    }
    if (activeTrackNotifier.value != null) {
      uiSignal.value++;
      _syncMediaSessionMetadata();
      updateRPC(force: true);
    }
  }

  void _updatePlaybackMetadata(Map track, Map fresh) {
    if (isLocalMusic(track) &&
        localTrackDigest(track) != localTrackDigest(fresh)) {
      return;
    }
    final originalKey = _trackDetails?.bind(track);
    final incomingKey = _trackDetails?.bind(fresh);
    if (originalKey != null &&
        incomingKey != null &&
        originalKey != incomingKey) {
      // A reused catalog ID must not replace the queued recording.
      return;
    }
    for (final key in [
      'title',
      'album',
      'artists',
      'duration',
      'audio_file',
      'video_file',
      'video_preview',
      'lyrics',
      'content_versions',
      'local_match_id',
    ]) {
      track[key] = fresh[key];
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
    if (tracks != null || _ownTracks.isNotEmpty) _applyTracks(tracks ?? []);
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
    if (localPath.isEmpty || _stateDisposing || downloadedOnly.value) return;
    final revision = downloadedOnly.revision;
    if (_artistSyncRevision == revision) {
      if (reportFailure) {
        throw StateError('Artist catalog refresh still running');
      }
      return;
    }
    _artistSyncRevision = revision;
    try {
      final uri = configuredServerUri('/api/artists/');
      final res = await _serverClient
          .get(uri)
          .timeout(const Duration(seconds: 8));
      if (!_catalogRequestCurrent(revision)) return;
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
          if (!_catalogRequestCurrent(revision)) return;
          if (mounted) setState(() {});

          // The list already contains name, bio and photo. No eager detail HTTP
          // request per artist; full albums are loaded only when the page opens.
          for (final artist in artistsList) {
            if (!_catalogRequestCurrent(revision)) return;
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
                if (!_catalogRequestCurrent(revision)) return;
                await atomicFileStore.writeStringLazy(detailFile, () {
                  if (!_catalogRequestCurrent(revision)) {
                    throw http.RequestAbortedException();
                  }
                  return json.encode({...details, ...artist});
                });
              }
            } catch (_) {}

            if (!_catalogRequestCurrent(revision)) return;
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
      if (!_catalogRequestCurrent(revision)) return;
      if (reportFailure) rethrow;
      debugPrint('Artists cache sync notice (working offline): $e');
    } finally {
      if (_artistSyncRevision == revision) _artistSyncRevision = null;
    }
  }

  Future<void> _refreshArtistPhotos() async {
    if (_isRefreshingArtistPhotos || _stateDisposing || downloadedOnly.value) {
      return;
    }
    final revision = downloadedOnly.revision;
    _isRefreshingArtistPhotos = true;
    try {
      // One worker, deduplicated IDs. Optional photos never hold revision polling.
      while (_artistPhotoQueue.isNotEmpty && _catalogRequestCurrent(revision)) {
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
          if (!_catalogRequestCurrent(revision)) return;
          final response = await _serverClient
              .get(Uri.parse(_resolveAbsoluteUrl(url)))
              .timeout(const Duration(seconds: 10));
          if (!_catalogRequestCurrent(revision)) return;
          if (response.statusCode == HttpStatus.ok &&
              response.bodyBytes.length > 500) {
            await atomicFileStore.writeBytesLazy(file, () {
              if (!_catalogRequestCurrent(revision)) {
                throw http.RequestAbortedException();
              }
              return response.bodyBytes;
            });
            if (!_catalogRequestCurrent(revision)) return;
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
      if (!_stateDisposing &&
          !downloadedOnly.value &&
          _artistPhotoQueue.isNotEmpty) {
        unawaited(_refreshArtistPhotos());
      }
    }
  }

  bool _catalogRequestCurrent(int revision) =>
      !_stateDisposing && downloadedOnly.permits(revision);

  bool _isCurrentDatabaseSync(int revision) =>
      !_stateDisposing &&
      !downloadedOnly.value &&
      revision == _databaseSyncRevision;

  Future<void> _refreshLiveCatalog() async {
    if (downloadedOnly.value) return;
    final revision = downloadedOnly.revision;
    await syncDatabase(reportFailure: true, refreshArtists: false);
    if (!_catalogRequestCurrent(revision)) return;
    await _syncArtistsCache(reportFailure: true);
    if (!_catalogRequestCurrent(revision)) return;
    unawaited(_refreshCachedArtwork());
  }

  Future<void> _refreshCachedArtwork() async {
    if (_isRefreshingArtwork || localPath.isEmpty || downloadedOnly.value) {
      return;
    }
    final revision = downloadedOnly.revision;
    _isRefreshingArtwork = true;
    try {
      final snapshot = List<dynamic>.from(_serverTracks);
      for (final track in snapshot) {
        if (!_catalogRequestCurrent(revision)) return;
        if (track is! Map || track['id'] is! int) continue;
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
          if (!_catalogRequestCurrent(revision)) return;
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
      if (mounted && _catalogRequestCurrent(revision)) {
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
    if (downloadedOnly.value || _stateDisposing) return;
    final revision = ++_databaseSyncRevision;
    final tracksUri = configuredServerUri('/api/tracks/');
    catalogSyncStatus.checking();

    try {
      final res = await _serverClient
          .get(tracksUri)
          .timeout(const Duration(seconds: 5));
      if (!_isCurrentDatabaseSync(revision)) return;
      if (res.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Track sync failed with HTTP ${res.statusCode}.',
          uri: tracksUri,
        );
      }
      final decoded = decodeTrackCatalog(
        res.bodyBytes,
        hasCachedTracks: _serverTracks.isNotEmpty,
      );
      if (!_isCurrentDatabaseSync(revision)) return;
      _applyTracks(List<dynamic>.from(decoded));
      catalogSyncStatus.succeeded();
      try {
        await _persistOfflineTracks();
      } catch (error) {
        debugPrint('Offline track cache write failed: $error');
      }
      if (refreshArtists && _isCurrentDatabaseSync(revision)) {
        unawaited(_syncArtistsCache());
      }
    } catch (e) {
      if (!_isCurrentDatabaseSync(revision)) return;
      catalogSyncStatus.failed(e);
      if (reportFailure) rethrow;
      if (_serverTracks.isEmpty) {
        final offlineTracks = await _readOfflineTrackCache();
        if (!_isCurrentDatabaseSync(revision)) return;
        _applyTracks(offlineTracks ?? <dynamic>[]);
      }
    }
  }

  Future<void> downloadFromNetwork() async {
    final query = searchQuery.trim();
    if (query.isEmpty || isSearchLoading || _stateDisposing) return;
    if (_showDownloadedOnlyNotice()) return;
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
      final res = await _serverClient
          .get(queryEndpoint)
          .timeout(const Duration(minutes: 5));
      final response = _decodeApiResponse(res);
      if (res.statusCode == HttpStatus.ok) {
        await syncDatabase();
        if (mounted && !_stateDisposing) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(tr('track_search_complete')),
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
    if (_showDownloadedOnlyNotice()) return;
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
    if (_showDownloadedOnlyNotice()) return;
    if (!isSupportedAlbumLink(url)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('invalid_album_link'))));
      return;
    }
    setState(() => isSearchLoading = true);
    try {
      final res = await _serverClient
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
          final status = await _serverClient
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
    if (confirmed == null ||
        _stateDisposing ||
        !mounted ||
        _showDownloadedOnlyNotice()) {
      return false;
    }
    _retryingAlbumTrack = true;
    try {
      final response = await _serverClient
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
    } finally {
      _retryingAlbumTrack = false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Downloads
  // ═══════════════════════════════════════════════════════════════════════════

  bool isTrackLocal(int id) {
    if (localPath.isEmpty) return false;
    final track = _ownTracks[id];
    try {
      final file = track == null ? _localAudioFile(id) : _trackAudioFile(track);
      return file.existsSync() && file.lengthSync() > 0;
    } on FileSystemException {
      return false;
    }
  }

  File _localAudioFile(int id) =>
      _trackUpdates?.audioFile(id) ?? File('$localPath/track_$id.mp3');

  File _trackAudioFile(dynamic track) {
    final digest = localTrackDigest(track);
    return digest == null
        ? _localAudioFile(track['id'] as int)
        : resolveLocalMusicAsset(Directory(localPath), localAudioName(digest));
  }

  File _localVideoFile(int id) {
    final digest = localTrackDigest(_ownTracks[id]);
    return digest == null
        ? (_trackUpdates?.videoFile(id) ?? File('$localPath/video_$id.mp4'))
        : localMusicVideo(Directory(localPath), digest);
  }

  void _onTrackUpdates() {
    if (_stateDisposing || !mounted || downloadedOnly.value) return;
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
    if (_showDownloadedOnlyNotice()) return;
    if (_downloadRecoveryFailed) {
      _downloadRemovalNotice('download_recovery_failed');
      return;
    }
    final monitor = _trackUpdates;
    if (monitor == null || _updateDialogOpen || !mounted) return;
    _updateDialogOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (_) => TrackUpdatesDialog(
          monitor: monitor,
          onUpdate: (offer) async {
            if (downloadedOnly.value) {
              throw StateError(tr('downloaded_only_action'));
            }
            if (downloadQueue.contains(offer.id)) {
              throw StateError('Track is being downloaded');
            }
            setState(() => downloadQueue.add(offer.id));
            _notifyArtistLibraryChanged();
            try {
              final track = await monitor.updateTrack(offer);
              if (_stateDisposing) return;
              final updated = _serverTracks
                  .map((old) => old['id'] == offer.id ? track : old)
                  .toList();
              if (!updated.any((item) => item['id'] == offer.id)) {
                updated.add(track);
              }
              _applyTracks(updated);
              // Leave current lyrics in place; the versioned LRC is read on next start.
              for (final queued in _playbackOrder.retainedTracks) {
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
      !downloadedOnly.value && (_trackUpdates?.offers.value.isNotEmpty ?? false)
      ? IconButton(
          tooltip: tr('track_updates'),
          onPressed: _showTrackUpdates,
          icon: Icon(Icons.system_update_alt, color: accentColorNotifier.value),
        )
      : const SizedBox.shrink();

  Widget _buildCatalogSyncButton() => downloadedOnly.value
      ? const SizedBox.shrink()
      : CatalogSyncButton(
          status: catalogSyncStatus,
          onRefresh: () => unawaited(syncDatabase()),
        );

  bool isTrackDownloadComplete(dynamic track) {
    if (localPath.isEmpty || track is! Map) return false;
    final rawTrackId = track['id'];
    final trackId = rawTrackId is int
        ? rawTrackId
        : int.tryParse(rawTrackId?.toString() ?? '');
    if (trackId == null) return false;
    try {
      final digest = localTrackDigest(track);
      final audioFile = digest == null
          ? _localAudioFile(trackId)
          : resolveLocalMusicAsset(
              Directory(localPath),
              localAudioName(digest),
            );
      return audioFile.existsSync() && audioFile.lengthSync() > 0;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> deleteDownloadedTrack(dynamic track) async {
    if (isLocalMusic(track)) return;
    if (_downloadRecoveryFailed) {
      _downloadRemovalNotice('download_recovery_failed');
      return;
    }
    if (track is! Map || localPath.isEmpty) return;
    final rawTrackId = track['id'];
    final trackId = rawTrackId is int
        ? rawTrackId
        : int.tryParse(rawTrackId?.toString() ?? '');
    if (trackId == null) return;
    if (downloadQueue.contains(trackId)) return;
    if (_audioHoldsTrack(trackId) ||
        activeTrackNotifier.value?['id'] == trackId ||
        _videoTrackId == trackId) {
      _pendingDownloadRemovals[trackId] = track;
      if (_crossfade?.holdsTrack(trackId) == true) _crossfade?.cancel();
      _downloadRemovalNotice('download_removal_deferred');
      return;
    }
    downloadQueue.add(trackId);
    try {
      final monitor = _trackUpdates;
      if (monitor == null) {
        throw StateError('Download index is not ready');
      }
      final cleanupPending = await monitor.removeDownload(
        trackId,
        LocalDownloadRemover(Directory(localPath)),
      );
      invalidateTrackCover(trackId);
      _downloadRemovalNotice(
        cleanupPending
            ? 'download_removal_cleanup_pending'
            : 'track_deleted_from_storage',
      );
    } catch (e) {
      debugPrint('Error deleting track files: $e');
      if (await File(
        '$localPath/.download_removals/track_$trackId/journal.json',
      ).exists()) {
        _downloadRecoveryFailed = true;
      }
      _downloadRemovalNotice(
        _downloadRecoveryFailed
            ? 'download_recovery_failed'
            : 'download_removal_failed',
      );
    } finally {
      downloadQueue.remove(trackId);
      if (mounted && !_stateDisposing) {
        setState(() {});
        _notifyArtistLibraryChanged();
      }
    }
  }

  void _downloadRemovalNotice(String key) {
    if (!mounted || _stateDisposing) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr(key))));
  }

  Future<void> _drainDownloadRemovals() async {
    if (_stateDisposing || _drainingDownloadRemovals) return;
    _drainingDownloadRemovals = true;
    try {
      for (final entry in _pendingDownloadRemovals.entries.toList()) {
        if (_audioHoldsTrack(entry.key) ||
            activeTrackNotifier.value?['id'] == entry.key ||
            _videoTrackId == entry.key ||
            downloadQueue.contains(entry.key)) {
          continue;
        }
        _pendingDownloadRemovals.remove(entry.key);
        await deleteDownloadedTrack(entry.value);
      }
    } finally {
      _drainingDownloadRemovals = false;
    }
  }

  bool _audioHoldsTrack(int id) =>
      _audioSourceTrackId == id ||
      _closingAudioTrackId == id ||
      _crossfade?.holdsTrack(id) == true;

  void _openArtistScreen(int artistId, String artistName) {
    if (trackSelection.isNotEmpty) clearTrackSelection();
    final artist = cachedArtists
        .whereType<Map>()
        .where((a) => a['id'] == artistId)
        .firstOrNull;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => ArtistScreen(
          artistId: artistId,
          artistName: artistName,
          initialArtistData: artist == null
              ? null
              : Map<String, dynamic>.from(artist),
          getAllTracks: () => cachedTracks,
          onPlayTrack: (queue, idx) => startPlayback(queue, idx),
          canPlayNext: () => playingTrack != null,
          onPlayNext: playTracksNext,
          onToggleFavorite: (id) => toggleFavorite(id),
          onToggleFavorites: (ids) => toggleTrackFavorites(ids),
          getPlaylists: () => {
            for (final playlist in myPlaylists)
              playlist['id'] as int: playlist['name'].toString(),
          },
          onAddToPlaylist: (id, ids) => changePlaylistTracks(id, ids),
          onCreatePlaylist: (ids) =>
              showCreatePlaylistDialog(initialTrackIds: ids),
          onDownloadTrack: (t) => downloadMediaFile(t),
          onDownloadAlbum: (tracks) => downloadAllTracks(tracks),
          onDeleteDownloadedTrack: (t) => deleteDownloadedTrack(t),
          onMissingLocalMusic: () => unawaited(showLocalMusicImport()),
          onRemoveLocalMusic: (track) =>
              unawaited(_confirmRemoveOwnTrack(track)),
          onMatchLocalMusic: (track) => unawaited(_matchOwnTrack(track)),
          trackDetailsAction: _trackDetailsAction,
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

  VoidCallback? _trackDetailsAction(dynamic track) {
    final store = _trackDetails;
    if (store == null || track is! Map) return null;
    final key = store.bind(track);
    if (key == null) return null;
    return () => unawaited(_editTrackDetails(track, store, key));
  }

  Future<void> _editTrackDetails(
    Map track,
    TrackDetailsStore store,
    String key,
  ) async {
    if (!mounted || _stateDisposing) return;
    final shown = displayTrackDetails(track);
    await showDialog<void>(
      context: context,
      builder: (_) => TrackDetailsDialog(
        initial: shown,
        hasEdits: trackDetailsPatch(track) != null,
        onSave: (edited) async {
          final original =
              cachedTracks
                  .whereType<Map>()
                  .where(
                    (item) =>
                        item['id'] == track['id'] && store.bind(item) == key,
                  )
                  .firstOrNull ??
              track;
          final patch = edited == null
              ? null
              : resolveTrackDetailsEdit(
                  shown: shown,
                  edited: edited,
                  original: originalTrackDetails(original),
                  previous: trackDetailsPatch(original),
                );
          await store.save(key, patch);
          if (!mounted || _stateDisposing) return;
          setState(() {});
          _notifyArtistLibraryChanged();
          _notifyPlayNext();
        },
      ),
    );
  }

  Future<void> downloadMediaFile(dynamic mediaObj) async {
    if (_showDownloadedOnlyNotice()) return;
    if (isLocalMusic(mediaObj)) return;
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
    if (id == null ||
        localPath.isEmpty ||
        _stateDisposing ||
        _downloadRecoveryFailed) {
      return Future.value(
        TrackDownloadResult(
          id: id ?? 0,
          title: title,
          audioReady: false,
          videoReady: false,
          errors: {
            DownloadComponent.library: tr(
              _downloadRecoveryFailed
                  ? 'download_recovery_failed'
                  : localPath.isEmpty
                  ? 'library_not_ready'
                  : 'invalid_track',
            ),
          },
        ),
      );
    }
    final pending = _mediaDownloadTasks[id];
    if (pending != null) return pending;
    // A new explicit download cancels a still-deferred removal, never the
    // transaction that has already reserved downloadQueue below.
    _pendingDownloadRemovals.remove(id);
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
    Future<String?> generateVideoUrl() =>
        _clipTaskLimiter.run<String?>(() async {
          final signature = _videoAvailabilitySignature(track);
          if (!_clipRetryGate.canRequest(
            id,
            signature,
            force: retryUnavailableVideo,
          )) {
            videoUnavailable = _unavailableVideoSignatures[id] == signature;
            if (videoUnavailable) return null;
            throw HttpException(tr('video_retry_delayed'));
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
              expectedSha256: track['content_versions']?['audio'] as String?,
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

        if (!supportsVideoClips) return;
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
                expectedSha256: track['content_versions']?['video'] as String?,
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
            for (final item in [
              ..._playbackOrder.retainedTracks,
              ...cachedTracks,
            ]) {
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
      if (mounted && !_stateDisposing) {
        setState(() {});
        if (videoReady && _expandedClipTrack == id) {
          _initializeVideo(activeTrackNotifier.value);
        }
      }
      _notifyArtistLibraryChanged();
    }
    return TrackDownloadResult(
      id: id,
      title: track['title']?.toString() ?? '$id',
      audioReady: audioReady,
      videoReady: videoReady,
      videoRequired: supportsVideoClips,
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
    if (_showDownloadedOnlyNotice()) return;
    final revision = downloadedOnly.revision;
    while (_bulkDownloadActive && !_stateDisposing) {
      await _bulkDownloadFinished?.future;
    }
    if (!_catalogRequestCurrent(revision) || !mounted) return;
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
          '${tr(label)}. ${tr('download_audio')}: ${result.audioReady}/${result.results.length}'
          '${supportsVideoClips ? ', ${tr('download_video')}: ${result.videoReady}/${result.results.length}' : ''}',
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

  bool get _storageBusy =>
      _stateDisposing ||
      _loadingStorageProfile ||
      downloadQueue.isNotEmpty ||
      _coverDownloads.isNotEmpty;

  Future<({Set<int> tracks, Set<int> artists})>
  _storageArtworkProtection() async {
    final protectedTracks = <int>{};
    final protectedArtists = <int>{};
    final retained = [
      ..._playbackOrder.retainedTracks,
      if (activeTrackNotifier.value != null) activeTrackNotifier.value!,
    ];
    final retainedIds = {for (final track in retained) track['id']};
    for (final track in [...cachedTracks, ...retained]) {
      if (track is! Map || track['id'] is! int || isLocalMusic(track)) continue;
      final id = track['id'] as int;
      final localLyrics =
          _trackUpdates?.lyricsFile(id) ?? File('$localPath/track_$id.lrc');
      if (retainedIds.contains(id) ||
          (await _localAudioFile(id).stat()).size > 0 ||
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
    return (tracks: protectedTracks, artists: protectedArtists);
  }

  Future<StorageUsage> loadStorageUsage() async {
    if (localPath.isEmpty || _loadingStorageProfile) {
      throw StateError('Library not ready');
    }
    final protection = await _storageArtworkProtection();
    return readStorageUsage(
      Directory(localPath),
      protectedTrackIds: protection.tracks,
      protectedArtistIds: protection.artists,
    );
  }

  Future<ArtworkCleanupResult> clearAllCache() async {
    if (_storageBusy || _clearingArtwork) {
      return const ArtworkCleanupResult(busy: true);
    }
    if (localPath.isEmpty) return const ArtworkCleanupResult(failed: true);
    _clearingArtwork = true;
    try {
      final protection = await _storageArtworkProtection();
      final result = await clearDisposableArtwork(
        Directory(localPath),
        protectedTrackIds: protection.tracks,
        protectedArtistIds: protection.artists,
        isBusy: () => _storageBusy,
      );
      if (result.removedFiles != 0 && !_stateDisposing) {
        clearCoverCache();
        PaintingBinding.instance.imageCache.clear();
        if (mounted) {
          setState(() {});
          _notifyArtistLibraryChanged();
        }
      }
      return result;
    } finally {
      _clearingArtwork = false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Favorites / playlists
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> toggleFavorite(int id) => toggleTrackFavorites([id]);

  Future<void> toggleTrackFavorites(Iterable<int> trackIds) {
    final ids = trackIds.toSet();
    final work = _favoritesTail.then((_) async {
      if (_ownCatalogRead) {
        ids.removeWhere((id) => id < 0 && !_isLibraryTrackId(id));
      }
      if (ids.isEmpty || _stateDisposing) return;
      final previous = {for (final id in ids) id: favs.contains(id)};
      final add = !ids.every(favs.contains);
      void apply() {
        if (add) {
          favs.addAll(ids);
        } else {
          favs.removeAll(ids);
        }
      }

      if (mounted) {
        setState(apply);
      } else {
        apply();
      }
      _syncTaskbarControls();
      _notifyArtistLibraryChanged();
      if (!await saveFavorites()) {
        if (_stateDisposing) return;
        void restore() {
          for (final entry in previous.entries) {
            if (entry.value) {
              favs.add(entry.key);
            } else {
              favs.remove(entry.key);
            }
          }
        }

        if (mounted) {
          setState(restore);
        } else {
          restore();
        }
        _syncTaskbarControls();
        _notifyArtistLibraryChanged();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(tr('favorite_save_failed'))));
        }
      } else if (!add && navId == 1 && !_stateDisposing) {
        if (mounted) {
          setState(() => trackSelection.removeAll(ids));
        } else {
          trackSelection.removeAll(ids);
        }
      }
    });
    _favoritesTail = work.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return work;
  }

  Future<bool> saveFavorites() async {
    final favFile = File('$localPath/liked_tracks.json');
    final snapshot = json.encode(favs.toList());
    try {
      await atomicFileStore.writeString(favFile, snapshot);
      return true;
    } catch (error) {
      debugPrint('Favorite save failed: $error');
      return false;
    }
  }

  Future<bool> changePlaylistTracks(
    int playlistId,
    Iterable<int> trackIds, {
    bool remove = false,
  }) {
    final ids = trackIds.toSet();
    final work = _playlistReorderTail.then((_) async {
      if (!remove && _ownCatalogRead) {
        ids.removeWhere((id) => id < 0 && !_isLibraryTrackId(id));
      }
      if (_stateDisposing || ids.isEmpty) return false;
      final index = myPlaylists.indexWhere((p) => p['id'] == playlistId);
      if (index < 0) return false;
      final previous = List<dynamic>.from(myPlaylists[index]['tracks']);
      final existingIds = previous.toSet();
      final next = remove
          ? previous.where((id) => !ids.contains(id)).toList()
          : [...previous, ...ids.where((id) => !existingIds.contains(id))];
      if (listEquals(previous, next)) return true;
      final expected = List<dynamic>.of(next);
      void apply() => myPlaylists[index]['tracks'] = next;
      if (mounted) {
        setState(apply);
      } else {
        apply();
      }
      if (await savePlaylists()) {
        if (remove &&
            !_stateDisposing &&
            navId >= 3 &&
            navId - 3 < myPlaylists.length &&
            myPlaylists[navId - 3]['id'] == playlistId) {
          if (mounted) {
            setState(() => trackSelection.removeAll(ids));
          } else {
            trackSelection.removeAll(ids);
          }
        }
        return true;
      }
      final current = myPlaylists.indexWhere((p) => p['id'] == playlistId);
      if (!_stateDisposing &&
          current >= 0 &&
          identical(myPlaylists[current]['tracks'], next) &&
          listEquals(myPlaylists[current]['tracks'] as List, expected)) {
        void restore() => myPlaylists[current]['tracks'] = previous;
        if (mounted) {
          setState(restore);
        } else {
          restore();
        }
      }
      return false;
    });
    _playlistReorderTail = work.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return work;
  }

  void clearTrackSelection() {
    if (mounted) {
      setState(trackSelection.clear);
    } else {
      trackSelection.clear();
    }
  }

  void handleTrackTap(
    List<dynamic> tracks,
    int index, {
    required bool touch,
    int? playlistId,
  }) {
    final id = tracks[index]['id'] as int;
    var selected = false;
    void select() {
      selected = trackSelection.tap(
        id,
        [for (final track in tracks) track['id'] as int],
        control:
            HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed,
        shift: HardwareKeyboard.instance.isShiftPressed,
        touch: touch,
      );
    }

    if (mounted) {
      setState(select);
    } else {
      select();
    }
    if (selected || (isPlaying && _playbackOrder.current?.trackId == id)) {
      return;
    }
    if (downloadedOnly.value && !isTrackDownloadComplete(tracks[index])) {
      _playNextNotice(tr('downloaded_only_unavailable'));
      return;
    }
    startPlayback(tracks, index, playlistId: playlistId);
  }

  ImageProvider? getPlaylistImage(String pathOrUrl) {
    if (pathOrUrl.startsWith('http')) {
      return downloadedOnly.value ? null : NetworkImage(pathOrUrl);
    }
    return FileImage(resolvePlaylistArtwork(Directory(localPath), pathOrUrl));
  }

  ImageProvider? _playlistThumbnail(
    BuildContext context,
    String path,
    double size,
  ) {
    final provider = getPlaylistImage(path);
    if (provider == null) return null;
    final version = _playlistArtworkVersions[path] ?? 0;
    final imagePath =
        Uri.tryParse(path)?.path.toLowerCase() ?? path.toLowerCase();
    // Animated codecs can ignore target dimensions. Do not duplicate full GIF/
    // WebP frame buffers for selected/unselected avatar sizes or another DPR.
    if (imagePath.endsWith('.gif') || imagePath.endsWith('.webp')) {
      return CoverThumbnailProvider.original(provider, cacheVersion: version);
    }
    return coverThumbnail(context, provider, size, cacheVersion: version);
  }

  Future<void> _invalidatePlaylistArtwork(String path) async {
    if (path.isEmpty) return;
    // A replacement keeps its portable filename. Version all decode sizes,
    // including ones previously used on another monitor/DPR, not only FileImage.
    _playlistArtworkVersions.update(
      path,
      (version) => version + 1,
      ifAbsent: () => 1,
    );
    await getPlaylistImage(path)?.evict();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Playback
  // ═══════════════════════════════════════════════════════════════════════════

  TrackTransitionMode get _transitionMode => trackTransitionModeNotifier.value;

  void _logAudioError(Object error) => debugPrint('Audio playback: $error');

  AudioContext _mobileAudioContext({required bool sharedAndroidFocus}) =>
      AudioContext(
        android: AudioContextAndroid(
          isSpeakerphoneOn: false,
          audioMode: AndroidAudioMode.normal,
          stayAwake: true,
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.media,
          audioFocus: sharedAndroidFocus
              ? AndroidAudioFocus.none
              : AndroidAudioFocus.gain,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: {AVAudioSessionOptions.mixWithOthers},
        ),
      );

  PlaybackDeck _newAudioDeck({required bool sharedAndroidFocus}) =>
      PlaybackDeck(
        volume: volume,
        fadeEnabled: _transitionMode != TrackTransitionMode.off,
        replayGainEnabled: replayGainEnabledNotifier.value,
        onError: _logAudioError,
        context: isDesktop
            ? null
            : _mobileAudioContext(sharedAndroidFocus: sharedAndroidFocus),
      );

  Future<void> _setPlaybackVolume(double value) {
    _crossfade?.setVolume(value);
    return _trackFade.setVolume(value);
  }

  void _subscribeToAudioDeck({bool alreadyPlaying = false}) {
    unawaited(_statisticsStateSubscription?.cancel());
    unawaited(_audioDurationSubscription?.cancel());
    unawaited(_audioPositionSubscription?.cancel());
    unawaited(_audioCompleteSubscription?.cancel());
    final player = audioPlayer;
    bool stillCurrent() => !_stateDisposing && identical(player, audioPlayer);
    bool sourceSettled() =>
        _settledTrackRevision == _trackRevision &&
        _audioSourceTrackId != null &&
        _audioSourceTrackId == activeTrackNotifier.value?['id'];

    final updater = playbackPositionUpdater(player.getCurrentPosition);
    player.positionUpdater = updater;
    _statisticsStateSubscription = player.onPlayerStateChanged.listen((state) {
      if (!stillCurrent()) return;
      final playing = state == PlayerState.playing;
      _statistics?.setPlaying(playing);
      if (_trackFade.enabled) {
        if (playing) {
          unawaited(_syncTrackFade(currentPositionNotifier.value));
        } else {
          _trackFade.hold();
        }
      }
      // Completion must leave the prepared deck available for handoff.
      if (!playing && state != PlayerState.completed) _crossfade?.cancel();
    });
    _audioDurationSubscription = player.onDurationChanged.listen((duration) {
      if (!stillCurrent() || !sourceSettled()) return;
      trackDurations[_audioSourceTrackId!] = duration.inSeconds;
      _statistics?.setDuration(duration);
      fullDurationNotifier.value = duration;
      _syncMediaSessionMetadata();
    });
    _audioPositionSubscription = player.onPositionChanged.listen((position) {
      if (!stillCurrent()) return;
      if (PerformanceFrameMonitor.enabled) _benchmarkPositionEvents++;
      if (!mounted || !sourceSettled()) return;
      _statistics?.position(position);
      currentPositionNotifier.value = position;
      if (_useLiveLyricPosition) checkLyrics(position);
      _linuxMediaSession?.updatePosition(position);
      if (_trackFade.enabled) unawaited(_syncTrackFade(position));
    });
    _audioCompleteSubscription = player.onPlayerComplete.listen((_) {
      if (!stillCurrent() || !sourceSettled()) return;
      final handoff = _crossfade?.takeAtEnd();
      final next = _nextPlaybackMove(
        automatic: true,
        alreadyStarting: handoff?.source.slot,
      );
      if (next == null) {
        _statistics?.endTrack();
        _stopPlaybackAtQueueEnd();
      } else {
        _advancePlayback(next, handoff: handoff);
      }
    });
    if (alreadyPlaying) updater.start();
  }

  int? get _startingQueueSlot => _crossfade?.audibleSource?.slot;

  bool Function(PlaybackEntry)? get _playbackAvailability =>
      downloadedOnly.value
      ? (entry) => isTrackDownloadComplete(entry.track)
      : null;

  PlaybackMove? _nextPlaybackMove({
    required bool automatic,
    int? alreadyStarting,
  }) => _playbackOrder.next(
    loopMode,
    automatic: automatic,
    alreadyStarting: alreadyStarting,
    isPlayable: _playbackAvailability,
  );

  bool get _canPlayNext => _nextPlaybackMove(automatic: false) != null;

  void _notifyPlayNext() {
    if (!_stateDisposing) _playNextChanges.value++;
  }

  void _savePlayNextEdit() {
    _crossfade?.reconcileNextSource();
    _notifyPlayNext();
    _syncMediaSessionPlayback();
    unawaited(_saveState());
  }

  void playTracksNext(List<dynamic> tracks) {
    if (!mounted || _stateDisposing) return;
    for (final track in tracks) {
      _trackDetails?.bind(track);
    }
    final added = _playbackOrder.insertNext(
      tracks,
      alreadyStarting: _startingQueueSlot,
    );
    if (added == 0) return;
    _savePlayNextEdit();
    _playNextNotice(tr('play_next_added').replaceFirst('{count}', '$added'));
  }

  void _playNextNotice(String text) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  void showPlayNext() {
    if (_playbackOrder.current == null || _stateDisposing) return;
    final panel = ValueListenableBuilder<int>(
      valueListenable: _playNextChanges,
      builder: (context, revision, child) => PlayNextPanel(
        playing: playingTrack as Map?,
        insertions: _playbackOrder.insertions.toList(),
        startingSlot: _startingQueueSlot,
        isUnavailable: downloadedOnly.value
            ? (entry) => !isTrackDownloadComplete(entry.track)
            : null,
        onRemove: (slot) {
          if (_playbackOrder.removeInsertion(
            slot,
            alreadyStarting: _startingQueueSlot,
          )) {
            _savePlayNextEdit();
          }
        },
        onClear: () {
          if (_playbackOrder.clearInsertions(
            alreadyStarting: _startingQueueSlot,
          )) {
            _savePlayNextEdit();
          }
        },
      ),
    );
    if (MediaQuery.sizeOf(context).width < 800) {
      unawaited(
        showModalBottomSheet<void>(
          context: context,
          useSafeArea: true,
          isScrollControlled: true,
          backgroundColor: const Color(0xFF242124),
          builder: (context) => panel,
        ),
      );
    } else {
      unawaited(
        showDialog<void>(
          context: context,
          builder: (context) =>
              Dialog(backgroundColor: const Color(0xFF242124), child: panel),
        ),
      );
    }
  }

  Widget _buildPlayNextButton() => ValueListenableBuilder<int>(
    valueListenable: _playNextChanges,
    builder: (context, revision, child) {
      final count = _playbackOrder.insertionCount;
      return PlaybackShortcutScope(
        child: IconButton(
          key: const ValueKey('open_play_next'),
          tooltip: tr('play_next_queue'),
          onPressed: showPlayNext,
          icon: Badge.count(
            count: count,
            isLabelVisible: count > 0,
            child: const Icon(Icons.queue_music_rounded, color: Colors.white70),
          ),
        ),
      );
    },
  );

  CrossfadeSource? _nextCrossfadeSource() {
    if (_stateDisposing ||
        !isPlaying ||
        !_audioSourceLocal ||
        _settledTrackRevision != _trackRevision ||
        _fadeSeekRevision == _seekRevision ||
        _transitionMode != TrackTransitionMode.crossfade ||
        _closingAudioTrackId != null ||
        isAudioServiceActive ||
        (Platform.isAndroid && _androidPlaybackFocus?.available != true)) {
      return null;
    }
    final next = _nextPlaybackMove(
      automatic: true,
      alreadyStarting: _startingQueueSlot,
    )?.entry;
    if (next == null) return null;
    final nextId = next.trackId;
    if (nextId == _audioSourceTrackId ||
        downloadQueue.contains(nextId) ||
        _pendingDownloadRemovals.containsKey(nextId)) {
      return null;
    }
    if (supportsVideoClips &&
        playVideoClipNotifier.value &&
        (_videoController != null ||
            _initializingVideoController != null ||
            _VideoRequest.from(activeTrackNotifier.value).videoUrl != null ||
            _VideoRequest.from(next.track).videoUrl != null)) {
      return null;
    }
    return (
      slot: next.slot,
      trackId: nextId,
      path: _trackAudioFile(next.track).path,
    );
  }

  void _configureFadeTail() {
    _trackFade.nearEndLead = TrackCrossfade.prepareWithin;
    _trackFade.onNearEnd = _transitionMode == TrackTransitionMode.crossfade
        ? _sampleCrossfade
        : null;
  }

  void _sampleCrossfade(Duration remaining, double userVolume) {
    if (fullDurationNotifier.value < TrackCrossfade.minimumTrackDuration) {
      return;
    }
    (_crossfade ??= TrackCrossfade<PlaybackDeck>(
      createDeck: () => _newAudioDeck(sharedAndroidFocus: true),
      fileReady: (path) async =>
          await LyricAudioFile.inspect(File(path)) != null,
      nextSource: _nextCrossfadeSource,
      onError: _logAudioError,
      onReleased: () => unawaited(_drainDownloadRemovals()),
      onAudibleChanged: _notifyPlayNext,
    )).update(remaining, userVolume);
  }

  Future<void> _retireOutgoingDeck(PlaybackDeck old, int? sourceId) async {
    _closingAudioTrackId = sourceId;
    try {
      final work = old.dispose().catchError(_logAudioError);
      _closingAudioWork = work;
      await work;
    } finally {
      _closingAudioTrackId = null;
      _closingAudioWork = null;
      unawaited(_drainDownloadRemovals());
    }
  }

  Future<void> _configureAndroidFocusForSource(int revision) async {
    final deck = _audioDeck;
    await deck.contextReady;
    if (!Platform.isAndroid || !_isCurrentTrackRevision(revision)) return;
    final shared = _transitionMode == TrackTransitionMode.crossfade;
    if (shared == _androidDeckUsesSharedFocus) return;
    // setAudioContext can reload a prepared Android source. Change it only
    // between sources and never while the current one is still audible.
    if (deck.player.source != null) await deck.player.release();
    if (!_isCurrentTrackRevision(revision)) return;
    if (!shared) {
      await _androidPlaybackFocus?.dispose();
      _androidPlaybackFocus = null;
      _resumeAfterFocusRevision = null;
    }
    await deck.player.setAudioContext(
      _mobileAudioContext(sharedAndroidFocus: shared),
    );
    _androidDeckUsesSharedFocus = shared;
  }

  Future<bool> _acquireAndroidPlaybackFocus() =>
      (_androidPlaybackFocus ??= AndroidPlaybackFocus(
        _onAndroidInterruption,
      )).acquire();

  void _onAndroidInterruption(AudioInterruptionEvent event) {
    if (_stateDisposing || !mounted || !_androidDeckUsesSharedFocus) return;
    if (event.begin) {
      if (isPlaying) {
        pauseTrack();
        _resumeAfterFocusRevision = event.type == AudioInterruptionType.pause
            ? _transportRevision
            : null;
      } else if (event.type == AudioInterruptionType.unknown) {
        _resumeAfterFocusRevision = null;
      }
    } else {
      final revision = _resumeAfterFocusRevision;
      _resumeAfterFocusRevision = null;
      if (!isPlaying && revision == _transportRevision) pauseTrack();
    }
  }

  Future<void>? _syncTrackFade(Duration position, {bool? playing}) {
    if (!_trackFade.enabled ||
        _stateDisposing ||
        _fadeSeekRevision == _seekRevision ||
        _settledTrackRevision != _trackRevision ||
        _audioSourceTrackId == null) {
      return null;
    }
    final state = audioPlayer.state;
    if (playing != false &&
        (state == PlayerState.completed || state == PlayerState.stopped)) {
      return null;
    }
    return _trackFade.updatePosition(
      position,
      fullDurationNotifier.value,
      playing: playing ?? (isPlaying && state == PlayerState.playing),
    );
  }

  void _onTrackFadeChanged() {
    _crossfade?.cancel(allowRetry: true);
    _configureFadeTail();
    final enabled = _transitionMode != TrackTransitionMode.off;
    unawaited(_trackFade.setEnabled(enabled));
    if (enabled) unawaited(_syncTrackFade(currentPositionNotifier.value));
  }

  void _onReplayGainChanged() {
    final enabled = replayGainEnabledNotifier.value;
    unawaited(_audioDeck.setReplayGainEnabled(enabled));
    unawaited(_crossfade?.incomingDeck?.setReplayGainEnabled(enabled));
  }

  void startPlayback(List<dynamic> targetQueue, int index, {int? playlistId}) {
    if (targetQueue.isEmpty || index < 0 || index >= targetQueue.length) return;
    if (downloadedOnly.value) {
      index = targetQueue.indexWhere(isTrackDownloadComplete, index);
      if (index < 0) {
        if (mounted) _playNextNotice(tr('downloaded_only_unavailable'));
        return;
      }
    }
    if (isPremium) playCount++;

    for (final track in targetQueue) {
      _trackDetails?.bind(track);
    }
    setState(() {
      _playbackOrder.reset(targetQueue, index);
      playingPlaylistId = playlistId;
    });
    isShuffledNotifier.value = false;
    if (playingTrack != null) _activateTrackForPlayback(playingTrack);
  }

  void pauseTrack() {
    if (playingQueue.isEmpty) return;
    final shouldPlay = !isPlaying;
    final entry = _playbackOrder.current;
    if (shouldPlay &&
        downloadedOnly.value &&
        entry != null &&
        !isTrackDownloadComplete(entry.track)) {
      _playNextNotice(tr('downloaded_only_unavailable'));
      return;
    }
    if (shouldPlay &&
        entry != null &&
        (downloadedOnly.value ||
            _resumeNeedsSource ||
            entry.inserted ||
            isLocalMusic(entry.track)) &&
        (_settledTrackRevision != _trackRevision ||
            _audioSourceTrackId != entry.trackId)) {
      _activateTrackForPlayback(entry.track);
      return;
    }
    final revision = ++_transportRevision;
    if (!shouldPlay) {
      _crossfade?.cancel();
      if (_trackFade.enabled) _trackFade.hold();
    }
    _setPlaying(shouldPlay);
    _syncMediaSessionPlayback();
    unawaited(_saveState());
    unawaited(
      _enqueueAudioWork(() async {
        if (_stateDisposing || revision != _transportRevision) return;
        try {
          if (shouldPlay) {
            final gain = _syncTrackFade(
              currentPositionNotifier.value,
              playing: false,
            );
            if (gain != null) {
              await gain;
              if (_stateDisposing || revision != _transportRevision) return;
            }
            if (_androidDeckUsesSharedFocus) {
              final granted = await _acquireAndroidPlaybackFocus();
              if (_stateDisposing || revision != _transportRevision) return;
              if (!granted) throw StateError('Android audio focus unavailable');
            }
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
    if (_playbackOrder.current == null) return;
    final next = _nextPlaybackMove(automatic: false);
    if (next != null) {
      _advancePlayback(next);
    } else {
      _stopPlaybackAtQueueEnd();
    }
  }

  void prevTrack() {
    if (playingQueue.isEmpty) return;
    if (currentPositionNotifier.value > const Duration(seconds: 3)) {
      seekTo(Duration.zero);
      return;
    }
    final previous = _playbackOrder.previous(
      loopMode,
      isPlayable: _playbackAvailability,
    );
    if (previous == null) {
      seekTo(Duration.zero);
    } else {
      _activateTrackForPlayback(previous.track);
    }
  }

  /// Benchmark control: jump directly to a slot in the base list.
  void _playIndex(int index) {
    if (playingQueue.isEmpty || index < 0 || index >= playingQueue.length) {
      return;
    }
    _playbackOrder.jumpToBase(index);
    _activateTrackForPlayback(playingTrack);
  }

  void _advancePlayback(
    PlaybackMove move, {
    CrossfadeHandoff<PlaybackDeck>? handoff,
  }) {
    // An already audible preroll may have skipped an unavailable insertion
    // while local-only was on. Keep that reservation if the mode just changed.
    _playbackOrder.take(
      move,
      skipUnavailable: downloadedOnly.value || handoff != null,
    );
    _activateTrackForPlayback(move.entry.track, handoff: handoff);
  }

  bool _skipUnavailableInsertion(
    PlaybackEntry? entry,
    int trackRevision,
    int transportRevision,
  ) {
    if (entry == null ||
        !mounted ||
        !_isCurrentTrackRevision(trackRevision) ||
        transportRevision != _transportRevision ||
        !_playbackOrder.discardFailedInsertion(entry)) {
      return false;
    }
    _playNextNotice(
      tr(
        'play_next_unavailable',
      ).replaceFirst('{title}', entry.track['title']?.toString() ?? ''),
    );
    // Do not repeat a failed occurrence, even with repeat-one enabled.
    final next = _nextPlaybackMove(automatic: false);
    if (next != null) {
      _advancePlayback(next);
    } else {
      // The prior track is still the session anchor; prepare it paused.
      _activateTrackForPlayback(playingTrack, play: false);
    }
    return true;
  }

  void _activateTrackForPlayback(
    dynamic targetTrack, {
    CrossfadeHandoff<PlaybackDeck>? handoff,
    bool play = true,
  }) {
    _resumeNeedsSource = false;
    _crossfade?.cancel(allowRetry: true);
    _trackFade.beginTrack();
    _statistics?.endTrack();
    final trackRevision = ++_trackRevision;
    final transportRevision = ++_transportRevision;
    _seekRevision += 1;
    final position = handoff?.position ?? Duration.zero;
    if (handoff != null) {
      final old = _audioDeck;
      final oldId = _audioSourceTrackId;
      _audioDeck = handoff.deck;
      _audioSourceLocal = true;
      _audioSourceTrackId = handoff.source.trackId;
      _settledTrackRevision = trackRevision;
      trackDurations[handoff.source.trackId] = handoff.duration.inSeconds;
      _trackFade.beginTrack(fadeIn: false);
      _configureFadeTail();
      _subscribeToAudioDeck(alreadyPlaying: true);
      unawaited(_retireOutgoingDeck(old, oldId));
      unawaited(_trackFade.setVolume(volume));
      _statistics?.beginTrack(targetTrack as Map, duration: handoff.duration);
      _statistics?.setPlaying(true);
      _statistics?.position(position);
    }
    _setPlaying(play);
    discordStart = handoff == null
        ? null
        : DateTime.now().millisecondsSinceEpoch - position.inMilliseconds;
    currentPositionNotifier.value = position;
    fullDurationNotifier.value = handoff?.duration ?? Duration.zero;
    activeTrackNotifier.value = targetTrack;
    _notifyPlayNext();
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
    if (handoff != null) {
      updateRPC(force: true);
      return;
    }
    final entry = _playbackOrder.current;
    unawaited(
      _enqueueAudioWork(
        () => _playTrackSource(
          targetTrack: targetTrack,
          trackRevision: trackRevision,
          transportRevision: transportRevision,
          entry: entry,
        ),
      ),
    );
  }

  Future<void> _playTrackSource({
    required dynamic targetTrack,
    required int trackRevision,
    required int transportRevision,
    required PlaybackEntry? entry,
  }) async {
    if (!_isCurrentTrackRevision(trackRevision)) return;
    final trackId = targetTrack['id'] as int;
    final localAudio = await LyricAudioFile.inspect(
      _trackAudioFile(targetTrack),
    );
    final hasLocalTrack = localAudio != null;
    if (!_isCurrentTrackRevision(trackRevision)) return;

    _audioSourceTrackId = null;
    _audioSourceLocal = false;
    _settledTrackRevision = -1;
    if (localAudio == null &&
        (isLocalMusic(targetTrack) || downloadedOnly.value)) {
      if (_skipUnavailableInsertion(entry, trackRevision, transportRevision)) {
        return;
      }
      if (transportRevision == _transportRevision) {
        _setPlaying(false);
        _syncMediaSessionPlayback();
        if (isLocalMusic(targetTrack)) {
          _localMusicMissing();
        } else if (mounted) {
          _playNextNotice(tr('downloaded_only_unavailable'));
        }
      }
      await audioPlayer.stop();
      return;
    }
    try {
      if (_audioDeck.contextReady != null) {
        await _configureAndroidFocusForSource(trackRevision);
        if (!_isCurrentTrackRevision(trackRevision)) return;
      }
      if (_androidDeckUsesSharedFocus &&
          audioPlayer.state == PlayerState.playing) {
        // Android can automatically start a newly prepared source on a
        // playing deck. Wait for shared focus before resuming it below.
        await audioPlayer.pause();
        if (!_isCurrentTrackRevision(trackRevision)) return;
      }
      if (_trackFade.enabled) {
        // Some backends prepare a new source while already playing. Set the
        // initial gain before replacing it so the new track cannot pop in.
        await _trackFade.updatePosition(
          Duration.zero,
          Duration.zero,
          playing: false,
        );
        if (!_isCurrentTrackRevision(trackRevision)) return;
      }
      var audioUrl = targetTrack['audio_file']?.toString() ?? '';
      if (!hasLocalTrack && entry?.inserted == true) {
        final resolved = Uri.tryParse(_resolveAbsoluteUrl(audioUrl));
        if (audioUrl.trim().isEmpty ||
            resolved == null ||
            !resolved.hasAuthority ||
            (resolved.scheme != 'http' && resolved.scheme != 'https')) {
          throw StateError('No playable source for queued track');
        }
        audioUrl = resolved.toString();
      }
      if (!await _setPlaybackSource(localAudio, audioUrl)) {
        if (_isCurrentTrackRevision(trackRevision)) _stopPlaybackAtQueueEnd();
        return;
      }
    } catch (error) {
      if (_skipUnavailableInsertion(entry, trackRevision, transportRevision)) {
        _logAudioError(error);
        return;
      }
      if (_isCurrentTrackRevision(trackRevision) && _trackFade.enabled) {
        unawaited(_trackFade.reset());
      }
      if (_isCurrentTrackRevision(trackRevision) &&
          transportRevision == _transportRevision) {
        _setPlaying(false);
        _syncMediaSessionPlayback();
      }
      rethrow;
    }
    if (!_isCurrentTrackRevision(trackRevision)) return;

    _audioSourceTrackId = trackId;
    _audioSourceLocal = hasLocalTrack;
    _settledTrackRevision = trackRevision;
    _prepareLyricTiming();
    unawaited(_drainDownloadRemovals());
    var resuming = false;
    try {
      final duration = await audioPlayer.getDuration();
      if (!_isCurrentTrackRevision(trackRevision)) return;
      if (duration != null) {
        trackDurations[trackId] = duration.inSeconds;
        fullDurationNotifier.value = duration;
      }

      _statistics?.beginTrack(targetTrack as Map, duration: duration);
      _statistics?.setPlaying(audioPlayer.state == PlayerState.playing);
      if (_trackFade.enabled) {
        await _trackFade.updatePosition(
          Duration.zero,
          fullDurationNotifier.value,
          playing: false,
        );
        if (!_isCurrentTrackRevision(trackRevision)) return;
      }
      if (isPlaying && _androidDeckUsesSharedFocus) {
        final granted = await _acquireAndroidPlaybackFocus();
        if (!_isCurrentTrackRevision(trackRevision)) return;
        if (isPlaying && !granted) {
          throw StateError('Android audio focus unavailable');
        }
      }
      if (isPlaying) {
        resuming = true;
        await audioPlayer.resume();
      } else {
        await audioPlayer.pause();
      }
    } catch (error) {
      if (resuming &&
          _skipUnavailableInsertion(entry, trackRevision, transportRevision)) {
        _logAudioError(error);
        return;
      }
      if (_isCurrentTrackRevision(trackRevision) && _trackFade.enabled) {
        unawaited(_trackFade.reset());
      }
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
    final localAudio = await LyricAudioFile.inspect(
      _trackAudioFile(targetTrack),
    );
    final hasLocalTrack = localAudio != null;
    if (!_isCurrentTrackRevision(trackRevision)) return;

    _audioSourceTrackId = null;
    _audioSourceLocal = false;
    _settledTrackRevision = -1;
    if (localAudio == null && isLocalMusic(targetTrack)) return;
    if (_audioDeck.contextReady != null) {
      await _configureAndroidFocusForSource(trackRevision);
      if (!_isCurrentTrackRevision(trackRevision)) return;
    }
    if (!await _setPlaybackSource(
      localAudio,
      targetTrack['audio_file'].toString(),
    )) {
      _resumeNeedsSource = true;
      return;
    }
    if (!_isCurrentTrackRevision(trackRevision)) return;

    _audioSourceTrackId = trackId;
    _audioSourceLocal = hasLocalTrack;
    _settledTrackRevision = trackRevision;
    _prepareLyricTiming();
    unawaited(_drainDownloadRemovals());
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

  Future<bool> _setPlaybackSource(LyricAudioFile? file, String url) async {
    if (file == null && downloadedOnly.value) return false;
    _openingRemoteAudio = file == null;
    try {
      await _audioDeck.setTrackSource(
        file == null ? UrlSource(url) : DeviceFileSource(file.path),
        localAudio: file,
      );
      return true;
    } finally {
      _openingRemoteAudio = false;
    }
  }

  void _stopPlaybackAtQueueEnd() {
    _linuxPlaybackStopped = true;
    final revision = ++_transportRevision;
    _crossfade?.cancel();
    if (_trackFade.enabled) _trackFade.hold();
    _setPlaying(false);
    _syncMediaSessionPlayback();
    updateRPC(force: true);
    unawaited(_saveState());
    unawaited(
      _enqueueAudioWork(() async {
        if (_stateDisposing || revision != _transportRevision) return;
        try {
          await audioPlayer.stop();
          if (_stateDisposing || revision != _transportRevision) return;
          _audioSourceTrackId = null;
          _audioSourceLocal = false;
          await _androidPlaybackFocus?.release();
        } finally {
          if (!_stateDisposing &&
              revision == _transportRevision &&
              _trackFade.enabled) {
            unawaited(_trackFade.reset());
          }
        }
      }),
    );
  }

  // ── Shuffle ──────────────────────────────────────────────────────────────

  void toggleShuffle() {
    if (playingQueue.isEmpty) return;
    setState(_playbackOrder.toggleShuffle);
    _crossfade?.reconcileNextSource();
    isShuffledNotifier.value = isShuffled;
    _syncMediaSessionPlayback();
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
    if (downloadedOnly.value &&
        playingTrack != null &&
        !isTrackDownloadComplete(playingTrack)) {
      return;
    }
    final trackRevision = _trackRevision;
    final seekRevision = ++_seekRevision;
    _fadeSeekRevision = seekRevision;
    _crossfade?.cancel(allowRetry: true);
    if (_trackFade.enabled) _trackFade.hold();
    currentPositionNotifier.value = pos;
    _linuxMediaSession?.seeked(pos);
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
          if (_fadeSeekRevision == seekRevision) _fadeSeekRevision = null;
          _statistics?.setSeeking(false);
        }
        if (!_isCurrentTrackRevision(trackRevision) ||
            seekRevision != _seekRevision) {
          return;
        }
        unawaited(_syncTrackFade(pos));

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
    final networkRevision = downloadedOnly.revision;
    _pendingTimedLyrics = null;
    _lyricTiming.value = null;
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
    if (isLocalMusic(trackObj)) {
      _commitLyrics(
        revision: revision,
        trackId: trackId,
        lyrics: parseLrcString(originalLyrics),
        plainText: originalLyrics,
      );
      return;
    }
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
      unawaited(_writeLyricsFile(localLrc, dbLyrics, trackId));
      return;
    }

    try {
      if (!_catalogRequestCurrent(networkRevision)) {
        _commitLyrics(
          revision: revision,
          trackId: trackId,
          lyrics: const [],
          plainText: '',
        );
        return;
      }
      final parsedUrl = Uri.https('lrclib.net', '/api/get', {
        'artist_name': artistName,
        'track_name': trackTitle,
        if (recordingDuration > 0) 'duration': '$recordingDuration',
      });
      final res = await _serverClient
          .get(parsedUrl)
          .timeout(const Duration(seconds: 15));
      if (!_isCurrentLyricsRequest(revision, trackId)) return;
      if (res.statusCode == HttpStatus.ok &&
          _catalogRequestCurrent(networkRevision)) {
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
          unawaited(_writeLyricsFile(localLrc, contents, trackId));
          unawaited(
            _saveLyricsToServer(trackId, contents, expectedLyricsVersion),
          );
          return;
        }
      }
    } catch (e) {
      if (_catalogRequestCurrent(networkRevision)) debugPrint("error $e");
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
    noLrcData = lyrics.isEmpty ? plainText : '';
    lrcLoading = false;
    if (lyrics.isNotEmpty) {
      _pendingTimedLyrics = (
        contents: plainText,
        trackId: trackId,
        revision: revision,
      );
    }
    _setLyricTimeline(lyrics);
    updateRPC(force: true);
    _prepareLyricTiming();
  }

  bool get _useLiveLyricPosition {
    final timing = _lyricTiming.value;
    return timing != null &&
        (timing.hasPreview || timing.advanceMilliseconds != 0);
  }

  void _setLyricTimeline(List<LyricLine> lyrics) {
    globalLyrics
      ..clear()
      ..addAll(lyrics);
    currentLine = lyricLineIndexAt(globalLyrics, currentPositionNotifier.value);
    uiSignal.value++;
  }

  void _prepareLyricTiming() {
    final input = _pendingTimedLyrics;
    if (input == null ||
        _audioSourceTrackId != input.trackId ||
        _settledTrackRevision != _trackRevision ||
        !_isCurrentLyricsRequest(input.revision, input.trackId)) {
      return;
    }
    _pendingTimedLyrics = null;
    final localAudio = _audioDeck.localAudio;
    final store = _lyricTimingStore;
    if (localAudio == null || store == null) return;

    final trackRevision = _trackRevision;
    final session = LyricTimingSession(
      store: store,
      textStore: _lyricTextEditStore,
      trackId: input.trackId,
      contents: input.contents,
      fingerprintAudio: localAudio.fingerprint,
      isCurrent: () =>
          _isCurrentTrackRevision(trackRevision) &&
          _isCurrentLyricsRequest(input.revision, input.trackId),
      onTimeline: (lyrics) {
        _setLyricTimeline(lyrics);
        if (isPlaying) updateRPC();
      },
    );
    unawaited(() async {
      try {
        await session.restore();
      } catch (error) {
        debugPrint('Could not restore lyric timing: ${error.runtimeType}');
      }
      try {
        await session.restoreTextEdits();
      } catch (error) {
        debugPrint('Could not restore lyric edits: ${error.runtimeType}');
      }
      if (session.isCurrent) _lyricTiming.value = session;
    }());
  }

  Future<void> _writeLyricsFile(File file, String contents, int trackId) async {
    try {
      await atomicFileStore.writeString(file, contents);
      lyricsSearchIndex.invalidate(trackId);
      if (!_stateDisposing && searchQuery.trim().isNotEmpty) {
        _scheduleLyricsSearch();
      }
    } catch (error) {
      debugPrint('Lyrics cache write failed: $error');
    }
  }

  Future<void> _saveLyricsToServer(
    int trackId,
    String lyricsText,
    String expectedLyricsVersion,
  ) async {
    if (trackId <= 0 || downloadedOnly.value) return;
    final revision = downloadedOnly.revision;
    try {
      final url = configuredServerUri('/api/tracks/$trackId/update_lyrics/');
      final res = await _serverClient
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'lyrics': lyricsText,
              'expected_lyrics_version': expectedLyricsVersion,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (!_catalogRequestCurrent(revision)) return;
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
        if (!_catalogRequestCurrent(revision)) return;
        await _trackUpdates?.acknowledgeLocalLyrics(trackId, lyricsText);
      } else if (res.statusCode == HttpStatus.conflict) {
        // A manual edit wins. Keep its server content and let normal polling offer it.
        unawaited(_trackUpdates?.checkNow());
      } else {
        debugPrint('Failed to update lyrics on server: ${res.body}');
      }
    } catch (e) {
      if (_catalogRequestCurrent(revision)) {
        debugPrint('Error updating lyrics on server: $e');
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Discord RPC
  // ═══════════════════════════════════════════════════════════════════════════

  DiscordAnimatedArtwork? _discordArtwork;
  DiscordCoverLookup? _discordCovers;

  bool _canPublishDiscord() =>
      !_stateDisposing &&
      discordActivityAllowed(
        discordPrivacyNotifier.value,
        isPlaying: isPlaying,
      ) &&
      playingIndex >= 0 &&
      playingIndex < playingQueue.length &&
      activeTrackNotifier.value?['id'] == playingTrack['id'];

  void updateRPC({bool force = false}) {
    _discordPresence?.refresh(force: force, clearBeforePublish: !isPlaying);
  }

  RPCActivity _buildDiscordActivity() {
    final trackData = playingTrack;
    final title = trackData['title'];
    final artist = trackData['album']['artist']['name'];
    final ownTrack = isLocalMusic(trackData);
    final publicCover = ownTrack ? null : _discordCovers?.imageFor(trackData);
    String? animatedCover;
    // Animation is a fallback, never an override of iTunes/Deezer/Last.fm.
    if (!ownTrack &&
        _discordCovers?.isResolved(trackData) == true &&
        publicCover?.isTrackCover != true) {
      animatedCover = _discordArtwork?.imageFor(trackData);
    }
    final largeImage =
        selectDiscordCoverImage(
          discovered: publicCover,
          stored: downloadedOnly.value
              ? null
              : trackData['album']?['cover']?.toString(),
          animated: animatedCover,
        ) ??
        'https://cdn.discordapp.com/app-icons/1480246072042590219/36573ffd3ca304580ed8968517090b0e.png';

    final duration = trackData['duration'];
    final durationMs = duration is num && duration.toInt() > 0
        ? duration.toInt() * 1000
        : null;
    final currentLyric = currentLine >= 0 && currentLine < globalLyrics.length
        ? globalLyrics[currentLine].txt
        : null;
    final start = discordStart;
    final String state;
    if (isPlaying) {
      state =
          currentLyric ??
          (currentLine == -1 && globalLyrics.isNotEmpty
              ? tr('lyrics_intro')
              : tr('listening_music'));
    } else {
      final liveDuration = fullDurationNotifier.value;
      final total = liveDuration > Duration.zero
          ? liveDuration
          : Duration(milliseconds: durationMs ?? 0);
      final position = formatDuration(currentPositionNotifier.value);
      state = tr('paused_at').replaceAll(
        '{position}',
        total > Duration.zero
            ? '$position / ${formatDuration(total)}'
            : position,
      );
    }
    return RPCActivity(
      details: '$title — $artist',
      state: state,
      activityType: ActivityType.listening,
      statusDisplayType: resolveDiscordStatusDisplayType(
        showLyrics: discordLyricsStatusNotifier.value,
        isPlaying: isPlaying,
        currentLyric: currentLyric,
      ),
      assets: RPCAssets(largeImage: largeImage),
      timestamps: isPlaying && start != null
          ? RPCTimestamps(
              start: start,
              end: durationMs == null ? null : start + durationMs,
            )
          : null,
      buttons: discordShowGitHubButtonNotifier.value
          ? const [
              RPCButton(
                label: 'GitHub',
                url: 'https://github.com/cursedworld/ShikiMusic',
              ),
            ]
          : null,
    );
  }

  void showLyricsScreen() {
    if (playingQueue.isEmpty) return;
    final proposals = downloadedOnly.value
        ? null
        : _lyricTimingProposals ??= LyricTimingProposalClient(
            client: _serverClient,
          );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PresentationOverlay(
          onSeekRequested: seekTo,
          timing: _lyricTiming,
          proposals: proposals,
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Dialogs
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> showPlaylistContextMenu(
    BuildContext context,
    Offset position,
    int index,
  ) async {
    if (index < 0 || index >= myPlaylists.length) return;
    Tooltip.dismissAllToolTips();
    final playlistId = myPlaylists[index]['id'] as int;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
    final point = overlay.globalToLocal(position);
    final touchMenu = MediaQuery.sizeOf(context).width < 800;
    final hasBackground = isPlaylistBackgroundName(
      myPlaylists[index]['background'],
    );
    PopupMenuItem<String> action(
      String value,
      IconData icon,
      String label, {
      bool destructive = false,
      bool enabled = true,
    }) => PopupMenuItem(
      value: value,
      enabled: enabled,
      height: touchMenu ? 48 : (destructive ? 36 : 40),
      child: Row(
        children: [
          Icon(
            icon,
            color: !enabled
                ? Colors.white38
                : destructive
                ? Colors.redAccent
                : Colors.white70,
            size: destructive ? 16 : 18,
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              tr(label),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: !enabled
                    ? Colors.white38
                    : destructive
                    ? Colors.redAccent
                    : Colors.white,
                fontSize: destructive ? 13 : 14,
              ),
            ),
          ),
        ],
      ),
    );
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(point.dx, point.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      color: const Color(0xFF242024),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Colors.white10),
      ),
      items: [
        action('rename', Icons.edit_outlined, 'playlist_rename'),
        action('artwork', Icons.image_outlined, 'playlist_change_artwork'),
        action(
          'background',
          Icons.wallpaper,
          hasBackground
              ? 'playlist_change_background'
              : 'playlist_add_background',
          enabled: !_pickingPlaylistBackground,
        ),
        if (hasBackground)
          action(
            'reset_background',
            Icons.restore,
            'playlist_reset_background',
          ),
        const PopupMenuDivider(height: 8),
        action(
          'delete',
          Icons.delete_outline,
          'playlist_delete',
          destructive: true,
        ),
      ],
    );
    if (!mounted || !context.mounted || value == null) return;
    final currentIndex = myPlaylists.indexWhere((p) => p['id'] == playlistId);
    if (currentIndex < 0) return;
    if (value == 'rename') {
      final name = await showDialog<String>(
        context: context,
        builder: (_) => PlaylistNameDialog(
          initialName: myPlaylists[currentIndex]['name']?.toString() ?? '',
        ),
      );
      if (mounted && name != null) {
        await updatePlaylistDetails(playlistId, {'name': name});
      }
    } else if (value == 'artwork') {
      await changePlaylistArtwork(playlistId);
    } else if (value == 'background') {
      await _choosePlaylistBackgroundPhoto(playlistId);
    } else if (value == 'reset_background') {
      await updatePlaylistDetails(playlistId, {'background': null});
    } else if (value == 'delete') {
      final background = myPlaylists[currentIndex]['background'];
      setState(() {
        if (navId == currentIndex + 3) {
          navId = 0;
          trackSelection.clear();
        } else if (navId > currentIndex + 3) {
          navId--;
        }
        myPlaylists.removeAt(currentIndex);
      });
      if (!await savePlaylists()) return;
      await _removeUnusedPlaylistBackground(background);
      if (mounted && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('playlist_deleted'))));
      }
    }
  }

  Future<void> _choosePlaylistBackgroundPhoto(int playlistId) async {
    if (_pickingPlaylistBackground) return;
    _pickingPlaylistBackground = true;
    void showStatus(String key) {
      if (!mounted || _stateDisposing) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr(key))));
    }

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: playlistPhotoExtensions,
        dialogTitle: tr('playlist_select_background_photo'),
      );
      if (!mounted || _stateDisposing || result == null) return;
      final path = result.files.single.path;
      if (path == null) throw const FormatException('Missing photo path');
      if (await setPlaylistBackgroundPhoto(playlistId, path)) {
        showStatus('playlist_background_saved');
      }
    } on FormatException {
      showStatus('playlist_background_invalid');
    } catch (_) {
      showStatus('playlist_background_failed');
    } finally {
      _pickingPlaylistBackground = false;
    }
  }

  Future<void> changePlaylistArtwork(int playlistId) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        dialogTitle: tr('select_image'),
      );
      final path = result?.files.single.path;
      if (path == null || !mounted) return;
      final artwork = await showPlaylistCropDialog(context, path);
      if (artwork == null || !mounted) return;
      final playlist = myPlaylists
          .where((p) => p['id'] == playlistId)
          .firstOrNull;
      if (playlist == null) return;
      final oldImage = playlist['image']?.toString() ?? '';
      final image = await saveCroppedPlaylistArtwork(
        Directory(localPath),
        artwork,
        playlistId,
      );
      if (!mounted) return;
      await _invalidatePlaylistArtwork(oldImage);
      if (image != oldImage) await _invalidatePlaylistArtwork(image);
      if (mounted) await updatePlaylistDetails(playlistId, {'image': image});
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('playlist_image_failed'))));
      }
    }
  }

  Future<bool> showCreatePlaylistDialog({
    Iterable<int> initialTrackIds = const [],
  }) async {
    Tooltip.dismissAllToolTips();
    final trackIds = initialTrackIds.where(_isLibraryTrackId).toSet().toList();
    String pName = "";
    CroppedPlaylistArtwork? selectedArtwork;
    bool selectingImage = false;
    bool saving = false;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            final dialog = AlertDialog(
              scrollable: true,
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
                  if (trackIds.isNotEmpty) ...[
                    Text(
                      tr(
                        'tracks_selected',
                      ).replaceAll('{count}', '${trackIds.length}'),
                      style: const TextStyle(color: Colors.white54),
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    key: const ValueKey('playlist_name'),
                    autofocus: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: tr('playlist_name'),
                      hintStyle: const TextStyle(color: Colors.white54),
                      enabledBorder: const UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: const UnderlineInputBorder(
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
                      onPressed: selectingImage || saving
                          ? null
                          : () async {
                              setStateDialog(() => selectingImage = true);
                              try {
                                final result = await FilePicker.platform
                                    .pickFiles(
                                      type: FileType.image,
                                      dialogTitle: tr('select_image'),
                                    );
                                final path = result?.files.single.path;
                                if (path == null || !ctx.mounted) return;
                                final artwork = await showPlaylistCropDialog(
                                  ctx,
                                  path,
                                );
                                if (artwork == null || !ctx.mounted) return;
                                setStateDialog(() => selectedArtwork = artwork);
                              } catch (_) {
                                if (ctx.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        tr('playlist_image_failed'),
                                      ),
                                    ),
                                  );
                                }
                              } finally {
                                if (ctx.mounted) {
                                  setStateDialog(() => selectingImage = false);
                                }
                              }
                            },
                      icon: const Icon(Icons.folder_open),
                      label: Text(
                        selectedArtwork != null
                            ? tr('image_selected')
                            : tr('select_image'),
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
                  onPressed: saving ? null : () => Navigator.pop(ctx, false),
                  child: Text(
                    tr('cancel'),
                    style: const TextStyle(color: Colors.white54),
                  ),
                ),
                TextButton(
                  onPressed: saving || selectingImage
                      ? null
                      : () async {
                          if (saving || selectingImage) return;
                          if (pName.trim().isNotEmpty) {
                            setStateDialog(() => saving = true);
                            final playlistId =
                                DateTime.now().microsecondsSinceEpoch;
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
                                      content: Text(
                                        tr('playlist_image_failed'),
                                      ),
                                    ),
                                  );
                                }
                                return;
                              }
                            }
                            if (!mounted || !ctx.mounted) return;
                            final saved = await createPlaylist(
                              pName,
                              trackIds: trackIds,
                              image: image,
                              playlistId: playlistId,
                            );
                            if (!ctx.mounted) return;
                            setStateDialog(() => saving = false);
                            if (saved) Navigator.pop(ctx, true);
                          }
                        },
                  child: Text(
                    tr('create'),
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            );
            return PopScope(canPop: !saving, child: dialog);
          },
        );
      },
    );
    return result ?? false;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  UI Builders
  // ═══════════════════════════════════════════════════════════════════════════

  Widget buildDownloadButton() {
    if (playingQueue.isEmpty) return const SizedBox(width: 24);
    final trackId = playingTrack['id'];
    final isDownloaded = isTrackDownloadComplete(playingTrack);
    final track = playingTrack;
    if (isLocalMusic(track)) {
      return LocalMusicIndicator(
        available: isDownloaded,
        onRemove: () => unawaited(_confirmRemoveOwnTrack(track)),
      );
    }
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
        onPressed: () => deleteDownloadedTrack(playingTrack),
      );
    } else if (downloadedOnly.value) {
      return const SizedBox(width: 24);
    } else {
      return IconButton(
        icon: const Icon(Icons.download, color: Colors.white54, size: 24),
        onPressed: () => downloadMediaFile(playingTrack),
      );
    }
  }

  void updateSearchQuery(String value) {
    trackSelection.clear();
    _lyricsSearchQueryRevision++;
    _lyricsSearchTimer?.cancel();
    void apply() {
      searchQuery = value;
      _preparingLyricsSearch =
          value.trim().isNotEmpty && navId != -1 && !lyricsSearchIndex.isReady;
    }

    if (mounted) {
      setState(apply);
    } else {
      apply();
    }
    if (value.trim().isEmpty) {
      lyricsSearchIndex.clear();
    } else if (navId != -1) {
      _scheduleLyricsSearch();
    }
  }

  void _selectNav(int id) {
    setState(() {
      navId = id;
      trackSelection.clear();
    });
    if (searchQuery.trim().isNotEmpty) updateSearchQuery(searchQuery);
  }

  void _scheduleLyricsSearch() {
    _lyricsSearchTimer?.cancel();
    _lyricsSearchTimer = Timer(
      const Duration(milliseconds: 180),
      () => unawaited(refreshLyricsSearch()),
    );
  }

  Future<void> refreshLyricsSearch() async {
    if (_stateDisposing || searchQuery.trim().isEmpty || navId == -1) return;
    final revision = _lyricsSearchQueryRevision;
    try {
      await lyricsSearchIndex.prepare(
        cachedTracks,
        lyricsFile: (id) =>
            _trackUpdates?.lyricsFile(id) ?? File('$localPath/track_$id.lrc'),
      );
    } catch (error) {
      debugPrint('Lyrics search preparation failed: $error');
    }
    if (_stateDisposing || revision != _lyricsSearchQueryRevision) return;
    if (mounted) {
      setState(() => _preparingLyricsSearch = false);
    } else {
      _preparingLyricsSearch = false;
    }
  }

  Future<void> submitSearch() async {
    final submitted = searchQuery;
    final revision = downloadedOnly.revision;
    if (navId != -1 && normalizeLyricsSearch(submitted).isNotEmpty) {
      await refreshLyricsSearch();
      if (_stateDisposing || submitted != searchQuery) return;
      final query = LyricsSearchQuery(submitted);
      if (cachedTracks.any(
        (track) => lyricsSearchIndex.matches(track['id'] as int, query),
      )) {
        return;
      }
    }
    if (!_catalogRequestCurrent(revision)) return;
    await downloadFromNetwork();
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
                    updateSearchQuery('');
                  },
                ),
              if (!downloadedOnly.value)
                IconButton(
                  key: const ValueKey('import_album_link'),
                  tooltip: _albumImportProgress == null
                      ? tr('import_album')
                      : '${tr('import_progress')}: $_albumImportProgress',
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
        onChanged: updateSearchQuery,
        onSubmitted: (_) => unawaited(submitSearch()),
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
            onPressed: () => _selectNav(0),
          ),
          const SizedBox(height: 20),
          IconButton(
            icon: Icon(
              Icons.favorite,
              color: navId == 1 ? accentColorNotifier.value : Colors.white54,
            ),
            tooltip: tr('sidebar_favorites'),
            onPressed: () => _selectNav(1),
          ),
          const SizedBox(height: 20),
          IconButton(
            icon: Icon(
              Icons.offline_pin,
              color: navId == 2 ? Colors.white : Colors.white54,
            ),
            tooltip: tr('sidebar_downloaded'),
            onPressed: () => _selectNav(2),
          ),
          const SizedBox(height: 20),
          IconButton(
            icon: Icon(
              Icons.people_alt_outlined,
              color: navId == -1 ? Colors.white : Colors.white54,
            ),
            tooltip: tr('sidebar_artists'),
            onPressed: () {
              _selectNav(-1);
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
                      onTap: () => _selectNav(i + 3),
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
                                ? _playlistThumbnail(
                                    ctx,
                                    myPlaylists[i]['image'],
                                    navId == i + 3 ? 36 : 28,
                                  )
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
          Tooltip(
            message: tr('create_playlist'),
            preferBelow: true,
            verticalOffset: 16,
            constraints: const BoxConstraints(minHeight: 24),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            textStyle: const TextStyle(fontSize: 12, color: Colors.black87),
            decoration: BoxDecoration(
              color: const Color(0xFFF3EFF1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: IconButton(
              icon: const Icon(Icons.add_box, color: Colors.white54),
              onPressed: showCreatePlaylistDialog,
            ),
          ),
          const SizedBox(height: 10),
          Tooltip(
            message: tr('settings'),
            preferBelow: true,
            verticalOffset: 16,
            constraints: const BoxConstraints(minHeight: 24),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            textStyle: const TextStyle(fontSize: 12, color: Colors.black87),
            decoration: BoxDecoration(
              color: const Color(0xFFF3EFF1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: IconButton(
              icon: const Icon(Icons.settings, color: Colors.white54),
              onPressed: _openSettings,
            ),
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
                        ? _playlistThumbnail(ctx, pl['image'], 32)
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
                    _selectNav(i + 3);
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
        _selectNav(id);
        Navigator.pop(context);
        if (id == -1) {
          unawaited(_syncArtistsCache());
        }
      },
    );
  }

  void _openSettings() {
    Tooltip.dismissAllToolTips();
    Navigator.push(
      context,
      SettingsRoute(
        builder: (context) => SettingsScreen(
          changeDownloadedOnly: _changeDownloadedOnly,
          storageBuilder: (_) => StorageScreen(
            loadUsage: loadStorageUsage,
            clearCache: clearAllCache,
          ),
          statistics: _statistics,
          getStatisticsTracks: () => cachedTracks,
          statisticsArtists: cachedArtists,
          onCreateStatisticsPlaylist: (name, ids) =>
              createPlaylist(name, trackIds: ids),
          beforeLibraryExport: () async {
            if (_downloadRecoveryFailed) {
              throw StateError(tr('download_recovery_failed'));
            }
            await atomicFileStore.writeString(
              File('$localPath/my_playlists.json'),
              jsonEncode(myPlaylists),
            );
            await atomicFileStore.writeString(
              File('$localPath/liked_tracks.json'),
              jsonEncode(favs.toList()),
            );
            await _persistOfflineTracks();
          },
        ),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  bool get _hasServerTransfer =>
      isSearchLoading ||
      _retryingAlbumTrack ||
      _bulkDownloadActive ||
      _mediaDownloadTasks.isNotEmpty ||
      downloadQueue.isNotEmpty;

  Future<bool> _changeDownloadedOnly(
    bool enabled,
    BuildContext settings,
  ) async {
    if (!enabled) {
      downloadedOnly.value = false;
      return true;
    }
    bool busy(String key) {
      if (settings.mounted) {
        ScaffoldMessenger.of(
          settings,
        ).showSnackBar(SnackBar(content: Text(tr(key))));
      }
      return false;
    }

    if (_hasServerTransfer) return busy('downloaded_only_busy');
    if (_openingRemoteAudio) return busy('downloaded_only_stream_busy');
    if (audioPlayer.source is UrlSource) {
      final trackRevision = _trackRevision;
      final stop = await showDialog<bool>(
        context: settings,
        builder: (context) => AlertDialog(
          title: Text(tr('downloaded_only')),
          content: Text(tr('downloaded_only_stop_stream')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('downloaded_only_stop_and_enable')),
            ),
          ],
        ),
      );
      if (stop != true || !settings.mounted || _stateDisposing) return false;
      if (_hasServerTransfer) return busy('downloaded_only_busy');
      if (_openingRemoteAudio || !_isCurrentTrackRevision(trackRevision)) {
        return busy('downloaded_only_stream_busy');
      }
      var applied = false;
      await _enqueueAudioWork(() async {
        if (!_isCurrentTrackRevision(trackRevision) || _hasServerTransfer) {
          return;
        }
        if (audioPlayer.source is UrlSource) {
          await audioPlayer.release();
          if (!_isCurrentTrackRevision(trackRevision)) return;
          _transportRevision++;
          _seekRevision++;
          _statistics?.endTrack();
          _audioSourceTrackId = null;
          _audioSourceLocal = false;
          _settledTrackRevision = -1;
          _resumeNeedsSource = true;
          _setPlaying(false);
          discordStart = null;
          unawaited(_saveState());
        }
        if (_hasServerTransfer) return;
        downloadedOnly.value = true;
        applied = true;
      });
      return applied ||
          busy(
            _hasServerTransfer
                ? 'downloaded_only_busy'
                : 'downloaded_only_stream_busy',
          );
    }

    downloadedOnly.value = true;
    return true;
  }

  // ── Mobile mini-player ───────────────────────────────────────────────────

  Widget _mobilePlaybackControls() => MobilePlaybackControls(
    isFavorite: favs.contains(playingTrack['id']),
    isPlaying: isPlaying,
    loopMode: loopMode,
    isShuffled: isShuffled,
    onFavorite: () => toggleFavorite(playingTrack['id']),
    onPrevious: prevTrack,
    onPlayPause: pauseTrack,
    onNext: nextTrack,
    onRepeat: toggleLoopMode,
    onShuffle: toggleShuffle,
  );

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
        child: LayoutBuilder(
          builder: (context, constraints) => Container(
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
                      child: AnimatedSwitcher(
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : mobileControlTransition,
                        child: Image(
                          key: ValueKey(playingTrack['id']),
                          image: coverThumbnail(
                            context,
                            getPictureProvider(playingTrack),
                            52,
                          ),
                          width: 52,
                          height: 52,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    // Title + Artist
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            trackDisplayTitle(playingTrack),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 3),
                          NowPlayingArtist(
                            track: playingTrack,
                            onOpen: _openArtistScreen,
                            fontSize: 13,
                          ),
                        ],
                      ),
                    ),
                    _buildPlayNextButton(),
                    if (constraints.maxWidth >= 500) _mobilePlaybackControls(),
                  ],
                ),
                if (constraints.maxWidth < 500)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: _mobilePlaybackControls(),
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
      ),
    );
  }

  // ── Desktop player panel ─────────────────────────────────────────────────

  Widget _buildDesktopArtwork() {
    final track = playingTrack;
    final trackId = track?['id'];
    final showClip =
        trackId is int &&
        supportsVideoClips &&
        playVideoClipNotifier.value &&
        (_expandedClipTrack == trackId ||
            (_videoTrackId == trackId && _isVideoInitialized));
    final cover = Builder(
      builder: (context) => Image(
        image: coverThumbnail(context, getPictureProvider(track), 240),
        fit: BoxFit.cover,
      ),
    );
    final artwork = RepaintBoundary(
      child: RotationTransition(
        turns: _vinylController ?? const AlwaysStoppedAnimation(0.0),
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
            child: showClip
                ? ClipPreview(
                    key: ValueKey(trackId),
                    controller: _visibleClip,
                    cover: cover,
                    onExpanded: (expanded) =>
                        _setClipExpanded(trackId, expanded),
                  )
                : cover,
          ),
        ),
      ),
    );
    if (showClip) return artwork;

    final vinyl = supportsVinylRotation && vinylRotationNotifier.value;
    // The old spin gestures are for the cover; clicking a clip expands it.
    return GestureDetector(
      onTap: vinyl
          ? () {
              setState(() {
                if (_vinylController!.isAnimating) {
                  _vinylController!.stop();
                  _vinylUserStopped = true;
                } else if (isPlaying) {
                  _vinylController!.repeat();
                  _vinylUserStopped = false;
                }
              });
            }
          : null,
      onDoubleTap: vinyl
          ? () {
              _vinylController!.stop();
              _vinylController!.value = 0.0;
              _vinylUserStopped = true;
              setState(() {});
            }
          : null,
      child: MouseRegion(
        cursor: supportsVinylRotation
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: artwork,
      ),
    );
  }

  Widget buildDesktopPlayer(BuildContext context) {
    return DesktopPlayerPanel(
      child: playingQueue.isEmpty
          ? const SizedBox.shrink()
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildDesktopArtwork(),
                const SizedBox(height: 30),
                Text(
                  trackDisplayTitle(playingTrack),
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
                NowPlayingArtist(
                  track: playingTrack,
                  onOpen: _openArtistScreen,
                  fontSize: 16,
                  centered: true,
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          if (_isMuted) {
                            volume = _volumeBeforeMute;
                          } else {
                            _volumeBeforeMute = volume;
                            volume = 0;
                          }
                        });
                        unawaited(_setPlaybackVolume(volume));
                        _syncLinuxMediaSession();
                        _saveState();
                      },
                      child: Icon(
                        _isMuted
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
                          setState(() => volume = v);
                          unawaited(_setPlaybackVolume(v));
                          _syncLinuxMediaSession();
                        },
                        onChangeEnd: (v) => _saveState(),
                      ),
                    ),
                    _buildPlayNextButton(),
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
                        tooltip: tr('taskbar_previous'),
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
                        tooltip: tr(
                          isPlaying ? 'taskbar_pause' : 'taskbar_play',
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
                        tooltip: tr('taskbar_next'),
                        onPressed: () => nextTrack(),
                      ),
                      const SizedBox(width: 10),
                      IconButton(
                        icon: const Icon(
                          Icons.mic,
                          color: Colors.white54,
                          size: 24,
                        ),
                        tooltip: tr('open_lyrics'),
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
                            ? tr('shuffle_off')
                            : tr('artist_shuffle'),
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
                        tooltip: tr(switch (loopMode) {
                          LoopMode.off => 'repeat_off',
                          LoopMode.list => 'repeat_queue',
                          LoopMode.one => 'repeat_track',
                        }),
                        onPressed: toggleLoopMode,
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildArtistsView(bool isMobile) => ArtistLibraryView(
    catalog: cachedArtists,
    tracks: cachedTracks,
    query: searchQuery,
    onOpen: _openArtistScreen,
  );

  // ═══════════════════════════════════════════════════════════════════════════
  //  Build
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    bool isMobile = MediaQuery.of(context).size.width < 800;
    final localOnly = downloadedOnly.value;
    final compactTracks =
        supportsCompactTrackList && compactTrackListNotifier.value;

    List<dynamic> finalListToRender;
    String headText = "";

    if (navId == -1) {
      finalListToRender = [];
      headText = tr('sidebar_artists');
    } else if (navId == 0) {
      finalListToRender = _matchedLocalServerIds.isEmpty
          ? cachedTracks
          : cachedTracks
                .where((track) => !_matchedLocalServerIds.contains(track['id']))
                .toList();
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

    final lyricsQuery = LyricsSearchQuery(searchQuery);
    final filterToLocal =
        localOnly &&
        navId != 2 &&
        (navId == 0 || searchQuery.trim().isNotEmpty);
    List<dynamic> finalList = finalListToRender
        .where(
          (track) =>
              (matchesTrackDetailsSearch(track, searchQuery) ||
                  lyricsSearchIndex.matches(track['id'] as int, lyricsQuery)) &&
              (!filterToLocal || isTrackDownloadComplete(track)),
        )
        .toList();
    // Drop selection for rows hidden by live catalog or lyric-search updates.
    if (trackSelection.isNotEmpty) {
      trackSelection.retain(finalList.map((track) => track['id'] as int));
    }
    final selectedTracks = trackSelection.inOrder(finalList);
    final allSelectedFavorited =
        selectedTracks.isNotEmpty &&
        selectedTracks.every((track) => favs.contains(track['id']));
    final requestedDownloads = selectedTracks.isEmpty
        ? finalList
        : selectedTracks;
    final downloadTargets = localOnly
        ? const <dynamic>[]
        : _ownTracks.isEmpty
        ? requestedDownloads
        : requestedDownloads
              .where((track) => downloadTrackId(track) != null)
              .toList();
    final visiblePlaylist = navId >= 3 && navId - 3 < myPlaylists.length
        ? myPlaylists[navId - 3]
        : null;
    final playlistId = visiblePlaylist?['id'] as int?;
    final playlistPhoto = visiblePlaylist?['background'];
    final trackMenuPlaylists = playlistId == null
        ? {for (final p in myPlaylists) p['id'] as int: p['name'].toString()}
        : const <int, String>{};
    final visibleTrackIds = playlistId == null
        ? const <int>[]
        : [for (final track in finalList) track['id'] as int];
    void onPlaylistReorder(int oldIndex, int newIndex) {
      if (playlistId == null) return;
      unawaited(
        reorderPlaylist(playlistId, visibleTrackIds, oldIndex, newIndex),
      );
    }

    var mainContent = Expanded(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: isMobile ? 15.0 : 30.0,
          vertical: 20.0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) =>
                  isMobile || constraints.maxWidth < (navId == 0 ? 680 : 620)
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
                            _buildCatalogSyncButton(),
                            if (navId == 0) _buildLocalMusicButton(),
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
                        if (downloadTargets.isNotEmpty)
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              icon: const Icon(
                                Icons.download_for_offline,
                                size: 18,
                              ),
                              label: Text(
                                tr(
                                  selectedTracks.isEmpty
                                      ? 'download_all'
                                      : 'download_selected_tracks',
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white10,
                                foregroundColor: Colors.white,
                                elevation: 0,
                              ),
                              onPressed: _bulkDownloadActive
                                  ? null
                                  : () => downloadAllTracks(downloadTargets),
                            ),
                          ),
                        const SizedBox(height: 10),
                        buildSearchField(isMobile: true),
                      ],
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                headText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
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
                        ),
                        const SizedBox(width: 12),
                        Row(
                          children: [
                            _buildTrackUpdatesButton(),
                            _buildCatalogSyncButton(),
                            if (navId == 0) _buildLocalMusicButton(),
                            if (downloadTargets.isNotEmpty)
                              ElevatedButton.icon(
                                icon: const Icon(
                                  Icons.download_for_offline,
                                  size: 18,
                                ),
                                label: Text(
                                  tr(
                                    selectedTracks.isEmpty
                                        ? 'download_all'
                                        : 'download_selected_tracks',
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.white10,
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                ),
                                onPressed: _bulkDownloadActive
                                    ? null
                                    : () => downloadAllTracks(downloadTargets),
                              ),
                            const SizedBox(width: 15),
                            buildSearchField(),
                          ],
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 20),
            if (selectedTracks.isNotEmpty)
              TrackSelectionBar(
                count: selectedTracks.length,
                onPlayNext: playingTrack == null
                    ? null
                    : () => playTracksNext(selectedTracks),
                onClear: clearTrackSelection,
                onCreatePlaylist: () => showCreatePlaylistDialog(
                  initialTrackIds: selectedTracks.map(
                    (track) => track['id'] as int,
                  ),
                ),
                playlists: {
                  for (final playlist in myPlaylists)
                    playlist['id'] as int: playlist['name'].toString(),
                },
                onPlaylistSelected: (id) => unawaited(
                  changePlaylistTracks(
                    id,
                    selectedTracks.map((track) => track['id'] as int),
                  ),
                ),
                onPlay: () {
                  final queue = List<dynamic>.of(selectedTracks);
                  clearTrackSelection();
                  startPlayback(queue, 0, playlistId: playlistId);
                },
              ),
            Expanded(
              child: navId == -1
                  ? _buildArtistsView(isMobile)
                  : isLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: Colors.redAccent),
                    )
                  : finalList.isEmpty && _preparingLyricsSearch
                  ? Center(
                      child: Text(
                        tr('search_lyrics_loading'),
                        style: const TextStyle(color: Colors.white54),
                      ),
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
                                      ? '${tr('import_progress')}: $_albumImportProgress'
                                      : tr('server_waiting_for_response'),
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
                                      ? tr(
                                          'search_no_matches',
                                        ).replaceAll('{query}', searchQuery)
                                      : navId == 1
                                      ? tr('favorites_empty')
                                      : navId >= 3
                                      ? tr('playlist_empty')
                                      : localOnly
                                      ? tr('downloaded_only_empty')
                                      : tr('no_data'),
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 16,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                if (searchQuery.isNotEmpty && !localOnly) ...[
                                  const SizedBox(height: 20),
                                  ElevatedButton.icon(
                                    onPressed: downloadFromNetwork,
                                    icon: const Icon(Icons.cloud_sync),
                                    label: Text(tr('search_online')),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.redAccent,
                                      foregroundColor: Colors.white,
                                    ),
                                  ),
                                ] else if (searchQuery.isEmpty &&
                                    navId == 0 &&
                                    localPath.isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  TextButton.icon(
                                    onPressed: () =>
                                        unawaited(showLocalMusicImport()),
                                    icon: const Icon(
                                      Icons.audio_file_outlined,
                                      size: 20,
                                    ),
                                    label: Text(tr('local_import')),
                                  ),
                                ],
                              ],
                            ),
                    )
                  // ── Track list with smooth scroll ──
                  : PlaylistTrackList(
                      key: ValueKey('track_list_$navId'),
                      onReorder: playlistId == null ? null : onPlaylistReorder,
                      itemCount: finalList.length,
                      itemBuilder: (ctx, idx) {
                        final currentObject = finalList[idx];
                        final ownTrack = isLocalMusic(currentObject);
                        final trackId = currentObject['id'];
                        final editDetails = _trackDetailsAction(currentObject);
                        final hasArtistOverride =
                            trackDetailsPatch(currentObject)?.artist != null;
                        final isActiveTrack =
                            (playingQueue.isNotEmpty &&
                                playingIndex < playingQueue.length)
                            ? currentObject['id'] == playingTrack['id']
                            : false;
                        final isDownloaded = isTrackDownloadComplete(
                          currentObject,
                        );
                        final unavailable = localOnly && !isDownloaded;
                        final isDownloading = downloadQueue.contains(trackId);
                        final isFavorited = favs.contains(trackId);
                        final isSelected = trackSelection.contains(
                          trackId as int,
                        );
                        final actionTracks = isSelected
                            ? selectedTracks
                            : [currentObject];
                        final rowFavorited = isSelected
                            ? allSelectedFavorited
                            : isFavorited;
                        final cover = ClipRRect(
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
                        );

                        return Container(
                          key: ValueKey(trackId),
                          margin: EdgeInsets.only(
                            bottom: compactTracks ? compactTrackRowGap : 10,
                          ),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Colors.black.withValues(alpha: 0.16)
                                : isActiveTrack
                                ? Colors.white.withValues(alpha: 0.1)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: ListTile(
                            selected: isSelected,
                            selectedTileColor: Colors.transparent,
                            // Keep ListTile density and control bounds intact.
                            // https://api.flutter.dev/flutter/material/ListTile/contentPadding.html
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: compactTracks ? 0 : 5,
                            ),
                            leading: playlistId != null
                                ? PlaylistTrackDragHandle(
                                    key: ValueKey('playlist_drag_$trackId'),
                                    index: idx,
                                    itemCount: finalList.length,
                                    onReorder: onPlaylistReorder,
                                    artwork: cover,
                                    touchMode: isMobile,
                                  )
                                : cover,
                            title: Text(
                              trackDisplayTitle(currentObject),
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
                              cursor: unavailable || hasArtistOverride
                                  ? SystemMouseCursors.basic
                                  : SystemMouseCursors.click,
                              child: GestureDetector(
                                onTap: unavailable
                                    ? null
                                    : () {
                                        if (trackSelection.isNotEmpty ||
                                            HardwareKeyboard
                                                .instance
                                                .isControlPressed ||
                                            HardwareKeyboard
                                                .instance
                                                .isMetaPressed ||
                                            HardwareKeyboard
                                                .instance
                                                .isShiftPressed) {
                                          handleTrackTap(
                                            finalList,
                                            idx,
                                            touch: isMobile,
                                            playlistId: playlistId,
                                          );
                                          return;
                                        }
                                        if (hasArtistOverride) return;
                                        final a =
                                            currentObject['album']?['artist'];
                                        final aId = a?['id'] is int
                                            ? a['id'] as int
                                            : 0;
                                        final aName =
                                            a?['name']?.toString() ?? '';
                                        if (aName.isNotEmpty) {
                                          _openArtistScreen(aId, aName);
                                        }
                                      },
                                child: Text(
                                  unavailable
                                      ? tr('downloaded_only_unavailable')
                                      : trackDisplayArtist(currentObject),
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
                                      key: ValueKey('track_remove_$trackId'),
                                      onPressed: () => unawaited(
                                        changePlaylistTracks(
                                          playlistId!,
                                          actionTracks.map(
                                            (t) => t['id'] as int,
                                          ),
                                          remove: true,
                                        ),
                                      ),
                                    ),
                                  if (editDetails != null ||
                                      (ownTrack && !localOnly) ||
                                      playingTrack != null ||
                                      (playlistId == null &&
                                          myPlaylists.isNotEmpty))
                                    TrackPlayNextMenu(
                                      key: ValueKey(
                                        playlistId == null &&
                                                myPlaylists.isNotEmpty
                                            ? 'track_playlist_$trackId'
                                            : 'track_play_next_$trackId',
                                      ),
                                      onEditDetails: editDetails,
                                      onPlayNext: playingTrack == null
                                          ? null
                                          : () => playTracksNext(actionTracks),
                                      playNextCount: actionTracks.length,
                                      onMatchLocal: ownTrack && !localOnly
                                          ? () => unawaited(
                                              _matchOwnTrack(currentObject),
                                            )
                                          : null,
                                      playlists: trackMenuPlaylists,
                                      onPlaylistSelected: (pId) => unawaited(
                                        changePlaylistTracks(
                                          pId,
                                          actionTracks.map(
                                            (t) => t['id'] as int,
                                          ),
                                        ),
                                      ),
                                    ),
                                  IconButton(
                                    key: ValueKey('track_favorite_$trackId'),
                                    icon: Icon(
                                      rowFavorited
                                          ? Icons.favorite
                                          : Icons.favorite_border,
                                      color: rowFavorited
                                          ? Colors.redAccent
                                          : Colors.white54,
                                    ),
                                    onPressed: () => unawaited(
                                      toggleTrackFavorites(
                                        actionTracks.map((t) => t['id'] as int),
                                      ),
                                    ),
                                  ),
                                  if (isSelected && downloadTargets.isNotEmpty)
                                    IconButton(
                                      key: ValueKey('track_download_$trackId'),
                                      tooltip: tr('download_selected_tracks'),
                                      onPressed: _bulkDownloadActive
                                          ? null
                                          : () =>
                                                downloadAllTracks(actionTracks),
                                      icon: const Icon(
                                        Icons.download,
                                        color: Colors.white54,
                                      ),
                                    )
                                  else if (ownTrack)
                                    LocalMusicIndicator(
                                      key: ValueKey(
                                        'local_music_remove_$trackId',
                                      ),
                                      available: isDownloaded,
                                      onRemove: () => unawaited(
                                        _confirmRemoveOwnTrack(currentObject),
                                      ),
                                    )
                                  else if (isDownloading)
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
                                  else if (!localOnly)
                                    IconButton(
                                      icon: const Icon(
                                        Icons.download,
                                        color: Colors.white54,
                                      ),
                                      onPressed: () =>
                                          downloadMediaFile(currentObject),
                                    ),
                                  if (isActiveTrack && isPlaying) ...[
                                    const SizedBox(width: 15),
                                    const Icon(
                                      Icons.graphic_eq,
                                      color: Colors.redAccent,
                                    ),
                                  ] else if (!unavailable &&
                                      (!isMobile ||
                                          playlistId == null ||
                                          playingTrack == null)) ...[
                                    const SizedBox(width: 15),
                                    const Icon(
                                      Icons.play_arrow,
                                      color: Colors.white54,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            onTap: () => handleTrackTap(
                              finalList,
                              idx,
                              touch: isMobile,
                              playlistId: playlistId,
                            ),
                            onLongPress: isMobile
                                ? () => setState(
                                    () => trackSelection.toggle(trackId),
                                  )
                                : null,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );

    if (isMobile) {
      mainContent = Expanded(
        child: MobileSectionTransition(
          section: navId,
          child: mainContent.child,
        ),
      );
    }

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
          builder: (context, customBg, child) => PlayerBackdrop(
            directory: globalLocalPath,
            name: customBg,
            dimming: backgroundDimmingNotifier,
            playlistPhoto: isPlaylistBackgroundName(playlistPhoto)
                ? playlistPhoto as String
                : null,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: _gradientFromAccent(accentColorNotifier.value),
            ),
            allowMotion: !_isVideoInitialized || !playVideoClipNotifier.value,
            child: child!,
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
                    if (playingQueue.isNotEmpty) buildDesktopPlayer(context),
                  ],
                ),
        ),
      ),
    );
  }
}
