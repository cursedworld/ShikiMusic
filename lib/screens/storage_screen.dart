import 'package:flutter/material.dart';

import '../disposable_cache.dart';
import '../globals.dart' show languageNotifier;
import '../localization.dart';

class StorageScreen extends StatefulWidget {
  const StorageScreen({
    super.key,
    required this.loadUsage,
    required this.clearCache,
  });

  final Future<StorageUsage> Function() loadUsage;
  final Future<ArtworkCleanupResult> Function() clearCache;

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  static const _background = Color(0xFF161416);
  static const _surface = Color(0xFF242024);
  static const _text = Color(0xFFF3EFF1);
  static const _muted = Color(0xFFB9B0B5);
  late Future<StorageUsage> _usage;
  bool _clearing = false;
  ArtworkCleanupResult? _lastCleanup;

  @override
  void initState() {
    super.initState();
    // Keep the scan outside build so resize, theme and progress don't restart it.
    // https://api.flutter.dev/flutter/widgets/FutureBuilder-class.html
    _usage = Future.sync(widget.loadUsage);
  }

  void _retryUsage() {
    final reading = Future<StorageUsage>.sync(widget.loadUsage);
    setState(() {
      _usage = reading;
    });
  }

  Future<void> _confirmAndClear(StorageUsage usage) async {
    // Use the route result for explicit confirmation, including keyboard use.
    // https://api.flutter.dev/flutter/material/showDialog.html
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _surface,
        scrollable: true,
        title: Text(tr('clear_cache'), style: const TextStyle(color: _text)),
        content: Text(
          [
            _withSize('storage_estimated', usage.reclaimableBytes),
            tr('clear_cache_body'),
          ].join('\n\n'),
          style: const TextStyle(color: _muted),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('cancel'), style: const TextStyle(color: _text)),
          ),
          TextButton(
            key: const ValueKey('storage_confirm_clear'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('clear'), style: const TextStyle(color: _text)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _clearing) return;
    setState(() {
      _clearing = true;
      _lastCleanup = null;
    });
    ArtworkCleanupResult result;
    try {
      result = await widget.clearCache();
    } catch (_) {
      result = const ArtworkCleanupResult(failed: true);
    }
    if (!mounted) return;
    final refreshed = !result.busy || result.removedFiles > 0
        ? Future<StorageUsage>.sync(widget.loadUsage)
        : null;
    setState(() {
      _clearing = false;
      _lastCleanup = result;
      if (refreshed != null) _usage = refreshed;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _background,
    appBar: AppBar(
      title: Text(tr('storage')),
      backgroundColor: _background,
      foregroundColor: _text,
    ),
    body: SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: FutureBuilder<StorageUsage>(
            future: _usage,
            builder: (context, snapshot) {
              final reading = snapshot.connectionState != ConnectionState.done;
              final usage = snapshot.data;
              final result = _lastCleanup;
              return ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                children: [
                  if (reading || _clearing) ...[
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        tr(
                          _clearing
                              ? 'storage_cleaning'
                              : 'storage_calculating',
                        ),
                        style: const TextStyle(color: _muted),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 12),
                  ],
                  if (snapshot.hasError && !reading) ...[
                    Text(
                      tr('storage_read_error'),
                      style: const TextStyle(color: _text),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: _retryUsage,
                        child: Text(
                          tr('stats_retry'),
                          style: const TextStyle(color: _text),
                        ),
                      ),
                    ),
                  ] else ...[
                    _sizeRow('storage_music', usage?.audioBytes),
                    _sizeRow('storage_clips', usage?.clipBytes),
                    _sizeRow('storage_artwork', usage?.artworkBytes),
                    const Divider(height: 28),
                    _sizeRow('storage_reclaimable', usage?.reclaimableBytes),
                    Text(
                      tr('storage_cache_hint'),
                      style: const TextStyle(color: _muted),
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton(
                        key: const ValueKey('storage_clear'),
                        onPressed:
                            reading ||
                                _clearing ||
                                usage?.hasReclaimableArtwork != true
                            ? null
                            : () => _confirmAndClear(usage!),
                        child: Text(tr('clear_cache')),
                      ),
                    ),
                  ],
                  if (result != null) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _cleanupMessage(result),
                        style: const TextStyle(color: _text),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget _sizeRow(String label, int? bytes) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      children: [
        Expanded(
          child: Text(tr(label), style: const TextStyle(color: _text)),
        ),
        const SizedBox(width: 12),
        Text(
          bytes == null ? '—' : _formatSize(bytes),
          style: const TextStyle(color: _text, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}

String _cleanupMessage(ArtworkCleanupResult result) {
  final lines = [
    if (result.removedFiles > 0)
      _withSize('storage_freed', result.removedBytes),
    if (result.failed) tr('cache_clear_failed'),
    if (result.busy) tr('wait_for_downloads'),
  ];
  return lines.isEmpty ? tr('storage_no_files_to_clear') : lines.join('\n');
}

String _withSize(String key, int bytes) =>
    tr(key).replaceAll('{size}', _formatSize(bytes));

String _formatSize(int bytes) {
  const unitStep = 1000;
  final units = tr('storage_size_units').split('/');
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= unitStep && unit < units.length - 1) {
    value /= unitStep;
    unit++;
  }
  var number = unit == 0
      ? bytes.toString()
      : value.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
  if (languageNotifier.value == 'ru') number = number.replaceFirst('.', ',');
  return '$number ${units[unit]}';
}
