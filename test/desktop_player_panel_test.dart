import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/localization.dart';
import 'package:shiki/screens/home_screen.dart';
import 'package:shiki/widgets/desktop_player_panel.dart';

final _panel = find.byType(DesktopPlayerPanel);
final _scrollView = find.descendant(
  of: _panel,
  matching: find.byType(SingleChildScrollView),
);
final _artwork = find.descendant(
  of: _panel,
  matching: find.byType(RotationTransition),
);
final _play = find.ancestor(
  of: find.byIcon(Icons.play_circle_fill),
  matching: find.byType(IconButton),
);

Future<void> _showPlayer(
  WidgetTester tester,
  Size size, {
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final player = MainAppScreenState()
    ..playingQueue = [
      {
        'id': 1,
        'title': 'A longer track title that might wrap in the panel',
        'artists': [
          {'id': 12, 'name': 'Test artist'},
        ],
      },
    ];
  addTearDown(() {
    player.catalogSyncStatus.dispose();
    player.searchInput.dispose();
    player.searchFocusNode.dispose();
    player.currentPositionNotifier.dispose();
    player.fullDurationNotifier.dispose();
  });

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => Row(
            children: [
              const Expanded(child: SizedBox()),
              player.buildDesktopPlayer(context),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(of: _scrollView, matching: find.byType(Scrollable)),
    )
    .position;

void main() {
  testWidgets('the desktop transport sits below center in a tall window', (
    tester,
  ) async {
    await _showPlayer(tester, const Size(1440, 1350));
    final panel = tester.getRect(_panel);
    final content = tester.getRect(_scrollView);
    expect(panel.size, const Size(360, 1350));
    expect(
      content.top - panel.top,
      greaterThan(2 * (panel.bottom - content.bottom)),
    );
    expect(panel.bottom - content.bottom, greaterThan(80));
    expect(content.center.dx, closeTo(panel.center.dx, 0.1));
    expect(tester.getSize(_artwork), const Size.square(240));
    expect(_position(tester).maxScrollExtent, 0);

    final artwork = tester.element(_artwork);
    tester.view.physicalSize = const Size(1024, 700);
    await tester.pumpAndSettle();
    expect(tester.element(_artwork), same(artwork));
    expect(_position(tester).maxScrollExtent, 0);
    expect(_play.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'short window keeps the buttons visible and the cover reachable',
    (tester) async {
      await _showPlayer(tester, const Size(1024, 345), textScale: 2);
      expect(_play.hitTestable(), findsOneWidget);
      expect(_position(tester).pixels, 0);
      expect(_position(tester).maxScrollExtent, greaterThan(0));
      expect(
        tester.getTopLeft(_artwork).dy,
        lessThan(tester.getTopLeft(_panel).dy),
      );

      final viewport = tester.getRect(_scrollView);
      final mouse = Offset(viewport.left + 8, viewport.center.dy);
      final delta = _position(tester).maxScrollExtent + 24;
      await tester.sendEventToBinding(
        PointerScrollEvent(position: mouse, scrollDelta: Offset(0, -delta)),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(_artwork).dy, greaterThanOrEqualTo(0));
      expect(tester.getBottomRight(_artwork).dy, lessThan(345));

      await tester.sendEventToBinding(
        PointerScrollEvent(position: mouse, scrollDelta: Offset(0, delta)),
      );
      await tester.pumpAndSettle();
      expect(_play.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final language in ['ru', 'en', 'ja']) {
    testWidgets('desktop control tips use the $language strings', (
      tester,
    ) async {
      final previous = languageNotifier.value;
      languageNotifier.value = language;
      addTearDown(() => languageNotifier.value = previous);
      await _showPlayer(tester, const Size(1280, 760));

      for (final key in [
        'taskbar_previous',
        'taskbar_play',
        'taskbar_next',
        'open_lyrics',
        'repeat_off',
      ]) {
        expect(find.byTooltip(tr(key)), findsOneWidget);
      }
    });
  }
}
