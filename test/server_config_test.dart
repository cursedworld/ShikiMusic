import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/server_config.dart';

void main() {
  group('normalizeServerBaseUrl', () {
    test('removes whitespace, trailing slash, query, and fragment', () {
      expect(
        normalizeServerBaseUrl(' https://music.example.test/root///?x=1#part '),
        'https://music.example.test/root',
      );
    });

    test('uses current local default for empty and invalid values', () {
      expect(normalizeServerBaseUrl(''), defaultServerBaseUrl);
      expect(normalizeServerBaseUrl('not a server'), defaultServerBaseUrl);
      expect(
        normalizeServerBaseUrl('ftp://example.test'),
        defaultServerBaseUrl,
      );
      expect(
        normalizeServerBaseUrl('http:///missing-host'),
        defaultServerBaseUrl,
      );
    });
  });

  group('buildServerUriForBase', () {
    test('joins leading-slash path without a double slash', () {
      expect(
        buildServerUriForBase(
          'https://music.example.test/root/',
          '/api/tracks/',
        ).toString(),
        'https://music.example.test/root/api/tracks/',
      );
    });

    test('encodes query values and omits null or empty values', () {
      final uri = buildServerUriForBase(
        'https://music.example.test/',
        '/api/smart_search/',
        queryParameters: <String, Object?>{
          'q': 'AC/DC & friends',
          'page': 2,
          'tag': <Object?>['рок', 'live & loud', null],
          'ignored': null,
          'empty': <Object?>[],
        },
      );

      expect(uri.path, '/api/smart_search/');
      expect(uri.queryParameters['q'], 'AC/DC & friends');
      expect(uri.queryParameters['page'], '2');
      expect(uri.queryParametersAll['tag'], <String>['рок', 'live & loud']);
      expect(uri.queryParameters.containsKey('ignored'), isFalse);
      expect(uri.queryParameters.containsKey('empty'), isFalse);
      expect(uri.toString(), contains('q=AC%2FDC+%26+friends'));
    });

    test('falls back safely when explicit base is invalid', () {
      expect(
        buildServerUriForBase('invalid', 'api/tracks').toString(),
        '$defaultServerBaseUrl/api/tracks',
      );
    });
  });

  group('resolveMediaUrlForBase', () {
    const base = 'https://music.example.test/root/';

    test('keeps absolute media URL byte-for-byte unchanged', () {
      const media = 'https://cdn.example.test/a%20b.mp4?token=x%2Fy';
      expect(resolveMediaUrlForBase(base, media), media);
    });

    test('resolves root-relative media URL against server origin', () {
      expect(
        resolveMediaUrlForBase(base, '/media/video.mp4?quality=high'),
        'https://music.example.test/media/video.mp4?quality=high',
      );
    });

    test('resolves relative media URL below configured base path', () {
      expect(
        resolveMediaUrlForBase(base, 'media/audio.mp3'),
        'https://music.example.test/root/media/audio.mp3',
      );
    });

    test('keeps empty media URL empty', () {
      expect(resolveMediaUrlForBase('invalid', '   '), '');
    });
  });

  test('configured wrappers use normalized environment-backed base', () {
    expect(configuredServerBaseUri.toString(), configuredServerBaseUrl);
    expect(
      configuredServerUri(
        '/api/smart_search/',
        queryParameters: <String, Object?>{'q': 'a&b'},
      ),
      buildServerUriForBase(
        configuredServerBaseUrl,
        '/api/smart_search/',
        queryParameters: <String, Object?>{'q': 'a&b'},
      ),
    );
    expect(
      resolveConfiguredMediaUrl('/media/clip.mp4'),
      resolveMediaUrlForBase(configuredServerBaseUrl, '/media/clip.mp4'),
    );
  });
}
