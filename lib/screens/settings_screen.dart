import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../app_paths.dart';
import '../atomic_file_store.dart';
import '../globals.dart';
import '../localization.dart';
import '../listening_statistics.dart';
import 'statistics_screen.dart';
import '../server_config.dart';
import '../widgets/server_address_setting.dart';

/// Available accent color themes (key → localization key + color).
const Map<String, Color> themeColors = {
  'color_red': Color(0xFFFF5252),
  'color_blue': Color(0xFF448AFF),
  'color_purple': Color(0xFFE040FB),
  'color_green': Color(0xFF69F0AE),
  'color_orange': Color(0xFFFFAB40),
  'color_pink': Color(0xFFFF4081),
  'color_teal': Color(0xFF18FFFF),
  'color_black': Color(0xFF333333),
};

/// Available UI languages.
const Map<String, String> availableLanguages = {
  'ru': 'Русский',
  'en': 'English',
  'ja': '日本語',
};

const int _maxCustomBackgroundFileBytes = 64 * 1024 * 1024;
const int _maxCustomBackgroundPixels = 40 * 1000 * 1000;
const int _maxCustomBackgroundSide = 20 * 1000;

/// Runs settings writes in invocation order, including their async setup.
///
/// The queue tail absorbs failures so one failed write cannot block newer
/// settings from being persisted.
class SettingsPersistenceQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> enqueue<T>(Future<T> Function() operation) {
    final result = _tail.then<T>((_) => operation());
    _tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return result;
  }
}

/// Converts a selected background to the same JPEG format used by the UI.
///
/// This is top-level so [compute] can run all file IO, decoding, resizing, and
/// encoding outside the UI isolate. The limits reject decompression bombs
/// before allocating their full pixel buffers.
Uint8List? processCustomBackgroundImage(String sourcePath) {
  final sourceFile = File(sourcePath);
  final sourceLength = sourceFile.lengthSync();
  if (sourceLength <= 0 || sourceLength > _maxCustomBackgroundFileBytes) {
    return null;
  }

  final bytes = sourceFile.readAsBytesSync();
  if (bytes.isEmpty || bytes.length > _maxCustomBackgroundFileBytes) {
    return null;
  }

  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (decoder == null ||
      info == null ||
      info.numFrames < 1 ||
      !_isSafeCustomBackgroundSize(info.width, info.height)) {
    return null;
  }

  final image = decoder.decodeFrame(0);
  if (image == null ||
      !_isSafeCustomBackgroundSize(image.width, image.height)) {
    return null;
  }

  img.Image processedImage = image;
  if (image.width > 1920 || image.height > 1080) {
    final aspectRatio = image.width / image.height;
    final int newWidth;
    final int newHeight;
    if (image.width > image.height) {
      newWidth = 1920;
      newHeight = (1920 / aspectRatio).round();
    } else {
      newHeight = 1080;
      newWidth = (1080 * aspectRatio).round();
    }
    processedImage = img.copyResize(image, width: newWidth, height: newHeight);
  }

  return img.encodeJpg(processedImage, quality: 85);
}

bool _isSafeCustomBackgroundSize(int width, int height) =>
    width > 0 &&
    height > 0 &&
    width <= _maxCustomBackgroundSide &&
    height <= _maxCustomBackgroundSide &&
    width * height <= _maxCustomBackgroundPixels;

