import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../localization.dart';
import '../server_config.dart';

class ServerAddressSetting extends StatefulWidget {
  const ServerAddressSetting({
    super.key,
    required this.value,
    required this.onSave,
    this.client,
  });
  final String value;
  final Future<bool> Function(String) onSave;
  final http.Client? client;

  @override
  State<ServerAddressSetting> createState() => _ServerAddressSettingState();
}

class _ServerAddressSettingState extends State<ServerAddressSetting> {
  late final TextEditingController _controller;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(ServerAddressSetting oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _controller.text = widget.value;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run(bool testConnection) async {
    final value = _controller.text.trim();
    if (!isValidServerBaseUrl(value)) {
      setState(() => _message = tr('server_invalid'));
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (testConnection) {
        final client = widget.client ?? http.Client();
        try {
          final response = await client
              .get(buildServerUriForBase(value, 'api/tracks/catalog-revision/'))
              .timeout(const Duration(seconds: 5));
          final valid =
              response.statusCode == 200 && jsonDecode(response.body) is Map;
          if (mounted) {
            setState(
              () => _message = tr(
                valid ? 'server_connected' : 'server_unavailable',
              ),
            );
          }
        } finally {
          if (widget.client == null) client.close();
        }
      } else {
        final saved = await widget.onSave(normalizeServerBaseUrl(value));
        if (mounted) {
          setState(
            () => _message = tr(saved ? 'server_saved' : 'server_save_failed'),
          );
        }
      }
    } catch (_) {
      if (mounted) setState(() => _message = tr('server_unavailable'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const ValueKey('server_address'),
          controller: _controller,
          enabled: !_busy,
          autocorrect: false,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: tr('server_address'),
            hintText: tr('server_address_hint'),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              onPressed: _busy ? null : () => _run(true),
              child: Text(tr('server_test')),
            ),
            TextButton(
              onPressed: _busy ? null : () => _run(false),
              child: Text(tr('server_save')),
            ),
          ],
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_message != null)
          Text(
            _message!,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
      ],
    ),
  );
}
