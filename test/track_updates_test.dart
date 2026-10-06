import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiki/track_updates.dart';

String digest(List<int> bytes) => sha256.convert(bytes).toString();

class FixtureApi {
  List<int> audio = utf8.encode('original audio');
  String lyrics = '[00:01.00]Original';
  String artist = 'Artist';
  List<int>? video;
  bool corruptVideo = false;
  int videoRequests = 0;
  bool offline = false;
  bool failAudio = false;
  bool corruptAudio = false;
  bool changeOnConfirm = false;
  int audioRequests = 0;
  int detailRequests = 0;
  final requests = <http.Request>[];

  Map<String, dynamic> get track => {
    'id': 1,
    'title': 'Track',
    'audio_file': '/media/song.mp3',
    'video_file': video == null ? null : '/media/video.mp4',
    'lyrics': lyrics,
    'album': {
      'id': 1,
      'title': 'Album',
      'artist': {'id': 1, 'name': artist},
    },
    'artists': [],
    'duration': 30,
    'content_versions': {
      'audio': digest(audio),
      'lyrics': digest(utf8.encode(lyrics)),
      'metadata': digest(utf8.encode(artist)),
      'video': video == null ? null : digest(video!),
    },
  };

  late final client = MockClient((request) async {
    requests.add(request);
    if (offline) return http.Response('offline', 503);
    if (request.url.path.endsWith('/catalog-revision/')) {
      final tag = '"${digest(utf8.encode('$artist:$lyrics'))}"';
      return http.Response(
        '{}',
        request.headers['If-None-Match'] == tag ? 304 : 200,
        headers: {'etag': tag},
      );
    }
    if (request.url.path.endsWith('/revisions/')) {
      final body = jsonEncode([
        {
          'id': 1,
          'title': 'Track',
          'content_versions': track['content_versions'],
        },
      ]);
      final tag = '"${digest(utf8.encode(body))}"';
      return http.Response(
        body,
        request.headers['If-None-Match'] == tag ? 304 : 200,
        headers: {'etag': tag},
      );
    }
    if (request.url.path.endsWith('/tracks/1/')) {
      detailRequests++;
      if (changeOnConfirm && detailRequests.isEven) lyrics += ' edited again';
      return http.Response(jsonEncode(track), 200);
    }
    if (request.url.path == '/media/song.mp3') {
      audioRequests++;
      if (failAudio) return http.Response('failed', 500);
      return http.Response.bytes(
        corruptAudio ? utf8.encode('wrong bytes') : audio,
        200,
      );
    }
    if (request.url.path == '/media/video.mp4') {
      videoRequests++;
      return http.Response.bytes(
        corruptVideo ? utf8.encode('bad MP4') : video!,
        200,
      );
    }
    return http.Response('missing', 404);
  });
}

