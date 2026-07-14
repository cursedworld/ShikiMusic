import 'package:flutter_test/flutter_test.dart';

import '../tool/perf/evaluator.dart';

void main() {
  test('passes when candidate stays within regression budgets', () {
    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: _run(rssMiB: 100, cpuPercent: 10.8, firstVideoFrameMs: 500),
      platform: 'windows',
    );

    expect(report.exitCode, 0, reason: report.issues.toString());
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

  test('baseline thresholds cannot be relaxed by candidate', () {
    final candidate = _run(
      rssMiB: 111,
      cpuPercent: 10.5,
      firstVideoFrameMs: 700,
    );
    for (final rawScenario in candidate['scenarios']! as List<Object?>) {
      final scenario = rawScenario! as Map<String, Object?>;
      final metrics = scenario['metrics']! as Map<String, Object?>;
      final rss = metrics['rssMiB']! as Map<String, Object?>;
      rss['maxRegressionPercent'] = 100;
    }

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 1);
    expect(report.issues.map((issue) => issue.kind), contains('regression'));
  });

  test('returns infrastructure when mandatory metrics are missing', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    final scenarios = candidate['scenarios']! as List<Object?>;
    final scenario = scenarios.first! as Map<String, Object?>;
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

  test('returns infrastructure when a whole scenario is missing', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    final scenarios = candidate['scenarios']! as List<Object?>;
    scenarios.removeLast();

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 2);
    expect(
      report.issues.map((issue) => issue.kind),
      contains('missing-scenario'),
    );
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

  test('returns infrastructure when fixtures differ', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    final metadata = candidate['metadata']! as Map<String, Object?>;
    final hashes = metadata['fixtureHashes']! as Map<String, Object?>;
    hashes['video_62060.mp4'] = 'different';

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 2);
    expect(
      report.issues.map((issue) => issue.kind),
      contains('incompatible-runs'),
    );
  });

  test('requires the complete fixed fixture manifest', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    final metadata = candidate['metadata']! as Map<String, Object?>;
    final hashes = metadata['fixtureHashes']! as Map<String, Object?>;
    hashes.remove('download_fixture.mp4');

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 2);
    expect(
      report.issues.map((issue) => issue.kind),
      contains('missing-fixture-hashes'),
    );
  });

  test('requires all strict provenance metadata', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    final metadata = candidate['metadata']! as Map<String, Object?>;
    metadata.remove('appBundleSha256');

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 2);
    expect(
      report.issues.map((issue) => issue.path),
      contains('candidate.metadata.appBundleSha256'),
    );
  });

  test(
    'requires equal collector contracts but allows candidate code hashes',
    () {
      final candidate = _run(
        rssMiB: 100,
        cpuPercent: 10,
        firstVideoFrameMs: 480,
      );
      final metadata = candidate['metadata']! as Map<String, Object?>;
      metadata['sourceTreeSha256'] = 'candidate-source';
      metadata['appExecutableSha256'] = 'candidate-executable';
      metadata['appBundleSha256'] = 'candidate-bundle';

      final compatible = evaluatePerformance(
        baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
        candidate: candidate,
        platform: 'windows',
      );
      expect(compatible.exitCode, 0);

      metadata['collectorSha256'] = 'different-collector';
      final incompatible = evaluatePerformance(
        baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
        candidate: candidate,
        platform: 'windows',
      );
      expect(incompatible.exitCode, 2);
      expect(
        incompatible.issues.map((issue) => issue.kind),
        contains('incompatible-runs'),
      );
    },
  );

  test('requires exact frame and process-isolation contracts', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    final measurement = candidate['measurement']! as Map<String, Object?>;
    measurement['frameBudgetMicros'] = 8333;
    measurement['runKind'] = 'smoke';

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 2);
    expect(
      report.issues.map((issue) => issue.kind),
      containsAll(['invalid-frame-budget', 'invalid-measurement-contract']),
    );
  });

  test('rejects claimed statistics that do not match samples', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    final metric = _metric(candidate, 'cold-start-server-offline', 'rssMiB');
    metric['samples'] = [1, 2, 100];
    metric['median'] = 2;
    metric['p95'] = 2;

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 2);
    expect(report.issues.map((issue) => issue.kind), contains('stat-mismatch'));
  });

  test('enforces exact and equal scenario durations', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    _scenario(candidate, 'large-mp3-mp4-download')['durationSeconds'] = 120;

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 2);
    expect(
      report.issues.map((issue) => issue.kind),
      containsAll(['invalid-duration', 'incompatible-runs']),
    );
  });

  test('enforces exact scenario action schedule', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    _scenario(candidate, 'rapid-track-switch-20')['actionCadenceMs'] = 500;

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 2);
    expect(
      report.issues.map((issue) => issue.kind),
      contains('invalid-action-schedule'),
    );
  });

  test('requires runtime evidence for scenario action schedule', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    final runs =
        _scenario(candidate, 'rapid-track-switch-20')['runs']! as List<Object?>;
    final firstRun = runs.first! as Map<String, Object?>;
    final frameResult = firstRun['frameResult']! as Map<String, Object?>;
    final evidence = frameResult['scenarioEvidence']! as Map<String, Object?>;
    evidence['actionCadenceMs'] = 500;

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 2);
    expect(
      report.issues.map((issue) => issue.kind),
      contains('invalid-raw-scenario-evidence'),
    );
  });

  test('requires the isolated server URL in runtime evidence', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    final evidence =
        _scenario(candidate, 'audio-only-ten-minutes')['scenarioEvidence']!
            as Map<String, Object?>;
    evidence['serverBaseUrl'] = 'http://192.168.31.13:8000';

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 2);
    expect(
      report.issues.map((issue) => issue.kind),
      contains('invalid-scenario-evidence'),
    );
  });

  test(
    'requires video position advancement in every raw visible-video run',
    () {
      final candidate = _run(
        rssMiB: 100,
        cpuPercent: 10,
        firstVideoFrameMs: 480,
      );
      final runs =
          _scenario(candidate, 'local-video-60fps-ten-minutes')['runs']!
              as List<Object?>;
      final firstRun = runs.first! as Map<String, Object?>;
      final frameResult = firstRun['frameResult']! as Map<String, Object?>;
      final evidence = frameResult['scenarioEvidence']! as Map<String, Object?>;
      evidence['videoProgressEvents'] = 0;
      evidence['videoPositionAdvanceMs'] = 0.0;

      final report = evaluatePerformance(
        baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
        candidate: candidate,
        platform: 'windows',
      );

      expect(report.exitCode, 2);
      expect(
        report.issues.map((issue) => issue.kind),
        contains('invalid-video-progress-evidence'),
      );
    },
  );

  test('rejects sparse raw resource sampling', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    final runs =
        _scenario(candidate, 'audio-only-ten-minutes')['runs']!
            as List<Object?>;
    final firstRun = runs.first! as Map<String, Object?>;
    final samples = firstRun['resourceSamples']! as List<Object?>;
    firstRun['resourceSamples'] = <Object?>[samples.first, samples.last];

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 2);
    expect(
      report.issues.map((issue) => issue.kind),
      contains('sparse-resource-samples'),
    );
  });

  test('rejects action timestamps that violate cadence', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    final runs =
        _scenario(candidate, 'rapid-track-switch-20')['runs']! as List<Object?>;
    final firstRun = runs.first! as Map<String, Object?>;
    final frameResult = firstRun['frameResult']! as Map<String, Object?>;
    final evidence = frameResult['scenarioEvidence']! as Map<String, Object?>;
    final timestamps = evidence['actionElapsedMs']! as List<double>;
    timestamps[1] = timestamps[0] + 10;

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 2);
    expect(
      report.issues.map((issue) => issue.kind),
      contains('invalid-action-timestamps'),
    );
  });

  test('rejects action cadence more than 250 ms late', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    final runs =
        _scenario(candidate, 'rapid-track-switch-20')['runs']! as List<Object?>;
    final firstRun = runs.first! as Map<String, Object?>;
    final frameResult = firstRun['frameResult']! as Map<String, Object?>;
    final evidence = frameResult['scenarioEvidence']! as Map<String, Object?>;
    final timestamps = evidence['actionElapsedMs']! as List<double>;
    timestamps[1] = timestamps[0] + 501;

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 2);
    expect(
      report.issues.map((issue) => issue.kind),
      contains('invalid-action-timestamps'),
    );
  });

  test('rejects accumulated action schedule drift', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    final runs =
        _scenario(candidate, 'rapid-track-switch-20')['runs']! as List<Object?>;
    final firstRun = runs.first! as Map<String, Object?>;
    final frameResult = firstRun['frameResult']! as Map<String, Object?>;
    final evidence = frameResult['scenarioEvidence']! as Map<String, Object?>;
    final timestamps = evidence['actionElapsedMs']! as List<double>;
    for (var index = 0; index < timestamps.length; index += 1) {
      timestamps[index] = 1000 + 450.0 * index;
    }

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 2);
    expect(
      report.issues.map((issue) => issue.kind),
      contains('invalid-action-timestamps'),
    );
  });

  test('rejects hidden decoder activity above idle threshold', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    final scenario = _scenario(
      candidate,
      'minimize-video-five-minutes-restore',
    );
    final runs = scenario['runs']! as List<Object?>;
    final firstRun = runs.first! as Map<String, Object?>;
    firstRun['hiddenDecoderMaximumUtilizationPercent'] = 0.051;

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 2);
    expect(
      report.issues.map((issue) => issue.kind),
      contains('invalid-hidden-decoder-samples'),
    );
  });

  test('rejects a substantially short cold-start capture window', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    final scenario = _scenario(candidate, 'cold-start-server-offline');
    final scenarioEvidence =
        scenario['scenarioEvidence']! as Map<String, Object?>;
    scenarioEvidence['captureDurationMs'] = 24999.0;
    final runs = scenario['runs']! as List<Object?>;
    for (final rawRun in runs.cast<Map<String, Object?>>()) {
      final frameResult = rawRun['frameResult']! as Map<String, Object?>;
      final evidence = frameResult['scenarioEvidence']! as Map<String, Object?>;
      evidence['captureDurationMs'] = 24999.0;
    }

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 2);
    expect(
      report.issues.map((issue) => issue.kind),
      contains('invalid-capture-window'),
    );
  });

  test('does not trust self-claimed scenario action counts', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    final evidence =
        _scenario(candidate, 'rapid-track-switch-20')['scenarioEvidence']!
            as Map<String, Object?>;
    evidence['expectedActions'] = 1;
    evidence['completedActions'] = 1;

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 2);
    expect(
      report.issues.map((issue) => issue.kind),
      containsAll(['invalid-scenario-evidence', 'incomplete-scenario-action']),
    );
  });

  test('requires positive Flutter frame counts in visible scenarios', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    _setMetricValue(
      candidate,
      'local-video-60fps-ten-minutes',
      'flutterFrameCount',
      0,
    );

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 2);
    expect(
      report.issues.map((issue) => issue.kind),
      contains('invalid-frame-count'),
    );
  });

  test('allows a truly idle run to report zero frames and zero misses', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    _setMetricValue(
      candidate,
      'idle-home-five-minutes',
      'flutterFrameCount',
      0,
    );
    _setMetricValue(
      candidate,
      'idle-home-five-minutes',
      'missedFrameRatioPercent',
      0,
    );
    _setRawFrameEvidence(
      candidate,
      'idle-home-five-minutes',
      totalFrames: 0,
      missedFrames: 0,
      missedRatio: null,
    );

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 0);
  });

  test('requires runtime decoder proof for every measured run', () {
    final candidate = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    final decoder = _metric(
      candidate,
      'local-video-30fps-ten-minutes',
      'decoderEvidence',
    );
    decoder['runtimeVerified'] = false;
    decoder['positiveRunSamples'] = [1, 0, 1];

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 2);
    expect(
      report.issues.map((issue) => issue.kind),
      containsAll(['unverified-decoder', 'invalid-decoder-samples']),
    );
  });

  test('hard candidate safety gates cannot be omitted or relaxed', () {
    final baseline = _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480);
    final candidate = _run(rssMiB: 104, cpuPercent: 10, firstVideoFrameMs: 480);
    _setMetricValue(
      candidate,
      'large-mp3-mp4-download',
      'downloadRssOverheadMiB',
      33,
    );
    _setRawDownloadOverhead(candidate, 33);
    _metric(
      baseline,
      'large-mp3-mp4-download',
      'downloadRssOverheadMiB',
    ).remove('maxAbsolute');
    final metric = _metric(
      candidate,
      'large-mp3-mp4-download',
      'downloadRssOverheadMiB',
    );
    metric.remove('maxAbsolute');

    final report = evaluatePerformance(
      baseline: baseline,
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 1);
    expect(report.issues.map((issue) => issue.kind), contains('regression'));
  });

  test('minimized RSS is bounded by candidate audio RSS', () {
    final candidate = _run(rssMiB: 104, cpuPercent: 10, firstVideoFrameMs: 480);
    _setMetricValue(
      candidate,
      'minimize-video-five-minutes-restore',
      'rssAt15sMiB',
      125,
    );
    _setRawRssAt15(candidate, 125);

    final report = evaluatePerformance(
      baseline: _run(rssMiB: 100, cpuPercent: 10, firstVideoFrameMs: 480),
      candidate: candidate,
      platform: 'windows',
    );

    expect(report.exitCode, 1);
    expect(
      report.issues.map((issue) => issue.path),
      contains(
        'candidate.scenarios.minimize-video-five-minutes-restore.metrics.rssAt15sMiB',
      ),
    );
  });
}

