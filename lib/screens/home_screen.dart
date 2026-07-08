import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_discord_rpc/flutter_discord_rpc.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audio_service/audio_service.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_media_session/flutter_media_session.dart' as fms;
import 'package:image/image.dart' as img;
import 'package:video_player/video_player.dart';

import '../globals.dart';
import '../localization.dart';
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

// ═══════════════════════════════════════════════════════════════════════════
//  MainAppScreen
// ═══════════════════════════════════════════════════════════════════════════

class MainAppScreen extends StatefulWidget {
  const MainAppScreen({super.key});

  @override
  State<MainAppScreen> createState() => MainAppScreenState();
}

class MainAppScreenState extends State<MainAppScreen>
    with TickerProviderStateMixin {
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
          await file.writeAsBytes(jpegBytes);
          return true;
        }
      }
    } catch (e) {
      debugPrint('Error downloading or cropping cover: $e');
    }
    // Clean up if it failed or was not a valid cropped image
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
    return false;
  }

  /// Asynchronously download cover art to local storage for the lock screen widget
  Future<void> _ensureCoverDownloaded(dynamic track) async {
    if (isDesktop || localPath.isEmpty) return;
    final id = track['id'];
    final coverFile = File('$localPath/cover_$id.jpg');

    if (await _isCoverValidAndSquare(coverFile)) return;

    // Delete invalid/uncropped file before re-downloading
    try {
      if (await coverFile.exists()) {
        await coverFile.delete();
      }
    } catch (_) {}

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
  // ignore: unused_field
  int _syncTicks = 0;

  // ── Vinyl rotation animation (desktop) ───────────────────────────────────
  late AnimationController _vinylController;
  bool _vinylUserStopped = false;

  VideoPlayerController? _videoController;
  bool _isVideoInitialized = false;

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

    startData();

    // Request notification permission for background media controls on Android 13+
    _requestNotificationPermission();

    // Initialize Media3 session for notification/lock screen
    _initMediaSession();

    HardwareKeyboard.instance.addHandler(_handleGlobalKeys);

    if (isDesktop) {
      try {
        FlutterDiscordRPC.instance.connect();
      } catch (e) {
        debugPrint('Discord RPC connect failed: $e');
      }
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
    audioPlayer.onDurationChanged.listen((d) {
      fullDurationNotifier.value = d;
      // Cache track duration for playlist stats
      if (playingQueue.isNotEmpty && playingIndex < playingQueue.length) {
        trackDurations[playingQueue[playingIndex]['id'] as int] = d.inSeconds;
      }
      _syncMediaSessionMetadata();
    });
    audioPlayer.onPositionChanged.listen((p) {
      if (mounted) currentPositionNotifier.value = p;
    });

    audioPlayer.onPlayerComplete.listen((event) {
      if (loopMode == LoopMode.one) {
        startPlayback(playingQueue, playingIndex);
      } else {
        nextTrack();
      }
    });

    backgroundPollingTimer = Timer.periodic(
      const Duration(milliseconds: 1000),
      (_) async {
        if (!isPlaying || globalLyrics.isEmpty) return;
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
  void dispose() {
    vinylRotationNotifier.removeListener(_onVinylRotationChanged);
    activeTrackNotifier.removeListener(_onActiveTrackChanged);
    isPlayingNotifier.removeListener(_syncVideoPlayState);
    playVideoClipNotifier.removeListener(_onVideoSettingChanged);
    uiSignal.removeListener(_syncVideoDrift);
    _videoController?.dispose();
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
      try {
        FlutterDiscordRPC.instance.disconnect();
        FlutterDiscordRPC.instance.dispose();
      } catch (e) {
        debugPrint('Discord RPC dispose failed: $e');
      }
    } else {
      WakelockPlus.disable();
    }

    audioPlayer.dispose();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Helpers
  // ═══════════════════════════════════════════════════════════════════════════

  void _onActiveTrackChanged() {
    if (mounted) {
      _initializeVideo(activeTrackNotifier.value);
    }
  }

  void _syncVideoPlayState() {
    if (_videoController == null || !_isVideoInitialized) return;
    if (isPlayingNotifier.value) {
      _videoController!.play();
    } else {
      _videoController!.pause();
    }
  }

  void _onVideoSettingChanged() {
    if (mounted) {
      _initializeVideo(activeTrackNotifier.value);
    }
  }

  String _resolveAbsoluteUrl(String url) {
    if (url.startsWith('/')) {
      return 'http://192.168.31.13:8000$url';
    }
    return url;
  }

  void _syncVideoDrift() {
    if (_videoController == null || !_isVideoInitialized || !mounted) return;
    final audioPos = currentPositionNotifier.value;
    final videoPos = _videoController!.value.position;
    final diff = (audioPos.inMilliseconds - videoPos.inMilliseconds).abs();
    if (diff > 1200) {
      _videoController!.seekTo(audioPos);
    }
  }

  void _fetchAndDownloadClip(int trackId) async {
    try {
      final res = await http.post(
        Uri.parse('http://192.168.31.13:8000/api/tracks/$trackId/download_clip/'),
      );
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        var videoUrl = data['video_url']?.toString();
        if (videoUrl != null && mounted) {
          videoUrl = _resolveAbsoluteUrl(videoUrl);
          // Update track in memory queue and cache
          for (var i = 0; i < playingQueue.length; i++) {
            if (playingQueue[i]['id'] == trackId) {
              setState(() {
                playingQueue[i]['video_file'] = videoUrl;
              });
            }
          }
          if (activeTrackNotifier.value != null && activeTrackNotifier.value['id'] == trackId) {
            setState(() {
              activeTrackNotifier.value['video_file'] = videoUrl;
            });
            _initializeVideo(activeTrackNotifier.value);
          }

          // If track is downloaded, download the clip in background for offline use
          if (isTrackLocal(trackId)) {
            final videoFile = File('$localPath/video_$trackId.mp4');
            if (!await videoFile.exists()) {
              final videoStream = await http.get(Uri.parse(videoUrl));
              await videoFile.writeAsBytes(videoStream.bodyBytes);
            }
          }

          // Update cachedTracks local cache to avoid future searches
          for (var i = 0; i < cachedTracks.length; i++) {
            if (cachedTracks[i]['id'] == trackId) {
              cachedTracks[i]['video_file'] = videoUrl;
            }
          }
          final offlineJsonFile = File('$localPath/offline_tracks.json');
          await offlineJsonFile.writeAsString(json.encode(cachedTracks));
        }
      }
    } catch (e) {
      debugPrint('Error fetching video clip background: $e');
    }
  }

  void _initializeVideo(dynamic trackData) async {
    if (_videoController != null) {
      final oldController = _videoController!;
      _videoController = null;
      _isVideoInitialized = false;
      if (mounted) setState(() {});
      await oldController.dispose();
    }

    if (trackData == null || !playVideoClipNotifier.value) return;

    final videoFileUrl = trackData['video_file'];
    if (videoFileUrl == null || videoFileUrl.toString().isEmpty) {
      final trackId = trackData['id'];
      _fetchAndDownloadClip(trackId);
      return;
    }

    try {
      final trackId = trackData['id'];
      final localVideoFile = File('$localPath/video_$trackId.mp4');
      VideoPlayerController controller;

      if (localVideoFile.existsSync()) {
        controller = VideoPlayerController.file(localVideoFile);
      } else {
        final resolvedUrl = _resolveAbsoluteUrl(videoFileUrl.toString());
        controller = VideoPlayerController.networkUrl(Uri.parse(resolvedUrl));
      }

      _videoController = controller;
      await controller.initialize();

      if (!mounted || _videoController != controller) {
        await controller.dispose();
        return;
      }

      setState(() {
        _isVideoInitialized = true;
      });

      await controller.setVolume(0.0); // Muted background playback
      await controller.setLooping(true);

      if (isPlayingNotifier.value) {
        await controller.play();
      }

      final currentPos = currentPositionNotifier.value;
      await controller.seekTo(currentPos);
    } catch (e) {
      debugPrint('Error initializing circular video player: $e');
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
    } else if (isPlaying && !_vinylUserStopped) {
      _vinylController.repeat();
    }
  }

  void _setPlaying(bool value) {
    if (mounted) setState(() => isPlaying = value);
    isPlayingNotifier.value = value;
    if (value && !_vinylUserStopped && vinylRotationNotifier.value) {
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

  Future<void> startData() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final appDir = Directory('${docsDir.path}/ShikiMusic');
    if (!appDir.existsSync()) {
      appDir.createSync(recursive: true);
    }

    // Migrate existing tracks, covers, and config files from root Documents directory
    try {
      final entities = docsDir.listSync();
      for (final entity in entities) {
        if (entity is File) {
          final name = entity.path.split(Platform.pathSeparator).last;
          if (name.startsWith('track_') ||
              name.startsWith('cover_') ||
              name == 'liked_tracks.json' ||
              name == 'my_playlists.json' ||
              name == 'offline_tracks.json' ||
              name == 'app_state.json' ||
              name == 'shiki_settings.json') {
            final newPath = '${appDir.path}/$name';
            try {
              await entity.rename(newPath);
              debugPrint('Migrated: $name -> $newPath');
            } catch (e) {
              // Fallback to copy & delete if rename fails across different partitions
              await entity.copy(newPath);
              await entity.delete();
              debugPrint('Migrated via copy/delete: $name -> $newPath');
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Migration failed: $e');
    }

    localPath = appDir.path;
    globalLocalPath = localPath;
    await readFavorites();
    await readPlaylists();
    await syncDatabase();
    await _loadState();
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
      await f.writeAsString(json.encode(data));
    } catch (e) {
      debugPrint(e.toString());
    }
  }

  Future<void> _loadState() async {
    if (localPath.isEmpty) return;
    try {
      final f = File('$localPath/app_state.json');
      if (await f.exists()) {
        final data = json.decode(await f.readAsString());

        if (data['volume'] != null) {
          volume = (data['volume'] as num).toDouble();
          audioPlayer.setVolume(volume);
        }
        if (data['loopMode'] != null) {
          loopMode = LoopMode.values[data['loopMode']];
        }
        if (data['isShuffled'] != null) {
          isShuffled = data['isShuffled'];
        }
        if (data['unshuffledQueue'] != null) {
          _unshuffledQueue = List<dynamic>.from(data['unshuffledQueue']);
        }

        if (data['playingQueue'] != null && data['playingQueue'].isNotEmpty) {
          playingQueue = List<dynamic>.from(data['playingQueue']);
          playingIndex = data['playingIndex'] ?? 0;

          final targetTrack = playingQueue[playingIndex];
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

          final localTrackPath = File(
            '$localPath/track_${targetTrack['id']}.mp3',
          );
          if (await localTrackPath.exists()) {
            await audioPlayer.setSource(DeviceFileSource(localTrackPath.path));
          } else {
            await audioPlayer.setSource(UrlSource(targetTrack['audio_file']));
          }

          if (data['position'] != null) {
            final pos = Duration(milliseconds: data['position']);
            await audioPlayer.seek(pos);
            currentPositionNotifier.value = pos;
          }

          fetchLyrics(targetTrack);
          setState(() {});
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
        setState(() => favs = Set<int>.from(list));
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
        setState(() {
          myPlaylists = List<Map<String, dynamic>>.from(
            list.map((e) => Map<String, dynamic>.from(e)),
          );
        });
      } catch (e) {
        debugPrint(e.toString());
      }
    }
  }

  Future<void> savePlaylists() async {
    final f = File('$localPath/my_playlists.json');
    await f.writeAsString(json.encode(myPlaylists));
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Network
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> syncDatabase() async {
    final offlineJsonFile = File('$localPath/offline_tracks.json');
    try {
      final res = await http
          .get(Uri.parse('http://192.168.31.13:8000/api/tracks/'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final data = json.decode(utf8.decode(res.bodyBytes));
        await offlineJsonFile.writeAsString(json.encode(data));
        setState(() {
          cachedTracks = data;
          isLoading = false;
        });
      }
    } catch (e) {
      if (await offlineJsonFile.exists()) {
        setState(() {
          cachedTracks = json.decode(offlineJsonFile.readAsStringSync());
          isLoading = false;
        });
      } else {
        setState(() => isLoading = false);
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
      final queryEndpoint = Uri.parse(
        'http://192.168.31.13:8000/api/smart_search/?q=${Uri.encodeComponent(searchQuery)}',
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
    return File('$localPath/track_$id.mp3').existsSync();
  }

  Future<void> downloadMediaFile(dynamic mediaObj) async {
    final trackId = mediaObj['id'];
    setState(() => downloadQueue.add(trackId));
    try {
      final audioFile = File('$localPath/track_$trackId.mp3');
      final coverFile = File('$localPath/cover_${trackId}_${getCoverFileName(mediaObj)}');
      final lrcFile = File('$localPath/track_$trackId.lrc');

      if (!await audioFile.exists()) {
        final audioStream = await http.get(Uri.parse(mediaObj['audio_file']));
        await audioFile.writeAsBytes(audioStream.bodyBytes);
      }
      if (!await _isCoverValidAndSquare(coverFile)) {
        try {
          if (await coverFile.exists()) {
            await coverFile.delete();
          }
        } catch (_) {}
        await _downloadAndCropCover(
          mediaObj['album']['cover'].toString(),
          coverFile,
        );
      }
      if (!await lrcFile.exists() &&
          mediaObj['lyrics'] != null &&
          mediaObj['lyrics'].toString().trim().isNotEmpty) {
        await lrcFile.writeAsString(mediaObj['lyrics'].toString());
      }

      // Check if clip exists or download it on the server first
      var videoFileUrl = mediaObj['video_file']?.toString();
      if (videoFileUrl == null || videoFileUrl.trim().isEmpty) {
        try {
          final res = await http.post(
            Uri.parse('http://192.168.31.13:8000/api/tracks/$trackId/download_clip/'),
          ).timeout(const Duration(seconds: 15));
          if (res.statusCode == 200) {
            final data = json.decode(res.body);
            videoFileUrl = data['video_url']?.toString();
            if (videoFileUrl != null) {
              videoFileUrl = _resolveAbsoluteUrl(videoFileUrl);
              // Save to memory lists
              for (var i = 0; i < playingQueue.length; i++) {
                if (playingQueue[i]['id'] == trackId) {
                  playingQueue[i]['video_file'] = videoFileUrl;
                }
              }
              for (var i = 0; i < cachedTracks.length; i++) {
                if (cachedTracks[i]['id'] == trackId) {
                  cachedTracks[i]['video_file'] = videoFileUrl;
                }
              }
              final offlineJsonFile = File('$localPath/offline_tracks.json');
              await offlineJsonFile.writeAsString(json.encode(cachedTracks));
            }
          }
        } catch (_) {}
      }

      if (videoFileUrl != null && videoFileUrl.trim().isNotEmpty) {
        final videoFile = File('$localPath/video_$trackId.mp4');
        if (!await videoFile.exists()) {
          final resolvedUrl = _resolveAbsoluteUrl(videoFileUrl);
          final videoStream = await http.get(Uri.parse(resolvedUrl));
          await videoFile.writeAsBytes(videoStream.bodyBytes);
        }
      }
    } catch (e) {
      debugPrint(e.toString());
    }
    setState(() => downloadQueue.remove(trackId));
  }

  Future<void> downloadAllTracks(List<dynamic> tracksToDownload) async {
    for (var track in tracksToDownload) {
      final trackId = track['id'];
      if (!isTrackLocal(trackId) && !downloadQueue.contains(trackId)) {
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
    await favFile.writeAsString(json.encode(favs.toList()));
  }

  ImageProvider getPlaylistImage(String pathOrUrl) {
    if (pathOrUrl.startsWith('http')) return NetworkImage(pathOrUrl);
    return FileImage(File(pathOrUrl));
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Playback
  // ═══════════════════════════════════════════════════════════════════════════

  void startPlayback(List<dynamic> targetQueue, int index) async {
    if (targetQueue.isEmpty) return;
    if (isPremium) playCount++;

    setState(() {
      playingQueue = List.from(targetQueue);
      playingIndex = index;
    });
    _setPlaying(true);

    // Reset shuffle when starting fresh from a list tap
    isShuffled = false;
    _unshuffledQueue = [];

    final targetTrack = playingQueue[playingIndex];
    activeTrackNotifier.value = targetTrack;
    _ensureCoverDownloaded(targetTrack);

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

    final localTrackPath = File('$localPath/track_${targetTrack['id']}.mp3');
    if (await localTrackPath.exists()) {
      await audioPlayer.play(DeviceFileSource(localTrackPath.path));
    } else {
      await audioPlayer.play(UrlSource(targetTrack['audio_file']));
    }

    discordStart = DateTime.now().millisecondsSinceEpoch;
    fetchLyrics(targetTrack);
    _syncMediaSessionMetadata();
    _syncMediaSessionPlayback();
    _saveState();
  }

  void pauseTrack() async {
    if (playingQueue.isEmpty) return;
    if (isPlaying) {
      await audioPlayer.pause();
      _setPlaying(false);
      updateRPC(force: true);
    } else {
      await audioPlayer.resume();
      _setPlaying(true);
      discordStart =
          DateTime.now().millisecondsSinceEpoch -
          currentPositionNotifier.value.inMilliseconds;
      updateRPC(force: true);
    }
    _syncMediaSessionPlayback();
    _saveState();
  }

  void nextTrack() {
    if (playingQueue.isEmpty) return;
    if (playingIndex < playingQueue.length - 1) {
      _playIndex(playingIndex + 1);
    } else {
      if (loopMode == LoopMode.list || loopMode == LoopMode.one) {
        _playIndex(0);
      } else {
        audioPlayer.stop();
        _setPlaying(false);
        updateRPC(force: true);
      }
    }
  }

  void prevTrack() {
    if (playingQueue.isEmpty) return;
    if (currentPositionNotifier.value.inSeconds > 3) {
      audioPlayer.seek(Duration.zero);
      _saveState();
    } else {
      if (playingIndex > 0) {
        _playIndex(playingIndex - 1);
      } else {
        if (loopMode == LoopMode.list || loopMode == LoopMode.one) {
          _playIndex(playingQueue.length - 1);
        } else {
          audioPlayer.seek(Duration.zero);
          _saveState();
        }
      }
    }
  }

  /// Internal: play a specific index within the *current* queue (preserves
  /// shuffle state).
  void _playIndex(int index) async {
    if (playingQueue.isEmpty) return;

    setState(() => playingIndex = index);
    _setPlaying(true);

    final targetTrack = playingQueue[playingIndex];
    activeTrackNotifier.value = targetTrack;
    _ensureCoverDownloaded(targetTrack);

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

    final localTrackPath = File('$localPath/track_${targetTrack['id']}.mp3');
    if (await localTrackPath.exists()) {
      await audioPlayer.play(DeviceFileSource(localTrackPath.path));
    } else {
      await audioPlayer.play(UrlSource(targetTrack['audio_file']));
    }

    discordStart = DateTime.now().millisecondsSinceEpoch;
    fetchLyrics(targetTrack);
    _syncMediaSessionMetadata();
    _syncMediaSessionPlayback();
    _saveState();
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

  void seekTo(Duration pos) async {
    await audioPlayer.seek(pos);
    currentPositionNotifier.value = pos;
    discordStart = DateTime.now().millisecondsSinceEpoch - pos.inMilliseconds;
    
    // Immediately seek the video controller to match the audio seek
    if (_videoController != null && _isVideoInitialized) {
      await _videoController!.seekTo(pos);
    }
    
    checkLyrics(pos);
    _syncMediaSessionPlayback();
  }

  Future<void> fetchLyrics(dynamic trackObj) async {
    globalLyrics.clear();
    noLrcData = "";
    currentLine = -1;
    lrcLoading = true;
    uiSignal.value++;

    String artistName = trackObj['album']['artist']['name'];
    String trackTitle = trackObj['title'];
    int trackId = trackObj['id'];

    void parseLrcString(String lrcContent) {
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
            globalLyrics.add(
              LyricLine(
                Duration(minutes: min, seconds: sec, milliseconds: ms),
                txt,
                txt,
              ),
            );
          }
        }
      }
    }

    final localLrc = File('$localPath/track_$trackId.lrc');
    if (await localLrc.exists()) {
      final fileContent = await localLrc.readAsString();
      parseLrcString(fileContent);
      if (globalLyrics.isEmpty) noLrcData = fileContent;
      lrcLoading = false;
      uiSignal.value++;
      updateRPC(force: true);
      return;
    }

    if (trackObj['lyrics'] != null &&
        trackObj['lyrics'].toString().trim().isNotEmpty) {
      final dbLyrics = trackObj['lyrics'].toString();
      parseLrcString(dbLyrics);
      if (globalLyrics.isEmpty) noLrcData = dbLyrics;
      try {
        await localLrc.writeAsString(dbLyrics);
      } catch (_) {}
      lrcLoading = false;
      uiSignal.value++;
      updateRPC(force: true);
      return;
    }

    try {
      final parsedUrl = Uri.parse(
        'https://lrclib.net/api/get?artist_name=${Uri.encodeComponent(artistName)}&track_name=${Uri.encodeComponent(trackTitle)}',
      );
      final res = await http.get(parsedUrl).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final jsonData = json.decode(utf8.decode(res.bodyBytes));
        final syncedText = jsonData['syncedLyrics'];
        final plainText = jsonData['plainLyrics'];

        if (syncedText != null && syncedText.toString().isNotEmpty) {
          parseLrcString(syncedText);
          try {
            await localLrc.writeAsString(syncedText.toString());
          } catch (_) {}
          _saveLyricsToServer(trackId, syncedText.toString());
        } else if (plainText != null) {
          noLrcData = plainText;
          try {
            await localLrc.writeAsString(plainText.toString());
          } catch (_) {}
          _saveLyricsToServer(trackId, plainText.toString());
        }
      }
    } catch (e) {
      debugPrint("error $e");
    }

    lrcLoading = false;
    uiSignal.value++;
    updateRPC(force: true);
  }

  Future<void> _saveLyricsToServer(int trackId, String lyricsText) async {
    try {
      final url = Uri.parse('http://192.168.31.13:8000/api/tracks/$trackId/update_lyrics/');
      final res = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'lyrics': lyricsText}),
      );
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
        final offlineJsonFile = File('$localPath/offline_tracks.json');
        if (await offlineJsonFile.exists()) {
          await offlineJsonFile.writeAsString(json.encode(cachedTracks));
        }
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
    if (_publicCoverCache.containsKey(id)) {
      return _publicCoverCache[id];
    }

    final title = trackData['title']?.toString() ?? '';
    final artist = trackData['album']?['artist']?['name']?.toString() ?? '';
    if (title.isEmpty) return null;

    // 1. Try iTunes Search API (extremely fast, clean square covers)
    try {
      final itunesUrl = 'https://itunes.apple.com/search?term=${Uri.encodeComponent('$artist $title')}&entity=song&limit=1';
      final res = await http.get(Uri.parse(itunesUrl)).timeout(const Duration(seconds: 3));
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
              'http://ws.audioscrobbler.com/2.0/?method=track.getInfo&artist=${Uri.encodeComponent(artist)}&track=${Uri.encodeComponent(title)}&api_key=b25b959554ed76058ac220b7b2e0a026&format=json',
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
              'http://ws.audioscrobbler.com/2.0/?method=track.search&artist=${Uri.encodeComponent(artist)}&track=${Uri.encodeComponent(title)}&api_key=b25b959554ed76058ac220b7b2e0a026&format=json',
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
    if (!isDesktop || playingQueue.isEmpty) return;

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

        FlutterDiscordRPC.instance.setActivity(
          activity: RPCActivity(
            details: p1,
            state: p2,
            activityType: ActivityType.listening,
            assets: RPCAssets(largeImage: largeImg),
            timestamps: discordStart != null
                ? RPCTimestamps(
                    start: discordStart!,
                    end: durationMs != null ? (discordStart! + durationMs) : null,
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
        FlutterDiscordRPC.instance.setActivity(
          activity: RPCActivity(
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
    final isDownloaded = isTrackLocal(trackId);
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
                            child: _isVideoInitialized &&
                                    _videoController != null &&
                                    playVideoClipNotifier.value
                                ? SizedBox.expand(
                                    child: FittedBox(
                                      fit: BoxFit.cover,
                                      child: SizedBox(
                                        width: _videoController!.value.size.width,
                                        height: _videoController!.value.size.height,
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
                        final isDownloaded = isTrackLocal(trackId);
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
