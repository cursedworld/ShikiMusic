import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';

import '../app_paths.dart';
import '../app_build_info.dart';
import '../atomic_file_store.dart';
import '../background_photo.dart';
import '../background_video.dart';
import '../custom_background.dart';
import '../globals.dart';
import '../localization.dart';
import '../listening_statistics.dart';
import '../lyrics_background_blur.dart';
import '../lyrics_text_size.dart';
import '../platform_capabilities.dart';
import 'statistics_screen.dart';
import 'library_transfer_screen.dart';
import '../server_config.dart';
import '../track_transition_mode.dart';
import '../widgets/lyrics_background_blur_dialog.dart';
import '../widgets/lyrics_text_size_dialog.dart';
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

class SettingsRoute extends MaterialPageRoute<void> {
  SettingsRoute({required super.builder});

  bool _previewBackground = false;

  @override
  bool get opaque => !_previewBackground;

  void setBackgroundPreview(bool visible) {
    _previewBackground = visible;
    // The settings page normally occludes the player. Reveal its existing
    // backdrop only while the preview is open.
    // https://api.flutter.dev/flutter/widgets/OverlayEntry/opaque.html
    if (isActive &&
        animation?.isCompleted == true &&
        overlayEntries.isNotEmpty) {
      overlayEntries.first.opaque = opaque;
    }
  }
}