class SettingsScreen extends StatefulWidget {
  final ListeningStatistics? statistics;
  final List<dynamic> statisticsTracks, statisticsArtists;
  final FutureOr<bool?> Function() onClearCache;
  final Future<Directory> Function() dataDirectoryProvider;
  const SettingsScreen({
    super.key,
    required this.onClearCache,
    this.dataDirectoryProvider = getShikiDataDirectory,
    this.statistics,
    this.statisticsTracks = const [],
    this.statisticsArtists = const [],
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late String _selectedColorKey;
  String _selectedLang = languageNotifier.value;
  bool _vinylRotation = vinylRotationNotifier.value;
  bool _playVideoClip = playVideoClipNotifier.value;
  bool _discordShowGitHubButton = discordShowGitHubButtonNotifier.value;
  bool _discordLyricsStatus = discordLyricsStatusNotifier.value;
  late final Future<Directory> Function() _getDataDirectory;
  static final SettingsPersistenceQueue _settingsPersistence =
      SettingsPersistenceQueue();
  static Future<void> _backgroundMutation = Future<void>.value();
  bool _isDisposed = false;
  bool _isClearingCache = false;
  String _serverBaseUrl = configuredServerBaseUrl;
  bool _settingsReady = false;
  bool _settingsLoadFailed = false;

  @override
  void initState() {
    super.initState();
    _selectedColorKey =
        themeColors.entries
            .where((entry) => entry.value == accentColorNotifier.value)
            .map((entry) => entry.key)
            .firstOrNull ??
        'custom';
    _getDataDirectory = widget.dataDirectoryProvider;
    _loadSettings();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  Future<void> _loadSettings() async {
    setState(() {
      _settingsReady = false;
      _settingsLoadFailed = false;
    });
    try {
      final appDir = await _getDataDirectory();
      final file = File('${appDir.path}/shiki_settings.json');
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString());
        final savedBackground = data['customBackground'];
        final availableBackground =
            savedBackground is String &&
                savedBackground.isNotEmpty &&
                await File('${appDir.path}/$savedBackground').exists()
            ? savedBackground
            : null;
        if (!mounted) return;
        setState(() {
          final savedColor = data['themeColor'];
          if (themeColors.containsKey(savedColor) || savedColor == 'custom') {
            _selectedColorKey = savedColor as String;
          }
          _selectedLang = data['language'] ?? _selectedLang;
          _vinylRotation = data['vinylRotation'] ?? true;
          _playVideoClip = data['playVideoClip'] ?? false;
          _discordShowGitHubButton = data['discordShowGitHubButton'] ?? true;
          _discordLyricsStatus = data['discordLyricsStatus'] == true;
          final server = data['serverBaseUrl'];
          if (server is String && isValidServerBaseUrl(server)) {
            _serverBaseUrl = normalizeServerBaseUrl(server);
          }
        });

        customBackgroundNotifier.value = availableBackground;

        if (_selectedColorKey == 'custom' && data['accentColor'] != null) {
          accentColorNotifier.value = Color(data['accentColor'] as int);
        } else if (themeColors.containsKey(_selectedColorKey)) {
          accentColorNotifier.value = themeColors[_selectedColorKey]!;
        }

        languageNotifier.value = _selectedLang;
        vinylRotationNotifier.value = _vinylRotation;
        playVideoClipNotifier.value = _playVideoClip;
        discordShowGitHubButtonNotifier.value = _discordShowGitHubButton;
        discordLyricsStatusNotifier.value = _discordLyricsStatus;
      }
      if (mounted) setState(() => _settingsReady = true);
    } catch (_) {
      if (mounted) setState(() => _settingsLoadFailed = true);
    }
  }

  Future<bool> _saveSettings() {
    final contents = jsonEncode({
      'themeColor': _selectedColorKey,
      'language': _selectedLang,
      'vinylRotation': _vinylRotation,
      'playVideoClip': _playVideoClip,
      'discordShowGitHubButton': _discordShowGitHubButton,
      'discordLyricsStatus': _discordLyricsStatus,
      'serverBaseUrl': _serverBaseUrl,
      'customBackground': customBackgroundNotifier.value,
      'accentColor': _selectedColorKey == 'custom'
          ? accentColorNotifier.value.toARGB32()
          : null,
    });
    return _settingsPersistence.enqueue(() async {
      try {
        final appDir = await _getDataDirectory();
        final file = File('${appDir.path}/shiki_settings.json');
        await atomicFileStore.writeString(file, contents);
        return true;
      } catch (error) {
        debugPrint('Error saving settings: $error');
        return false;
      }
    });
  }

  static const _background = Color(0xFF161416);
  static const _surface = Color(0xFF242024);
  static const _text = Color(0xFFF3EFF1);
  static const _muted = Color(0xFFB9B0B5);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _background,
      appBar: AppBar(
        backgroundColor: _background,
        foregroundColor: _text,
        surfaceTintColor: Colors.transparent,
        title: Text(tr('settings_title')),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ValueListenableBuilder<String?>(
        valueListenable: customBackgroundNotifier,
        builder: (context, customBg, _) => Stack(
          fit: StackFit.expand,
          children: [
            if (customBg != null && globalLocalPath.isNotEmpty)
              Image.file(
                File('$globalLocalPath/$customBg'),
                fit: BoxFit.cover,
                color: Colors.black.withValues(alpha: 0.82),
                colorBlendMode: BlendMode.srcOver,
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) => const ColoredBox(color: _background),
              ),
            SafeArea(
              top: false,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 36),
                    children: [
                      if (_settingsLoadFailed) ...[
                        Text(
                          tr('settings_load_error'),
                          style: const TextStyle(color: _muted),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: _loadSettings,
                            child: Text(tr('stats_retry')),
                          ),
                        ),
                      ],
                      _section(tr('settings_appearance')),
                      _row(
                        title: tr('settings_accent'),
                        value: tr(
                          _selectedColorKey == 'custom'
                              ? 'settings_custom_color'
                              : _selectedColorKey,
                        ),
                      ),
                      _palette(),
                      const SizedBox(height: 8),
                      _row(
                        key: const ValueKey('settings_background'),
                        title: tr('settings_background'),
                        value: tr(
                          customBg == null
                              ? 'settings_background_default'
                              : 'settings_background_custom',
                        ),
                        onTap: _settingsReady ? _uploadCustomBackground : null,
                        action: customBg == null
                            ? null
                            : IconButton(
                                key: const ValueKey('remove_custom_background'),
                                tooltip: tr('settings_remove_background'),
                                onPressed: _settingsReady
                                    ? _removeCustomBackground
                                    : null,
                                icon: const Icon(
                                  Icons.close,
                                  size: 18,
                                  color: _muted,
                                ),
                              ),
                      ),
                      _row(
                        key: const ValueKey('settings_language'),
                        title: tr('language'),
                        value:
                            availableLanguages[_selectedLang] ?? _selectedLang,
                        onTap: _settingsReady ? _chooseLanguage : null,
                      ),
                      _section(tr('settings_playback')),
                      _toggle(
                        key: const ValueKey('vinyl_rotation_switch'),
                        title: tr('vinyl_rotation'),
                        hint: tr('vinyl_rotation_hint'),
                        value: _vinylRotation,
                        onChanged: (value) {
                          setState(() => _vinylRotation = value);
                          vinylRotationNotifier.value = value;
                          _saveSettings();
                        },
                      ),
                      _toggle(
                        key: const ValueKey('video_clip_switch'),
                        title: tr('play_video_clip_desc'),
                        hint: tr('play_video_clip_hint'),
                        value: _playVideoClip,
                        onChanged: (value) {
                          setState(() => _playVideoClip = value);
                          playVideoClipNotifier.value = value;
                          _saveSettings();
                        },
                      ),
                      _section(tr('discord_settings')),
                      if (isDesktop)
                        _toggle(
                          key: const ValueKey('discord_lyrics_status_switch'),
                          title: tr('discord_lyrics_status'),
                          hint: tr('discord_lyrics_status_hint'),
                          value: _discordLyricsStatus,
                          onChanged: (value) {
                            setState(() => _discordLyricsStatus = value);
                            discordLyricsStatusNotifier.value = value;
                            _saveSettings();
                          },
                        ),
                      _toggle(
                        key: const ValueKey('discord_github_switch'),
                        title: tr('discord_github_button_desc'),
                        hint: tr('discord_github_button_hint'),
                        value: _discordShowGitHubButton,
                        onChanged: (value) {
                          setState(() => _discordShowGitHubButton = value);
                          discordShowGitHubButtonNotifier.value = value;
                          _saveSettings();
                        },
                      ),
                      _section(tr('settings_data')),
                      if (widget.statistics != null)
                        _row(
                          key: const ValueKey('open_statistics'),
                          title: tr('stats_title'),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => StatisticsScreen(
                                statistics: widget.statistics!,
                                tracks: widget.statisticsTracks,
                                artists: widget.statisticsArtists,
                              ),
                            ),
                          ),
                        ),
                      _row(
                        key: const ValueKey('settings_server'),
                        title: tr('settings_server'),
                        value: _serverBaseUrl,
                        onTap: _settingsReady ? _editServer : null,
                      ),
                      _row(
                        title: tr('clear_cache'),
                        hint: tr('clear_cache_desc'),
                        onTap: _isClearingCache ? null : _confirmClearCache,
                      ),
                      _section(tr('about')),
                      _row(
                        title: 'ShikiMusic',
                        value: '${tr('version')} 1.0.0',
                      ),
                      Text(
                        tr('personal_player'),
                        style: const TextStyle(color: _muted, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 8),
    child: Text(
      title,
      style: const TextStyle(
        color: _text,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _row({
    Key? key,
    required String title,
    String? value,
    String? hint,
    VoidCallback? onTap,
    Widget? action,
  }) => Material(
    key: key,
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final stackValue =
                value != null &&
                (constraints.maxWidth < 400 ||
                    MediaQuery.textScalerOf(context).scale(14) > 20);
            return Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(color: _text, fontSize: 15),
                      ),
                      if (hint != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          hint,
                          style: const TextStyle(
                            color: _muted,
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ],
                      if (stackValue) ...[
                        const SizedBox(height: 4),
                        Text(
                          value,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: _muted, fontSize: 14),
                        ),
                      ],
                    ],
                  ),
                ),
                if (value != null && !stackValue) ...[
                  const SizedBox(width: 24),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth * 0.45,
                    ),
                    child: Text(
                      value,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: const TextStyle(color: _muted, fontSize: 14),
                    ),
                  ),
                ],
                ?action,
                if (onTap != null) ...[
                  const SizedBox(width: 12),
                  const Icon(Icons.chevron_right, size: 20, color: _muted),
                ],
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _toggle({
    required Key key,
    required String title,
    required String hint,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => SwitchListTile(
    key: key,
    contentPadding: EdgeInsets.zero,
    title: Text(title, style: const TextStyle(color: _text, fontSize: 15)),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        hint,
        style: const TextStyle(color: _muted, fontSize: 12, height: 1.4),
      ),
    ),
    value: value,
    activeThumbColor: accentColorNotifier.value,
    activeTrackColor: accentColorNotifier.value.withValues(alpha: 0.3),
    onChanged: _settingsReady ? onChanged : null,
  );

