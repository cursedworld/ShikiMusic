import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

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
      final file = File('${dir.path}/shiki_settings.json');
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString());
        setState(() {
          _selectedColorKey = data['themeColor'] ?? 'color_red';
          _selectedLang = data['language'] ?? 'ru';
          _vinylRotation = data['vinylRotation'] ?? true;
        });
        if (themeColors.containsKey(_selectedColorKey)) {
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
      final file = File('${dir.path}/shiki_settings.json');
      await file.writeAsString(jsonEncode({
        'themeColor': _selectedColorKey,
        'language': _selectedLang,
        'vinylRotation': _vinylRotation,
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
      backgroundColor: gradColors.last,
      appBar: AppBar(
        backgroundColor: gradColors.first,
        title: Text(tr('settings_title')),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: gradColors,
          ),
        ),
        child: ListView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.all(20),
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
                    setState(() => _selectedColorKey = entry.key);
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
}
