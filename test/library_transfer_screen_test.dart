import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/screens/library_transfer_screen.dart';
import 'package:shiki/localization.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shiki-transfer-ui-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  for (final width in [320.0, 1440.0]) {
    testWidgets('transfer options fit width $width', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: LibraryTransferScreen(directory: directory)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SwitchListTile), findsNWidgets(2));
      expect(find.text(tr('transfer_export')), findsOneWidget);
      await tester.scrollUntilVisible(find.text(tr('transfer_import')), 200);
      expect(find.text(tr('transfer_import')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
