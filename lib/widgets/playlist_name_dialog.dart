import 'package:flutter/material.dart';

import '../globals.dart';
import '../localization.dart';

class PlaylistNameDialog extends StatefulWidget {
  const PlaylistNameDialog({super.key, required this.initialName});
  final String initialName;

  @override
  State<PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<PlaylistNameDialog> {
  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName);
    _name.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _name.text.length,
    );
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final value = _name.text.trim();
    if (value.isNotEmpty) Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: const Color(0xFF242024),
    title: Text(
      tr('playlist_rename'),
      style: const TextStyle(color: Colors.white),
    ),
    content: SizedBox(
      width: 320,
      child: TextField(
        key: const ValueKey('playlist_rename_input'),
        controller: _name,
        autofocus: true,
        style: const TextStyle(color: Colors.white),
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: tr('playlist_name'),
          labelStyle: const TextStyle(color: Colors.white70),
          focusedBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: accentColorNotifier.value),
          ),
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _save(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr('cancel')),
      ),
      TextButton(
        onPressed: _name.text.trim().isEmpty ? null : _save,
        child: Text(tr('playlist_save')),
      ),
    ],
  );
}
