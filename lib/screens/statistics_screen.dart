import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../globals.dart';
import '../listening_statistics.dart';
import '../localization.dart';
import '../statistics_artwork.dart';

class StatisticsScreen extends StatefulWidget {
  const StatisticsScreen({
    super.key,
    required this.statistics,
    this.tracks = const [],
    this.artists = const [],
  });
  final ListeningStatistics statistics;
  final List<dynamic> tracks, artists;

  @override
  State<StatisticsScreen> createState() => _StatisticsScreenState();
}

class _StatisticsScreenState extends State<StatisticsScreen> {
  StatisticsSummary? _summary;
  String _period = 'month';
  DateTimeRange? _customRange;
  bool _byPlays = false,
      _showArtists = false,
      _loading = true,
      _transferring = false;
  String? _error;
  int _request = 0;
  bool _expanded = false;
  late final StatisticsArtwork _artworks;

  @override
  void initState() {
    super.initState();
    _artworks = StatisticsArtwork(
      tracks: widget.tracks,
      artists: widget.artists,
    );
    _load();
  }

  DateTimeRange? get _range {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return switch (_period) {
      'week' => DateTimeRange(
        start: DateTime(today.year, today.month, today.day - 6),
        end: today,
      ),
      'month' => DateTimeRange(
        start: DateTime(today.year, today.month, today.day - 29),
        end: today,
      ),
      'year' => DateTimeRange(start: DateTime(today.year), end: today),
      'custom' => _customRange,
      _ => null,
    };
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    final range = _range;
    try {
      final summary = await widget.statistics.summary(
        from: range == null ? null : statisticsDay(range.start),
        to: statisticsDay(range?.end ?? DateTime.now()),
        byPlays: _byPlays,
      );
      if (mounted && request == _request) setState(() => _summary = summary);
    } catch (_) {
      if (mounted && request == _request) {
        setState(() => _error = tr('stats_error'));
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _selectPeriod(String value) async {
    if (value == 'custom') {
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(1970),
        lastDate: DateTime.now(),
        initialDateRange: _customRange ?? _range,
        builder: (context, child) => Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: ColorScheme.fromSeed(
              seedColor: accentColorNotifier.value,
              brightness: Brightness.dark,
            ),
          ),
          child: child!,
        ),
      );
      if (picked == null || !mounted) return;
      _customRange = picked;
    }
    if (!mounted) return;
    setState(() => _period = value);
    await _load();
  }

