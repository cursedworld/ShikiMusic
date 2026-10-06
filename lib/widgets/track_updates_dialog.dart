import 'package:flutter/material.dart';
import '../globals.dart';
import '../localization.dart';
import '../track_updates.dart';

class TrackUpdatesDialog extends StatefulWidget {
  const TrackUpdatesDialog({
    super.key,
    required this.monitor,
    required this.onUpdate,
  });
  final TrackUpdateMonitor monitor;
  final Future<void> Function(TrackUpdateOffer) onUpdate;

  @override
  State<TrackUpdatesDialog> createState() => _TrackUpdatesDialogState();
}

class _TrackUpdatesDialogState extends State<TrackUpdatesDialog> {
  int? _busy;
  int? _failed;

  Future<void> _update(TrackUpdateOffer offer) async {
    setState(() {
      _busy = offer.id;
      _failed = null;
    });
    try {
      await widget.onUpdate(offer);
    } catch (_) {
      if (mounted) setState(() => _failed = offer.id);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: const Color(0xFF202020),
    title: Text(
      tr('track_updates'),
      style: const TextStyle(color: Colors.white),
    ),
    content: SizedBox(
      width: 520,
      height: MediaQuery.sizeOf(context).height.clamp(240, 640) * 0.55,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('track_updates_hint'),
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ValueListenableBuilder<List<TrackUpdateOffer>>(
              valueListenable: widget.monitor.offers,
              builder: (context, offers, _) => offers.isEmpty
                  ? Center(
                      child: Text(
                        tr('tracks_up_to_date'),
                        style: const TextStyle(color: Colors.white70),
                      ),
                    )
                  : ListView.builder(
                      itemCount: offers.length,
                      itemBuilder: (context, index) {
                        final offer = offers[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                offer.title,
                                style: const TextStyle(color: Colors.white),
                              ),
                              if (_failed == offer.id)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 8,
                                  ),
                                  child: Text(
                                    tr('track_update_failed'),
                                    style: const TextStyle(
                                      color: Colors.redAccent,
                                    ),
                                  ),
                                ),
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  style: TextButton.styleFrom(
                                    minimumSize: const Size(88, 44),
                                foregroundColor: accentColorNotifier.value,
                                  ),
                                  onPressed: _busy == null
                                      ? () => _update(offer)
                                      : null,
                                  child: _busy == offer.id
                                      ? SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                      color: accentColorNotifier.value,
                                            semanticsLabel: tr(
                                              'updating_track',
                                            ),
                                          ),
                                        )
                                      : Text(tr('update_track')),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr('update_later')),
      ),
    ],
  );
}
