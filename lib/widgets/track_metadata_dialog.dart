import 'package:flutter/material.dart';

import '../localization.dart';
import '../music_import.dart';

class TrackMetadataDialog extends StatefulWidget {
  const TrackMetadataDialog({super.key, required this.metadata});

  final Map<String, dynamic> metadata;

  @override
  State<TrackMetadataDialog> createState() => _TrackMetadataDialogState();
}

class _TrackMetadataDialogState extends State<TrackMetadataDialog> {
  late final TextEditingController _title;
  late final TextEditingController _artist;
  late final TextEditingController _album;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(
      text: widget.metadata['title']?.toString() ?? '',
    );
    _artist = TextEditingController(
      text: widget.metadata['artist']?.toString() ?? '',
    );
    _album = TextEditingController(
      text: widget.metadata['album']?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _album.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid =
        _title.text.trim().isNotEmpty && _artist.text.trim().isNotEmpty;
    return AlertDialog(
      backgroundColor: const Color(0xFF202020),
      title: Text(tr('confirm_track_metadata')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tr('metadata_confirmation_hint')),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('metadata_title'),
                controller: _title,
                decoration: InputDecoration(labelText: tr('track_title')),
                onChanged: (_) => setState(() {}),
              ),
              TextField(
                key: const ValueKey('metadata_artist'),
                controller: _artist,
                decoration: InputDecoration(labelText: tr('track_artist')),
                onChanged: (_) => setState(() {}),
              ),
              TextField(
                key: const ValueKey('metadata_album'),
                controller: _album,
                decoration: InputDecoration(labelText: tr('track_album')),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('cancel')),
        ),
        TextButton(
          key: const ValueKey('metadata_confirm'),
          onPressed: valid
              ? () => Navigator.pop(context, <String, dynamic>{
                  'title': _title.text.trim(),
                  'artist': _artist.text.trim(),
                  'album': _album.text.trim(),
                  'source_url': widget.metadata['source_url']?.toString() ?? '',
                })
              : null,
          child: Text(tr('confirm_import')),
        ),
      ],
    );
  }
}

class AlbumImportDialog extends StatefulWidget {
  const AlbumImportDialog({super.key, this.initialUrl = ''});

  final String initialUrl;

  @override
  State<AlbumImportDialog> createState() => _AlbumImportDialogState();
}

class _AlbumImportDialogState extends State<AlbumImportDialog> {
  late final TextEditingController _url;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.initialUrl);
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _submit() {
    if (isSupportedAlbumLink(_url.text)) {
      Navigator.pop(context, _url.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: const Color(0xFF202020),
    title: Text(tr('import_album')),
    content: SizedBox(
      width: 440,
      child: TextField(
        key: const ValueKey('album_import_url'),
        controller: _url,
        autofocus: true,
        decoration: InputDecoration(hintText: tr('album_link_hint')),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr('cancel')),
      ),
      TextButton(
        key: const ValueKey('album_import_confirm'),
        onPressed: isSupportedAlbumLink(_url.text) ? _submit : null,
        child: Text(tr('confirm_import')),
      ),
    ],
  );
}

class AlbumImportErrorsDialog extends StatelessWidget {
  const AlbumImportErrorsDialog({super.key, required this.errors});

  final List<dynamic> errors;

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: const Color(0xFF202020),
    title: Text(tr('import_partial')),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: errors.map((item) {
            if (item is! Map) return Text(item.toString());
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${item['title'] ?? item['index'] ?? ''}: ${item['error'] ?? ''}',
                  ),
                  if (item['confirmation_required'] == true &&
                      item['metadata'] is Map)
                    TextButton(
                      onPressed: () => Navigator.pop(context, item),
                      child: Text(tr('confirm_track_metadata')),
                    ),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr('close')),
      ),
    ],
  );
}