  Widget _palette() => Align(
    alignment: Alignment.centerLeft,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 464),
      child: LayoutBuilder(
        builder: (context, constraints) => GridView(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: constraints.maxWidth >= 432 ? 8 : 4,
            mainAxisSpacing: 4,
            mainAxisExtent: 52,
          ),
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            for (final entry in themeColors.entries)
              Semantics(
                key: ValueKey('theme_${entry.key}'),
                selected: _selectedColorKey == entry.key,
                button: true,
                label: tr(entry.key),
                child: Tooltip(
                  message: tr(entry.key),
                  child: Material(
                    color: Colors.transparent,
                    child: InkResponse(
                      radius: 24,
                      onTap: !_settingsReady
                          ? null
                          : () {
                              setState(() => _selectedColorKey = entry.key);
                              accentColorNotifier.value = entry.value;
                              _saveSettings();
                            },
                      child: Center(
                        child: Container(
                          width: 38,
                          height: 38,
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _selectedColorKey == entry.key
                                  ? _text
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: entry.value,
                              shape: BoxShape.circle,
                            ),
                            child: _selectedColorKey == entry.key
                                ? Icon(
                                    Icons.check,
                                    size: 16,
                                    color: entry.value.computeLuminance() > 0.5
                                        ? Colors.black
                                        : Colors.white,
                                  )
                                : null,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );

  Future<void> _chooseLanguage() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: _surface,
        title: Text(tr('language'), style: const TextStyle(color: _text)),
        children: [
          for (final language in availableLanguages.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, language.key),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        language.value,
                        style: const TextStyle(color: _text),
                      ),
                    ),
                    if (_selectedLang == language.key)
                      Icon(
                        Icons.check,
                        color: accentColorNotifier.value,
                        size: 20,
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    setState(() => _selectedLang = selected);
    languageNotifier.value = selected;
    await _saveSettings();
  }

  Future<void> _editServer() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: _surface,
      title: Text(tr('settings_server'), style: const TextStyle(color: _text)),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: ServerAddressSetting(
            value: _serverBaseUrl,
            onSave: (value) async {
              final previous = _serverBaseUrl;
              setState(() => _serverBaseUrl = value);
              final saved = await _saveSettings();
              if (!saved && mounted) setState(() => _serverBaseUrl = previous);
              return saved;
            },
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('close')),
        ),
      ],
    ),
  );

