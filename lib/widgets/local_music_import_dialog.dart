import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../local_music_import.dart';
import '../localization.dart';

class LocalMusicImportDialog extends StatefulWidget {
  const LocalMusicImportDialog({
    super.key,
    required this.desktop,
    required this.onImport,
    this.chooseFiles,
  });
  final bool desktop;
  final Future<LocalMusicImportResult> Function(
    List<LocalMusicFile>,
    LocalImportCancel,
    LocalMusicProgress,
  )
  onImport;
  final Future<List<LocalMusicFile>?> Function()? chooseFiles;

  @override
  State<LocalMusicImportDialog> createState() => _LocalMusicImportDialogState();
}

class _LocalMusicImportDialogState extends State<LocalMusicImportDialog> {
  LocalImportCancel? _cancel;
  LocalMusicImportResult? _result;
  ({int index, int total, String name, double? fraction})? _progress;
  bool _choosing = false;
  bool _failed = false;

  Future<List<LocalMusicFile>?> _chooseFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      // Not all Android providers declare a MIME type for .lrc.
      type: widget.desktop ? FileType.custom : FileType.any,
      allowedExtensions: widget.desktop ? ['mp3', 'lrc'] : null,
      withData: false,
    );
    return result?.files
        .map((file) => (name: file.name, path: file.path))
        .toList();
  }

  Future<void> _chooseAndImport() async {
    setState(() {
      _choosing = true;
      _failed = false;
    });
    try {
      final files = await (widget.chooseFiles ?? _chooseFiles)();
      if (!mounted || files == null || files.isEmpty) return;
      final token = LocalImportCancel();
      setState(() {
        _choosing = false;
        _cancel = token;
        _progress = null;
      });
      final result = await widget.onImport(files, token, (
        index,
        total,
        name,
        fraction,
      ) {
        if (mounted) {
          setState(
            () => _progress = (
              index: index,
              total: total,
              name: name,
              fraction: fraction,
            ),
          );
        }
      });
      if (mounted) setState(() => _result = result);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) {
        setState(() {
          _choosing = false;
          _cancel = null;
        });
      }
    }
  }

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final progress = _progress;
    final cancel = _cancel;
    final busy = _choosing || cancel != null;
    final muted = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(color: Colors.white70);
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: Text(tr('local_import')),
        backgroundColor: const Color(0xff242124),
        scrollable: true,
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 408),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (cancel != null) ...[
                Text(
                  progress == null
                      ? tr('local_import_preparing')
                      : '${progress.index} / ${progress.total}   ${progress.name}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 14),
                LinearProgressIndicator(value: progress?.fraction),
              ] else if (result == null) ...[
                Text(tr('local_import_copy')),
                const SizedBox(height: 10),
                Text(
                  tr(
                    widget.desktop
                        ? 'local_import_lrc_desktop'
                        : 'local_import_lrc_mobile',
                  ),
                  style: muted,
                ),
              ] else ...[
                Text(
                  tr('local_import_summary')
                      .replaceAll('{added}', '${result.added}')
                      .replaceAll('{existing}', '${result.alreadyPresent}'),
                ),
                if (result.restored > 0)
                  Text(
                    tr(
                      'local_import_restored',
                    ).replaceAll('{count}', '${result.restored}'),
                  ),
                if (result.cancelled)
                  Text(tr('local_import_cancelled'), style: muted),
                if (result.problems.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    tr(
                      'local_import_problem_count',
                    ).replaceAll('{count}', '${result.problems.length}'),
                  ),
                  const Divider(),
                  for (final item in result.problems.take(20))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        '${item.name}: ${tr('local_import_${item.problem.name}')}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                    ),
                  if (result.problems.length > 20)
                    Text(
                      tr(
                        'local_import_more_problems',
                      ).replaceAll('{count}', '${result.problems.length - 20}'),
                      style: muted,
                    ),
                ],
              ],
              if (_failed)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text(
                    tr('local_import_save_failed'),
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          if (cancel != null)
            TextButton(
              onPressed: cancel.requested
                  ? null
                  : () => setState(cancel.cancel),
              child: Text(tr('cancel')),
            )
          else
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: Text(tr(result == null ? 'cancel' : 'close')),
            ),
          if (result == null && cancel == null)
            FilledButton.icon(
              key: const ValueKey('pick_local_music'),
              onPressed: busy ? null : _chooseAndImport,
              icon: const Icon(Icons.folder_open_outlined, size: 18),
              label: Text(tr('local_import_choose')),
            ),
        ],
      ),
    );
  }
}

class LocalMusicIndicator extends StatelessWidget {
  const LocalMusicIndicator({
    super.key,
    required this.available,
    this.onMissing,
  });
  final bool available;
  final VoidCallback? onMissing;

  @override
  Widget build(BuildContext context) {
    if (!available && onMissing != null) {
      return IconButton(
        tooltip: tr('local_import_missing'),
        onPressed: onMissing,
        icon: const Icon(Icons.error_outline, color: Colors.white54, size: 21),
      );
    }
    return Tooltip(
      message: tr(available ? 'local_import_owned' : 'local_import_missing'),
      child: SizedBox(
        width: 40,
        child: Icon(
          available ? Icons.audio_file_outlined : Icons.error_outline,
          color: Colors.white54,
          size: 20,
        ),
      ),
    );
  }
}