const _scenarioRequirements = <String, Set<String>>{
  'cold-start-server-offline': {'startupTimeMs'},
  'idle-home-five-minutes': {},
  'audio-only-ten-minutes': {},
  'local-video-30fps-ten-minutes': {'decoderEvidence'},
  'local-video-60fps-ten-minutes': {'decoderEvidence'},
  'minimize-video-five-minutes-restore': {
    'decoderEvidence',
    'firstVideoFrameMs',
    'hiddenFlutterFramesAfterRelease',
  },
  'large-mp3-mp4-download': {},
  'rapid-track-switch-20': {'decoderEvidence'},
  'lyrics-blur-five-minutes': {},
  'video-enable-disable-30': {'decoderEvidence'},
};

const _scenarioDurations = <String, int>{
  'cold-start-server-offline': 30,
  'idle-home-five-minutes': 300,
  'audio-only-ten-minutes': 600,
  'local-video-30fps-ten-minutes': 600,
  'local-video-60fps-ten-minutes': 600,
  'minimize-video-five-minutes-restore': 300,
  'large-mp3-mp4-download': 600,
  'rapid-track-switch-20': 60,
  'lyrics-blur-five-minutes': 300,
  'video-enable-disable-30': 120,
};

const _scenarioWarmups = <String, int>{
  'cold-start-server-offline': 0,
  'idle-home-five-minutes': 10,
  'audio-only-ten-minutes': 15,
  'local-video-30fps-ten-minutes': 15,
  'local-video-60fps-ten-minutes': 15,
  'minimize-video-five-minutes-restore': 15,
  'large-mp3-mp4-download': 15,
  'rapid-track-switch-20': 10,
  'lyrics-blur-five-minutes': 10,
  'video-enable-disable-30': 10,
};

