import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiki/localization.dart';
import 'package:shiki/widgets/server_address_setting.dart';

void main() {
  testWidgets(
    'server address can be tested and saved without redirecting current player',
    (tester) async {
      String? saved;
      final client = MockClient((request) async {
        expect(
          request.url.toString(),
          'http://localhost:8000/api/tracks/catalog-revision/',
        );
        return http.Response('{"revision":"fixture"}', 200);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ServerAddressSetting(
              value: 'http://localhost:8000',
              client: client,
              onSave: (value) async {
                saved = value;
                return true;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text(tr('server_test')));
      await tester.pumpAndSettle();
      expect(find.text(tr('server_connected')), findsOneWidget);
      await tester.tap(find.text(tr('server_save')));
      await tester.pumpAndSettle();
      expect(saved, 'http://localhost:8000');
      expect(find.text(tr('server_saved')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('server_address')),
        'file:///private',
      );
      await tester.tap(find.text(tr('server_save')));
      await tester.pumpAndSettle();
      expect(find.text(tr('server_invalid')), findsOneWidget);
      client.close();
    },
  );
}
