import 'dart:convert';
import 'dart:io' as io;

import 'evaluator.dart';

void main(List<String> args) {
  final parsed = _parseArgs(args);
  final baselinePath = parsed['baseline'];
  final candidatePath = parsed['candidate'];
  final platform = parsed['platform'];

  if (baselinePath == null || candidatePath == null) {
    io.stderr.writeln(
      'Usage: dart run tool/perf/evaluate.dart --baseline <file> --candidate <file> [--platform windows|linux|android]',
    );
    io.exit(2);
  }

  try {
    final baseline = _readJsonObject(baselinePath);
    final candidate = _readJsonObject(candidatePath);
    final report = evaluatePerformance(
      baseline: baseline,
      candidate: candidate,
      platform: platform,
    );
    const encoder = JsonEncoder.withIndent('  ');
    io.stdout.writeln(encoder.convert(report.toJson()));
    io.exit(report.exitCode);
  } on FormatException catch (error) {
    io.stderr.writeln('Invalid benchmark JSON: ${error.message}');
    io.exit(2);
  } on io.FileSystemException catch (error) {
    io.stderr.writeln('Cannot read benchmark JSON: ${error.message}');
    io.exit(2);
  }
}

Map<String, Object?> _readJsonObject(String path) {
  final decoded = jsonDecode(io.File(path).readAsStringSync());
  if (decoded is Map<String, Object?>) {
    return decoded;
  }
  if (decoded is Map) {
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }
  throw const FormatException('Root JSON value must be an object.');
}

Map<String, String> _parseArgs(List<String> args) {
  final parsed = <String, String>{};
  for (var index = 0; index < args.length; index += 1) {
    final arg = args[index];
    if (!arg.startsWith('--')) {
      continue;
    }
    final key = arg.substring(2);
    if (index + 1 >= args.length || args[index + 1].startsWith('--')) {
      continue;
    }
    parsed[key] = args[index + 1];
    index += 1;
  }
  return parsed;
}