const _scenarioActionStartDelays = <String, int>{
  'cold-start-server-offline': 0,
  'idle-home-five-minutes': 0,
  'audio-only-ten-minutes': 0,
  'local-video-30fps-ten-minutes': 0,
  'local-video-60fps-ten-minutes': 0,
  'minimize-video-five-minutes-restore': 0,
  'large-mp3-mp4-download': 1000,
  'rapid-track-switch-20': 1000,
  'lyrics-blur-five-minutes': 0,
  'video-enable-disable-30': 1000,
};

const _scenarioActionCadences = <String, int>{
  'cold-start-server-offline': 0,
  'idle-home-five-minutes': 0,
  'audio-only-ten-minutes': 0,
  'local-video-30fps-ten-minutes': 0,
  'local-video-60fps-ten-minutes': 0,
  'minimize-video-five-minutes-restore': 0,
  'large-mp3-mp4-download': 0,
  'rapid-track-switch-20': 250,
  'lyrics-blur-five-minutes': 0,
  'video-enable-disable-30': 2000,
};

const _scenarioActions = <String, int>{
  'cold-start-server-offline': 0,
  'idle-home-five-minutes': 0,
  'audio-only-ten-minutes': 1,
  'local-video-30fps-ten-minutes': 1,
  'local-video-60fps-ten-minutes': 1,
  'minimize-video-five-minutes-restore': 2,
  'large-mp3-mp4-download': 1,
  'rapid-track-switch-20': 20,
  'lyrics-blur-five-minutes': 2,
  'video-enable-disable-30': 30,
};

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
    'os': 'test os',
    'device': 'test device',
    'cpu': 'test cpu',
    'gpu': 'test gpu',
    'driver': 'test driver',
    'frameInstrumentation': true,
    'sourceTreeSha256': 'source-hash',
    'appExecutableSha256': 'executable-hash',
    'appBundleSha256': 'bundle-hash',
    'contractSha256': 'contract-hash',
    'collectorSha256': 'collector-hash',
    'fixtureManifestSha256': 'manifest-hash',
    'seedDataSha256': 'seed-hash',
    'videoBackend': 'test',
    'decoder': 'test',
    'decoderEvidence': 'test fixture',
    'fixtureHashes': {
      'app_state.template.json': 'hash-app-state',
      'liked_tracks.template.json': 'hash-liked',
      'my_playlists.template.json': 'hash-playlists',
      'offline_tracks.template.json': 'hash-offline',
      'shiki_settings.template.json': 'hash-settings',
      'track_62030.mp3': 'hash-track-30',
      'track_62030.lrc': 'hash-lrc-30',
      'video_62030.mp4': 'hash-video-30',
      'cover_62030_fixture.jpg': 'hash-cover-30',
      'track_62060.mp3': 'hash-track-60',
      'track_62060.lrc': 'hash-lrc-60',
      'video_62060.mp4': 'hash-video-60',
      'cover_62060_fixture.jpg': 'hash-cover-60',
      'download_fixture.mp3': 'hash-large-mp3',
      'download_fixture.mp4': 'hash-large-mp4',
      'download_fixture_cover.jpg': 'hash-download-cover',
    },
  },
  'measurement': {
    'warmupRuns': 1,
    'warmupRunSeconds': 30,
    'measuredRuns': 3,
    'sampleIntervalMs': 500,
    'frameBudgetMicros': 16667,
    'processIsolation': 'fresh-process-per-run',
    'stateReset': 'seed-copy-v1',
    'runKind': 'baseline',
  },
  'scenarios': [
    for (final requirement in _scenarioRequirements.entries)
      {
        'id': requirement.key,
        'warmupSeconds': _scenarioWarmups[requirement.key],
        'durationSeconds': _scenarioDurations[requirement.key],
        'actionStartDelayMs': _scenarioActionStartDelays[requirement.key],
        'actionCadenceMs': _scenarioActionCadences[requirement.key],
        'scenarioEvidence': {
          'ready': true,
          'captureStarted': true,
          'captureEnded': true,
          'captureDurationMs': _scenarioDurations[requirement.key]! * 1000.0,
          'actionCompleted': true,
          'serverBaseUrl': 'http://127.0.0.1:65534',
          'videoProgressEvents': 100,
          'videoPositionAdvanceMs': 5000.0,
          'videoPlayingSamples': 100,
          'videoBufferingSamples': 0,
          'videoControllerReleasedAfterHiddenMs':
              requirement.key == 'minimize-video-five-minutes-restore'
              ? 550.0
              : null,
          'completedActions': _scenarioActions[requirement.key],
          'expectedActions': _scenarioActions[requirement.key],
          'actionStartDelayMs': _scenarioActionStartDelays[requirement.key],
          'actionCadenceMs': _scenarioActionCadences[requirement.key],
          'actionElapsedMs': _actionElapsedMs(requirement.key),
        },
        'runs': _rawRuns(
          scenarioId: requirement.key,
          durationSeconds: _scenarioDurations[requirement.key]!,
          warmupSeconds: _scenarioWarmups[requirement.key]!,
          rssMiB: rssMiB,
          cpuPercent: cpuPercent,
          firstVideoFrameMs: firstVideoFrameMs,
        ),
        'metrics': {
          'rssMiB': _numericMetric(
            value: rssMiB,
            compareStat: 'median',
            maxRegressionPercent: 5,
          ),
          'cpuPercent': _numericMetric(
            value: cpuPercent,
            compareStat: 'median',
            maxRegressionPercent: 10,
          ),
          'missedFrameRatioPercent': _numericMetric(
            value: 0.1,
            compareStat: 'p95',
            maxAbsolute: 1,
          ),
          'flutterFrameCount': _numericMetric(
            value: 1000,
            compareStat: 'median',
          ),
          if (requirement.value.contains('startupTimeMs'))
            'startupTimeMs': _numericMetric(
              value: 500,
              compareStat: 'p95',
              maxRegressionPercent: 10,
            ),
          if (requirement.key == 'cold-start-server-offline')
            'startupTimeMs': _numericMetric(
              value: 1000,
              compareStat: 'p95',
              maxRegressionPercent: 10,
            ),
          if (requirement.value.contains('firstVideoFrameMs'))
            'firstVideoFrameMs': _numericMetric(
              value: firstVideoFrameMs,
              compareStat: 'p95',
              failureAbove: 1000,
            ),
          if (requirement.value.contains('hiddenFlutterFramesAfterRelease'))
            'hiddenFlutterFramesAfterRelease': _numericMetric(
              value: 0,
              compareStat: 'p95',
              maxAbsolute: 0,
            ),
          if (requirement.value.contains('decoderEvidence'))
            'decoderEvidence': {
              'requiredEvidence': true,
              'evidence': 'test decoder evidence',
              'runtimeVerified': true,
              'probeKind': 'windows-gpu-engine-videodecode',
              'positiveRunSamples': [1, 1, 1],
              if (requirement.key == 'minimize-video-five-minutes-restore')
                'hiddenMaximumRunSamples': [0, 0, 0],
            },
          if (requirement.key == 'minimize-video-five-minutes-restore') ...{
            'rssAt15sMiB': _numericMetric(value: rssMiB, compareStat: 'median'),
            'backgroundCpuPercent': _numericMetric(
              value: 0.5,
              compareStat: 'median',
              maxAbsolute: 1,
            ),
          },
          if (requirement.key == 'large-mp3-mp4-download')
            'downloadRssOverheadMiB': _numericMetric(
              value: 10,
              compareStat: 'p95',
              maxAbsolute: 32,
            ),
          if ({
            'rapid-track-switch-20',
            'video-enable-disable-30',
          }.contains(requirement.key))
            'retainedRssGrowthMiB': _numericMetric(
              value: 5,
              compareStat: 'p95',
              maxAbsolute: 10,
            ),
        },
      },
  ],
};

