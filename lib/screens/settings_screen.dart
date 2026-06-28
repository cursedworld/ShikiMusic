import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;

import '../globals.dart';
import '../localization.dart';

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

class SettingsScreen extends StatefulWidget {
  final VoidCallback onClearCache;
  const SettingsScreen({super.key, required this.onClearCache});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _selectedColorKey = 'color_red';
  String _selectedLang = 'ru';
  bool _vinylRotation = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/ShikiMusic/shiki_settings.json');
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString());
        setState(() {
          _selectedColorKey = data['themeColor'] ?? 'color_red';
          _selectedLang = data['language'] ?? 'ru';
          _vinylRotation = data['vinylRotation'] ?? true;
        });

        customBackgroundNotifier.value = data['customBackground'];

        if (_selectedColorKey == 'custom' && data['accentColor'] != null) {
          accentColorNotifier.value = Color(data['accentColor'] as int);
        } else if (themeColors.containsKey(_selectedColorKey)) {
          accentColorNotifier.value = themeColors[_selectedColorKey]!;
        }

        languageNotifier.value = _selectedLang;
        vinylRotationNotifier.value = _vinylRotation;
      }
    } catch (_) {}
  }

  Future<void> _saveSettings() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final appDir = Directory('${dir.path}/ShikiMusic');
      if (!appDir.existsSync()) {
        appDir.createSync(recursive: true);
      }
      final file = File('${appDir.path}/shiki_settings.json');
      await file.writeAsString(jsonEncode({
        'themeColor': _selectedColorKey,
        'language': _selectedLang,
        'vinylRotation': _vinylRotation,
        'customBackground': customBackgroundNotifier.value,
        'accentColor': _selectedColorKey == 'custom'
            ? accentColorNotifier.value.toARGB32()
            : null,
      }));
    } catch (_) {}
  }

  List<Color> _gradientFromAccent(Color accent) {
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

  @override
  Widget build(BuildContext context) {
    final accent = accentColorNotifier.value;
    final gradColors = _gradientFromAccent(accent);

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(tr('settings_title')),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
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
                      colors: gradColors,
                    ),
                  ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                    20,
                    20 + MediaQuery.of(context).padding.top + kToolbarHeight,
                    20,
                    20,
                  ),
                  children: [
            // ── Theme Color ──
            _buildSectionHeader(Icons.palette, tr('color_theme')),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: themeColors.entries.map((entry) {
                final isSelected = entry.key == _selectedColorKey;
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _selectedColorKey = entry.key;
                    });
                    accentColorNotifier.value = entry.value;
                    _saveSettings();
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: entry.value.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isSelected ? entry.value : Colors.white12,
                        width: isSelected ? 3 : 1,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: entry.value,
                            shape: BoxShape.circle,
                            boxShadow: isSelected
                                ? [
                                    BoxShadow(
                                      color: entry.value.withValues(alpha: 0.5),
                                      blurRadius: 10,
                                    ),
                                  ]
                                : null,
                          ),
                          child: isSelected
                              ? const Icon(Icons.check,
                                  color: Colors.white, size: 18)
                              : null,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          tr(entry.key),
                          style: TextStyle(
                            color: isSelected ? Colors.white : Colors.white54,
                            fontSize: 9,
                            fontWeight:
                                isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),

            const SizedBox(height: 16),
            _buildCustomBackgroundOption(accent),

            const SizedBox(height: 32),

            // ── Language ──
            _buildSectionHeader(Icons.language, tr('language')),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: availableLanguages.entries.map((entry) {
                  final isSelected = entry.key == _selectedLang;
                  return ListTile(
                    title: Text(
                      entry.value,
                      style: TextStyle(
                        color: isSelected ? accent : Colors.white70,
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    trailing: isSelected
                        ? Icon(Icons.check_circle, color: accent, size: 22)
                        : const Icon(Icons.circle_outlined,
                            color: Colors.white24, size: 22),
                    onTap: () {
                      setState(() => _selectedLang = entry.key);
                      languageNotifier.value = entry.key;
                      _saveSettings();
                    },
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  );
                }).toList(),
              ),
            ),

            const SizedBox(height: 32),

            // ── Vinyl Rotation ──
            _buildSectionHeader(Icons.album, tr('vinyl_rotation')),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SwitchListTile(
                title: Text(
                  tr('vinyl_rotation_desc'),
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  tr('vinyl_rotation_hint'),
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                value: _vinylRotation,
                activeThumbColor: accent,
                activeTrackColor: accent.withValues(alpha: 0.3),
                onChanged: (val) {
                  setState(() => _vinylRotation = val);
                  vinylRotationNotifier.value = val;
                  _saveSettings();
                },
              ),
            ),

            const SizedBox(height: 32),

            // ── Clear Cache ──
            _buildSectionHeader(Icons.cleaning_services, tr('storage')),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.white54),
                title: Text(
                  tr('clear_cache'),
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  tr('clear_cache_desc'),
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: gradColors[1],
                      title: Text(tr('clear_cache_confirm'),
                          style: const TextStyle(color: Colors.white)),
                      content: Text(
                        tr('clear_cache_body'),
                        style: const TextStyle(color: Colors.white70),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text(tr('cancel'),
                              style: const TextStyle(color: Colors.white54)),
                        ),
                        TextButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            widget.onClearCache();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(tr('cache_cleared')),
                                backgroundColor: Colors.black87,
                              ),
                            );
                          },
                          child: Text(tr('clear'),
                              style: TextStyle(color: accent)),
                        ),
                      ],
                    ),
                  );
                },
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),

            const SizedBox(height: 32),

            // ── About ──
            _buildSectionHeader(Icons.info_outline, tr('about')),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.graphic_eq, color: accent, size: 24),
                      const SizedBox(width: 10),
                      const Text(
                        'ShikiMusic',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${tr('version')} 1.0.0',
                    style: const TextStyle(color: Colors.white38, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tr('personal_player'),
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 40),
          ],
        ),
      ),
    ),
  );
    },
  ),
);
}

  Widget _buildSectionHeader(IconData icon, String title) {
    return Row(
      children: [
        Icon(icon, color: Colors.white38, size: 20),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }

  Widget _buildCustomBackgroundOption(Color accent) {
    final isCustomBg = customBackgroundNotifier.value != null;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isCustomBg ? accent : Colors.white12,
          width: isCustomBg ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.image_outlined, color: isCustomBg ? accent : Colors.white54, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isCustomBg
                      ? tr('custom_bg_active')
                      : tr('custom_bg_title'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              ElevatedButton.icon(
                onPressed: _uploadCustomBackground,
                style: ElevatedButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                icon: const Icon(Icons.upload_file),
                label: Text(tr('select_image')),
              ),
              if (isCustomBg) ...[
                const SizedBox(width: 12),
                IconButton(
                  onPressed: _removeCustomBackground,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.redAccent.withValues(alpha: 0.2),
                    foregroundColor: Colors.redAccent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.all(12),
                  ),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _uploadCustomBackground() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      if (result != null && result.files.single.path != null) {
        final pickedPath = result.files.single.path!;
        final dir = await getApplicationDocumentsDirectory();
        final appDir = Directory('${dir.path}/ShikiMusic');
        if (!appDir.existsSync()) {
          appDir.createSync(recursive: true);
        }

        // Read and decode image from disk
        final bytes = await File(pickedPath).readAsBytes();
        final image = img.decodeImage(bytes);
        if (image == null) return;

        // Resize to maximum HD dimensions to save CPU/RAM
        img.Image processedImage = image;
        if (image.width > 1920 || image.height > 1080) {
          double aspectRatio = image.width / image.height;
          int newWidth, newHeight;
          if (image.width > image.height) {
            newWidth = 1920;
            newHeight = (1920 / aspectRatio).round();
          } else {
            newHeight = 1080;
            newWidth = (1080 * aspectRatio).round();
          }
          processedImage = img.copyResize(image, width: newWidth, height: newHeight);
        }

        // Delete existing background files
        _deleteCustomBgFiles();

        // Save as optimized JPEG
        final ext = 'jpg';
        final newFileName = 'custom_bg_${DateTime.now().millisecondsSinceEpoch}.$ext';
        final newPath = '${appDir.path}/$newFileName';
        final jpegBytes = img.encodeJpg(processedImage, quality: 85);
        await File(newPath).writeAsBytes(jpegBytes);

        customBackgroundNotifier.value = newFileName;

        _saveSettings();
      }
    } catch (e) {
      debugPrint('Error uploading custom background: $e');
    }
  }

  void _removeCustomBackground() async {
    try {
      _deleteCustomBgFiles();

      setState(() {
        if (_selectedColorKey == 'custom') {
          _selectedColorKey = 'color_red';
          accentColorNotifier.value = themeColors['color_red']!;
        }
      });

      customBackgroundNotifier.value = null;

      _saveSettings();
    } catch (e) {
      debugPrint('Error removing custom background: $e');
    }
  }

  void _deleteCustomBgFiles() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final appDir = Directory('${dir.path}/ShikiMusic');
      if (appDir.existsSync()) {
        final entities = appDir.listSync();
        for (var entity in entities) {
          if (entity is File && entity.path.contains('custom_bg_')) {
            try {
              entity.deleteSync();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

}
