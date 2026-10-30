import 'dart:async';
import '../album_order.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../globals.dart';
import '../atomic_file_store.dart';
import '../cover_processing.dart';
import '../localization.dart';
import '../server_config.dart';
import '../track_selection.dart';
import '../widgets/track_selection_bar.dart';

class ArtistScreen extends StatefulWidget {
  final int artistId;
  final String artistName;
  final Map<String, dynamic>? initialArtistData;
  final List<dynamic> Function() getAllTracks;
  final Function(List<dynamic> queue, int index) onPlayTrack;
  final Function(int trackId) onToggleFavorite;
  final Future<void> Function(List<int> ids)? onToggleFavorites;
  final Map<int, String> Function()? getPlaylists;
  final Future<bool> Function(int playlistId, List<int> ids)? onAddToPlaylist;
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
    this.initialArtistData,
    required this.getAllTracks,
    required this.onPlayTrack,
    required this.onToggleFavorite,
    this.onToggleFavorites,
    this.getPlaylists,
    this.onAddToPlaylist,
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
  final _selection = TrackSelection();
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
    _artistData = widget.initialArtistData;
    if (_artistData != null) _isLoading = false;
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
    setState(() {
      _hasFreshCatalog = true;
      _selection.retain(_getArtistTracks().map((track) => track['id'] as int));
    });
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
              _artistData = {...data, ...?widget.initialArtistData};
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
      return albumTrackOrder(
        catalog.where((track) => _asId(track['album']?['id']) == albumId),
      );
    }
    // Initial offline/detail fallback only. A confirmed empty catalog wins.
    for (final album in _artistData?['albums'] as List? ?? const []) {
      if (album is Map &&
          _asId(album['id']) == albumId &&
          album['tracks'] is List) {
        return albumTrackOrder(List<dynamic>.from(album['tracks'] as List));
      }
    }
    return albumTrackOrder(
      _getArtistTracks().where(
        (track) => _asId(track['album']?['id']) == albumId,
      ),
    );
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
        : albumTrackOrder(
            tracks.where((t) => t['album']?['id'] == _selectedAlbumId),
          );
    if (_selection.isNotEmpty) {
      _selection.retain(filteredTracks.map((track) => track['id'] as int));
    }
    final selectedTracks = _selection.inOrder(filteredTracks);
    final allSelectedFavorited =
        selectedTracks.isNotEmpty &&
        selectedTracks.every(
          (track) => widget.isTrackFavorited(track['id'] as int),
        );
    final touchMode = MediaQuery.sizeOf(context).width < 800;
    final downloadSelection = selectedTracks.isNotEmpty
        ? selectedTracks
        : _selectedAlbumId == null
        ? tracks
        : _albumDownloadTracks(_selectedAlbumId!);

    final photoUrl = _artistData?['photo'];
    final bio = _artistData?['bio']?.toString().trim() ?? '';
    final photoProvider = getArtistPhotoProvider(
      _artistData ?? {'id': widget.artistId, 'photo': photoUrl},
    );

    void tapTrack(int index) {
      var consumed = false;
      setState(() {
        consumed = _selection.tap(
          filteredTracks[index]['id'] as int,
          [for (final track in filteredTracks) track['id'] as int],
          control:
              HardwareKeyboard.instance.isControlPressed ||
              HardwareKeyboard.instance.isMetaPressed,
          shift: HardwareKeyboard.instance.isShiftPressed,
          touch: touchMode,
        );
      });
      if (!consumed) widget.onPlayTrack(filteredTracks, index);
    }

    Future<void> favoriteTracks(List<dynamic> targets) async {
      final ids = targets.map((track) => track['id'] as int).toList();
      if (widget.onToggleFavorites != null) {
        await widget.onToggleFavorites!(ids);
      } else {
        final add = !ids.every(widget.isTrackFavorited);
        for (final id in ids) {
          if (widget.isTrackFavorited(id) != add) widget.onToggleFavorite(id);
        }
      }
      if (mounted) setState(() {});
    }

    void downloadTracks(List<dynamic> targets) {
      if (widget.onDownloadAlbum != null) {
        unawaited(widget.onDownloadAlbum!(List<dynamic>.of(targets)));
      } else {
        for (final track in targets) {
          widget.onDownloadTrack(track);
        }
      }
    }

    final screen = Scaffold(
      backgroundColor: const Color(0xFF161416),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: Icon(
            _selection.isNotEmpty ? Icons.close : Icons.arrow_back,
            color: Colors.white,
          ),
          tooltip: _selection.isNotEmpty ? tr('clear_track_selection') : null,
          onPressed: () => _selection.isNotEmpty
              ? setState(_selection.clear)
              : Navigator.pop(context),
        ),
      ),
      body: ValueListenableBuilder<String?>(
        valueListenable: customBackgroundNotifier,
        builder: (context, background, content) => Stack(
          fit: StackFit.expand,
          children: [
            if (background != null && globalLocalPath.isNotEmpty)
              RepaintBoundary(
                child: Image.file(
                  File('$globalLocalPath/$background'),
                  key: const ValueKey('artist_background'),
                  fit: BoxFit.cover,
                  color: Colors.black.withValues(alpha: 0.82),
                  colorBlendMode: BlendMode.srcOver,
                  gaplessPlayback: true,
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) =>
                      const ColoredBox(color: Color(0xFF161416)),
                ),
              ),
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1200),
                child: content,
              ),
            ),
          ],
        ),
        child: _isLoading && tracks.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : CustomScrollView(
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                slivers: [
                  SliverToBoxAdapter(
                    child: _buildArtistHeader(
                      context,
                      photoProvider,
                      tracks,
                      albums,
                      accent,
                    ),
                  ),
                  if (bio.isNotEmpty)
                    SliverToBoxAdapter(child: _buildBiography(bio, accent)),

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
                                onTap: () => setState(() {
                                  _selectedAlbumId = null;
                                  _selection.clear();
                                }),
                                child: Container(
                                  width: 120,
                                  margin: const EdgeInsets.only(right: 14),
                                  decoration: BoxDecoration(
                                    color: isAllSelected
                                        ? accent.withValues(alpha: 0.10)
                                        : Colors.white.withValues(alpha: 0.05),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: isAllSelected
                                          ? accent
                                          : Colors.white12,
                                      width: 1,
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
                                _selection.clear();
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
                                            width: isSelected ? 2 : 1,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                          color: Colors.white10,
                                          image: coverProvider != null
                                              ? DecorationImage(
                                                  image: coverThumbnail(
                                                    context,
                                                    coverProvider,
                                                    120,
                                                  ),
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
                                        color: isSelected
                                            ? accent
                                            : Colors.white,
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
                                  tooltip: selectedTracks.isNotEmpty
                                      ? tr('download_selected_tracks')
                                      : _selectedAlbumId == null
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
                  if (selectedTracks.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: TrackSelectionBar(
                          count: selectedTracks.length,
                          onClear: () => setState(_selection.clear),
                          playlists: widget.getPlaylists?.call() ?? const {},
                          onPlaylistSelected: widget.onAddToPlaylist == null
                              ? null
                              : (id) {
                                  unawaited(
                                    widget.onAddToPlaylist!(
                                      id,
                                      selectedTracks
                                          .map((track) => track['id'] as int)
                                          .toList(),
                                    ),
                                  );
                                },
                          onPlay: () {
                            final queue = List<dynamic>.of(selectedTracks);
                            setState(_selection.clear);
                            widget.onPlayTrack(queue, 0);
                          },
                        ),
                      ),
                    ),
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
                        final isSelected = _selection.contains(trackId as int);
                        final targets = isSelected ? selectedTracks : [track];
                        final rowFav = isSelected
                            ? allSelectedFavorited
                            : isFav;

                        return Container(
                          key: ValueKey('artist_track_$trackId'),
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Colors.black.withValues(alpha: 0.16)
                                : activeTrackId == trackId
                                ? Colors.white.withValues(alpha: 0.1)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: ListTile(
                            selected: isSelected,
                            selectedTileColor: Colors.transparent,
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
                                  key: ValueKey('artist_favorite_$trackId'),
                                  icon: Icon(
                                    rowFav
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                    color: rowFav
                                        ? Colors.redAccent
                                        : Colors.white54,
                                    size: 22,
                                  ),
                                  onPressed: () {
                                    unawaited(favoriteTracks(targets));
                                  },
                                ),
                                if (isSelected)
                                  IconButton(
                                    key: ValueKey('artist_download_$trackId'),
                                    tooltip: tr('download_selected_tracks'),
                                    onPressed: () => downloadTracks(targets),
                                    icon: const Icon(
                                      Icons.download,
                                      color: Colors.white54,
                                      size: 22,
                                    ),
                                  )
                                else if (isDownloading)
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
                                  color: isPlayingThis
                                      ? accent
                                      : Colors.white54,
                                  size: 22,
                                ),
                              ],
                            ),
                            onTap: () => tapTrack(idx),
                            onLongPress: touchMode
                                ? () =>
                                      setState(() => _selection.toggle(trackId))
                                : null,
                          ),
                        );
                      }, childCount: filteredTracks.length),
                    ),
                  ),

                  const SliverToBoxAdapter(child: SizedBox(height: 100)),
                ],
              ),
      ),
    );
    return Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape &&
            _selection.isNotEmpty) {
          setState(_selection.clear);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: screen,
    );
  }

  Widget _buildArtistHeader(
    BuildContext context,
    ImageProvider? photo,
    List<dynamic> tracks,
    List<dynamic> albums,
    Color accent,
  ) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final portrait = Container(
          key: const ValueKey('artist_portrait'),
          width: 112,
          height: 112,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white24),
            color: Colors.white10,
            image: photo == null
                ? null
                : DecorationImage(
                    image: coverThumbnail(context, photo, 112),
                    fit: BoxFit.cover,
                  ),
          ),
          child: photo == null
              ? const Icon(Icons.person, color: Colors.white54, size: 48)
              : null,
        );
        final details = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _currentArtistName(tracks),
              key: const ValueKey('artist_title'),
              style: const TextStyle(
                color: Color(0xFFF3EFF1),
                fontSize: 32,
                fontWeight: FontWeight.w700,
                height: 1.15,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 10),
            Text(
              '${tracks.length} ${tr('artist_tracks_count')} · ${albums.length} ${tr('artist_albums_count')}',
              style: const TextStyle(color: Color(0xFFB9B0B5), fontSize: 14),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.play_arrow_rounded, size: 22),
                  label: Text(tr('artist_play_all')),
                  style: FilledButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor:
                        ThemeData.estimateBrightnessForColor(accent) ==
                            Brightness.dark
                        ? Colors.white
                        : Colors.black,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                  ),
                  onPressed: tracks.isEmpty
                      ? null
                      : () => widget.onPlayTrack(tracks, 0),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.shuffle, size: 18),
                  label: Text(tr('artist_shuffle')),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 14,
                    ),
                  ),
                  onPressed: tracks.isEmpty
                      ? null
                      : () {
                          final shuffled = List<dynamic>.from(tracks)
                            ..shuffle();
                          widget.onPlayTrack(shuffled, 0);
                        },
                ),
              ],
            ),
          ],
        );
        return constraints.maxWidth < 520
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [portrait, const SizedBox(height: 20), details],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  portrait,
                  const SizedBox(width: 28),
                  Expanded(child: details),
                ],
              );
      },
    ),
  );

  Widget _buildBiography(String bio, Color accent) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
    child: Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: LayoutBuilder(
          builder: (context, constraints) {
            const bodyStyle = TextStyle(
              color: Color(0xFFCCC6CB),
              fontSize: 15,
              height: 1.65,
            );
            final measure = TextPainter(
              text: TextSpan(text: bio, style: bodyStyle),
              maxLines: 4,
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout(maxWidth: constraints.maxWidth);
            final canExpand = measure.didExceedMaxLines;
            measure.dispose();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('artist_bio'),
                  style: const TextStyle(
                    color: Color(0xFFF3EFF1),
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  bio,
                  style: bodyStyle,
                  maxLines: _isBioExpanded ? null : 4,
                  overflow: _isBioExpanded
                      ? TextOverflow.visible
                      : TextOverflow.ellipsis,
                ),
                if (canExpand)
                  TextButton(
                    key: const ValueKey('artist_bio_expand'),
                    style: TextButton.styleFrom(
                      foregroundColor: accent,
                      padding: EdgeInsets.zero,
                      alignment: Alignment.centerLeft,
                    ),
                    onPressed: () =>
                        setState(() => _isBioExpanded = !_isBioExpanded),
                    child: Text(tr(_isBioExpanded ? 'show_less' : 'read_more')),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );

  String _getAlbumTitle(int? albumId, List<dynamic> albums) {
    if (albumId == null) return '';
    for (final album in albums) {
      if (album['id'] == albumId) return album['title']?.toString() ?? '';
    }
    return '';
  }
}
