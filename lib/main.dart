import 'package:flutter/material.dart';
import 'package:flutter_discord_rpc/flutter_discord_rpc.dart';
import 'dart:convert';
import 'dart:io';

import 'app_paths.dart';
import 'atomic_file_store.dart';
import 'globals.dart';
import 'perf/frame_metrics.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'server_config.dart';

void _assertPerformanceIsolation() {
  final benchmarkLaunchRequested =
      Platform.environment['SHIKI_PERF_RUN_ID']?.trim().isNotEmpty == true ||
      Platform.environment['SHIKI_PERF_EXPECTED_DATA_DIR']?.trim().isNotEmpty ==
          true ||
      Platform.environment['SHIKI_PERF_EXPECTED_SERVER_URL']
              ?.trim()
              .isNotEmpty ==
          true;
  if (!PerformanceFrameMonitor.enabled) {
    if (benchmarkLaunchRequested) {
      throw StateError('Benchmark collector requires an instrumented build.');
    }
    return;
  }

  final expectedDataDirectory = Platform
      .environment['SHIKI_PERF_EXPECTED_DATA_DIR']
      ?.trim();
  final expectedServerUrl = Platform
      .environment['SHIKI_PERF_EXPECTED_SERVER_URL']
      ?.trim();
  if (expectedDataDirectory == null || expectedDataDirectory.isEmpty) {
    throw StateError('Benchmark expected data directory is missing.');
  }
  if (expectedServerUrl != benchmarkServerBaseUrl ||
      configuredServerBaseUrl != benchmarkServerBaseUrl) {
    throw StateError('Benchmark server isolation configuration mismatch.');
  }
  if (!hasAppDataDirectoryOverride ||
      !_sameAbsolutePath(appDataDirectoryOverride, expectedDataDirectory)) {
    throw StateError('Benchmark data directory isolation mismatch.');
  }
}

bool _sameAbsolutePath(String first, String second) {
  String normalize(String value) {
    final path = Directory(
      value,
    ).absolute.path.replaceAll('/', Platform.pathSeparator);
    return Platform.isWindows ? path.toLowerCase() : path;
  }

  return normalize(first) == normalize(second);
}

Future<void> _loadSavedSettings() async {
  try {
    final appDir = await getShikiDataDirectory();
    globalLocalPath = appDir.path;

    final file = File('${appDir.path}/shiki_settings.json');
    if (!hasAppDataDirectoryOverride) {
      final documents = await getDocumentsRootDirectory();
      final oldFile = File('${documents.path}/shiki_settings.json');
      if (!file.existsSync() && oldFile.existsSync()) {
        try {
          await atomicFileStore.writeBytes(file, await oldFile.readAsBytes());
        } catch (_) {}
      }
    }

    if (await file.exists()) {
      final data = jsonDecode(await file.readAsString());

      // Restore accent color
      final colorKey = data['themeColor'] ?? 'color_red';
      if (colorKey == 'custom' && data['accentColor'] != null) {
        accentColorNotifier.value = Color(data['accentColor'] as int);
      } else if (themeColors.containsKey(colorKey)) {
        accentColorNotifier.value = themeColors[colorKey]!;
      }

      // Restore custom background
      final savedBackground = data['customBackground'];
      if (savedBackground is String && savedBackground.isNotEmpty) {
        final backgroundFile = File('${appDir.path}/$savedBackground');
        customBackgroundNotifier.value = await backgroundFile.exists()
            ? savedBackground
            : null;
      } else {
        customBackgroundNotifier.value = null;
      }

      // Restore language
      languageNotifier.value = data['language'] ?? 'ru';

      // Restore vinyl rotation setting
      vinylRotationNotifier.value = data['vinylRotation'] ?? true;

      // Restore video clip setting
      playVideoClipNotifier.value = data['playVideoClip'] ?? false;

      // Restore discord github button setting
      discordShowGitHubButtonNotifier.value =
          data['discordShowGitHubButton'] ?? true;
    }
  } catch (_) {}
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _assertPerformanceIsolation();

  // Limit image cache to reduce memory usage
  PaintingBinding.instance.imageCache.maximumSize = 50;
  PaintingBinding.instance.imageCache.maximumSizeBytes =
      100 * 1024 * 1024; // 100 MB

  // Load saved settings early so the first frame uses the right theme
  await _loadSavedSettings();

  // Compiled out of normal builds. Benchmark builds opt in explicitly with
  // --dart-define=SHIKI_PERF_METRICS=true.
  if (PerformanceFrameMonitor.enabled) {
    await PerformanceFrameMonitor.install();
  }

  if (isDesktop && !PerformanceFrameMonitor.enabled) {
    try {
      await FlutterDiscordRPC.initialize("1480246072042590219");
    } catch (e) {
      debugPrint('Discord RPC init failed: $e');
    }
  } else {
    // Disabled audio_service on Android to prevent conflicts with flutter_media_session
    isAudioServiceActive = false;
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Rebuild the entire theme when accent color or language changes
    return ValueListenableBuilder<Color>(
      valueListenable: accentColorNotifier,
      builder: (context, accent, _) {
        return ValueListenableBuilder<String>(
          valueListenable: languageNotifier,
          builder: (context, lang, _) {
            return MaterialApp(
              debugShowCheckedModeBanner: false,
              title: "ShikiMusic",
              theme: ThemeData.dark().copyWith(
                colorScheme: ColorScheme.dark(
                  primary: accent,
                  secondary: accent,
                  surface: const Color(0xFF121212),
                  onSurface: Colors.white,
                  onPrimary: Colors.white,
                  onSecondary: Colors.white,
                ),
                scaffoldBackgroundColor: const Color(0xFF000000),
                appBarTheme: AppBarTheme(
                  backgroundColor: const Color(0xFF121212),
                  foregroundColor: Colors.white,
                  iconTheme: const IconThemeData(color: Colors.white),
                  titleTextStyle: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                progressIndicatorTheme: ProgressIndicatorThemeData(
                  color: accent,
                ),
                floatingActionButtonTheme: FloatingActionButtonThemeData(
                  backgroundColor: accent,
                  foregroundColor: Colors.white,
                ),
                sliderTheme: SliderThemeData(
                  activeTrackColor: accent,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: accent,
                  trackHeight: 4.0,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6.0,
                  ),
                ),
              ),
              home: const MainAppScreen(),
            );
          },
        );
      },
    );
  }
}
