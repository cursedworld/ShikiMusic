import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../globals.dart';
import '../atomic_file_store.dart';
import '../cover_processing.dart';
import '../localization.dart';
import '../server_config.dart';

class ArtistScreen extends StatefulWidget {
  final int artistId;
  final String artistName;
  final List<dynamic> Function() getAllTracks;
  final Function(List<dynamic> queue, int index) onPlayTrack;
  final Function(int trackId) onToggleFavorite;
  final Function(dynamic track) onDownloadTrack;
  final Future<void> Function(List<dynamic> tracks)? onDownloadAlbum;
  final Function(dynamic track) onDeleteDownloadedTrack;
  final bool Function(dynamic track) isTrackDownloaded;
  final bool Function(int trackId) isTrackFavorited;
  final bool Function(int trackId) isDownloading;
  final Listenable? libraryChanges;

  /// An injected client remains owned by its caller.
  final http.Client? httpClient;

  const ArtistScreen({
    super.key,
    required this.artistId,
    required this.artistName,
    required this.getAllTracks,
    required this.onPlayTrack,
    required this.onToggleFavorite,
    required this.onDownloadTrack,
    this.onDownloadAlbum,
    required this.onDeleteDownloadedTrack,
    required this.isTrackDownloaded,
    required this.isTrackFavorited,
    required this.isDownloading,
    this.libraryChanges,
    this.httpClient,
  });

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  Map<String, dynamic>? _artistData;
  bool _isLoading = true;
  bool _isBioExpanded = false;
  int? _selectedAlbumId; // null = all albums
  late final http.Client _httpClient;
  late final bool _ownsHttpClient;
  bool _hasFreshCatalog = false;
  int _cacheReloadRevision = 0;
  final Set<Future<void>> _metadataWork = {};

  @visibleForTesting
  Future<void> get metadataIdle =>
      Future.wait(_metadataWork.toList()).then((_) {});