  Future<void> _transfer(bool importing) async {
    setState(() => _transferring = true);
    try {
      if (importing) {
        final picked = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['json'],
        );
        if (picked == null) return;
        final path = picked.files.single.path;
        if (path == null) throw const FormatException('Missing backup file');
        await widget.statistics.importFile(path);
      } else {
        final bytes = await widget.statistics.exportData();
        final saved = await FilePicker.platform.saveFile(
          dialogTitle: tr('stats_export'),
          fileName: 'shiki-statistics-${statisticsDay(DateTime.now())}.json',
          type: FileType.custom,
          allowedExtensions: ['json'],
          bytes: bytes,
        );
        if (saved == null) return;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr(importing ? 'stats_imported' : 'stats_exported')),
        ),
      );
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(importing ? 'stats_import_error' : 'stats_export_error'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _transferring = false);
    }
  }

  String _duration(int milliseconds) {
    final minutes = milliseconds ~/ 60000;
    if (milliseconds > 0 && minutes == 0) return tr('stats_under_minute');
    if (minutes < 60) return '$minutes ${tr('stats_minutes')}';
    return '${minutes ~/ 60} ${tr('stats_hours')} ${minutes % 60} ${tr('stats_minutes')}';
  }

  String _date(DateTime value) =>
      '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')}.${value.year}';

  static const _background = Color(0xFF161416);
  static const _surface = Color(0xFF242024);
  static const _text = Color(0xFFF3EFF1);
  static const _muted = Color(0xFFB9B0B5);

  @override
  Widget build(BuildContext context) {
    final accent = accentColorNotifier.value;
    final summary = _summary;
    final ranks = summary == null
        ? <StatisticsRank>[]
        : _showArtists
        ? summary.topArtists
        : summary.topTracks;
    final visibleCount = _expanded ? ranks.length : math.min(5, ranks.length);
    return Scaffold(
      backgroundColor: _background,
      appBar: AppBar(
        backgroundColor: _background,
        foregroundColor: _text,
        surfaceTintColor: Colors.transparent,
        title: Text(tr('stats_music')),
        actions: [
          IconButton(
            tooltip: tr('stats_refresh'),
            onPressed: _loading || _transferring ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: RefreshIndicator(
              onRefresh: _load,
              color: accent,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Align(
                            alignment: Alignment.centerRight,
                            child: PopupMenuButton<String>(
                              key: const ValueKey('stats_period'),
                              tooltip: tr('stats_period_custom'),
                              enabled: !_transferring,
                              initialValue: _period,
                              onSelected: _selectPeriod,
                              color: _surface,
                              itemBuilder: (_) => [
                                for (final value in [
                                  'week',
                                  'month',
                                  'year',
                                  'all',
                                  'custom',
                                ])
                                  PopupMenuItem(
                                    value: value,
                                    child: Text(tr('stats_period_$value')),
                                  ),
                              ],
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        _period == 'custom' &&
                                                _customRange != null
                                            ? '${_date(_customRange!.start)} — ${_date(_customRange!.end)}'
                                            : tr('stats_period_$_period'),
                                        style: const TextStyle(
                                          color: _text,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    const Icon(
                                      Icons.expand_more,
                                      size: 20,
                                      color: _muted,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          if (_loading || _transferring)
                            LinearProgressIndicator(
                              color: accent,
                              minHeight: 2,
                            ),
                          if (_error != null) ...[
                            Text(
                              _error!,
                              style: const TextStyle(color: Colors.redAccent),
                            ),
                            TextButton.icon(
                              onPressed: _load,
                              icon: const Icon(Icons.refresh),
                              label: Text(tr('stats_retry')),
                            ),
                          ],
                          if (summary != null) ...[
                            const SizedBox(height: 8),
                            if (summary.topArtists.isNotEmpty)
                              _featuredArtist(summary.topArtists.first)
                            else
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 24,
                                ),
                                child: Text(
                                  tr('stats_empty'),
                                  style: const TextStyle(color: _muted),
                                ),
                              ),
                            const SizedBox(height: 28),
                            Wrap(
                              spacing: 32,
                              runSpacing: 16,
                              children: [
                                _total(
                                  tr('stats_total_listened'),
                                  _duration(summary.listeningMs),
                                ),
                                _total(tr('stats_tracks'), '${summary.tracks}'),
                                _total(
                                  tr('stats_artists'),
                                  '${summary.artists}',
                                ),
                              ],
                            ),
                            const SizedBox(height: 36),
                            Wrap(
                              alignment: WrapAlignment.spaceBetween,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 24,
                              runSpacing: 8,
                              children: [
                                Wrap(
                                  spacing: 16,
                                  children: [
                                    _rankTab(
                                      false,
                                      tr('stats_favorite_tracks'),
                                      accent,
                                    ),
                                    _rankTab(true, tr('stats_artists'), accent),
                                  ],
                                ),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 230,
                                  ),
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<bool>(
                                      isExpanded: true,
                                      value: _byPlays,
                                      dropdownColor: _surface,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(color: _muted),
                                      items: [
                                        for (final value in [false, true])
                                          DropdownMenuItem(
                                            value: value,
                                            child: Text(
                                              tr(
                                                value
                                                    ? 'stats_sort_plays'
                                                    : 'stats_sort_time',
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                      ],
                                      onChanged: _transferring
                                          ? null
                                          : (value) {
                                              if (value == null) return;
                                              setState(() => _byPlays = value);
                                              _load();
                                            },
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                          ],
                        ],
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    sliver: SliverList.builder(
                      itemCount: visibleCount,
                      itemBuilder: (context, index) =>
                          _rankRow(ranks[index], index, ranks.first, accent),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (ranks.length > 5)
                            TextButton(
                              key: const ValueKey('stats_expand_ranking'),
                              onPressed: () =>
                                  setState(() => _expanded = !_expanded),
                              child: Text(
                                tr(_expanded ? 'stats_less' : 'stats_more'),
                              ),
                            ),
                          if (summary != null) ...[
                            const SizedBox(height: 28),
                            Text(
                              tr('stats_daily'),
                              style: const TextStyle(
                                color: _text,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 20),
                            if (summary.listeningMs > 0)
                              _chart(summary, accent)
                            else
                              const SizedBox(height: 12),
                            const SizedBox(height: 28),
                            Wrap(
                              spacing: 32,
                              runSpacing: 16,
                              children: [
                                _total(
                                  tr('stats_plays'),
                                  '${summary.plays}',
                                  secondary: true,
                                ),
                                _total(
                                  tr('stats_active_days'),
                                  '${summary.days.length}',
                                  secondary: true,
                                ),
                                _total(
                                  tr('stats_app_time'),
                                  _duration(summary.appMs),
                                  secondary: true,
                                ),
                              ],
                            ),
                            const SizedBox(height: 28),
                          ],
                          if (summary?.firstDay != null)
                            Text(
                              '${tr('stats_since')} ${_date(DateTime.parse(summary!.firstDay!))}',
                              style: const TextStyle(
                                color: _muted,
                                fontSize: 12,
                              ),
                            ),
                          Theme(
                            data: Theme.of(
                              context,
                            ).copyWith(dividerColor: Colors.transparent),
                            child: ExpansionTile(
                              tilePadding: EdgeInsets.zero,
                              childrenPadding: const EdgeInsets.only(
                                bottom: 16,
                              ),
                              title: Text(
                                tr('stats_details'),
                                style: const TextStyle(
                                  color: _muted,
                                  fontSize: 13,
                                ),
                              ),
                              children: [
                                Text(
                                  tr('stats_counting_hint'),
                                  style: const TextStyle(
                                    color: _muted,
                                    fontSize: 13,
                                    height: 1.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            children: [
                              TextButton.icon(
                                onPressed: _transferring
                                    ? null
                                    : () => _transfer(false),
                                icon: const Icon(
                                  Icons.file_upload_outlined,
                                  size: 18,
                                ),
                                label: Text(tr('stats_export')),
                              ),
                              TextButton.icon(
                                onPressed: _transferring
                                    ? null
                                    : () => _transfer(true),
                                icon: const Icon(
                                  Icons.file_download_outlined,
                                  size: 18,
                                ),
                                label: Text(tr('stats_import')),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            tr('stats_private'),
                            style: const TextStyle(color: _muted, fontSize: 12),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            tr('stats_backup_hint'),
                            style: const TextStyle(
                              color: _muted,
                              fontSize: 12,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _featuredArtist(StatisticsRank artist) => LayoutBuilder(
    builder: (context, constraints) {
      final narrow = constraints.maxWidth < 420;
      final size = narrow ? 88.0 : 132.0;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('stats_favorite_artist'),
            style: const TextStyle(color: _muted, fontSize: 14),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _artwork(artist, artist: true, size: size),
              SizedBox(width: narrow ? 18 : 28),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      artist.name.isEmpty ? tr('stats_untitled') : artist.name,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _text,
                        fontSize: narrow ? 26 : 38,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _duration(artist.milliseconds),
                      style: const TextStyle(color: _text, fontSize: 16),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${artist.plays} ${tr('stats_plays_short')}',
                      style: const TextStyle(color: _muted, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      );
    },
  );

  Widget _artwork(
    StatisticsRank item, {
    required bool artist,
    required double size,
  }) {
    final provider = _artworks.forRank(item, artist: artist);
    final fallback = Center(
      child: artist && item.name.isNotEmpty
          ? Text(
              item.name.characters.first.toUpperCase(),
              style: TextStyle(
                color: _muted,
                fontSize: size * 0.4,
                fontWeight: FontWeight.w600,
              ),
            )
          : Icon(Icons.music_note_outlined, color: _muted, size: size * 0.4),
    );
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size > 60 ? 16 : 6),
        child: ColoredBox(
          color: _surface,
          child: provider == null
              ? fallback
              : Image(
                  image: ResizeImage.resizeIfNeeded(
                    (size * MediaQuery.devicePixelRatioOf(context)).ceil(),
                    null,
                    provider,
                  ),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) => fallback,
                ),
        ),
      ),
    );
  }

  Widget _total(String label, String value, {bool secondary = false}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        value,
        style: TextStyle(
          color: secondary ? _muted : _text,
          fontSize: secondary ? 16 : 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 4),
      Text(label, style: const TextStyle(color: _muted, fontSize: 13)),
    ],
  );

  Widget _rankTab(bool artists, String label, Color accent) => TextButton(
    key: ValueKey(artists ? 'stats_rank_artists' : 'stats_rank_tracks'),
    onPressed: () => setState(() {
      _showArtists = artists;
      _expanded = false;
    }),
    style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 0),
      foregroundColor: _showArtists == artists ? _text : _muted,
      textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
        fontSize: 18,
        fontWeight: _showArtists == artists ? FontWeight.w600 : FontWeight.w400,
      ),
      shape: const RoundedRectangleBorder(),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        const SizedBox(height: 6),
        Container(
          height: 2,
          width: 24,
          color: _showArtists == artists ? accent : Colors.transparent,
        ),
      ],
    ),
  );

  Widget _rankRow(
    StatisticsRank item,
    int index,
    StatisticsRank leader,
    Color accent,
  ) => LayoutBuilder(
    builder: (context, constraints) {
      final compact =
          constraints.maxWidth < 460 ||
          MediaQuery.textScalerOf(context).scale(14) > 20;
      final value = _byPlays ? item.plays : item.milliseconds;
      final maxValue = _byPlays ? leader.plays : leader.milliseconds;
      final figures = _byPlays
          ? '${item.plays} ${tr('stats_plays_short')}'
          : _duration(item.milliseconds);
      return Padding(
        key: ValueKey('stats_rank_row_$index'),
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                '${index + 1}',
                style: const TextStyle(color: _muted, fontSize: 13),
              ),
            ),
            _artwork(item, artist: _showArtists, size: 44),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name.isEmpty ? tr('stats_untitled') : item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _text,
                      fontWeight: FontWeight.w500,
                      fontSize: 15,
                    ),
                  ),
                  if (item.detail.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      item.detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _muted, fontSize: 13),
                    ),
                  ],
                  if (compact) ...[
                    const SizedBox(height: 3),
                    Text(
                      figures,
                      style: const TextStyle(color: _muted, fontSize: 13),
                    ),
                  ],
                  if (_showArtists) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: 180,
                      child: LinearProgressIndicator(
                        value: maxValue == 0
                            ? 0
                            : (value / maxValue).clamp(0, 1),
                        minHeight: 3,
                        color: accent.withValues(alpha: 0.65),
                        backgroundColor: _surface,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (!compact) ...[
              const SizedBox(width: 16),
              Text(
                figures,
                style: const TextStyle(color: _muted, fontSize: 14),
              ),
            ],
          ],
        ),
      );
    },
  );

  Widget _chart(StatisticsSummary summary, Color accent) {
    final range = _range;
    final start =
        range?.start ??
        DateTime.tryParse(summary.firstDay ?? '') ??
        DateTime.now();
    final last = range?.end ?? DateTime.now();
    final end = DateTime(last.year, last.month, last.day);
    final byDay = {for (final day in summary.days) day.day: day.milliseconds};
    final dates = <DateTime>[];
    for (
      var date = start;
      !date.isAfter(end);
      date = DateTime(date.year, date.month, date.day + 1)
    ) {
      dates.add(date);
    }
    final count = math.min(30, dates.length);
    final buckets = <({DateTime from, DateTime to, int ms})>[];
    for (var i = 0; i < count; i++) {
      final first = i * dates.length ~/ count;
      final until = (i + 1) * dates.length ~/ count;
      var total = 0;
      for (var j = first; j < until; j++) {
        total += byDay[statisticsDay(dates[j])] ?? 0;
      }
      buckets.add((from: dates[first], to: dates[until - 1], ms: total));
    }
    final maximum = buckets.fold<int>(
      1,
      (value, bucket) => math.max(value, bucket.ms),
    );
    return Column(
      children: [
        SizedBox(
          height: 84,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final bucket in buckets)
                Expanded(
                  child: Tooltip(
                    message:
                        '${_date(bucket.from)}${bucket.to == bucket.from ? '' : ' — ${_date(bucket.to)}'}: ${_duration(bucket.ms)}',
                    child: Semantics(
                      label:
                          '${_date(bucket.from)} — ${_date(bucket.to)}: ${_duration(bucket.ms)}',
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Container(
                          height: math.max(2.0, bucket.ms / maximum * 84),
                          decoration: BoxDecoration(
                            color: bucket.ms == 0
                                ? Colors.white12
                                : accent.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                _date(start),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white60),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _date(end),
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white60),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
