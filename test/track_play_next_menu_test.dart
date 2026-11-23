import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/widgets/play_next_panel.dart';

void main() {
  setUp(() {
    final original = languageNotifier.value;
    languageNotifier.value = 'en';
    addTearDown(() => languageNotifier.value = original);
  });

  final entries = find.byType(PopupMenuItem<Object>);
  final divider = find.byType(PopupMenuDivider);
  final popup = find.byType(SingleChildScrollView);
  final trigger = find.byType(TrackPlayNextMenu);

  Future<void> openMenu(
    WidgetTester tester,
    TargetPlatform platform, {
    Map<int, String> playlists = const {7: 'Night', 8: 'Walk'},
    VoidCallback? onPlayNext,
    ValueChanged<int>? onPlaylistSelected,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(platform: platform),
        home: Scaffold(
          body: Center(
            child: TrackPlayNextMenu(
              onPlayNext: onPlayNext ?? () {},
              playlists: playlists,
              onPlaylistSelected: onPlaylistSelected,
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(trigger).height, greaterThanOrEqualTo(44));
    await tester.tap(trigger);
    await tester.pumpAndSettle();
  }

  testWidgets('desktop popup is shorter and keeps both operations', (
    tester,
  ) async {
    var next = 0;
    final picked = <int>[];
    await openMenu(
      tester,
      TargetPlatform.windows,
      onPlayNext: () => next++,
      onPlaylistSelected: picked.add,
    );
    expect(entries, findsNWidgets(3));
    for (var i = 0; i < 3; i++) {
      expect(tester.getSize(entries.at(i)).height, 32);
    }
    expect(tester.getSize(divider).height, 8);
    expect(tester.getSize(popup).height, 112);
    await tester.tap(entries.first);
    await tester.pumpAndSettle();
    expect(next, 1);
    expect(picked, isEmpty);

    await tester.tap(trigger);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Walk'));
    await tester.pumpAndSettle();
    expect(next, 1);
    expect(picked, [8]);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('keeps the original touch targets on $platform', (
      tester,
    ) async {
      await openMenu(tester, platform);
      expect(entries, findsNWidgets(3));
      for (var i = 0; i < 3; i++) {
        expect(tester.getSize(entries.at(i)).height, greaterThanOrEqualTo(48));
      }
      expect(tester.getSize(divider).height, 16);
      expect(tester.getSize(popup).height, 176);
    });
  }

  testWidgets('long playlist labels stay selectable in a bounded popup', (
    tester,
  ) async {
    final picked = <int>[];
    const name = 'Long playlist name with more words for a compact popup';
    await openMenu(
      tester,
      TargetPlatform.linux,
      playlists: const {21: name},
      onPlaylistSelected: picked.add,
    );
    expect(tester.getSize(popup).width, lessThanOrEqualTo(224));
    expect(tester.widget<Text>(find.text(name)).maxLines, 2);
    await tester.tap(find.text(name));
    await tester.pumpAndSettle();
    expect(picked, [21]);
    expect(tester.takeException(), isNull);
  });
}
