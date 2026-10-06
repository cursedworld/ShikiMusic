import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/widgets/track_metadata_dialog.dart';

void main() {
  testWidgets('album link confirmation accepts only supported playlist links', (
    tester,
  ) async {
    String? confirmed;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                confirmed = await showDialog<String>(
                  context: context,
                  builder: (_) => const AlbumImportDialog(),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('album_import_confirm')),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.byKey(const ValueKey('album_import_url')),
      'https://youtube.com/watch?v=song',
    );
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('album_import_confirm')),
          )
          .onPressed,
      isNull,
    );
    const playlist = 'https://music.youtube.com/playlist?list=album_fixture';
    await tester.enterText(
      find.byKey(const ValueKey('album_import_url')),
      playlist,
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('album_import_confirm')));
    await tester.pumpAndSettle();
    expect(confirmed, playlist);
    expect(tester.takeException(), isNull);
  });

  testWidgets('album failures let user select uncertain credits individually', (
    tester,
  ) async {
    final uncertain = {
      'title': 'Reuploaded song',
      'error': 'Unknown artist',
      'confirmation_required': true,
      'metadata': {
        'title': 'Song',
        'artist': '',
        'source_url': 'https://youtube.com/watch?v=fixture',
      },
    };
    Map? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selected = await showDialog<Map>(
                  context: context,
                  builder: (_) => AlbumImportErrorsDialog(
                    errors: [
                      uncertain,
                      {'title': 'Other song', 'error': 'Download failed'},
                    ],
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Other song: Download failed'), findsOneWidget);
    final confirmation = find.byWidgetPredicate(
      (widget) =>
          widget is TextButton &&
          widget.onPressed != null &&
          widget.child is Text &&
          (widget.child as Text).data != 'Закрыть' &&
          (widget.child as Text).data != 'Close',
    );
    // Open remains under the modal; the first action inside the dialog selects
    // only the uncertain track, without silently writing guessed metadata.
    final dialogButton = find
        .descendant(
          of: find.byType(AlbumImportErrorsDialog),
          matching: confirmation,
        )
        .first;
    await tester.tap(dialogButton);
    await tester.pumpAndSettle();
    expect(selected, same(uncertain));
  });

  testWidgets(
    'confirmation needs artist and returns edited credits, not uploader',
    (tester) async {
      Map<String, dynamic>? confirmed;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  confirmed = await showDialog<Map<String, dynamic>>(
                    context: context,
                    builder: (_) => const TrackMetadataDialog(
                      metadata: {
                        'title': 'Song',
                        'artist': '',
                        'album': 'Album',
                        'source_url': 'https://youtube.com/watch?v=fixture',
                      },
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      var confirm = tester.widget<TextButton>(
        find.byKey(const ValueKey('metadata_confirm')),
      );
      expect(confirm.onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('metadata_artist')),
        'Real artist',
      );
      await tester.enterText(
        find.byKey(const ValueKey('metadata_title')),
        'Correct title',
      );
      await tester.pump();
      confirm = tester.widget<TextButton>(
        find.byKey(const ValueKey('metadata_confirm')),
      );
      expect(confirm.onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('metadata_confirm')));
      await tester.pumpAndSettle();
      expect(confirmed, {
        'title': 'Correct title',
        'artist': 'Real artist',
        'album': 'Album',
        'source_url': 'https://youtube.com/watch?v=fixture',
      });
    },
  );
}
