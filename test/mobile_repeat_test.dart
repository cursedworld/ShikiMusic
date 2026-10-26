import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/globals.dart';
import 'package:shiki/screens/home_screen.dart';
import 'package:shiki/widgets/mobile_playback_controls.dart';

// Exercise the actual mini-player and repeat handler without native playback.
class _MiniPlayerState extends MainAppScreenState {
  VoidCallback? rebuild;
  @override
  void setState(VoidCallback fn) {
    fn();
    rebuild?.call();
  }
}

void main() {
  setUpAll(() async {
    const iconsPath = String.fromEnvironment('SHIKI_TEST_ICONS');
    if (iconsPath.isNotEmpty) {
      final icons = FontLoader('MaterialIcons');
      icons.addFont(
        Future.value(ByteData.sublistView(await File(iconsPath).readAsBytes())),
      );
      await icons.load();
    }
    final font = File('C:/Windows/Fonts/segoeui.ttf');
    if (!await font.exists()) return;
    final loader = FontLoader('MobileRepeatTest');
    loader.addFont(
      Future.value(ByteData.sublistView(await font.readAsBytes())),
    );
    await loader.load();
  });

  for (final width in [320.0, 375.0, 460.0, 768.0]) {
    testWidgets(
      'repeat fits mini-player width $width and cycles actual playback modes',
      (tester) async {
        final oldMode = loopModeNotifier.value;
        final oldLanguage = languageNotifier.value;
        languageNotifier.value = 'ru';
        addTearDown(() {
          loopModeNotifier.value = oldMode;
          languageNotifier.value = oldLanguage;
        });
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 812);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final state = _MiniPlayerState()
          ..playingQueue = [
            {
              'id': 1,
              'title': 'Длинное название музыкального трека',
              'artists': [
                {'id': 7, 'name': 'Исполнитель'},
              ],
              'album': {'cover': ''},
            },
          ];
        addTearDown(() {
          state.searchInput.dispose();
          state.searchFocusNode.dispose();
          state.currentPositionNotifier.dispose();
          state.fullDurationNotifier.dispose();
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark().copyWith(
              textTheme: ThemeData.dark().textTheme.apply(
                fontFamily: 'MobileRepeatTest',
              ),
            ),
            home: StatefulBuilder(
              builder: (context, setState) {
                state.rebuild = () => setState(() {});
                return Scaffold(
                  bottomNavigationBar: RepaintBoundary(
                    key: const ValueKey('repeat_capture'),
                    child: state.buildMobileMiniPlayer(),
                  ),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        final repeat = find.byKey(const ValueKey('mobile_repeat'));
        expect(repeat, findsOneWidget);
        expect(find.byType(IconButton), findsNWidgets(5));
        for (final button in find.byType(IconButton).evaluate()) {
          final size = tester.getSize(find.byWidget(button.widget));
          expect(size.width, greaterThanOrEqualTo(44));
          expect(size.height, greaterThanOrEqualTo(44));
        }
        final title = tester.getRect(
          find.text('Длинное название музыкального трека'),
        );
        if (width < 460) {
          expect(tester.getTopLeft(repeat).dy, greaterThan(title.bottom));
        }
        for (final mode in [LoopMode.list, LoopMode.one, LoopMode.off]) {
          await tester.tap(repeat);
          await tester.pumpAndSettle();
          expect(state.loopMode, mode);
          expect(loopModeNotifier.value, mode);
          expect(
            tester.widget<IconButton>(repeat).isSelected,
            mode != LoopMode.off,
          );
          expect(
            find.byIcon(mode == LoopMode.one ? Icons.repeat_one : Icons.repeat),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
        if (width == 375 &&
            const bool.fromEnvironment('SHIKI_MOBILE_CAPTURE')) {
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('repeat_capture')),
            );
            final image = await boundary.toImage();
            try {
              final png = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await Directory('.omx/mobile-qa').create(recursive: true);
              await File(
                '.omx/mobile-qa/repeat-375.png',
              ).writeAsBytes(png!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
        state.rebuild = null;
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('all five playback callbacks remain independent', (tester) async {
    final calls = List<int>.filled(5, 0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MobilePlaybackControls(
            isFavorite: false,
            isPlaying: false,
            loopMode: LoopMode.off,
            onFavorite: () => calls[0]++,
            onPrevious: () => calls[1]++,
            onPlayPause: () => calls[2]++,
            onNext: () => calls[3]++,
            onRepeat: () => calls[4]++,
          ),
        ),
      ),
    );
    for (final icon in [
      Icons.favorite_border,
      Icons.skip_previous_rounded,
      Icons.play_circle_fill,
      Icons.skip_next_rounded,
      Icons.repeat,
    ]) {
      await tester.tap(find.byIcon(icon));
    }
    await tester.pumpAndSettle();
    expect(calls, [1, 1, 1, 1, 1]);
  });
}
