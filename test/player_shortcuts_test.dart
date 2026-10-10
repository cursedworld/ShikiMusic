import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/player_shortcuts.dart';

void main() {
  late int toggles;
  late bool handled;
  late KeyEventCallback handler;
  setUp(() {
    toggles = 0;
    handled = false;
    handler = (event) {
      handled = handlePlaybackSpace(event, onToggle: () => toggles++);
      return handled;
    };
    HardwareKeyboard.instance.addHandler(handler);
  });
  tearDown(() => HardwareKeyboard.instance.removeHandler(handler));

  testWidgets('space still toggles playback outside text input', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Focus(autofocus: true, child: const SizedBox())),
    );
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    expect(handled, isTrue);
    expect(toggles, 1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    expect(toggles, 1);
  });

  for (final field in ['playlist_name', 'search', 'server_address']) {
    testWidgets('space belongs to the $field text field, not playback', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextField(
              key: ValueKey(field),
              controller: controller,
              autofocus: true,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(ValueKey(field)),
        'Мой любимый плейлист',
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      expect(handled, isFalse);
      expect(toggles, 0);
      expect(controller.text, 'Мой любимый плейлист');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('space activates a dialog button without pausing music', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                actions: [
                  TextButton(
                    autofocus: true,
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(toggles, 0);
    expect(find.text('Close'), findsNothing);
  });
}
