import 'package:flutter/material.dart';

import '../catalog_sync.dart';
import '../localization.dart';

class CatalogSyncButton extends StatelessWidget {
  const CatalogSyncButton({
    super.key,
    required this.status,
    required this.onRefresh,
  });

  final CatalogSyncStatus status;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: status,
    builder: (context, _) {
      final key = switch (status.phase) {
        CatalogSyncPhase.idle => 'catalog_refresh',
        CatalogSyncPhase.checking => 'catalog_checking',
        CatalogSyncPhase.synced => 'catalog_synced',
        CatalogSyncPhase.offline => 'catalog_offline',
        CatalogSyncPhase.error => 'catalog_error',
      };
      final last = status.lastSuccess;
      final time = last == null
          ? ''
          : '${MaterialLocalizations.of(context).formatShortDate(last)} '
                '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(last))}';
      final tooltip = [
        tr(key),
        if (last != null) tr('catalog_last_sync').replaceAll('{time}', time),
        tr('catalog_refresh'),
      ].join('\n');
      return IconButton(
        key: const ValueKey('catalog_sync'),
        tooltip: tooltip,
        onPressed: status.phase == CatalogSyncPhase.checking ? null : onRefresh,
        icon: Icon(
          switch (status.phase) {
            CatalogSyncPhase.offline => Icons.cloud_off_outlined,
            CatalogSyncPhase.error => Icons.sync_problem,
            _ => Icons.sync,
          },
          color: switch (status.phase) {
            CatalogSyncPhase.offline || CatalogSyncPhase.error => Colors.amber,
            _ => Colors.white54,
          },
        ),
      );
    },
  );
}