List<Map<String, Object?>> _rawRuns({
  required String scenarioId,
  required int durationSeconds,
  required int warmupSeconds,
  required double rssMiB,
  required double cpuPercent,
  required double firstVideoFrameMs,
}) => [
  for (var index = 1; index <= 3; index += 1)
    {
      'index': index,
      'runId': '$scenarioId-run-$index',
      'processId': 1000 + index,
      'actualDurationMs': durationSeconds * 1000.0,
      'resourceSamples': _captureResourceSamples(
        scenarioId: scenarioId,
        durationSeconds: durationSeconds,
        rssMiB: rssMiB,
        cpuPercent: cpuPercent,
      ),
      'preCaptureResourceSamples': _preCaptureResourceSamples(
        scenarioId: scenarioId,
        warmupSeconds: warmupSeconds,
        rssMiB: rssMiB,
        cpuPercent: cpuPercent,
      ),
      'startupTimeMs': scenarioId == 'cold-start-server-offline' ? 1000 : null,
      'frameResult': {
        'frameBudgetMicros': 16667,
        'totalFrames': 1000,
        'missedFrames': 1,
        'missedFrameRatioPercent': 0.1,
        'hiddenFlutterFrames': 0,
        'hiddenFlutterFramesAfterRelease':
            scenarioId == 'minimize-video-five-minutes-restore' ? 0 : null,
        'firstFrameAfterRestoreMs':
            scenarioId == 'minimize-video-five-minutes-restore'
            ? firstVideoFrameMs
            : null,
        'scenarioEvidence': _rawScenarioEvidence(scenarioId),
      },
      'scenarioEvidence': _rawScenarioEvidence(scenarioId),
      'decoderMaximumUtilizationPercent':
          _scenarioRequirements[scenarioId]!.contains('decoderEvidence')
          ? 1
          : null,
      'hiddenDecoderMaximumUtilizationPercent':
          scenarioId == 'minimize-video-five-minutes-restore' ? 0 : null,
    },
];

