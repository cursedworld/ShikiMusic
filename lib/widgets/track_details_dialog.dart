import 'package:flutter/material.dart';

import '../localization.dart';
import '../track_details.dart';

class TrackDetailsDialog extends StatefulWidget {
  const TrackDetailsDialog({
    super.key,
    required this.initial,
    required this.hasEdits,
    required this.onSave,
  });

  final TrackDetails initial;
  final bool hasEdits;
  // Null resets the local edits instead of saving the fields.
  final Future<void> Function(TrackDetails?) onSave;

  @override
  State<TrackDetailsDialog> createState() => _TrackDetailsDialogState();
}

class _TrackDetailsDialogState extends State<TrackDetailsDialog> {
  late final _title = TextEditingController(text: widget.initial.title);
  late final _artist = TextEditingController(text: widget.initial.artist);
  late final _album = TextEditingController(text: widget.initial.album);
  bool _saving = false;
  bool _saveFailed = false;

  TrackDetails get _draft => (
    title: _title.text.trim(),
    artist: _artist.text.trim(),
    album: _album.text.trim(),
  );

  bool get _canSave =>
      !_saving && _draft != widget.initial && validTrackDetails(_draft);

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _album.dispose();
    super.dispose();
  }

  Future<void> _save(TrackDetails? details) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    try {
      await widget.onSave(details);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveFailed = true;
      });
    }
  }

  Widget _field({
    Key? key,
    required TextEditingController controller,
    required String label,
    required TextInputAction action,
  }) => TextField(
    key: key,
    controller: controller,
    enabled: !_saving,
    textInputAction: action,
    maxLength: trackDetailsMaxLength,
    onChanged: (_) => setState(() => _saveFailed = false),
    decoration: InputDecoration(labelText: label, counterText: ''),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      scrollable: true,
      title: Text(tr('track_details')),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr('track_details_local_hint'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _field(
              key: const ValueKey('track_details_title'),
              controller: _title,
              label: tr('track_title'),
              action: TextInputAction.next,
            ),
            const SizedBox(height: 8),
            _field(
              controller: _artist,
              label: tr('track_artist'),
              action: TextInputAction.next,
            ),
            const SizedBox(height: 8),
            _field(
              controller: _album,
              label: tr('track_album'),
              action: TextInputAction.done,
            ),
            if (_saveFailed) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  tr('track_details_save_failed'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (widget.hasEdits)
          TextButton(
            key: const ValueKey('track_details_reset'),
            onPressed: _saving ? null : () => _save(null),
            child: Text(tr('track_details_reset')),
          ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(tr('cancel')),
        ),
        FilledButton(
          key: const ValueKey('track_details_save'),
          onPressed: _canSave ? () => _save(_draft) : null,
          child: Text(tr('track_details_save')),
        ),
      ],
    ),
  );
}
