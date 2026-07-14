import 'dart:io';

Future<void> main(List<String> arguments) async {
  final directoryValue = _argument(arguments, '--directory');
  final portValue = _argument(arguments, '--port');
  if (directoryValue == null || portValue == null) {
    stderr.writeln(
      'Usage: dart run tool/perf/fixture_server.dart '
      '--directory <path> --port <port>',
    );
    exitCode = 64;
    return;
  }

  final port = int.tryParse(portValue);
  if (port == null || port < 1024 || port > 65535) {
    stderr.writeln('Invalid port: $portValue');
    exitCode = 64;
    return;
  }

  final root = Directory(directoryValue).absolute;
  if (!await root.exists()) {
    stderr.writeln('Fixture directory does not exist: ${root.path}');
    exitCode = 66;
    return;
  }

  const fixtures = <String, String>{
    '/download_fixture.mp3': 'audio/mpeg',
    '/download_fixture.mp4': 'video/mp4',
    '/download_fixture_cover.jpg': 'image/jpeg',
  };
  final files = <String, File>{};
  for (final path in fixtures.keys) {
    final file = File(
      '${root.path}${Platform.pathSeparator}${path.substring(1)}',
    );
    if (!await file.exists() || await file.length() == 0) {
      stderr.writeln('Fixture is missing or empty: ${file.path}');
      exitCode = 66;
      return;
    }
    files[path] = file;
  }

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('READY http://127.0.0.1:$port');
  await for (final request in server) {
    final file = files[request.uri.path];
    if (file == null || (request.method != 'GET' && request.method != 'HEAD')) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      continue;
    }

    request.response.headers
      ..contentType = ContentType.parse(fixtures[request.uri.path]!)
      ..contentLength = await file.length()
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    if (request.method == 'GET') {
      await for (final chunk in file.openRead()) {
        request.response.add(chunk);
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }
    await request.response.close();
  }
}

String? _argument(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index < 0 || index + 1 >= arguments.length) {
    return null;
  }
  return arguments[index + 1];
}
