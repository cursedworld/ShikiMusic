import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../localization.dart';
import '../lrc_parser.dart';
import '../lyric_timing.dart';
import '../lyric_timing_proposals.dart';
import 'lyric_timing_controls.dart' show lyricProposalMessage;

class LyricLineEditDialog extends StatefulWidget {
  const LyricLineEditDialog({
    super.key,
    required this.session,
    required this.sourceLine,
    required this.original,
    required this.initial,
    required this.active,
    this.proposals,
  });

  final LyricTimingSession session;
  final int sourceLine;
  final String original;
  final String initial;
  final bool active;
  final LyricTimingProposalClient? proposals;

  @override
  State<LyricLineEditDialog> createState() => _LyricLineEditDialogState();
}

class _LyricLineEditDialogState extends State<LyricLineEditDialog> {
  late final _text = TextEditingController(text: widget.initial);
  bool _busy = false;
  bool _sending = false;
  bool _supported = false;
  bool _saveFailed = false;
  LyricTimingProposalResult? _result;

  @override
  void initState() {
    super.initState();
    final proposals = widget.proposals;
    if (widget.session.isServerTrack && proposals != null) {
      unawaited(() async {
        final supported = await proposals.supportsTextProposals();
        if (mounted && supported) setState(() => _supported = true);
      }());
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _edited() => setState(() {
    _result = null;
    _saveFailed = false;
  });

  Future<void> _save({bool send = false}) async {
    final value = _text.text.trim();
    if (_busy || !widget.active || !validLyricLineText(value)) return;
    setState(() {
      _busy = true;
      _saveFailed = false;
      _result = null;
    });
    try {
      final saved = await widget.session.saveLineText(widget.sourceLine, value);
      if (!mounted || !saved || !widget.session.isCurrent) return;
      final correction = send ? widget.session.savedTextCorrection : null;
      if (correction == null) {
        Navigator.of(context).pop();
        return;
      }
      setState(() => _sending = true);
      final result = await widget.proposals!.submitText(correction);
      if (mounted && widget.session.isCurrent) setState(() => _result = result);
    } catch (_) {
      if (mounted) setState(() => _saveFailed = true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _sending = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final valid = validLyricLineText(_text.text.trim());
    final active = widget.active && widget.session.isCurrent;
    final canSave = !_busy && active && valid;
    final result = _result;
    final canSend =
        _supported &&
        (widget.session.hasTextEdits || _text.text.trim() != widget.original) &&
        result != LyricTimingProposalResult.pending &&
        result != LyricTimingProposalResult.accepted &&
        result != LyricTimingProposalResult.rejected;
    final status = !active
        ? tr('lyric_line_track_changed')
        : _saveFailed
        ? tr('lyric_timing_save_error')
        : _sending
        ? tr('lyric_timing_sending')
        : result == null
        ? null
        : lyricProposalMessage(result);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        scrollable: true,
        title: Text(tr('lyric_edit_line')),
        content: SizedBox(
          width: 384,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('lyric_line_input'),
                controller: _text,
                autofocus: true,
                readOnly: _busy || !active,
                minLines: 1,
                maxLines: 3,
                maxLength: lyricLineTextLimit,
                inputFormatters: [
                  FilteringTextInputFormatter.singleLineFormatter,
                ],
                decoration: InputDecoration(
                  labelText: tr('lyric_line_label'),
                  errorText: valid ? null : tr('lyric_line_invalid'),
                  errorMaxLines: 3,
                ),
                onChanged: (_) => _edited(),
              ),
              if (active && _text.text.trim() != widget.original)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () {
                          _text.text = widget.original;
                          _edited();
                        },
                  child: Text(tr('lyric_line_revert')),
                ),
              if (status != null)
                Semantics(liveRegion: true, child: Text(status))
              else if (canSend && active)
                Text(tr('lyric_line_share_hint')),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: Text(tr('cancel')),
          ),
          if (canSend && active)
            TextButton(
              onPressed: canSave ? () => _save(send: true) : null,
              child: Text(tr('lyric_timing_propose')),
            ),
          FilledButton(
            onPressed: canSave ? _save : null,
            child: Text(tr('playlist_save')),
          ),
        ],
      ),
    );
  }
}
