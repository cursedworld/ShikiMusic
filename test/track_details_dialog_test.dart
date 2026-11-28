import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/localization.dart';
import 'package:shiki/track_details.dart';
import 'package:shiki/widgets/track_details_dialog.dart';

const _original = (title: 'Original', artist: 'Artist', album: 'Album');
final _title = find.byKey(const ValueKey('track_details_title'));
final _save = find.byKey(const ValueKey('track_details_save'));
final _reset = find.byKey(const ValueKey('track_details_reset'));

Future<void> _open(
  WidgetTester tester,
  Future<void> Function(TrackDetails?) onSave, {
  bool hasEdits = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => TrackDetailsDialog(
                initial: _original,
                hasEdits: hasEdits,
                onSave: onSave,
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'shows existing names and saves trimmed edits in a narrow window',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final originalLanguage = languageNotifier.value;
      addTearDown(() => languageNotifier.value = originalLanguage);
      languageNotifier.value = 'ja';
      final saved = <TrackDetails?>[];
      await _open(tester, (details) async => saved.add(details));
      expect(
        tester.widget<TextField>(_title).controller!.text,
        _original.title,
      );
      expect(find.text(tr('track_details')), findsOneWidget);
      expect(_reset, findsNothing);

      await tester.enterText(_title, '  ');
      await tester.pump();
      expect(tester.widget<FilledButton>(_save).onPressed, isNull);
      await tester.enterText(_title, '  Новое название  ');
      await tester.pump();
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(saved.single, (
        title: 'Новое название',
        artist: 'Artist',
        album: 'Album',
      ));
      expect(find.byType(TrackDetailsDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancel does not write; reset sends the explicit reset action', (
    tester,
  ) async {
    final saved = <TrackDetails?>[];
    await _open(tester, (details) async => saved.add(details), hasEdits: true);
    await tester.enterText(_title, 'Discarded');
    await tester.tap(find.text(tr('cancel')));
    await tester.pumpAndSettle();
    expect(saved, isEmpty);

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(_reset);
    await tester.pumpAndSettle();
    expect(saved, [null]);
    expect(find.byType(TrackDetailsDialog), findsNothing);
  });

  testWidgets('a failed write keeps the edit available to retry', (
    tester,
  ) async {
    var attempts = 0;
    await _open(tester, (_) async {
      if (++attempts == 1) throw StateError('test write failure');
    });
    await tester.enterText(_title, 'Keep draft');
    await tester.pump();
    await tester.tap(_save);
    await tester.pumpAndSettle();
    expect(find.text(tr('track_details_save_failed')), findsOneWidget);
    expect(tester.widget<TextField>(_title).controller!.text, 'Keep draft');
    await tester.tap(_save);
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.byType(TrackDetailsDialog), findsNothing);
  });
}
