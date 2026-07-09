import 'package:flutter_test/flutter_test.dart';

import '../tool/perf/evaluator.dart';

void main() {
  test('passes when candidate stays within regression budgets', () {
    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: _run(rssMiB: 104, cpuPercent: 10.8, firstVideoFrameMs: 700),
      platform: 'windows',
    );

    expect(report.exitCode, 0);
    expect(report.verdict, 'pass');
    expect(report.issues, isEmpty);
  });

  test('returns regression when candidate exceeds a metric budget', () {
    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: _run(rssMiB: 111, cpuPercent: 10.5, firstVideoFrameMs: 700),
      platform: 'windows',
    );

    expect(report.exitCode, 1);
    expect(report.verdict, 'regression');
    expect(report.issues.map((issue) => issue.kind), contains('regression'));
  });

  test('returns infrastructure when mandatory metrics are missing', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    final scenarios = candidate['scenarios']! as List<Object?>;
    final scenario = scenarios.single! as Map<String, Object?>;
    final metrics = scenario['metrics']! as Map<String, Object?>;
    metrics.remove('rssMiB');

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 2);
    expect(report.verdict, 'infrastructure');
  });

  test('returns infrastructure when repetitions are insufficient', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    final measurement = candidate['measurement']! as Map<String, Object?>;
    measurement['measuredRuns'] = 1;

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 2);
    expect(
      report.issues.map((issue) => issue.kind),
      contains('insufficient-repetitions'),
    );
  });
}

Map<String, Object?> _run({
  required double rssMiB,
  required double cpuPercent,
  required double firstVideoFrameMs,
}) => {
  'schemaVersion': 1,
  'metadata': {
    'commit': 'test',
    'platform': 'windows',
    'buildMode': 'profile',
    'flutterVersion': 'test',
    'videoBackend': 'test',
    'decoder': 'test',
    'decoderEvidence': 'test fixture',
  },
  'measurement': {'warmupRuns': 1, 'measuredRuns': 3, 'sampleIntervalMs': 1000},
  'scenarios': [
    {
      'id': 'minimize-video-five-minutes-restore',
      'metrics': {
        'rssMiB': {
          'required': true,
          'median': rssMiB,
          'p95': rssMiB,
          'compareStat': 'median',
          'maxRegressionPercent': 5,
        },
        'cpuPercent': {
          'required': true,
          'median': cpuPercent,
          'p95': cpuPercent,
          'compareStat': 'median',
          'maxRegressionPercent': 10,
        },
        'firstVideoFrameMs': {
          'required': true,
          'median': firstVideoFrameMs,
          'p95': firstVideoFrameMs,
          'compareStat': 'p95',
          'target': 500,
          'failureAbove': 1000,
        },
        'decoderEvidence': {
          'requiredEvidence': true,
          'evidence': 'test decoder evidence',
        },
      },
    },
  ],
};