void main() {
  late Directory directory;
  late FixtureApi api;
  late TrackUpdateMonitor monitor;
  var hashes = 0;
  var catalogChanges = 0;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shiki-updates-test-');
    api = FixtureApi();
    hashes = 0;
    catalogChanges = 0;
    await File('${directory.path}/track_1.mp3').writeAsBytes(api.audio);
    await File('${directory.path}/track_1.lrc').writeAsString(api.lyrics);
    monitor = TrackUpdateMonitor(
      directory: directory,
      tracks: () => [api.track],
      serverBase: 'http://fixture',
      client: api.client,
      onCatalogChanged: () async {
        catalogChanges++;
      },
      hashFile: (path) async {
        hashes++;
        return (await sha256.bind(File(path).openRead()).first).toString();
      },
    );
    await monitor.load();
  });

  tearDown(() async {
    monitor.dispose();
    api.client.close();
    await directory.delete(recursive: true);
  });

  test('unchanged downloaded MP3 hashed once; later polls use ETag', () async {
    await monitor.checkNow();
    await monitor.checkNow();
    await monitor.checkNow();
    expect(hashes, 1);
    expect(api.audioRequests, 0);
    expect(monitor.offers.value, isEmpty);
    expect(api.requests.last.headers['If-None-Match'], isNotNull);
  });

  test(
    'lyrics/timing change offers update without redownloading audio',
    () async {
      await monitor.checkNow();
      api.lyrics = '[00:02.00]Original';
      await monitor.checkNow();
      expect(monitor.offers.value, hasLength(1));
      expect(await monitor.lyricsFile(1).readAsString(), '[00:01.00]Original');
      await monitor.updateTrack(monitor.offers.value.single);
      expect(api.audioRequests, 0);
      expect(await monitor.lyricsFile(1).readAsString(), api.lyrics);
      expect(
        await File('${directory.path}/track_1.lrc').readAsString(),
        '[00:01.00]Original',
      );
      expect(monitor.offers.value, isEmpty);
      await monitor.checkNow();
      expect(monitor.offers.value, isEmpty);
    },
  );

  test(
    'new MP3 is versioned, original handle/file remain valid, index survives restart',
    () async {
      await monitor.checkNow();
      final original = monitor.audioFile(1);
      final openAudio = await original.open();
      api.audio = utf8.encode('replacement MP3');
      await monitor.checkNow();
      expect(await original.readAsBytes(), utf8.encode('original audio'));
      await monitor.updateTrack(monitor.offers.value.single);
      expect(monitor.audioFile(1).path, isNot(original.path));
      expect(await monitor.audioFile(1).readAsBytes(), api.audio);
      expect(await openAudio.read(100), utf8.encode('original audio'));
      await openAudio.close();
      final reloaded = TrackUpdateMonitor(
        directory: directory,
        tracks: () => [],
        client: api.client,
      );
      await reloaded.load();
      expect(reloaded.audioFile(1).path, monitor.audioFile(1).path);
      expect(reloaded.lyricsFile(1).path, monitor.lyricsFile(1).path);
      reloaded.dispose();
    },
  );

  test(
    'failed or corrupt audio never replaces original and retry succeeds',
    () async {
      await monitor.checkNow();
      final original = monitor.audioFile(1).path;
      api.audio = utf8.encode('new audio');
      await monitor.checkNow();
      final offer = monitor.offers.value.single;
      api.failAudio = true;
      await expectLater(
        monitor.updateTrack(offer),
        throwsA(isA<HttpException>()),
      );
      expect(monitor.audioFile(1).path, original);
      api.failAudio = false;
      api.corruptAudio = true;
      await expectLater(
        monitor.updateTrack(offer),
        throwsA(isA<FormatException>()),
      );
      expect(monitor.audioFile(1).path, original);
      expect(monitor.offers.value, hasLength(1));
      api.corruptAudio = false;
      await monitor.updateTrack(offer);
      expect(await monitor.audioFile(1).readAsBytes(), api.audio);
      expect(await File(original).readAsBytes(), utf8.encode('original audio'));
    },
  );

  test(
    'empty server lyrics are acknowledged without restoring obsolete lyrics',
    () async {
      await monitor.checkNow();
      api.lyrics = '';
      await monitor.checkNow();
      await monitor.updateTrack(monitor.offers.value.single);
      expect(monitor.hasManagedLyrics(1), isTrue);
      expect(await monitor.lyricsFile(1).readAsString(), isEmpty);
      await monitor.checkNow();
      expect(monitor.offers.value, isEmpty);
    },
  );

  test('server edit during transfer does not commit a mixed version', () async {
    await monitor.checkNow();
    final original = monitor.audioFile(1).path;
    api.audio = utf8.encode('new audio');
    await monitor.checkNow();
    api.changeOnConfirm = true;
    await expectLater(
      monitor.updateTrack(monitor.offers.value.single),
      throwsA(isA<StateError>()),
    );
    expect(monitor.audioFile(1).path, original);
    expect(await monitor.lyricsFile(1).readAsString(), '[00:01.00]Original');
    api.changeOnConfirm = false;
    await monitor.checkNow();
    await monitor.updateTrack(monitor.offers.value.single);
    expect(await monitor.lyricsFile(1).readAsString(), api.lyrics);
  });

  test(
    'metadata edits refresh automatically, not a file update prompt',
    () async {
      await monitor.checkNow();
      api.artist = 'Renamed artist';
      await monitor.checkNow();
      expect(catalogChanges, 2);
      expect(monitor.offers.value, isEmpty);
      expect(api.audioRequests, 0);
      expect(hashes, 1);
    },
  );

  test('failed catalog refresh retries on next poll', () async {
    monitor.dispose();
    var attempts = 0;
    monitor = TrackUpdateMonitor(
      directory: directory,
      tracks: () => [],
      client: api.client,
      serverBase: 'http://fixture',
      onCatalogChanged: () async {
        if (++attempts == 1) throw const HttpException('temporary failure');
      },
    );
    await monitor.checkNow();
    api.artist = 'New name';
    await monitor.checkNow();
    await monitor.checkNow();
    expect(attempts, 2);
  });

  test('offline server retains original and pending update', () async {
    await monitor.checkNow();
    api.lyrics = 'Changed';
    await monitor.checkNow();
    api.offline = true;
    await monitor.checkNow();
    expect(monitor.offers.value, hasLength(1));
    expect(
      await monitor.audioFile(1).readAsBytes(),
      utf8.encode('original audio'),
    );
  });

  test('legacy already-stale downloads are detected on first scan', () async {
    api.audio = utf8.encode('already changed on server');
    api.lyrics = 'Changed before player starts';
    await monitor.checkNow();
    expect(monitor.offers.value, hasLength(1));
    expect(api.audioRequests, 0);
  });

  test('index rejects path traversal and invalid revision filenames', () async {
    await File('${directory.path}/track_versions.json').writeAsString(
      jsonEncode({
        '1': {
          'versions': api.track['content_versions'],
          'audio': '../private.mp3',
          'lyrics': '../private.lrc',
        },
      }),
    );
    await monitor.load();
    expect(monitor.audioFile(1).path, '${directory.path}/track_1.mp3');
    expect(monitor.lyricsFile(1).path, '${directory.path}/track_1.lrc');
  });

  test(
    'default background hash works without capturing HTTP/service objects',
    () async {
      monitor.dispose();
      monitor = TrackUpdateMonitor(
        directory: directory,
        tracks: () => [api.track],
        serverBase: 'http://fixture',
        client: api.client,
      );
      await monitor.checkNow();
      expect(
        await File('${directory.path}/track_versions.json').exists(),
        isTrue,
      );
      expect(monitor.offers.value, isEmpty);
    },
  );

  test('registerDownload baseline remains readable after restart', () async {
    await monitor.registerDownload(api.track);
    final reloaded = TrackUpdateMonitor(
      directory: directory,
      tracks: () => [api.track],
      client: api.client,
    );
    await reloaded.load();
    expect(reloaded.audioFile(1).path, monitor.audioFile(1).path);
    reloaded.dispose();
  });

  test(
    'changed downloaded video is versioned; old open file remains usable',
    () async {
      api.video = utf8.encode('original video');
      final original = File('${directory.path}/video_1.mp4');
      await original.writeAsBytes(api.video!);
      await monitor.checkNow();
      final handle = await original.open();
      api.video = utf8.encode('replacement video');
      await monitor.checkNow();
      expect(monitor.offers.value, hasLength(1));
      await monitor.updateTrack(monitor.offers.value.single);
      expect(api.audioRequests, 0);
      expect(monitor.videoFile(1).path, isNot(original.path));
      expect(await monitor.videoFile(1).readAsBytes(), api.video);
      expect(await handle.read(100), utf8.encode('original video'));
      await handle.close();
      final reloaded = TrackUpdateMonitor(
        directory: directory,
        tracks: () => [],
        client: api.client,
      );
      await reloaded.load();
      expect(reloaded.videoFile(1).path, monitor.videoFile(1).path);
      reloaded.dispose();
    },
  );

  test(
    'corrupt replacement video preserves playable video and pending offer',
    () async {
      api.video = utf8.encode('original video');
      await File('${directory.path}/video_1.mp4').writeAsBytes(api.video!);
      await monitor.checkNow();
      final originalPath = monitor.videoFile(1).path;
      api.video = utf8.encode('new video');
      await monitor.checkNow();
      api.corruptVideo = true;
      await expectLater(
        monitor.updateTrack(monitor.offers.value.single),
        throwsA(isA<FormatException>()),
      );
      expect(monitor.videoFile(1).path, originalPath);
      expect(
        await monitor.videoFile(1).readAsBytes(),
        utf8.encode('original video'),
      );
      expect(monitor.offers.value, hasLength(1));
      api.corruptVideo = false;
      await monitor.updateTrack(monitor.offers.value.single);
      expect(await monitor.videoFile(1).readAsBytes(), api.video);
    },
  );

  test(
    'video downloaded after MP3 baseline is registered and tracked',
    () async {
      await monitor.checkNow();
      api.video = utf8.encode('new local video');
      await File('${directory.path}/video_1.mp4').writeAsBytes(api.video!);
      await monitor.registerDownload(api.track);
      await monitor.checkNow();
      expect(monitor.offers.value, isEmpty);
      api.video = utf8.encode('edited server video');
      await monitor.checkNow();
      expect(monitor.offers.value, hasLength(1));
    },
  );

  test('player-uploaded lyrics do not offer a redundant update', () async {
    await monitor.checkNow();
    api.lyrics = '[00:02.00]Fetched by player';
    await File('${directory.path}/track_1.lrc').writeAsString(api.lyrics);
    await monitor.acknowledgeLocalLyrics(1, api.lyrics);
    await monitor.checkNow();
    expect(monitor.offers.value, isEmpty);
    expect(api.audioRequests, 0);
  });

  test(
    'streamed track with cached lyrics updates lyrics without downloading MP3',
    () async {
      await File('${directory.path}/track_1.mp3').delete();
      await monitor.checkNow();
      expect(monitor.offers.value, isEmpty);
      expect(hashes, 0);
      api.lyrics = '[00:04.00]Updated streaming lyrics';
      await monitor.checkNow();
      await monitor.updateTrack(monitor.offers.value.single);
      expect(api.audioRequests, 0);
      expect(await monitor.audioFile(1).exists(), isFalse);
      expect(await monitor.lyricsFile(1).readAsString(), api.lyrics);
      final reloaded = TrackUpdateMonitor(
        directory: directory,
        tracks: () => [api.track],
        client: api.client,
        serverBase: 'http://fixture',
      );
      await reloaded.load();
      await reloaded.checkNow();
      expect(reloaded.offers.value, isEmpty);
      expect(reloaded.lyricsFile(1).path, monitor.lyricsFile(1).path);
      reloaded.dispose();
    },
  );

  test(
    'manual MP3 download promotes an existing lyrics-only baseline',
    () async {
      await File('${directory.path}/track_1.mp3').delete();
      await monitor.checkNow();
      await File('${directory.path}/track_1.mp3').writeAsBytes(api.audio);
      await monitor.registerDownload(api.track);
      api.audio = utf8.encode('new server MP3');
      await monitor.checkNow();
      expect(monitor.offers.value, hasLength(1));
      await monitor.updateTrack(monitor.offers.value.single);
      expect(await monitor.audioFile(1).readAsBytes(), api.audio);
    },
  );
}
