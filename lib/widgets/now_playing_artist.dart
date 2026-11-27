import 'package:flutter/material.dart';

import '../localization.dart';
import '../music_import.dart';

class NowPlayingArtist extends StatelessWidget {
  const NowPlayingArtist({
    super.key,
    required this.track,
    required this.onOpen,
    required this.fontSize,
    this.centered = false,
  });

  final dynamic track;
  final void Function(int id, String name) onOpen;
  final double fontSize;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final artists = <int, String>{};
    for (final entry in trackArtistEntries(track)) {
      final id = int.tryParse(entry['id']?.toString() ?? '');
      final name = entry['name']?.toString().trim() ?? '';
      if (id != null && id != 0 && name.isNotEmpty) {
        artists.putIfAbsent(id, () => name);
      }
    }
    final text = Text(
      trackArtistLabel(track),
      style: TextStyle(
        color: artists.isEmpty ? Colors.white54 : Colors.white70,
        fontSize: fontSize,
      ),
      textAlign: centered ? TextAlign.center : TextAlign.start,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (artists.isEmpty) return text;

    final target = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 24, minWidth: 24),
      child: Align(
        alignment: centered
            ? Alignment.center
            : AlignmentDirectional.centerStart,
        widthFactor: 1,
        heightFactor: 1,
        child: text,
      ),
    );
    final corners = BorderRadius.circular(4);
    void open(MapEntry<int, String> artist) => onOpen(artist.key, artist.value);

    return Material(
      type: MaterialType.transparency,
      child: artists.length == 1
          ? Semantics(
              link: true,
              hint: tr('artist_open_page'),
              child: InkWell(
                borderRadius: corners,
                onTap: () => open(artists.entries.single),
                child: target,
              ),
            )
          : Semantics(
              button: true,
              hint: tr('artist_choose'),
              child: PopupMenuButton<MapEntry<int, String>>(
                tooltip: '',
                borderRadius: corners,
                onSelected: open,
                itemBuilder: (context) => [
                  for (final artist in artists.entries)
                    PopupMenuItem(
                      value: artist,
                      child: Text(
                        artist.value,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                child: target,
              ),
            ),
    );
  }
}