  Future<void> _confirmClearCache() => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: _surface,
      title: Text(
        tr('clear_cache_confirm'),
        style: const TextStyle(color: _text),
      ),
      content: Text(
        tr('clear_cache_body'),
        style: const TextStyle(color: _muted),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(tr('cancel')),
        ),
        TextButton(
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            Navigator.pop(ctx);
            setState(() => _isClearingCache = true);
            try {
              final cleared = await widget.onClearCache();
              if (!mounted || cleared != true) return;
              messenger.showSnackBar(
                SnackBar(content: Text(tr('cache_cleared'))),
              );
            } catch (error) {
              debugPrint('Cache clear failed: $error');
              if (mounted) {
                messenger.showSnackBar(
                  SnackBar(content: Text(tr('cache_clear_failed'))),
                );
              }
            } finally {
              if (mounted) setState(() => _isClearingCache = false);
            }
          },
          child: Text(
            tr('clear'),
            style: TextStyle(color: accentColorNotifier.value),
          ),
        ),
      ],
    ),
  );

  Future<void> _uploadCustomBackground() =>
      _enqueueBackgroundMutation(_uploadCustomBackgroundNow);

  Future<void> _removeCustomBackground() =>
      _enqueueBackgroundMutation(_removeCustomBackgroundNow);

  Future<void> _enqueueBackgroundMutation(Future<void> Function() operation) {
    if (_isDisposed) return Future<void>.value();
    final previous = _backgroundMutation;
    final scheduled = () async {
      try {
        await previous;
      } catch (_) {}
      if (_isDisposed) return;
      await operation();
    }();
    _backgroundMutation = scheduled;
    return scheduled;
  }

  Future<void> _uploadCustomBackgroundNow() async {
    if (_isDisposed) return;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      if (result != null && result.files.single.path != null) {
        if (_isDisposed) return;
        final pickedPath = result.files.single.path!;
        final jpegBytes = await compute(
          processCustomBackgroundImage,
          pickedPath,
          debugLabel: 'custom-background-image',
        );
        if (_isDisposed || jpegBytes == null) return;

        final appDir = await _getDataDirectory();
        if (_isDisposed) return;

        // Save as optimized JPEG
        final ext = 'jpg';
        final newFileName =
            'custom_bg_${DateTime.now().microsecondsSinceEpoch}.$ext';
        final newPath = '${appDir.path}/$newFileName';
        final newFile = File(newPath);
        await atomicFileStore.writeBytes(newFile, jpegBytes);
        if (_isDisposed) {
          await _deleteUnusedBackgroundCandidate(newFile);
          return;
        }

        final previousBackground = customBackgroundNotifier.value;
        customBackgroundNotifier.value = newFileName;
        if (await _saveSettings()) {
          await _deleteCustomBgFiles(exceptFileName: newFileName);
        } else {
          if (customBackgroundNotifier.value == newFileName) {
            customBackgroundNotifier.value = previousBackground;
          }
          await _deleteUnusedBackgroundCandidate(newFile);
        }
      }
    } catch (e) {
      debugPrint('Error uploading custom background: $e');
    }
  }

  Future<void> _removeCustomBackgroundNow() async {
    if (_isDisposed) return;
    try {
      final previousBackground = customBackgroundNotifier.value;
      final previousColorKey = _selectedColorKey;
      final previousAccent = accentColorNotifier.value;

      setState(() {
        if (_selectedColorKey == 'custom') {
          _selectedColorKey = 'color_red';
          accentColorNotifier.value = themeColors['color_red']!;
        }
      });

      customBackgroundNotifier.value = null;

      if (await _saveSettings()) {
        await _deleteCustomBgFiles();
      } else {
        customBackgroundNotifier.value = previousBackground;
        if (mounted) {
          setState(() => _selectedColorKey = previousColorKey);
        } else {
          _selectedColorKey = previousColorKey;
        }
        accentColorNotifier.value = previousAccent;
      }
    } catch (e) {
      debugPrint('Error removing custom background: $e');
    }
  }

  Future<void> _deleteUnusedBackgroundCandidate(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException catch (error) {
      debugPrint('Failed to remove unused background: $error');
    }
  }

  Future<void> _deleteCustomBgFiles({String? exceptFileName}) async {
    try {
      final appDir = await _getDataDirectory();
      if (!await appDir.exists()) return;
      await for (final entity in appDir.list()) {
        if (entity is! File) continue;
        final fileName = entity.path.split(Platform.pathSeparator).last;
        final activeFileName = customBackgroundNotifier.value;
        if (!fileName.startsWith('custom_bg_') ||
            fileName == exceptFileName ||
            fileName == activeFileName) {
          continue;
        }
        try {
          await entity.delete();
        } on FileSystemException {
          // Stale backgrounds are harmless; keep the active one untouched.
        }
      }
    } catch (_) {}
  }
}
