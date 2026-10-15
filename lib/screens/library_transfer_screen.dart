import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../library_transfer.dart';
import '../listening_statistics.dart';
import '../localization.dart';
import '../statistics_store.dart';

class LibraryTransferScreen extends StatefulWidget {
  const LibraryTransferScreen({
    super.key,
    required this.directory,
    this.statistics,
    this.beforeExport,
  });
  final Directory directory;
  final ListeningStatistics? statistics;
  final Future<void> Function()? beforeExport;

  @override
  State<LibraryTransferScreen> createState() => _LibraryTransferScreenState();
}

class _LibraryTransferScreenState extends State<LibraryTransferScreen> {
  bool _media = false, _settings = false, _busy = false;
  bool _pendingImport = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    File('${widget.directory.path}/transfer_pending.json').exists().then((
      value,
    ) {
      if (mounted) setState(() => _pendingImport = value);
    });
  }

  Future<void> _transfer(bool importing) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    Directory? temporary;
    try {
      if (importing) {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['zip'],
          withData: false,
        );
        final path = result?.files.single.path;
        if (path == null) return;
        await prepareLibraryImport(
          directory: widget.directory,
          archive: path,
          restoreSettings: _settings,
        );
        if (mounted) {
          setState(() {
            _pendingImport = true;
            _message = tr('transfer_pending');
          });
        }
      } else {
        await widget.beforeExport?.call();
        final statsFile = File(
          '${widget.directory.path}/listening_statistics.sqlite',
        );
        final statistics = widget.statistics != null
            ? await widget.statistics!.exportData()
            : await statsFile.exists()
            ? await StatisticsStore(statsFile.path).exportData()
            : null;
        temporary = await Directory.systemTemp.createTemp('shiki-export-');
        final archive = await exportLibraryArchive(
          directory: widget.directory,
          destination: '${temporary.path}/shiki-library.zip',
          includeMedia: _media,
          statistics: statistics,
        );
        final name =
            'shiki-library-${DateTime.now().toIso8601String().substring(0, 10)}.zip';
        bool saved;
        if (Platform.isAndroid) {
          saved =
              await const MethodChannel(
                'shiki/library_transfer',
              ).invokeMethod<bool>('saveArchive', {
                'path': archive,
                'name': name,
              }) ??
              false;
        } else {
          final destination = await FilePicker.platform.saveFile(
            dialogTitle: tr('transfer_export'),
            fileName: name,
            type: FileType.custom,
            allowedExtensions: ['zip'],
          );
          saved = destination != null;
          if (destination != null) {
            // The save dialog obtains the user's destination/overwrite choice.
            await File(archive).copy(destination);
          }
        }
        if (saved && mounted) setState(() => _message = tr('transfer_saved'));
      }
    } catch (error) {
      if (mounted) setState(() => _message = '${tr('transfer_error')}\n$error');
    } finally {
      if (temporary != null) {
        // Only the directory created above; never the selected export target.
        try {
          await temporary.delete(recursive: true);
        } catch (_) {}
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      backgroundColor: const Color(0xFF161416),
      appBar: AppBar(
        title: Text(tr('transfer_title')),
        backgroundColor: const Color(0xFF161416),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                tr('transfer_hint'),
                style: const TextStyle(color: Color(0xFFB9B0B5), height: 1.5),
              ),
              const SizedBox(height: 24),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('transfer_media')),
                value: _media,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _media = value),
              ),
              OutlinedButton(
                onPressed: _busy ? null : () => _transfer(false),
                child: Text(tr('transfer_export')),
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('transfer_settings')),
                value: _settings,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _settings = value),
              ),
              Text(
                tr('transfer_import_hint'),
                style: const TextStyle(color: Color(0xFFB9B0B5), height: 1.5),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _busy || _pendingImport
                    ? null
                    : () => _transfer(true),
                child: Text(tr('transfer_import')),
              ),
              if (_pendingImport)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          setState(() => _busy = true);
                          try {
                            await cancelPendingLibraryImport(widget.directory);
                            if (mounted) {
                              setState(() {
                                _pendingImport = false;
                                _message = tr('transfer_cancelled');
                              });
                            }
                          } catch (error) {
                            if (mounted) {
                              setState(
                                () => _message =
                                    '${tr('transfer_error')}\n$error',
                              );
                            }
                          } finally {
                            if (mounted) setState(() => _busy = false);
                          }
                        },
                  child: Text(tr('transfer_cancel')),
                ),
              if (_busy) ...[
                const SizedBox(height: 24),
                const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Text(tr('transfer_working')),
              ],
              if (_message != null) ...[
                const SizedBox(height: 24),
                SelectableText(_message!),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
