import 'package:flutter/material.dart';
import 'package:flutter_discord_rpc/flutter_discord_rpc.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

import 'globals.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';

Future<void> _loadSavedSettings() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final appDir = Directory('${dir.path}/ShikiMusic');
    if (!appDir.existsSync()) {
      appDir.createSync(recursive: true);
    }
    globalLocalPath = appDir.path;

    final file = File('${appDir.path}/shiki_settings.json');
    final oldFile = File('${dir.path}/shiki_settings.json');
    if (!file.existsSync() && oldFile.existsSync()) {
      try {
        await oldFile.rename(file.path);
      } catch (_) {}
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
      customBackgroundNotifier.value = data['customBackground'];

      // Restore language
      languageNotifier.value = data['language'] ?? 'ru';

      // Restore vinyl rotation setting
      vinylRotationNotifier.value = data['vinylRotation'] ?? true;
    }
  } catch (_) {}
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Limit image cache to reduce memory usage
  PaintingBinding.instance.imageCache.maximumSize = 50;
  PaintingBinding.instance.imageCache.maximumSizeBytes =
      100 * 1024 * 1024; // 100 MB

  // Load saved settings early so the first frame uses the right theme
  await _loadSavedSettings();

  if (isDesktop) {
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
