import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/download_batch.dart';
import 'package:shiki/mobile_motion.dart';
import 'package:shiki/platform_capabilities.dart';

void main() {
  test('video clips are enabled only on desktop platforms', () {
    for (final platform in TargetPlatform.values) {
      expect(
        videoClipsSupportedOn(platform),
        [
          TargetPlatform.windows,
          TargetPlatform.linux,
          TargetPlatform.macOS,
        ].contains(platform),
      );
    }
  });

  test('audio-only downloads are complete without missing-video retries', () {
    final mobile = TrackDownloadResult(
      id: 1,
      title: 'Track',
      audioReady: true,
      videoReady: false,
      videoRequired: false,
    );
    final desktop = TrackDownloadResult(
      id: 1,
      title: 'Track',
      audioReady: true,
      videoReady: false,
    );
    expect(mobile.complete, isTrue);
    expect(mobile.needsRetry, isFalse);
    expect(desktop.complete, isFalse);
    expect(desktop.needsRetry, isTrue);
  });

  testWidgets(
    'section fade runs only on navigation and mounts one scroll view',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      Widget page(int section, String text) => MaterialApp(
        home: Scaffold(
          body: MobileSectionTransition(
            section: section,
            child: ListView(controller: scroll, children: [Text(text)]),
          ),
        ),
      );
      await tester.pumpWidget(page(0, 'First'));
      await tester.pumpAndSettle();
      Finder fade() => find.descendant(
        of: find.byType(MobileSectionTransition),
        matching: find.byType(FadeTransition),
      );
      expect(tester.widget<FadeTransition>(fade()).opacity.value, 1);
      await tester.pumpWidget(page(0, 'Playback changed'));
      expect(tester.widget<FadeTransition>(fade()).opacity.value, 1);
      await tester.pumpWidget(page(1, 'Next section'));
      expect(scroll.positions.length, 1);
      expect(tester.widget<FadeTransition>(fade()).opacity.value, 0);
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        tester.widget<FadeTransition>(fade()).opacity.value,
        inExclusiveRange(0, 1),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<FadeTransition>(fade()).opacity.value, 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('section transition respects reduced motion', (tester) async {
    Widget page(int section) => MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: MobileSectionTransition(
        section: section,
        child: const Text('Content'),
      ),
    );
    await tester.pumpWidget(page(0));
    await tester.pumpAndSettle();
    await tester.pumpWidget(page(1));
    final fade = find.descendant(
      of: find.byType(MobileSectionTransition),
      matching: find.byType(FadeTransition),
    );
    expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