List<Map<String, Object?>> _captureResourceSamples({
  required String scenarioId,
  required int durationSeconds,
  required double rssMiB,
  required double cpuPercent,
}) {
  const intervalMs = 500;
  final elapsedValues = List<double>.generate(
    durationSeconds * 1000 ~/ intervalMs,
    (index) => (index + 1) * intervalMs.toDouble(),
  );
  final lateSampleCount = elapsedValues
      .where((elapsedMs) => elapsedMs >= 15000)
      .length;
  final earlySampleCount = elapsedValues.length - lateSampleCount;
  final minimizeEarlyCpu =
      (elapsedValues.length * cpuPercent - lateSampleCount * 0.5) /
      earlySampleCount;
  return [
    for (final elapsedMs in elapsedValues)
      {
        'elapsedMs': elapsedMs,
        'rssMiB': rssMiB,
        'cpuPercent': scenarioId == 'minimize-video-five-minutes-restore'
            ? (elapsedMs >= 15000 ? 0.5 : minimizeEarlyCpu)
            : cpuPercent,
      },
  ];
}

List<Map<String, Object?>> _preCaptureResourceSamples({
  required String scenarioId,
  required int warmupSeconds,
  required double rssMiB,
  required double cpuPercent,
}) {
  if (warmupSeconds == 0) {
    return const [];
  }
  final preRss = switch (scenarioId) {
    'large-mp3-mp4-download' => rssMiB - 10,
    'rapid-track-switch-20' || 'video-enable-disable-30' => rssMiB - 5,
    _ => rssMiB,
  };
  return [
    {'elapsedMs': 500, 'rssMiB': preRss, 'cpuPercent': cpuPercent},
    {
      'elapsedMs': warmupSeconds * 1000 - 500,
      'rssMiB': preRss,
      'cpuPercent': cpuPercent,
    },
  ];
}