class SettingsScreen extends StatefulWidget {
  final ListeningStatistics? statistics;
  final List<dynamic> statisticsTracks, statisticsArtists;
  final WidgetBuilder? storageBuilder;
  final Future<Directory> Function() dataDirectoryProvider;
  final Future<void> Function()? beforeLibraryExport;
  const SettingsScreen({
    super.key,
    this.storageBuilder,
    this.dataDirectoryProvider = getShikiDataDirectory,
    this.statistics,
    this.statisticsTracks = const [],
    this.statisticsArtists = const [],
    this.beforeLibraryExport,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late String _selectedColorKey;
  String _selectedLang = languageNotifier.value;
  bool _vinylRotation = vinylRotationNotifier.value;
  bool _playVideoClip = playVideoClipNotifier.value;
  TrackTransitionMode _trackTransitionMode = trackTransitionModeNotifier.value;
  bool _replayGainEnabled = replayGainEnabledNotifier.value;
  bool _discordShowGitHubButton = discordShowGitHubButtonNotifier.value;
  bool _discordLyricsStatus = discordLyricsStatusNotifier.value;
  int _backgroundDimming = backgroundDimmingNotifier.value;
  bool _editingBackgroundDimming = false;
  late final Future<Directory> Function() _getDataDirectory;
  static final SettingsPersistenceQueue _settingsPersistence =
      SettingsPersistenceQueue();
  static Future<void> _backgroundMutation = Future<void>.value();
  bool _isDisposed = false;
  bool _isImportingBackground = false;
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        widget.statistics?.prepareSummary().catchError((Object error) {
          debugPrint('Statistics preparation failed: $error');
        }),
      );
    });
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
        final availableBackground = await availableCustomBackground(
          appDir,
          data['customBackground'],
        );
        if (!mounted) return;
        setState(() {
          final savedColor = data['themeColor'];
          if (themeColors.containsKey(savedColor) || savedColor == 'custom') {
            _selectedColorKey = savedColor as String;
          }
          _selectedLang = data['language'] ?? _selectedLang;
          _vinylRotation = data['vinylRotation'] ?? true;
          _playVideoClip = data['playVideoClip'] ?? false;
          _trackTransitionMode = TrackTransitionMode.fromSettings(
            data['trackTransitionMode'],
            data['smoothTrackTransitions'],
          );
          _replayGainEnabled = data['replayGainEnabled'] == true;
          _discordShowGitHubButton = data['discordShowGitHubButton'] ?? true;
          _discordLyricsStatus = data['discordLyricsStatus'] == true;
          _backgroundDimming = backgroundDimmingFromSettings(
            data['backgroundDimming'],
          );
          final server = data['serverBaseUrl'];
          if (server is String && isValidServerBaseUrl(server)) {
            _serverBaseUrl = normalizeServerBaseUrl(server);
          }
        });

        customBackgroundNotifier.value = availableBackground;
        backgroundDimmingNotifier.value = _backgroundDimming;
        compactTrackListNotifier.value = data['compactTrackList'] == true;
        lyricsTextSizeNotifier.value = LyricsTextSize.fromSettings(
          data['lyricsTextSize'],
        );
        lyricsBackgroundBlurNotifier.value = lyricsBackgroundBlurFromSettings(
          data['lyricsBackgroundBlur'],
        );

        if (_selectedColorKey == 'custom' && data['accentColor'] != null) {
          accentColorNotifier.value = Color(data['accentColor'] as int);
        } else if (themeColors.containsKey(_selectedColorKey)) {
          accentColorNotifier.value = themeColors[_selectedColorKey]!;
        }

        languageNotifier.value = _selectedLang;
        vinylRotationNotifier.value = _vinylRotation;
        playVideoClipNotifier.value = _playVideoClip;
        trackTransitionModeNotifier.value = _trackTransitionMode;
        replayGainEnabledNotifier.value = _replayGainEnabled;
        discordShowGitHubButtonNotifier.value = _discordShowGitHubButton;
        discordLyricsStatusNotifier.value = _discordLyricsStatus;
      }
      if (mounted) setState(() => _settingsReady = true);
    } catch (_) {
      if (mounted) setState(() => _settingsLoadFailed = true);
    }
  }

  Future<bool> _saveSettings({int? backgroundDimming}) {
    final contents = jsonEncode({
      'themeColor': _selectedColorKey,
      'language': _selectedLang,
      'vinylRotation': _vinylRotation,
      'playVideoClip': _playVideoClip,
      'trackTransitionMode': _trackTransitionMode.name,
      'replayGainEnabled': _replayGainEnabled,
      // Older releases can still read this as their sequential fade option.
      'smoothTrackTransitions': _trackTransitionMode != TrackTransitionMode.off,
      'discordShowGitHubButton': _discordShowGitHubButton,
      'discordLyricsStatus': _discordLyricsStatus,
      'serverBaseUrl': _serverBaseUrl,
      'customBackground': customBackgroundNotifier.value,
      'backgroundDimming': backgroundDimming ?? _backgroundDimming,
      'compactTrackList': compactTrackListNotifier.value,
      'lyricsTextSize': lyricsTextSizeNotifier.value.name,
      'lyricsBackgroundBlur': lyricsBackgroundBlurNotifier.value,
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
  Widget build(BuildContext context) => Visibility(
    visible:
        !_editingBackgroundDimming || ModalRoute.of(context) is! SettingsRoute,
    maintainState: true,
    child: _buildSettings(context),
  );

  Widget _buildSettings(BuildContext context) {
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
            if (savedBackgroundKind(customBg) == BackgroundKind.image &&
                globalLocalPath.isNotEmpty)
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
                        hint: tr('settings_background_formats'),
                        value: tr(
                          _isImportingBackground
                              ? 'settings_background_preparing'
                              : switch (savedBackgroundKind(customBg)) {
                                  BackgroundKind.image =>
                                    'settings_background_custom',
                                  BackgroundKind.gif =>
                                    'settings_background_gif',
                                  BackgroundKind.video =>
                                    'settings_background_video',
                                  null => 'settings_background_default',
                                },
                        ),
                        onTap: _settingsReady && !_isImportingBackground
                            ? _uploadCustomBackground
                            : null,
                        action: customBg == null
                            ? null
                            : IconButton(
                                key: const ValueKey('remove_custom_background'),
                                tooltip: tr('settings_remove_background'),
                                onPressed:
                                    _settingsReady && !_isImportingBackground
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
                        key: const ValueKey('settings_background_dimming'),
                        title: tr('settings_background_dimming'),
                        value: '$_backgroundDimming%',
                        onTap: _settingsReady && !_isImportingBackground
                            ? _editBackgroundDimming
                            : null,
                      ),
                      if (supportsCompactTrackList)
                        _row(
                          key: const ValueKey('track_list_density'),
                          title: tr('settings_track_list_density'),
                          value: _trackListDensityLabel(
                            compactTrackListNotifier.value,
                          ),
                          onTap: _settingsReady
                              ? _chooseTrackListDensity
                              : null,
                        ),
                      if (supportsVinylRotation)
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
                      _row(
                        key: const ValueKey('settings_language'),
                        title: tr('language'),
                        value:
                            availableLanguages[_selectedLang] ?? _selectedLang,
                        onTap: _settingsReady ? _chooseLanguage : null,
                      ),
                      _section(tr('settings_playback')),
                      _row(
                        key: const ValueKey('track_transition_setting'),
                        title: tr('smooth_track_transitions'),
                        hint: tr(_transitionHint(_trackTransitionMode)),
                        value: tr(
                          'track_transition_${_trackTransitionMode.name}',
                        ),
                        onTap: _settingsReady ? _chooseTrackTransition : null,
                      ),
                      _toggle(
                        key: const ValueKey('replay_gain_switch'),
                        title: tr('replay_gain'),
                        hint: tr('replay_gain_hint'),
                        value: _replayGainEnabled,
                        onChanged: (value) {
                          setState(() => _replayGainEnabled = value);
                          replayGainEnabledNotifier.value = value;
                          _saveSettings();
                        },
                      ),
                      if (supportsVideoClips)
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
                      _row(
                        key: const ValueKey('lyrics_text_size_setting'),
                        title: tr('lyrics_text_size'),
                        value: tr(
                          'lyrics_text_size_${lyricsTextSizeNotifier.value.name}',
                        ),
                        onTap: _settingsReady ? _chooseLyricsTextSize : null,
                      ),
                      _row(
                        key: const ValueKey('lyrics_background_blur_setting'),
                        title: tr('lyrics_background_blur'),
                        value: '${lyricsBackgroundBlurNotifier.value}%',
                        onTap: _settingsReady
                            ? _chooseLyricsBackgroundBlur
                            : null,
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
                      if (widget.storageBuilder != null)
                        _row(
                          title: tr('storage'),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: widget.storageBuilder!),
                          ),
                        ),
                      _row(
                        key: const ValueKey('library_transfer'),
                        title: tr('transfer_title'),
                        onTap: _settingsReady
                            ? () async {
                                final directory = await _getDataDirectory();
                                if (!context.mounted) return;
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => LibraryTransferScreen(
                                      directory: directory,
                                      statistics: widget.statistics,
                                      beforeExport: () async {
                                        await _settingsPersistence.enqueue(
                                          () async {},
                                        );
                                        await widget.beforeLibraryExport
                                            ?.call();
                                      },
                                    ),
                                  ),
                                );
                              }
                            : null,
                      ),
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
                      _section(tr('about')),
                      _row(
                        title: 'ShikiMusic',
                        value: appBuildLabel.isEmpty
                            ? null
                            : '${tr('version')} $appBuildLabel',
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

  String _trackListDensityLabel(bool compact) => tr(
    compact ? 'settings_track_list_compact' : 'settings_track_list_normal',
  );

  Future<void> _chooseTrackListDensity() async {
    final current = compactTrackListNotifier.value;
    final selected = await showDialog<bool>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: _surface,
        title: Text(
          tr('settings_track_list_density'),
          style: const TextStyle(color: _text),
        ),
        children: [
          for (final compact in [false, true])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, compact),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Semantics(
                  selected: compact == current,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _trackListDensityLabel(compact),
                          style: const TextStyle(color: _text),
                        ),
                      ),
                      if (compact == current)
                        Icon(Icons.check, color: accentColorNotifier.value),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    if (!mounted || selected == null || selected == current) return;
    setState(() => compactTrackListNotifier.value = selected);
    if (!await _saveSettings() && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('settings_track_list_save_failed'))),
      );
    }
  }

  Future<void> _chooseLyricsTextSize() async {
    final current = lyricsTextSizeNotifier.value;
    final selected = await showDialog<LyricsTextSize>(
      context: context,
      builder: (context) => LyricsTextSizeDialog(
        initialSize: current,
        backgroundColor: _surface,
        previewColor: _text,
      ),
    );
    if (!mounted || selected == null || selected == current) return;
    setState(() => lyricsTextSizeNotifier.value = selected);
    if (!await _saveSettings() && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('lyrics_text_size_save_failed'))),
      );
    }
  }

  Future<void> _chooseLyricsBackgroundBlur() async {
    final current = lyricsBackgroundBlurNotifier.value;
    final track = activeTrackNotifier.value;
    final artwork = track == null ? null : getPictureProvider(track);
    final selected = await showDialog<int>(
      context: context,
      builder: (_) => LyricsBackgroundBlurDialog(
        initialBlur: current,
        backgroundColor: _surface,
        cover: artwork is FileImage ? artwork : null,
      ),
    );
    if (!mounted || selected == null || selected == current) return;
    setState(() => lyricsBackgroundBlurNotifier.value = selected);
    if (!await _saveSettings() && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('lyrics_background_blur_save_failed'))),
      );
    }
  }

  String _transitionHint(TrackTransitionMode mode) => switch (mode) {
    TrackTransitionMode.off => 'track_transition_off_hint',
    TrackTransitionMode.fade => 'smooth_track_transitions_hint',
    TrackTransitionMode.crossfade => 'track_transition_crossfade_hint',
  };

  Future<void> _chooseTrackTransition() async {
    final selected = await showDialog<TrackTransitionMode>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: _surface,
        title: Text(tr('smooth_track_transitions')),
        children: [
          for (final mode in TrackTransitionMode.values)
            SimpleDialogOption(
              key: ValueKey('track_transition_option_${mode.name}'),
              onPressed: () => Navigator.pop(context, mode),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Semantics(
                  selected: _trackTransitionMode == mode,
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(tr('track_transition_${mode.name}')),
                            const SizedBox(height: 4),
                            Text(
                              tr(_transitionHint(mode)),
                              style: const TextStyle(
                                color: _muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_trackTransitionMode == mode)
                        Icon(
                          Icons.check,
                          color: accentColorNotifier.value,
                          size: 20,
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    if (!mounted || selected == null || selected == _trackTransitionMode) {
      return;
    }
    setState(() => _trackTransitionMode = selected);
    trackTransitionModeNotifier.value = selected;
    await _saveSettings();
  }

  Future<void> _editBackgroundDimming() async {
    if (!_settingsReady || _editingBackgroundDimming) return;
    final route = ModalRoute.of(context);
    final previewRoute = route is SettingsRoute ? route : null;
    final original = _backgroundDimming;
    var draft = original;
    var persisted = original;
    setState(() => _editingBackgroundDimming = true);
    previewRoute?.setBackgroundPreview(true);
    try {
      final selected = await showDialog<int>(
        context: context,
        useRootNavigator: false,
        barrierColor: previewRoute == null ? null : Colors.transparent,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, updateDialog) {
            void preview(int value) {
              updateDialog(() => draft = value);
              backgroundDimmingNotifier.value = value;
            }

            return AlertDialog(
              alignment: Alignment.bottomCenter,
              insetPadding: const EdgeInsets.all(16),
              scrollable: true,
              backgroundColor: _surface,
              surfaceTintColor: Colors.transparent,
              title: Text(
                tr('settings_background_dimming'),
                style: const TextStyle(color: _text),
              ),
              content: SizedBox(
                width: 360,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('settings_background_dimming_hint'),
                      style: const TextStyle(color: _muted),
                    ),
                    const SizedBox(height: 12),
                    Text('$draft%', style: const TextStyle(color: _text)),
                    Slider(
                      key: const ValueKey('background_dimming_slider'),
                      max: 100,
                      divisions: 100,
                      value: draft.toDouble(),
                      activeColor: accentColorNotifier.value,
                      onChanged: (value) => preview(value.round()),
                      semanticFormatterCallback: (value) =>
                          '${tr('settings_background_dimming')}: ${value.round()}%',
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  key: const ValueKey('background_dimming_reset'),
                  onPressed: draft == defaultBackgroundDimming
                      ? null
                      : () => preview(defaultBackgroundDimming),
                  child: Text(tr('settings_background_dimming_reset')),
                ),
                TextButton(
                  key: const ValueKey('background_dimming_cancel'),
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(tr('cancel')),
                ),
                TextButton(
                  key: const ValueKey('background_dimming_save'),
                  onPressed: () => Navigator.pop(dialogContext, draft),
                  child: Text(tr('settings_background_dimming_save')),
                ),
              ],
            );
          },
        ),
      );
      if (selected != null && selected != original && mounted) {
        if (await _saveSettings(backgroundDimming: selected)) {
          persisted = selected;
        } else {
          _showBackgroundError('settings_background_dimming_save_failed');
        }
      }
    } finally {
      backgroundDimmingNotifier.value = persisted;
      previewRoute?.setBackgroundPreview(false);
      if (mounted) {
        setState(() {
          _backgroundDimming = persisted;
          _editingBackgroundDimming = false;
        });
      }
    }
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
    setState(() => _isImportingBackground = true);
    File? candidate;
    var committed = false;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: backgroundPickerExtensions,
        dialogTitle: tr('settings_select_background'),
        allowMultiple: false,
      );
      if (_isDisposed || result == null) return;
      final selected = result.files.single;
      final pickedPath = selected.path;
      if (pickedPath == null) throw BackgroundProblem.invalid;
      final ext = switch (selected.extension?.toLowerCase()) {
        'gif' => 'gif',
        'mp4' => 'mp4',
        _ => 'jpg',
      };
      final appDir = await _getDataDirectory();
      if (_isDisposed) return;
      final newFileName =
          'custom_bg_${DateTime.now().microsecondsSinceEpoch}.$ext';
      final newFile = File('${appDir.path}/$newFileName');

      if (ext == 'gif' || ext == 'mp4') {
        await copyMotionBackground(File(pickedPath), newFile);
        candidate = newFile;
        if (ext == 'mp4' && !_isDisposed) {
          // Validate on the user's decoder before replacing their old wallpaper.
          final video = await openBackgroundVideo(newFile);
          await closeBackgroundVideo(video);
        }
      } else {
        final jpegBytes = await compute(
          processCustomBackgroundImage,
          pickedPath,
          debugLabel: 'custom-background-image',
        );
        if (_isDisposed) return;
        if (jpegBytes == null) throw BackgroundProblem.invalid;
        await atomicFileStore.writeBytes(newFile, jpegBytes);
        candidate = newFile;
      }

      if (_isDisposed) return;
      final previousBackground = customBackgroundNotifier.value;
      customBackgroundNotifier.value = newFileName;
      committed = await _saveSettings();
      if (!committed) {
        if (customBackgroundNotifier.value == newFileName) {
          customBackgroundNotifier.value = previousBackground;
        }
        throw const FileSystemException('Could not save background setting');
      }
      await _deleteCustomBgFiles(exceptFileName: newFileName);
    } on BackgroundProblem catch (problem) {
      _showBackgroundError(switch (problem) {
        BackgroundProblem.tooLarge => 'settings_background_limit',
        BackgroundProblem.invalid => 'settings_background_invalid',
      });
    } catch (e) {
      _showBackgroundError('settings_background_save_failed');
    } finally {
      if (candidate != null && !committed) {
        await _deleteUnusedBackgroundCandidate(candidate);
      }
      if (mounted) setState(() => _isImportingBackground = false);
    }
  }

  void _showBackgroundError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr(message))));
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
