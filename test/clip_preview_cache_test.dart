import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiki/clip_preview_cache.dart';
import 'package:shiki/media_file_downloader.dart';

final _version = 'a' * 64;
const _base = 'https://player.example.test';
const _original = 'original version of the clip';
final _digest = sha256.convert(utf8.encode(_original)).toString();
final _asset = '/media/clip_previews/v1_$_version.mp4';

ClipPreviewReference? _reference(Object? value, {int track = 23}) =>
    ClipPreviewReference.fromAdvertisement(
      value,
      serverTrackId: track,
      originalUrl: '$_base/media/clips/test.mp4',
      serverBaseUrl: _base,
    );

void main() {
  final path = '/api/tracks/23/clip-preview/$_version/';

  test(
    'the full clip is requested only when expanded or preview is unavailable',
    () {
      expect(
        planClipPlayback(
          expanded: false,
          originalReady: false,
          previewReady: false,
          canFetchPreview: true,
          canFetchOriginal: true,
        ),
        (usePreview: false, fetchPreview: true, fetchOriginal: false),
      );
      expect(
        planClipPlayback(
          expanded: true,
          originalReady: false,
          previewReady: true,
          canFetchPreview: true,
          canFetchOriginal: true,
        ),
        (usePreview: true, fetchPreview: false, fetchOriginal: true),
      );
      expect(
        planClipPlayback(
          expanded: true,
          originalReady: true,
          previewReady: true,
          canFetchPreview: true,
          canFetchOriginal: true,
        ),
        (usePreview: false, fetchPreview: false, fetchOriginal: false),
      );
      expect(
        planClipPlayback(
          expanded: false,
          originalReady: true,
          previewReady: true,
          canFetchPreview: true,
          canFetchOriginal: true,
        ),
        (usePreview: true, fetchPreview: false, fetchOriginal: false),
      );
      expect(
        planClipPlayback(
          expanded: false,
          originalReady: false,
          previewReady: false,
          canFetchPreview: false,
          canFetchOriginal: true,
        ),
        (usePreview: false, fetchPreview: false, fetchOriginal: true),
      );
      expect(
        planClipPlayback(
          expanded: true,
          originalReady: false,
          previewReady: true,
          canFetchPreview: false,
          canFetchOriginal: false,
        ),
        (usePreview: true, fetchPreview: false, fetchOriginal: false),
      );
    },
  );

  test(
    'only uses the configured server and the matching track and version',
    () {
      expect(_reference(path)?.endpoint.toString(), '$_base$path');
      expect(_reference(path, track: 24), isNull);
      expect(_reference('https://other.example.test$path'), isNull);
      expect(_reference('$path?version=other'), isNull);
      expect(_reference(null), isNull);
    },
  );

  test(
    'downloads a preview once and pairs it only with its original',
    () async {
      final directory = await Directory.systemTemp.createTemp('shiki-preview-');
      addTearDown(() => directory.delete(recursive: true));
      final calls = <String>[];
      final client = MockClient((request) async {
        calls.add(request.url.path);
        return request.url.path == path
            ? http.Response(
                jsonEncode({'url': _asset, 'source_sha256': _digest}),
                200,
              )
            : http.Response('small rendition', 200);
      });
      final downloader = MediaFileDownloader(client: client);
      addTearDown(downloader.close);
      final cache = ClipPreviewCache(directory);
      final reference = _reference(path)!;
      final cancel = Completer<void>();
      final asset = await cache.fetch(
        reference,
        client,
        downloader,
        abort: cancel.future,
      );

      expect(await asset!.file.readAsString(), 'small rendition');
      final offline = await ClipPreviewCache(directory).read(reference);
      expect(offline?.file.path, asset.file.path);
      expect(
        await cache.read(_reference(path.replaceFirst(_version, 'b' * 64))!),
        isNull,
      );
      final original = await File(
        '${directory.path}/original.mp4',
      ).writeAsString(_original);
      expect(await cache.matchesOriginal(offline!, original), isTrue);
      await original.writeAsString('a different edit');
      expect(await cache.matchesOriginal(offline, original), isFalse);
      final reused = await cache.fetch(
        reference,
        client,
        downloader,
        abort: cancel.future,
      );
      expect(reused?.file.path, asset.file.path);
      expect(calls, [path, _asset]);
    },
  );

  test('invalid manifest and 204 never download unrelated media', () async {
    final directory = await Directory.systemTemp.createTemp('shiki-preview-');
    addTearDown(() => directory.delete(recursive: true));
    for (final response in [
      http.Response('', 204),
      http.Response(
        jsonEncode({
          'url': 'https://other.example.test$_asset',
          'source_sha256': _digest,
        }),
        200,
      ),
      http.Response(jsonEncode({'url': _asset, 'source_sha256': 'bad'}), 200),
    ]) {
      final client = MockClient((request) async {
        expect(request.url.path, path);
        return response;
      });
      final downloader = MediaFileDownloader(client: client);
      addTearDown(downloader.close);
      expect(
        await ClipPreviewCache(directory).fetch(
          _reference(path)!,
          client,
          downloader,
          abort: Completer<void>().future,
        ),
        isNull,
      );
    }
  });
}