Map<String, Object?> _rawScenarioEvidence(String scenarioId) => {
  'ready': true,
  'captureStarted': true,
  'captureEnded': true,
  'captureDurationMs': _scenarioDurations[scenarioId]! * 1000.0,
  'actionCompleted': true,
  'actionError': '',
  'serverBaseUrl': 'http://127.0.0.1:65534',
  'videoProgressEvents': 100,
  'videoPositionAdvanceMs': 5000.0,
  'videoPlayingSamples': 100,
  'videoBufferingSamples': 0,
  'videoControllerReleasedAfterHiddenMs':
      scenarioId == 'minimize-video-five-minutes-restore' ? 550.0 : null,
  'expectedActions': _scenarioActions[scenarioId],
  'completedActions': _scenarioActions[scenarioId],
  'dataDirectory': 'test-data',
  'actionStartDelayMs': _scenarioActionStartDelays[scenarioId],
  'actionCadenceMs': _scenarioActionCadences[scenarioId],
  'actionElapsedMs': _actionElapsedMs(scenarioId),
};

List<double> _actionElapsedMs(String scenarioId) {
  final actions = _scenarioActions[scenarioId]!;
  final start = _scenarioActionStartDelays[scenarioId]!;
  final cadence = _scenarioActionCadences[scenarioId]!;
  if (start == 0 && cadence == 0) {
    return const [];
  }
  return [
    for (var index = 0; index < actions; index += 1)
      (start + cadence * index).toDouble(),
  ];
}

