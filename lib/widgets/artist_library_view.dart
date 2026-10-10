import 'package:flutter/material.dart';

import '../cover_processing.dart';
import '../globals.dart';
import '../localization.dart';

/// Keeps catalog order, adding performers found only in the offline library.
List<Map<String, dynamic>> artistLibraryEntries(
  List<dynamic> catalog,
  List<dynamic> tracks,
  String query,
) {
  final entries = <String, Map<String, dynamic>>{};
  void add(dynamic artist, {dynamic track}) {
    if (artist is! Map) return;
    final name = artist['name']?.toString().trim() ?? '';
    if (name.isEmpty) return;
    final key = name.toLowerCase();
    final entry = entries.putIfAbsent(
      key,
      () => {
        'id': artist['id'] ?? 0,
        'name': name,
        'photo': artist['photo'],
        'photo_version': artist['photo_version'],
        'tracks_count': track == null ? artist['tracks_count'] ?? 0 : 0,
        'albums_count': track == null ? artist['albums_count'] ?? 0 : 0,
        'track_ids': <Object?>{},
        'album_keys': <String>{},
      },
    );
    if (entry['id'] == 0 && artist['id'] != null) entry['id'] = artist['id'];
    if ((entry['photo']?.toString().isEmpty ?? true) &&
        artist['photo'] != null) {
      entry['photo'] = artist['photo'];
      entry['photo_version'] = artist['photo_version'];
    }
    if (track is Map) {
      (entry['track_ids'] as Set).add(track['id']);
      final album = track['album'];
      if (album is Map && (album['id'] != null || album['title'] != null)) {
        (entry['album_keys'] as Set).add(
          album['id'] != null ? 'id:${album['id']}' : 'title:${album['title']}',
        );
      }
    }
  }

  for (final artist in catalog) {
    add(artist);
  }
  for (final track in tracks) {
    if (track is! Map) continue;
    final album = track['album'];
    if (album is Map) add(album['artist'], track: track);
    final artists = track['artists'];
    if (artists is List) {
      for (final artist in artists) {
        add(artist, track: track);
      }
    }
  }
  final search = query.trim().toLowerCase();
  return entries.values
      .where((entry) => entry['name'].toString().toLowerCase().contains(search))
      .map(
        (entry) => {
          ...entry,
          'tracks_count':
              entry['tracks_count'] is int && entry['tracks_count'] > 0
              ? entry['tracks_count']
              : (entry['track_ids'] as Set).length,
          'albums_count':
              entry['albums_count'] is int && entry['albums_count'] > 0
              ? entry['albums_count']
              : (entry['album_keys'] as Set).length,
        },
      )
      .toList();
}

class ArtistLibraryView extends StatelessWidget {
  const ArtistLibraryView({
    super.key,
    required this.catalog,
    required this.tracks,
    required this.query,
    required this.onOpen,
  });

  final List<dynamic> catalog, tracks;
  final String query;
  final void Function(int id, String name) onOpen;

  @override
  Widget build(BuildContext context) {
    final artists = artistLibraryEntries(catalog, tracks, query);
    if (artists.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            tr(query.trim().isEmpty ? 'artists_empty' : 'artists_search_empty'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFFB9B0B5),
              fontSize: 15,
              height: 1.5,
            ),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                constraints.maxWidth < 720 ||
                MediaQuery.textScalerOf(context).scale(14) > 19;
            const photoSize = 56.0;
            const detailStyle = TextStyle(
              color: Color(0xFFB9B0B5),
              fontSize: 13,
              height: 1.4,
            );
            return ListView.separated(
              key: const PageStorageKey('artist_library_view'),
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: artists.length,
              separatorBuilder: (_, _) => Divider(
                height: 1,
                indent: 84,
                endIndent: 12,
                color: Colors.white.withValues(alpha: 0.06),
              ),
              itemBuilder: (context, index) {
                final artist = artists[index];
                final name = artist['name'] as String;
                final id = artist['id'] is int ? artist['id'] as int : 0;
                final provider = getArtistPhotoProvider(artist);
                final trackCount =
                    '${artist['tracks_count']} ${tr('artist_tracks_count')}';
                final albumCount =
                    '${artist['albums_count']} ${tr('artist_albums_count')}';
                final fallback = Center(
                  child: Text(
                    name.characters.first.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 22,
                      color: Color(0xFFB9B0B5),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                );
                return Material(
                  key: ValueKey('artist_tile_${id}_${name.toLowerCase()}'),
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => onOpen(id, name),
                    borderRadius: BorderRadius.circular(8),
                    hoverColor: Colors.white.withValues(alpha: 0.04),
                    focusColor: accentColorNotifier.value.withValues(
                      alpha: 0.18,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 14,
                      ),
                      child: Row(
                        children: [
                          SizedBox.square(
                            key: ValueKey('artist_photo_$index'),
                            dimension: photoSize,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: ColoredBox(
                                color: const Color(0xFF242024),
                                child: provider == null
                                    ? fallback
                                    : Image(
                                        image: coverThumbnail(
                                          context,
                                          provider,
                                          photoSize,
                                        ),
                                        fit: BoxFit.cover,
                                        gaplessPlayback: true,
                                        excludeFromSemantics: true,
                                        errorBuilder: (_, _, _) => fallback,
                                      ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Tooltip(
                                  message: name,
                                  child: Text(
                                    name,
                                    maxLines: compact ? 3 : 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Color(0xFFF3EFF1),
                                      fontSize: 17,
                                      fontWeight: FontWeight.w500,
                                      height: 1.3,
                                    ),
                                  ),
                                ),
                                if (compact) ...[
                                  const SizedBox(height: 5),
                                  Wrap(
                                    spacing: 12,
                                    runSpacing: 2,
                                    children: [
                                      Text(trackCount, style: detailStyle),
                                      Text(albumCount, style: detailStyle),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (!compact) ...[
                            const SizedBox(width: 24),
                            SizedBox(
                              width: 116,
                              child: Text(
                                trackCount,
                                textAlign: TextAlign.right,
                                style: detailStyle,
                              ),
                            ),
                            const SizedBox(width: 24),
                            SizedBox(
                              width: 116,
                              child: Text(
                                albumCount,
                                textAlign: TextAlign.right,
                                style: detailStyle,
                              ),
                            ),
                          ],
                          const SizedBox(width: 16),
                          const Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                            color: Color(0xFF81777E),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