  void _startMetadataWork(Future<void> operation) {
    _metadataWork.add(operation);
    unawaited(
      operation.then<void>(
        (_) => _metadataWork.remove(operation),
        onError: (Object error, StackTrace stackTrace) {
          _metadataWork.remove(operation);
        },
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _ownsHttpClient = widget.httpClient == null;
    _httpClient = widget.httpClient ?? http.Client();
    activeTrackNotifier.addListener(_onLibraryChanged);
    isPlayingNotifier.addListener(_onLibraryChanged);
    accentColorNotifier.addListener(_onLibraryChanged);
    widget.libraryChanges?.addListener(_onCatalogChanged);
    _startMetadataWork(_loadArtistDetails());
  }

  @override
  void didUpdateWidget(covariant ArtistScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.libraryChanges != widget.libraryChanges) {
      oldWidget.libraryChanges?.removeListener(_onCatalogChanged);
      widget.libraryChanges?.addListener(_onCatalogChanged);
    }
  }

  @override
  void dispose() {
    _cacheReloadRevision++;
    activeTrackNotifier.removeListener(_onLibraryChanged);
    isPlayingNotifier.removeListener(_onLibraryChanged);
    accentColorNotifier.removeListener(_onLibraryChanged);
    widget.libraryChanges?.removeListener(_onCatalogChanged);
    if (_ownsHttpClient) _httpClient.close();
    super.dispose();
  }

  void _onLibraryChanged() {
    if (mounted) setState(() {});
  }

  void _onCatalogChanged() {
    if (!mounted) return;
    setState(() => _hasFreshCatalog = true);
    _startMetadataWork(_reloadCachedMetadata());
  }

  Future<void> _reloadCachedMetadata() async {
    if (globalLocalPath.isEmpty) return;
    final revision = ++_cacheReloadRevision;
    try {
      final file = File(
        '$globalLocalPath/artist_details_${widget.artistId}.json',
      );
      if (!await file.exists()) return;
      if (!mounted || revision != _cacheReloadRevision) return;
      final data = jsonDecode(await file.readAsString());
      if (!mounted ||
          revision != _cacheReloadRevision ||
          data is! Map<String, dynamic>) {
        return;
      }
      setState(() {
        // Tracks/albums below come from the live catalog, not this snapshot.
        _artistData = {...?_artistData, ...data};
        _isLoading = false;
      });
    } on FileSystemException {
      // Offline metadata remains usable during an atomic cache replacement.
    } on FormatException {
      // A malformed optional metadata cache must not hide the music library.
    }
  }

  Future<void> _loadArtistDetails() async {
    // Read the cache first so a late disk read cannot replace fresh server data.
    await _loadOfflineArtistDetails();
    if (!mounted) return;
    await _fetchArtistDetails();
  }

  Future<void> _loadOfflineArtistDetails() async {
    final revision = _cacheReloadRevision;
    try {
      if (globalLocalPath.isNotEmpty) {
        final file = File(
          '$globalLocalPath/artist_details_${widget.artistId}.json',
        );
        if (await file.exists()) {
          if (!mounted || revision != _cacheReloadRevision) return;
          final data = jsonDecode(await file.readAsString());
          if (data is Map<String, dynamic> &&
              mounted &&
              revision == _cacheReloadRevision) {
            setState(() {
              _artistData = data;
              _isLoading = false;
            });
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _fetchArtistDetails() async {
    final revision = _cacheReloadRevision;
    try {
      final uri = configuredServerUri('/api/artists/${widget.artistId}/');
      final res = await _httpClient
          .get(uri)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        if (data is Map<String, dynamic>) {
          if (!mounted || revision != _cacheReloadRevision) return;
          // Metadata is ready; do not hold the screen behind a photo download.
          setState(() {
            _artistData = data;
            _isLoading = false;
          });
          if (globalLocalPath.isNotEmpty) {
            try {
              final file = File(
                '$globalLocalPath/artist_details_${widget.artistId}.json',
              );
              await atomicFileStore.writeStringLazy(file, () {
                if (!mounted || revision != _cacheReloadRevision) {
                  throw StateError('Artist metadata response became stale');
                }
                return utf8.decode(res.bodyBytes);
              });
              if (!mounted || revision != _cacheReloadRevision) return;

              final photoUrl = data['photo']?.toString();
              if (photoUrl != null && photoUrl.isNotEmpty) {
                final version = data['photo_version']?.toString();
                final suffix =
                    version != null &&
                        RegExp(r'^[a-f0-9]{64}$').hasMatch(version)
                    ? '_$version'
                    : '';
                final photoFile = File(
                  '$globalLocalPath/artist_${widget.artistId}$suffix.jpg',
                );
                if (!await photoFile.exists() ||
                    await photoFile.length() == 0) {
                  final photoUri = photoUrl.startsWith('http')
                      ? Uri.parse(photoUrl)
                      : configuredServerUri(photoUrl);
                  final photoRes = await _httpClient
                      .get(photoUri)
                      .timeout(const Duration(seconds: 10));
                  if (!mounted || revision != _cacheReloadRevision) return;
                  if (photoRes.statusCode == 200 &&
                      photoRes.bodyBytes.length > 500) {
                    await atomicFileStore.writeBytes(
                      photoFile,
                      photoRes.bodyBytes,
                    );
                  }
                }
              }
            } catch (_) {}
          }

          if (!mounted || revision != _cacheReloadRevision) return;
          setState(() {
            // Rebuild after a local photo becomes available.
          });
          return;
        }
      }
    } catch (_) {}

    if (mounted && revision == _cacheReloadRevision) {
      setState(() => _isLoading = false);
    }
  }

  List<dynamic> _getArtistTracks() {
    final catalog = widget.getAllTracks();
    final serverTracks = _artistData?['tracks'] as List<dynamic>? ?? const [];
    final source = catalog.isNotEmpty || _hasFreshCatalog
        ? catalog
        : serverTracks;
    return source.where(_belongsToArtist).toList();
  }

  bool _belongsToArtist(dynamic track) {
    if (track is! Map) return false;
    if (_asId(track['album']?['artist']?['id']) == widget.artistId) return true;
    for (final artist in track['artists'] as List? ?? const []) {
      if (artist is Map && _asId(artist['id']) == widget.artistId) return true;
    }
    return false;
  }

  int? _asId(dynamic value) => value is int ? value : int.tryParse('$value');

  List<dynamic> _albumDownloadTracks(int albumId) {
    final catalog = widget.getAllTracks();
    if (catalog.isNotEmpty || _hasFreshCatalog) {
      return catalog
          .where((track) => _asId(track['album']?['id']) == albumId)
          .toList();
    }
    // Initial offline/detail fallback only. A confirmed empty catalog wins.
    for (final album in _artistData?['albums'] as List? ?? const []) {
      if (album is Map &&
          _asId(album['id']) == albumId &&
          album['tracks'] is List) {
        return List<dynamic>.from(album['tracks'] as List);
      }
    }
    return _getArtistTracks()
        .where((track) => _asId(track['album']?['id']) == albumId)
        .toList();
  }

  String _currentArtistName(List<dynamic> tracks) {
    for (final track in tracks) {
      final albumArtist = track['album']?['artist'];
      if (albumArtist is Map && _asId(albumArtist['id']) == widget.artistId) {
        final name = albumArtist['name']?.toString().trim() ?? '';
        if (name.isNotEmpty) return name;
      }
      for (final artist in track['artists'] as List? ?? const []) {
        if (artist is Map && _asId(artist['id']) == widget.artistId) {
          final name = artist['name']?.toString().trim() ?? '';
          if (name.isNotEmpty) return name;
        }
      }
    }
    final name = _artistData?['name']?.toString().trim() ?? '';
    return name.isEmpty ? widget.artistName : name;
  }

  List<dynamic> _getArtistAlbums() {
    // Derive the discography from fresh tracks so old album snapshots cannot
    // keep renamed or reassigned songs on the open artist screen.
    final tracks = _getArtistTracks();
    final Map<int, Map<String, dynamic>> albumMap = {};
    for (final t in tracks) {
      final album = t['album'];
      if (album != null && album['id'] != null) {
        final aId = album['id'] as int;
        if (!albumMap.containsKey(aId)) {
          albumMap[aId] = {
            'id': aId,
            'title': album['title'] ?? '',
            'cover': album['cover'],
            'cover_version': album['cover_version'],
            'tracks': [t],
          };
        } else {
          albumMap[aId]!['tracks'].add(t);
        }
      }
    }
    for (final album in albumMap.values) {
      album['tracks'] = _albumDownloadTracks(album['id'] as int);
    }
    return albumMap.values.toList();
  }

  @override
  Widget build(BuildContext context) {
    final accent = accentColorNotifier.value;
    final activeTrackId = activeTrackNotifier.value?['id'];
    final isPlaying = isPlayingNotifier.value;
    final tracks = _getArtistTracks();
    final albums = _getArtistAlbums();

    final filteredTracks = _selectedAlbumId == null
        ? tracks
        : tracks.where((t) => t['album']?['id'] == _selectedAlbumId).toList();
    final downloadSelection = _selectedAlbumId == null
        ? tracks
        : _albumDownloadTracks(_selectedAlbumId!);

    final photoUrl = _artistData?['photo'];
    final bio = _artistData?['bio']?.toString().trim() ?? '';
    final photoProvider = getArtistPhotoProvider(
      _artistData ?? {'id': widget.artistId, 'photo': photoUrl},
    );

    return Scaffold(
      backgroundColor: const Color(0xFF0D0202),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _isLoading && tracks.isEmpty
          ? const Center(
              child: CircularProgressIndicator(color: Colors.redAccent),
            )
          : CustomScrollView(
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              slivers: [
                // ── Artist Banner Header ──
                SliverToBoxAdapter(
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(24, 70, 24, 20),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          accent.withValues(alpha: 0.35),
                          Colors.black.withValues(alpha: 0.95),
                        ],
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Avatar
                        Container(
                          width: 140,
                          height: 140,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: accent, width: 3),
                            boxShadow: [
                              BoxShadow(
                                color: accent.withValues(alpha: 0.4),
                                blurRadius: 24,
                                spreadRadius: 2,
                              ),
                            ],
                            image: photoProvider != null
                                ? DecorationImage(
                                    image: photoProvider,
                                    fit: BoxFit.cover,
                                  )
                                : null,
                            color: Colors.white10,
                          ),
                          child: photoProvider == null
                              ? const Icon(
                                  Icons.person,
                                  size: 70,
                                  color: Colors.white54,
                                )
                              : null,
                        ),
                        const SizedBox(height: 16),
                        // Artist Name
                        Text(
                          _currentArtistName(tracks),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 6),
                        // Stats
                        Text(
                          '${tracks.length} ${tr('artist_tracks_count')} • ${albums.length} ${tr('artist_albums_count')}',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 20),
                        // Play All / Shuffle Buttons
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ElevatedButton.icon(
                              icon: const Icon(
                                Icons.play_arrow_rounded,
                                size: 24,
                              ),
                              label: Text(
                                tr('artist_play_all'),
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: accent,
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(24),
                                ),
                                elevation: 6,
                              ),
                              onPressed: tracks.isEmpty
                                  ? null
                                  : () => widget.onPlayTrack(tracks, 0),
                            ),
                            const SizedBox(width: 16),
                            OutlinedButton.icon(
                              icon: Icon(
                                Icons.shuffle,
                                color: accent,
                                size: 20,
                              ),
                              label: Text(
                                tr('artist_shuffle'),
                                style: const TextStyle(color: Colors.white),
                              ),
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(
                                  color: accent.withValues(alpha: 0.6),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(24),
                                ),
                              ),
                              onPressed: tracks.isEmpty
                                  ? null
                                  : () {
                                      final shuffled = List.from(tracks)
                                        ..shuffle();
                                      widget.onPlayTrack(shuffled, 0);
                                    },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                // ── Biography Section ──
                if (bio.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 10,
                      ),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.info_outline,
                                  color: accent,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  tr('artist_bio'),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              bio,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                                height: 1.4,
                              ),
                              maxLines: _isBioExpanded ? null : 3,
                              overflow: _isBioExpanded
                                  ? null
                                  : TextOverflow.ellipsis,
                            ),
                            if (bio.length > 180) ...[
                              const SizedBox(height: 6),
                              GestureDetector(
                                onTap: () => setState(
                                  () => _isBioExpanded = !_isBioExpanded,
                                ),
                                child: Text(
                                  _isBioExpanded
                                      ? tr('show_less')
                                      : tr('read_more'),
                                  style: TextStyle(
                                    color: accent,
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),

                // ── Albums Discography Carousel ──
                if (albums.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                      child: Text(
                        tr('artist_albums'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 170,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        itemCount: albums.length + 1,
                        itemBuilder: (ctx, i) {
                          if (i == 0) {
                            final isAllSelected = _selectedAlbumId == null;
                            return GestureDetector(
                              onTap: () =>
                                  setState(() => _selectedAlbumId = null),
                              child: Container(
                                width: 120,
                                margin: const EdgeInsets.only(right: 14),
                                decoration: BoxDecoration(
                                  color: isAllSelected
                                      ? accent.withValues(alpha: 0.25)
                                      : Colors.white.withValues(alpha: 0.05),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isAllSelected
                                        ? accent
                                        : Colors.white12,
                                    width: isAllSelected ? 2 : 1,
                                  ),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.library_music,
                                      color: isAllSelected
                                          ? accent
                                          : Colors.white54,
                                      size: 38,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      tr('artist_all_tracks'),
                                      style: TextStyle(
                                        color: isAllSelected
                                            ? Colors.white
                                            : Colors.white70,
                                        fontWeight: isAllSelected
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                        fontSize: 12,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                    Text(
                                      '${tracks.length} ${tr('artist_tracks_count')}',
                                      style: const TextStyle(
                                        color: Colors.white38,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }

                          final album = albums[i - 1];
                          final aId = album['id'] as int?;
                          final isSelected = _selectedAlbumId == aId;
                          final coverUrl = album['cover']?.toString();
                          final albumTracks =
                              album['tracks'] as List<dynamic>? ?? [];
                          final ImageProvider? coverProvider =
                              coverUrl == null || coverUrl.isEmpty
                              ? null
                              : albumTracks.isNotEmpty
                              ? getPictureProvider(albumTracks.first)
                              : NetworkImage(
                                  coverUrl.startsWith('http')
                                      ? coverUrl
                                      : configuredServerUri(
                                          coverUrl,
                                        ).toString(),
                                );

                          return GestureDetector(
                            onTap: () => setState(() {
                              if (_selectedAlbumId == aId) {
                                _selectedAlbumId = null; // Toggle off
                              } else {
                                _selectedAlbumId = aId;
                              }
                            }),
                            child: Container(
                              width: 120,
                              margin: const EdgeInsets.only(right: 14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: Container(
                                      width: 120,
                                      height: 120,
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: isSelected
                                              ? accent
                                              : Colors.white12,
                                          width: isSelected ? 2.5 : 1,
                                        ),
                                        borderRadius: BorderRadius.circular(10),
                                        color: Colors.white10,
                                        image: coverProvider != null
                                            ? DecorationImage(
                                                image: coverProvider,
                                                fit: BoxFit.cover,
                                              )
                                            : null,
                                      ),
                                      child: coverProvider == null
                                          ? const Icon(
                                              Icons.album,
                                              color: Colors.white38,
                                              size: 40,
                                            )
                                          : null,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    album['title'] ?? '',
                                    style: TextStyle(
                                      color: isSelected ? accent : Colors.white,
                                      fontWeight: isSelected
                                          ? FontWeight.bold
                                          : FontWeight.w500,
                                      fontSize: 12,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    '${albumTracks.length} ${tr('artist_tracks_count')}',
                                    style: const TextStyle(
                                      color: Colors.white38,
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],

                // ── Tracks List Header ──
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            _selectedAlbumId == null
                                ? tr('artist_all_tracks')
                                : '${tr('albums_title')}: ${_getAlbumTitle(_selectedAlbumId, albums)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${filteredTracks.length} ${tr('artist_tracks_count')}',
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 13,
                              ),
                            ),
                            if (widget.onDownloadAlbum != null)
                              IconButton(
                                key: const ValueKey(
                                  'download_artist_selection',
                                ),
                                tooltip: _selectedAlbumId == null
                                    ? tr('download_all_tracks')
                                    : '${tr('download_album')} (${downloadSelection.length})',
                                icon: const Icon(
                                  Icons.download,
                                  color: Colors.white54,
                                ),
                                onPressed: downloadSelection.isEmpty
                                    ? null
                                    : () {
                                        unawaited(
                                          widget.onDownloadAlbum!(
                                            List<dynamic>.from(
                                              downloadSelection,
                                            ),
                                          ),
                                        );
                                      },
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                // ── Tracks List ──
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate((context, idx) {
                      final track = filteredTracks[idx];
                      final trackId = track['id'];
                      final isPlayingThis =
                          activeTrackId == trackId && isPlaying;
                      final isDownloaded = widget.isTrackDownloaded(track);
                      final isDownloading = widget.isDownloading(trackId);
                      final isFav = widget.isTrackFavorited(trackId);

                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: activeTrackId == trackId
                              ? Colors.white.withValues(alpha: 0.1)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: ListTile(
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image(
                              image: coverThumbnail(
                                context,
                                getPictureProvider(track),
                                48,
                              ),
                              width: 48,
                              height: 48,
                              fit: BoxFit.cover,
                            ),
                          ),
                          title: Text(
                            track['title'] ?? '',
                            style: TextStyle(
                              color: activeTrackId == trackId
                                  ? accent
                                  : Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            track['album']?['title'] ?? '',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 13,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Icon(
                                  isFav
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  color: isFav
                                      ? Colors.redAccent
                                      : Colors.white54,
                                  size: 22,
                                ),
                                onPressed: () {
                                  widget.onToggleFavorite(trackId);
                                  setState(() {});
                                },
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
                                IconButton(
                                  icon: const Icon(
                                    Icons.download_done,
                                    color: Colors.greenAccent,
                                    size: 24,
                                  ),
                                  tooltip: tr('delete_downloaded_track'),
                                  onPressed: () {
                                    widget.onDeleteDownloadedTrack(track);
                                    setState(() {});
                                  },
                                )
                              else
                                IconButton(
                                  icon: const Icon(
                                    Icons.download,
                                    color: Colors.white54,
                                    size: 22,
                                  ),
                                  onPressed: () {
                                    widget.onDownloadTrack(track);
                                    setState(() {});
                                  },
                                ),
                              const SizedBox(width: 8),
                              Icon(
                                isPlayingThis
                                    ? Icons.graphic_eq
                                    : Icons.play_arrow,
                                color: isPlayingThis ? accent : Colors.white54,
                                size: 22,
                              ),
                            ],
                          ),
                          onTap: () => widget.onPlayTrack(filteredTracks, idx),
                        ),
                      );
                    }, childCount: filteredTracks.length),
                  ),
                ),

                const SliverToBoxAdapter(child: SizedBox(height: 100)),
              ],
            ),
    );
  }

  String _getAlbumTitle(int? albumId, List<dynamic> albums) {
    if (albumId == null) return '';
    for (final album in albums) {
      if (album['id'] == albumId) return album['title']?.toString() ?? '';
    }
    return '';
  }
}