Map<String, Object?> _numericMetric({
  required double value,
  required String compareStat,
  double? maxRegressionPercent,
  double? maxAbsolute,
  double? failureAbove,
}) => {
  'required': true,
  'samples': [value, value, value],
  'median': value,
  'p95': value,
  'compareStat': compareStat,
  'evidence': 'test profile trace',
  'maxRegressionPercent': ?maxRegressionPercent,
  'maxAbsolute': ?maxAbsolute,
  'failureAbove': ?failureAbove,
};

Map<String, Object?> _scenario(Map<String, Object?> run, String id) =>
    (run['scenarios']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .singleWhere((scenario) => scenario['id'] == id);

Map<String, Object?> _metric(
  Map<String, Object?> run,
  String scenarioId,
  String metricName,
) =>
    (_scenario(run, scenarioId)['metrics']!
            as Map<String, Object?>)[metricName]!
        as Map<String, Object?>;

void _setMetricValue(
  Map<String, Object?> run,
  String scenarioId,
  String metricName,
  double value,
) {
  final metric = _metric(run, scenarioId, metricName);
  metric['samples'] = [value, value, value];
  metric['median'] = value;
  metric['p95'] = value;
}

void _setRawFrameEvidence(
  Map<String, Object?> run,
  String scenarioId, {
  required int totalFrames,
  required int missedFrames,
  required double? missedRatio,
}) {
  final runs = _scenario(run, scenarioId)['runs']! as List<Object?>;
  for (final rawRun in runs.cast<Map<String, Object?>>()) {
    final frame = rawRun['frameResult']! as Map<String, Object?>;
    frame['totalFrames'] = totalFrames;
    frame['missedFrames'] = missedFrames;
    frame['missedFrameRatioPercent'] = missedRatio;
  }
}

void _setRawDownloadOverhead(Map<String, Object?> run, double overhead) {
  final runs =
      _scenario(run, 'large-mp3-mp4-download')['runs']! as List<Object?>;
  for (final rawRun in runs.cast<Map<String, Object?>>()) {
    final resources = rawRun['resourceSamples']! as List<Object?>;
    final peak = resources
        .cast<Map<String, Object?>>()
        .map((sample) => sample['rssMiB']! as num)
        .reduce((left, right) => left > right ? left : right)
        .toDouble();
    final preCapture = rawRun['preCaptureResourceSamples']! as List<Object?>;
    for (final sample in preCapture.cast<Map<String, Object?>>()) {
      sample['rssMiB'] = peak - overhead;
    }
  }
}

void _setRawRssAt15(Map<String, Object?> run, double value) {
  final runs =
      _scenario(run, 'minimize-video-five-minutes-restore')['runs']!
          as List<Object?>;
  for (final rawRun in runs.cast<Map<String, Object?>>()) {
    final resources = rawRun['resourceSamples']! as List<Object?>;
    for (final sample in resources.cast<Map<String, Object?>>()) {
      final elapsedMs = (sample['elapsedMs']! as num).toDouble();
      if (elapsedMs >= 13000 && elapsedMs < 15000) {
        sample['rssMiB'] = value;
      }
    }
  }
}
