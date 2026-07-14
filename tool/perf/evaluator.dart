class EvaluationIssue {
  const EvaluationIssue({
    required this.kind,
    required this.path,
    required this.message,
  });

  final String kind;
  final String path;
  final String message;

  Map<String, Object?> toJson() => {
    'kind': kind,
    'path': path,
    'message': message,
  };
}

class MetricComparison {
  const MetricComparison({
    required this.scenario,
    required this.metric,
    required this.stat,
    required this.baseline,
    required this.candidate,
    required this.status,
    this.limit,
  });

  final String scenario;
  final String metric;
  final String stat;
  final double baseline;
  final double candidate;
  final double? limit;
  final String status;

  Map<String, Object?> toJson() => {
    'scenario': scenario,
    'metric': metric,
    'stat': stat,
    'baseline': baseline,
    'candidate': candidate,
    if (limit != null) 'limit': limit,
    'status': status,
  };
}

class EvaluationReport {
  const EvaluationReport({
    required this.exitCode,
    required this.verdict,
    required this.issues,
    required this.comparisons,
  });

  final int exitCode;
  final String verdict;
  final List<EvaluationIssue> issues;
  final List<MetricComparison> comparisons;

  Map<String, Object?> toJson() => {
    'verdict': verdict,
    'exitCode': exitCode,
    'issues': issues.map((issue) => issue.toJson()).toList(),
    'comparisons': comparisons
        .map((comparison) => comparison.toJson())
        .toList(),
  };
}

class _RawResourceSample {
  const _RawResourceSample({
    required this.elapsedMs,
    required this.rssMiB,
    required this.cpuPercent,
  });

  final double elapsedMs;
  final double rssMiB;
  final double cpuPercent;
}

const String _benchmarkServerBaseUrl = 'http://127.0.0.1:65534';
const Set<String> _requiredFixtureFiles = {
  'app_state.template.json',
  'liked_tracks.template.json',
  'my_playlists.template.json',
  'offline_tracks.template.json',
  'shiki_settings.template.json',
  'track_62030.mp3',
  'track_62030.lrc',
  'video_62030.mp4',
  'track_62060.mp3',
  'track_62060.lrc',
  'video_62060.mp4',
  'download_fixture.mp3',
  'download_fixture.mp4',
  'download_fixture_cover.jpg',
};
const Set<String> _visibleVideoScenarios = {
  'local-video-30fps-ten-minutes',
  'local-video-60fps-ten-minutes',
  'rapid-track-switch-20',
  'video-enable-disable-30',
};

const Map<String, Set<String>> _requiredScenarioMetrics = {
  'cold-start-server-offline': {
    'rssMiB',
    'cpuPercent',
    'missedFrameRatioPercent',
    'flutterFrameCount',
    'startupTimeMs',
  },
  'idle-home-five-minutes': {
    'rssMiB',
    'cpuPercent',
    'missedFrameRatioPercent',
    'flutterFrameCount',
  },
  'audio-only-ten-minutes': {
    'rssMiB',
    'cpuPercent',
    'missedFrameRatioPercent',
    'flutterFrameCount',
  },
  'local-video-30fps-ten-minutes': {
    'rssMiB',
    'cpuPercent',
    'missedFrameRatioPercent',
    'flutterFrameCount',
    'decoderEvidence',
  },
  'local-video-60fps-ten-minutes': {
    'rssMiB',
    'cpuPercent',
    'missedFrameRatioPercent',
    'flutterFrameCount',
    'decoderEvidence',
  },
  'minimize-video-five-minutes-restore': {
    'rssMiB',
    'cpuPercent',
    'missedFrameRatioPercent',
    'flutterFrameCount',
    'firstVideoFrameMs',
    'hiddenFlutterFramesAfterRelease',
    'rssAt15sMiB',
    'backgroundCpuPercent',
    'decoderEvidence',
  },
  'large-mp3-mp4-download': {
    'rssMiB',
    'cpuPercent',
    'missedFrameRatioPercent',
    'flutterFrameCount',
    'downloadRssOverheadMiB',
  },
  'rapid-track-switch-20': {
    'rssMiB',
    'cpuPercent',
    'missedFrameRatioPercent',
    'flutterFrameCount',
    'retainedRssGrowthMiB',
    'decoderEvidence',
  },
  'lyrics-blur-five-minutes': {
    'rssMiB',
    'cpuPercent',
    'missedFrameRatioPercent',
    'flutterFrameCount',
  },
  'video-enable-disable-30': {
    'rssMiB',
    'cpuPercent',
    'missedFrameRatioPercent',
    'flutterFrameCount',
    'retainedRssGrowthMiB',
    'decoderEvidence',
  },
};

const Map<String, String> _requiredMetricStats = {
  'rssMiB': 'median',
  'cpuPercent': 'median',
  'missedFrameRatioPercent': 'p95',
  'flutterFrameCount': 'median',
  'startupTimeMs': 'p95',
  'firstVideoFrameMs': 'p95',
  'hiddenFlutterFramesAfterRelease': 'p95',
  'rssAt15sMiB': 'median',
  'backgroundCpuPercent': 'median',
  'downloadRssOverheadMiB': 'p95',
  'retainedRssGrowthMiB': 'p95',
};

const Map<String, int> _requiredScenarioDurations = {
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

const Map<String, int> _requiredScenarioWarmups = {
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

const Map<String, int> _requiredActionStartDelays = {
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

const Map<String, int> _requiredActionCadences = {
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

const Set<String> _visibleFrameScenarios = {
  'cold-start-server-offline',
  'audio-only-ten-minutes',
  'local-video-30fps-ten-minutes',
  'local-video-60fps-ten-minutes',
  'minimize-video-five-minutes-restore',
  'large-mp3-mp4-download',
  'rapid-track-switch-20',
  'lyrics-blur-five-minutes',
  'video-enable-disable-30',
};

const Map<String, int> _expectedScenarioActions = {
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

EvaluationReport evaluatePerformance({
  required Map<String, Object?> baseline,
  required Map<String, Object?> candidate,
  String? platform,
}) {
  final infrastructureIssues = <EvaluationIssue>[
    ..._validateRun('baseline', baseline, platform: platform),
    ..._validateRun('candidate', candidate, platform: platform),
    ..._validateCompatibility(baseline, candidate),
  ];

  if (infrastructureIssues.isNotEmpty) {
    return EvaluationReport(
      exitCode: 2,
      verdict: 'infrastructure',
      issues: infrastructureIssues,
      comparisons: const [],
    );
  }

  final baselineScenarios = _scenarioMap(baseline);
  final candidateScenarios = _scenarioMap(candidate);
  final regressionIssues = <EvaluationIssue>[];
  final comparisons = <MetricComparison>[];

  _evaluateCandidateSafetyGates(
    baselineScenarios: baselineScenarios,
    candidateScenarios: candidateScenarios,
    issues: regressionIssues,
    comparisons: comparisons,
  );

  for (final scenarioId in baselineScenarios.keys) {
    if (!candidateScenarios.containsKey(scenarioId)) {
      infrastructureIssues.add(
        EvaluationIssue(
          kind: 'missing-scenario',
          path: 'candidate.scenarios.$scenarioId',
          message:
              'Candidate does not contain baseline scenario "$scenarioId".',
        ),
      );
    }
  }

  for (final entry in candidateScenarios.entries) {
    final scenarioId = entry.key;
    final candidateScenario = entry.value;
    final baselineScenario = baselineScenarios[scenarioId];
    if (baselineScenario == null) {
      infrastructureIssues.add(
        EvaluationIssue(
          kind: 'missing-scenario',
          path: 'baseline.scenarios.$scenarioId',
          message:
              'Baseline does not contain candidate scenario "$scenarioId".',
        ),
      );
      continue;
    }

    final candidateMetrics = _mapAt(candidateScenario, 'metrics');
    final baselineMetrics = _mapAt(baselineScenario, 'metrics');

    for (final baselineMetricEntry in baselineMetrics.entries) {
      final baselineMetricName = baselineMetricEntry.key;
      final baselineMetric = _asMap(baselineMetricEntry.value);
      if ((_boolAt(baselineMetric, 'required') ?? false) &&
          !candidateMetrics.containsKey(baselineMetricName)) {
        infrastructureIssues.add(
          EvaluationIssue(
            kind: 'missing-metric',
            path: 'candidate.scenarios.$scenarioId.metrics.$baselineMetricName',
            message: 'Required candidate metric is missing.',
          ),
        );
      }
    }

    for (final metricEntry in candidateMetrics.entries) {
      final metricName = metricEntry.key;
      final candidateMetric = _asMap(metricEntry.value);
      final baselineMetric = _asMap(baselineMetrics[metricName]);

      if (candidateMetric == null) {
        infrastructureIssues.add(
          EvaluationIssue(
            kind: 'invalid-metric',
            path: 'candidate.scenarios.$scenarioId.metrics.$metricName',
            message: 'Candidate metric must be an object.',
          ),
        );
        continue;
      }

      final isRequired =
          (_boolAt(candidateMetric, 'required') ?? false) ||
          (_boolAt(baselineMetric, 'required') ?? false);

      if (baselineMetric == null) {
        if (isRequired) {
          infrastructureIssues.add(
            EvaluationIssue(
              kind: 'missing-metric',
              path: 'baseline.scenarios.$scenarioId.metrics.$metricName',
              message: 'Required baseline metric is missing.',
            ),
          );
        }
        continue;
      }

      if (_boolAt(candidateMetric, 'requiredEvidence') == true ||
          _boolAt(baselineMetric, 'requiredEvidence') == true) {
        final evidence = _stringAt(candidateMetric, 'evidence');
        if (evidence == null || evidence.trim().isEmpty) {
          infrastructureIssues.add(
            EvaluationIssue(
              kind: 'missing-evidence',
              path:
                  'candidate.scenarios.$scenarioId.metrics.$metricName.evidence',
              message: 'Required decoder/backend evidence is missing.',
            ),
          );
        }
      }

      final comparisonStat =
          _stringAt(baselineMetric, 'compareStat') ??
          _stringAt(candidateMetric, 'compareStat') ??
          'median';
      final candidateValue = _numAt(candidateMetric, comparisonStat);
      final baselineValue = _numAt(baselineMetric, comparisonStat);

      if (isRequired && (candidateValue == null || baselineValue == null)) {
        infrastructureIssues.add(
          EvaluationIssue(
            kind: 'missing-stat',
            path: 'scenarios.$scenarioId.metrics.$metricName.$comparisonStat',
            message: 'Required metric statistic is missing.',
          ),
        );
        continue;
      }

      if (candidateValue == null || baselineValue == null) {
        continue;
      }

      final maxRegressionPercent = _numAt(
        baselineMetric,
        'maxRegressionPercent',
      );
      final maxAbsolute = _numAt(baselineMetric, 'maxAbsolute');
      final failureAbove = _numAt(baselineMetric, 'failureAbove');

      var status = 'pass';
      double? limit;

      if (maxRegressionPercent != null) {
        limit = baselineValue * (1 + maxRegressionPercent / 100);
        if (candidateValue > limit) {
          status = 'regression';
          regressionIssues.add(
            EvaluationIssue(
              kind: 'regression',
              path: 'candidate.scenarios.$scenarioId.metrics.$metricName',
              message:
                  '$metricName $comparisonStat regressed from $baselineValue to $candidateValue; limit is $limit.',
            ),
          );
        }
      }

      if (maxAbsolute != null) {
        limit = maxAbsolute;
        if (candidateValue > maxAbsolute) {
          status = 'regression';
          regressionIssues.add(
            EvaluationIssue(
              kind: 'regression',
              path: 'candidate.scenarios.$scenarioId.metrics.$metricName',
              message:
                  '$metricName $comparisonStat is $candidateValue; absolute limit is $maxAbsolute.',
            ),
          );
        }
      }

      if (failureAbove != null) {
        limit = failureAbove;
        if (candidateValue > failureAbove) {
          status = 'regression';
          regressionIssues.add(
            EvaluationIssue(
              kind: 'regression',
              path: 'candidate.scenarios.$scenarioId.metrics.$metricName',
              message:
                  '$metricName $comparisonStat is $candidateValue; failure threshold is $failureAbove.',
            ),
          );
        }
      }

      comparisons.add(
        MetricComparison(
          scenario: scenarioId,
          metric: metricName,
          stat: comparisonStat,
          baseline: baselineValue,
          candidate: candidateValue,
          limit: limit,
          status: status,
        ),
      );
    }
  }

  if (infrastructureIssues.isNotEmpty) {
    return EvaluationReport(
      exitCode: 2,
      verdict: 'infrastructure',
      issues: infrastructureIssues,
      comparisons: comparisons,
    );
  }

  if (regressionIssues.isNotEmpty) {
    return EvaluationReport(
      exitCode: 1,
      verdict: 'regression',
      issues: regressionIssues,
      comparisons: comparisons,
    );
  }

  return EvaluationReport(
    exitCode: 0,
    verdict: 'pass',
    issues: const [],
    comparisons: comparisons,
  );
}

List<EvaluationIssue> _validateRun(
  String label,
  Map<String, Object?> run, {
  String? platform,
}) {
  final issues = <EvaluationIssue>[];

  if (run['schemaVersion'] != 1) {
    issues.add(
      EvaluationIssue(
        kind: 'invalid-schema',
        path: '$label.schemaVersion',
        message: 'Expected schemaVersion 1.',
      ),
    );
  }

  final metadata = _mapAt(run, 'metadata');
  for (final field in [
    'commit',
    'platform',
    'buildMode',
    'flutterVersion',
    'os',
    'device',
    'cpu',
    'gpu',
    'driver',
    'sourceTreeSha256',
    'appExecutableSha256',
    'appBundleSha256',
    'contractSha256',
    'collectorSha256',
    'fixtureManifestSha256',
    'seedDataSha256',
  ]) {
    final value = _stringAt(metadata, field);
    if (value == null || value.trim().isEmpty) {
      issues.add(
        EvaluationIssue(
          kind: 'missing-metadata',
          path: '$label.metadata.$field',
          message: 'Required metadata field is missing.',
        ),
      );
    }
  }

  if (metadata['frameInstrumentation'] is! bool ||
      metadata['frameInstrumentation'] != true) {
    issues.add(
      EvaluationIssue(
        kind: 'invalid-metadata',
        path: '$label.metadata.frameInstrumentation',
        message: 'frameInstrumentation must be true.',
      ),
    );
  }

  final measuredPlatform = _stringAt(metadata, 'platform');
  if (measuredPlatform != null &&
      !const {'windows', 'linux', 'android'}.contains(measuredPlatform)) {
    issues.add(
      EvaluationIssue(
        kind: 'invalid-metadata',
        path: '$label.metadata.platform',
        message: 'platform must be windows, linux, or android.',
      ),
    );
  }
  final buildMode = _stringAt(metadata, 'buildMode');
  if (buildMode != null && !const {'profile', 'release'}.contains(buildMode)) {
    issues.add(
      EvaluationIssue(
        kind: 'invalid-metadata',
        path: '$label.metadata.buildMode',
        message: 'buildMode must be profile or release.',
      ),
    );
  }
  if (platform != null &&
      measuredPlatform != null &&
      measuredPlatform != platform) {
    issues.add(
      EvaluationIssue(
        kind: 'platform-mismatch',
        path: '$label.metadata.platform',
        message: 'Expected platform "$platform", found "$measuredPlatform".',
      ),
    );
  }

  final measurement = _mapAt(run, 'measurement');
  final warmupRuns = _integerAt(measurement, 'warmupRuns');
  final warmupRunSeconds = _integerAt(measurement, 'warmupRunSeconds');
  final measuredRuns = _integerAt(measurement, 'measuredRuns');
  final sampleIntervalMs = _integerAt(measurement, 'sampleIntervalMs');
  final frameBudgetMicros = _integerAt(measurement, 'frameBudgetMicros');

  if (warmupRuns != 1) {
    issues.add(
      EvaluationIssue(
        kind: 'invalid-warmup',
        path: '$label.measurement.warmupRuns',
        message: 'warmupRuns must equal 1.',
      ),
    );
  }
  if (warmupRunSeconds != 30) {
    issues.add(
      EvaluationIssue(
        kind: 'invalid-warmup',
        path: '$label.measurement.warmupRunSeconds',
        message: 'warmupRunSeconds must equal 30.',
      ),
    );
  }
  if (measuredRuns != 3) {
    issues.add(
      EvaluationIssue(
        kind: 'insufficient-repetitions',
        path: '$label.measurement.measuredRuns',
        message: 'Exactly three measured repetitions are required.',
      ),
    );
  }
  if (sampleIntervalMs != 500) {
    issues.add(
      EvaluationIssue(
        kind: 'invalid-sample-interval',
        path: '$label.measurement.sampleIntervalMs',
        message: 'sampleIntervalMs must equal 500.',
      ),
    );
  }
  if (frameBudgetMicros != 16667) {
    issues.add(
      EvaluationIssue(
        kind: 'invalid-frame-budget',
        path: '$label.measurement.frameBudgetMicros',
        message: 'frameBudgetMicros must equal 16667.',
      ),
    );
  }
  for (final contract in const {
    'processIsolation': 'fresh-process-per-run',
    'stateReset': 'seed-copy-v1',
    'runKind': 'baseline',
  }.entries) {
    if (_stringAt(measurement, contract.key) != contract.value) {
      issues.add(
        EvaluationIssue(
          kind: 'invalid-measurement-contract',
          path: '$label.measurement.${contract.key}',
          message: '${contract.key} must equal "${contract.value}".',
        ),
      );
    }
  }

  final fixtureHashes = _mapAt(metadata, 'fixtureHashes');
  final cover30Count = fixtureHashes.keys
      .where((name) => name.startsWith('cover_62030_'))
      .length;
  final cover60Count = fixtureHashes.keys
      .where((name) => name.startsWith('cover_62060_'))
      .length;
  if (fixtureHashes.length != _requiredFixtureFiles.length + 2 ||
      !_requiredFixtureFiles.every(fixtureHashes.containsKey) ||
      cover30Count != 1 ||
      cover60Count != 1 ||
      fixtureHashes.entries.any(
        (entry) =>
            entry.key.trim().isEmpty ||
            entry.value is! String ||
            (entry.value as String).trim().isEmpty,
      )) {
    issues.add(
      EvaluationIssue(
        kind: 'missing-fixture-hashes',
        path: '$label.metadata.fixtureHashes',
        message:
            'Exact playback media, covers, lyrics, templates, and download fixture hashes are required.',
      ),
    );
  }

  final scenarios = run['scenarios'];
  if (scenarios is! List || scenarios.isEmpty) {
    issues.add(
      EvaluationIssue(
        kind: 'missing-scenarios',
        path: '$label.scenarios',
        message: 'At least one scenario is required.',
      ),
    );
    return issues;
  }

  final scenarioIds = <String>{};
  final scenariosById = <String, Map<String, Object?>>{};
  final measuredRunCount = measuredRuns;
  for (var index = 0; index < scenarios.length; index += 1) {
    final scenario = _asMap(scenarios[index]);
    final path = '$label.scenarios[$index]';
    if (scenario == null) {
      issues.add(
        EvaluationIssue(
          kind: 'invalid-scenario',
          path: path,
          message: 'Scenario must be an object.',
        ),
      );
      continue;
    }

    final id = _stringAt(scenario, 'id');
    if (id == null || id.trim().isEmpty) {
      issues.add(
        EvaluationIssue(
          kind: 'missing-scenario-id',
          path: '$path.id',
          message: 'Scenario id is required.',
        ),
      );
    }
    if (id != null && id.trim().isNotEmpty) {
      if (!scenarioIds.add(id)) {
        issues.add(
          EvaluationIssue(
            kind: 'duplicate-scenario',
            path: '$path.id',
            message: 'Scenario "$id" occurs more than once.',
          ),
        );
      }
      scenariosById[id] = scenario;

      final requiredDuration = _requiredScenarioDurations[id];
      if (requiredDuration != null) {
        final durationSeconds = _integerAt(scenario, 'durationSeconds');
        if (durationSeconds != requiredDuration) {
          issues.add(
            EvaluationIssue(
              kind: 'invalid-duration',
              path: '$path.durationSeconds',
              message:
                  'Scenario "$id" duration must equal $requiredDuration seconds.',
            ),
          );
        }
      }

      final requiredWarmup = _requiredScenarioWarmups[id];
      if (requiredWarmup != null &&
          _integerAt(scenario, 'warmupSeconds') != requiredWarmup) {
        issues.add(
          EvaluationIssue(
            kind: 'invalid-warmup',
            path: '$path.warmupSeconds',
            message: 'Scenario "$id" warmupSeconds must equal $requiredWarmup.',
          ),
        );
      }

      final requiredActionStartDelay = _requiredActionStartDelays[id];
      if (requiredActionStartDelay != null &&
          _integerAt(scenario, 'actionStartDelayMs') !=
              requiredActionStartDelay) {
        issues.add(
          EvaluationIssue(
            kind: 'invalid-action-schedule',
            path: '$path.actionStartDelayMs',
            message:
                'Scenario "$id" actionStartDelayMs must equal $requiredActionStartDelay.',
          ),
        );
      }

      final requiredActionCadence = _requiredActionCadences[id];
      if (requiredActionCadence != null &&
          _integerAt(scenario, 'actionCadenceMs') != requiredActionCadence) {
        issues.add(
          EvaluationIssue(
            kind: 'invalid-action-schedule',
            path: '$path.actionCadenceMs',
            message:
                'Scenario "$id" actionCadenceMs must equal $requiredActionCadence.',
          ),
        );
      }

      issues.addAll(
        _validateScenarioEvidence(
          label: label,
          scenarioId: id,
          scenario: scenario,
        ),
      );
    }

    final metrics = scenario['metrics'];
    if (metrics is! Map || metrics.isEmpty) {
      issues.add(
        EvaluationIssue(
          kind: 'missing-metrics',
          path: '$path.metrics',
          message: 'Scenario metrics are required.',
        ),
      );
    }
  }

  for (final contractEntry in _requiredScenarioMetrics.entries) {
    final scenario = scenariosById[contractEntry.key];
    if (scenario == null) {
      issues.add(
        EvaluationIssue(
          kind: 'missing-scenario',
          path: '$label.scenarios.${contractEntry.key}',
          message: 'Mandatory performance scenario is missing.',
        ),
      );
      continue;
    }

    final metrics = _mapAt(scenario, 'metrics');
    for (final metricName in contractEntry.value) {
      final metric = _asMap(metrics[metricName]);
      final metricPath =
          '$label.scenarios.${contractEntry.key}.metrics.$metricName';
      if (metric == null) {
        issues.add(
          EvaluationIssue(
            kind: 'missing-metric',
            path: metricPath,
            message: 'Mandatory scenario metric is missing.',
          ),
        );
        continue;
      }

      if (metricName == 'decoderEvidence') {
        issues.addAll(
          _validateDecoderEvidence(
            metricPath: metricPath,
            metric: metric,
            platform: measuredPlatform,
            measuredRuns: measuredRunCount,
            scenarioId: contractEntry.key,
          ),
        );
        continue;
      }

      final requiredStat = _requiredMetricStats[metricName]!;
      if (_stringAt(metric, 'compareStat') != requiredStat) {
        issues.add(
          EvaluationIssue(
            kind: 'invalid-compare-stat',
            path: '$metricPath.compareStat',
            message: 'compareStat must be "$requiredStat".',
          ),
        );
      }

      issues.addAll(
        _validateNumericMetric(
          metricPath: metricPath,
          metric: metric,
          measuredRuns: measuredRunCount,
        ),
      );

      if ({
        'missedFrameRatioPercent',
        'flutterFrameCount',
        'startupTimeMs',
        'firstVideoFrameMs',
        'hiddenFlutterFramesAfterRelease',
      }.contains(metricName)) {
        final evidence = _stringAt(metric, 'evidence');
        if (evidence == null || evidence.trim().isEmpty) {
          issues.add(
            EvaluationIssue(
              kind: 'missing-evidence',
              path: '$metricPath.evidence',
              message: 'Profile/DevTools evidence is required.',
            ),
          );
        }
      }

      if (metricName == 'flutterFrameCount') {
        issues.addAll(
          _validateFrameCounts(
            scenarioId: contractEntry.key,
            metricPath: metricPath,
            metric: metric,
          ),
        );
      }
    }

    issues.addAll(
      _validateRawRuns(
        label: label,
        scenarioId: contractEntry.key,
        scenario: scenario,
        measuredRuns: measuredRunCount,
        sampleIntervalMs: sampleIntervalMs,
      ),
    );

    if (contractEntry.key == 'idle-home-five-minutes') {
      issues.addAll(
        _validateIdleFrameConsistency(label: label, scenario: scenario),
      );
    }
  }

  return issues;
}

List<EvaluationIssue> _validateRawRuns({
  required String label,
  required String scenarioId,
  required Map<String, Object?> scenario,
  required int? measuredRuns,
  required int? sampleIntervalMs,
}) {
  final path = '$label.scenarios.$scenarioId.runs';
  final rawRuns = scenario['runs'];
  if (rawRuns is! List ||
      measuredRuns == null ||
      rawRuns.length != measuredRuns) {
    return [
      EvaluationIssue(
        kind: 'invalid-raw-runs',
        path: path,
        message: 'Exactly one raw run object per measured run is required.',
      ),
    ];
  }

  final durationSeconds = _integerAt(scenario, 'durationSeconds');
  if (durationSeconds == null || sampleIntervalMs == null) {
    return [
      EvaluationIssue(
        kind: 'invalid-raw-runs',
        path: path,
        message: 'Valid scenario duration and sample interval are required.',
      ),
    ];
  }

  final issues = <EvaluationIssue>[];
  final runIds = <String>{};
  final processIds = <int>{};
  final rssSamples = <double>[];
  final cpuSamples = <double>[];
  final missedRatioSamples = <double>[];
  final flutterFrameSamples = <double>[];
  final startupSamples = <double>[];
  final firstVideoFrameSamples = <double>[];
  final hiddenFrameSamples = <double>[];
  final decoderSamples = <double>[];
  final hiddenDecoderSamples = <double>[];
  final downloadOverheadSamples = <double>[];
  final rssAt15sSamples = <double>[];
  final backgroundCpuSamples = <double>[];
  final retainedGrowthSamples = <double>[];
  final requiresPreCapture = {
    'large-mp3-mp4-download',
    'rapid-track-switch-20',
    'video-enable-disable-30',
  }.contains(scenarioId);
  final isVideoScenario =
      _requiredScenarioMetrics[scenarioId]?.contains('decoderEvidence') ??
      false;
  final expectedDurationMs = durationSeconds * 1000.0;

  for (var index = 0; index < rawRuns.length; index += 1) {
    final runPath = '$path[$index]';
    final run = _asMap(rawRuns[index]);
    if (run == null) {
      issues.add(
        EvaluationIssue(
          kind: 'invalid-raw-run',
          path: runPath,
          message: 'Raw run must be an object.',
        ),
      );
      continue;
    }

    if (_integerAt(run, 'index') != index + 1) {
      issues.add(
        EvaluationIssue(
          kind: 'invalid-raw-run',
          path: '$runPath.index',
          message: 'Raw run index must be ${index + 1}.',
        ),
      );
    }

    final runId = _stringAt(run, 'runId');
    if (runId == null || runId.trim().isEmpty || !runIds.add(runId)) {
      issues.add(
        EvaluationIssue(
          kind: 'non-fresh-run',
          path: '$runPath.runId',
          message: 'Every measured run needs a distinct non-empty runId.',
        ),
      );
    }
    final processId = _integerAt(run, 'processId');
    if (processId == null || processId <= 0 || !processIds.add(processId)) {
      issues.add(
        EvaluationIssue(
          kind: 'non-fresh-run',
          path: '$runPath.processId',
          message: 'Every measured run needs a distinct positive processId.',
        ),
      );
    }

    final resources = _readRawResourceSamples(run['resourceSamples']);
    if (resources == null || resources.isEmpty) {
      issues.add(
        EvaluationIssue(
          kind: 'invalid-resource-samples',
          path: '$runPath.resourceSamples',
          message:
              'resourceSamples must be finite and strictly increasing by elapsedMs.',
        ),
      );
    } else {
      issues.addAll(
        _validateResourceSampleCadence(
          path: '$runPath.resourceSamples',
          samples: resources,
          expectedDurationMs: expectedDurationMs,
          sampleIntervalMs: sampleIntervalMs,
        ),
      );
    }

    final preCapture = _readRawResourceSamples(
      run['preCaptureResourceSamples'],
      allowEmpty: true,
    );
    if (preCapture == null || (requiresPreCapture && preCapture.isEmpty)) {
      issues.add(
        EvaluationIssue(
          kind: 'invalid-pre-capture-samples',
          path: '$runPath.preCaptureResourceSamples',
          message: requiresPreCapture
              ? 'This scenario requires finite pre-capture resource samples.'
              : 'Pre-capture samples must be finite and strictly increasing.',
        ),
      );
    }

    final actualDurationMs = _numAt(run, 'actualDurationMs');
    final minimumDurationMs = expectedDurationMs - sampleIntervalMs;
    final maximumDurationMs = expectedDurationMs + sampleIntervalMs * 2;
    if (actualDurationMs == null ||
        !actualDurationMs.isFinite ||
        actualDurationMs < minimumDurationMs ||
        actualDurationMs > maximumDurationMs) {
      issues.add(
        EvaluationIssue(
          kind: 'invalid-raw-duration',
          path: '$runPath.actualDurationMs',
          message:
              'actualDurationMs must be between $minimumDurationMs and $maximumDurationMs.',
        ),
      );
    } else if (resources != null &&
        resources.isNotEmpty &&
        (actualDurationMs - resources.last.elapsedMs).abs() > 1) {
      issues.add(
        EvaluationIssue(
          kind: 'invalid-raw-duration',
          path: '$runPath.actualDurationMs',
          message: 'actualDurationMs must match the final resource sample.',
        ),
      );
    }

    if (resources != null && resources.isNotEmpty) {
      rssSamples.add(
        _median(resources.map((sample) => sample.rssMiB).toList()),
      );
      cpuSamples.add(
        _average(resources.map((sample) => sample.cpuPercent).toList()),
      );
    }

    final frame = _asMap(run['frameResult']);
    if (frame == null) {
      issues.add(
        EvaluationIssue(
          kind: 'invalid-frame-result',
          path: '$runPath.frameResult',
          message: 'Raw frameResult object is required.',
        ),
      );
    } else {
      if (_integerAt(frame, 'frameBudgetMicros') != 16667) {
        issues.add(
          EvaluationIssue(
            kind: 'invalid-frame-result',
            path: '$runPath.frameResult.frameBudgetMicros',
            message: 'Raw frame budget must equal 16667.',
          ),
        );
      }
      final totalFrames = _integerAt(frame, 'totalFrames');
      final missedFrames = _integerAt(frame, 'missedFrames');
      final hiddenFrames = _integerAt(frame, 'hiddenFlutterFrames');
      final hiddenFramesAfterRelease = _integerAt(
        frame,
        'hiddenFlutterFramesAfterRelease',
      );
      if (totalFrames == null ||
          totalFrames < 0 ||
          missedFrames == null ||
          missedFrames < 0 ||
          missedFrames > totalFrames ||
          hiddenFrames == null ||
          hiddenFrames < 0 ||
          hiddenFrames > totalFrames ||
          (scenarioId == 'minimize-video-five-minutes-restore' &&
              (hiddenFramesAfterRelease == null ||
                  hiddenFramesAfterRelease < 0 ||
                  hiddenFramesAfterRelease > hiddenFrames))) {
        issues.add(
          EvaluationIssue(
            kind: 'invalid-frame-result',
            path: '$runPath.frameResult',
            message: 'Raw Flutter frame counters are invalid.',
          ),
        );
      } else {
        flutterFrameSamples.add(totalFrames.toDouble());
        if (scenarioId == 'minimize-video-five-minutes-restore') {
          hiddenFrameSamples.add(hiddenFramesAfterRelease!.toDouble());
        }
        final rawRatio = frame['missedFrameRatioPercent'];
        if (totalFrames == 0) {
          if (scenarioId != 'idle-home-five-minutes' || rawRatio != null) {
            issues.add(
              EvaluationIssue(
                kind: 'invalid-frame-result',
                path: '$runPath.frameResult.missedFrameRatioPercent',
                message:
                    'Only idle may report zero frames, with a null raw ratio.',
              ),
            );
          }
          missedRatioSamples.add(0);
        } else {
          final expectedRatio = missedFrames * 100 / totalFrames;
          if (rawRatio is! num ||
              !rawRatio.toDouble().isFinite ||
              !_nearlyEqual(rawRatio.toDouble(), expectedRatio)) {
            issues.add(
              EvaluationIssue(
                kind: 'invalid-frame-result',
                path: '$runPath.frameResult.missedFrameRatioPercent',
                message: 'Raw missed-frame ratio does not match frame counts.',
              ),
            );
          }
          missedRatioSamples.add(expectedRatio);
        }
      }

      issues.addAll(
        _validateRawScenarioEvidence(
          path: '$runPath.frameResult.scenarioEvidence',
          scenarioId: scenarioId,
          evidence: _asMap(frame['scenarioEvidence']),
        ),
      );

      if (scenarioId == 'minimize-video-five-minutes-restore') {
        final firstFrame = _numAt(frame, 'firstFrameAfterRestoreMs');
        if (firstFrame == null || !firstFrame.isFinite || firstFrame < 0) {
          issues.add(
            EvaluationIssue(
              kind: 'invalid-frame-result',
              path: '$runPath.frameResult.firstFrameAfterRestoreMs',
              message: 'Restore scenario requires a finite first-frame time.',
            ),
          );
        } else {
          firstVideoFrameSamples.add(firstFrame);
        }
      }
    }

    if (scenarioId == 'cold-start-server-offline') {
      final startup = _numAt(run, 'startupTimeMs');
      if (startup == null || !startup.isFinite || startup < 0) {
        issues.add(
          EvaluationIssue(
            kind: 'invalid-startup-time',
            path: '$runPath.startupTimeMs',
            message: 'Cold-start run requires a finite startupTimeMs.',
          ),
        );
      } else {
        startupSamples.add(startup);
      }
    }

    if (isVideoScenario) {
      final decoder = _numAt(run, 'decoderMaximumUtilizationPercent');
      if (decoder == null || !decoder.isFinite || decoder <= 0) {
        issues.add(
          EvaluationIssue(
            kind: 'invalid-decoder-samples',
            path: '$runPath.decoderMaximumUtilizationPercent',
            message: 'Video run requires positive raw decoder utilization.',
          ),
        );
      } else {
        decoderSamples.add(decoder);
      }
    }
    if (scenarioId == 'minimize-video-five-minutes-restore') {
      final hiddenDecoder = _numAt(
        run,
        'hiddenDecoderMaximumUtilizationPercent',
      );
      if (hiddenDecoder == null ||
          !hiddenDecoder.isFinite ||
          hiddenDecoder < 0 ||
          hiddenDecoder > 0.05) {
        issues.add(
          EvaluationIssue(
            kind: 'invalid-hidden-decoder-samples',
            path: '$runPath.hiddenDecoderMaximumUtilizationPercent',
            message:
                'Minimized video run requires raw decoder utilization from 0 to 0.05%.',
          ),
        );
      } else {
        hiddenDecoderSamples.add(hiddenDecoder);
      }
    }

    if (resources == null || resources.isEmpty) {
      continue;
    }
    if (scenarioId == 'large-mp3-mp4-download' &&
        preCapture != null &&
        preCapture.isNotEmpty) {
      final peakRss = resources
          .map((sample) => sample.rssMiB)
          .reduce((left, right) => left > right ? left : right);
      final preRss = _median(
        preCapture.map((sample) => sample.rssMiB).toList(),
      );
      final overhead = peakRss - preRss;
      downloadOverheadSamples.add(overhead < 0 ? 0 : overhead);
    }
    if (scenarioId == 'minimize-video-five-minutes-restore') {
      final rssAt15 = _rawWindowStatistic(
        resources,
        startMs: 13000,
        endMs: 15000,
        value: (sample) => sample.rssMiB,
        statistic: 'median',
      );
      final backgroundCpu = _rawWindowStatistic(
        resources,
        startMs: 15000,
        endMs: expectedDurationMs,
        value: (sample) => sample.cpuPercent,
        statistic: 'average',
      );
      if (rssAt15 == null || backgroundCpu == null) {
        issues.add(
          EvaluationIssue(
            kind: 'invalid-resource-window',
            path: '$runPath.resourceSamples',
            message: 'Minimize resource windows contain no samples.',
          ),
        );
      } else {
        rssAt15sSamples.add(rssAt15);
        backgroundCpuSamples.add(backgroundCpu);
      }
    }
    if ({
          'rapid-track-switch-20',
          'video-enable-disable-30',
        }.contains(scenarioId) &&
        preCapture != null &&
        preCapture.isNotEmpty) {
      final windowStart = scenarioId == 'rapid-track-switch-20'
          ? 30000.0
          : 90000.0;
      final settledRss = _rawWindowStatistic(
        resources,
        startMs: windowStart,
        endMs: expectedDurationMs,
        value: (sample) => sample.rssMiB,
        statistic: 'median',
      );
      if (settledRss == null) {
        issues.add(
          EvaluationIssue(
            kind: 'invalid-resource-window',
            path: '$runPath.resourceSamples',
            message: 'Retained-growth resource window contains no samples.',
          ),
        );
      } else {
        final preRss = _median(
          preCapture.map((sample) => sample.rssMiB).toList(),
        );
        final growth = settledRss - preRss;
        retainedGrowthSamples.add(growth < 0 ? 0 : growth);
      }
    }
  }

  final expectedMetrics = <String, List<double>>{
    'rssMiB': rssSamples,
    'cpuPercent': cpuSamples,
    'missedFrameRatioPercent': missedRatioSamples,
    'flutterFrameCount': flutterFrameSamples,
    if (scenarioId == 'cold-start-server-offline')
      'startupTimeMs': startupSamples,
    if (scenarioId == 'minimize-video-five-minutes-restore') ...{
      'firstVideoFrameMs': firstVideoFrameSamples,
      'hiddenFlutterFramesAfterRelease': hiddenFrameSamples,
      'rssAt15sMiB': rssAt15sSamples,
      'backgroundCpuPercent': backgroundCpuSamples,
    },
    if (scenarioId == 'large-mp3-mp4-download')
      'downloadRssOverheadMiB': downloadOverheadSamples,
    if ({
      'rapid-track-switch-20',
      'video-enable-disable-30',
    }.contains(scenarioId))
      'retainedRssGrowthMiB': retainedGrowthSamples,
  };
  final metrics = _mapAt(scenario, 'metrics');
  for (final entry in expectedMetrics.entries) {
    if (entry.value.length == rawRuns.length) {
      issues.addAll(
        _validateRawMetricSamples(
          path: '$label.scenarios.$scenarioId.metrics.${entry.key}.samples',
          metric: _asMap(metrics[entry.key]),
          expected: entry.value,
        ),
      );
    }
  }
  if (isVideoScenario && decoderSamples.length == rawRuns.length) {
    final decoderMetric = _asMap(metrics['decoderEvidence']);
    issues.addAll(
      _validateRawSampleList(
        path:
            '$label.scenarios.$scenarioId.metrics.decoderEvidence.positiveRunSamples',
        actual: decoderMetric?['positiveRunSamples'],
        expected: decoderSamples,
      ),
    );
    if (scenarioId == 'minimize-video-five-minutes-restore' &&
        hiddenDecoderSamples.length == rawRuns.length) {
      issues.addAll(
        _validateRawSampleList(
          path:
              '$label.scenarios.$scenarioId.metrics.decoderEvidence.hiddenMaximumRunSamples',
          actual: decoderMetric?['hiddenMaximumRunSamples'],
          expected: hiddenDecoderSamples,
        ),
      );
    }
  }

  return issues;
}

List<_RawResourceSample>? _readRawResourceSamples(
  Object? raw, {
  bool allowEmpty = false,
}) {
  if (raw is! List || (!allowEmpty && raw.isEmpty)) {
    return null;
  }
  final result = <_RawResourceSample>[];
  var previousElapsed = -1.0;
  for (final rawSample in raw) {
    final sample = _asMap(rawSample);
    final elapsedMs = _numAt(sample, 'elapsedMs');
    final rssMiB = _numAt(sample, 'rssMiB');
    final cpuPercent = _numAt(sample, 'cpuPercent');
    if (sample == null ||
        elapsedMs == null ||
        !elapsedMs.isFinite ||
        elapsedMs < 0 ||
        elapsedMs <= previousElapsed ||
        rssMiB == null ||
        !rssMiB.isFinite ||
        rssMiB < 0 ||
        cpuPercent == null ||
        !cpuPercent.isFinite ||
        cpuPercent < 0) {
      return null;
    }
    result.add(
      _RawResourceSample(
        elapsedMs: elapsedMs,
        rssMiB: rssMiB,
        cpuPercent: cpuPercent,
      ),
    );
    previousElapsed = elapsedMs;
  }
  return result;
}

List<EvaluationIssue> _validateResourceSampleCadence({
  required String path,
  required List<_RawResourceSample> samples,
  required double expectedDurationMs,
  required int sampleIntervalMs,
}) {
  final expectedCount = (expectedDurationMs / sampleIntervalMs).floor();
  final calculatedMinimum = (expectedCount * 0.9).floor();
  final minimumCount = calculatedMinimum < 1 ? 1 : calculatedMinimum;
  final gaps = <double>[];
  for (var index = 1; index < samples.length; index += 1) {
    gaps.add(samples[index].elapsedMs - samples[index - 1].elapsedMs);
  }
  final lateFirstSample = samples.first.elapsedMs > sampleIntervalMs * 2;
  final sparseGaps =
      gaps.isNotEmpty &&
      (gaps.reduce((left, right) => left > right ? left : right) >
              sampleIntervalMs * 2 ||
          _nearestRankP95(gaps) > sampleIntervalMs * 1.5);
  if (samples.length < minimumCount || lateFirstSample || sparseGaps) {
    return [
      EvaluationIssue(
        kind: 'sparse-resource-samples',
        path: path,
        message: 'Resource samples do not satisfy count and cadence gates.',
      ),
    ];
  }
  return const [];
}

List<EvaluationIssue> _validateRawScenarioEvidence({
  required String path,
  required String scenarioId,
  required Map<String, Object?>? evidence,
}) {
  final expectedActions = _expectedScenarioActions[scenarioId];
  final expectedActionStartDelay = _requiredActionStartDelays[scenarioId];
  final expectedActionCadence = _requiredActionCadences[scenarioId];
  final actionStartDelay = expectedActionStartDelay ?? 0;
  final actionCadence = expectedActionCadence ?? 0;
  if (evidence == null ||
      evidence['ready'] != true ||
      !_hasValidCaptureWindow(evidence, scenarioId) ||
      evidence['actionCompleted'] != true ||
      (evidence['actionError'] != null &&
          (evidence['actionError'] is! String ||
              (evidence['actionError'] as String).trim().isNotEmpty)) ||
      _integerAt(evidence, 'expectedActions') != expectedActions ||
      _integerAt(evidence, 'completedActions') != expectedActions ||
      _stringAt(evidence, 'serverBaseUrl') != _benchmarkServerBaseUrl ||
      _integerAt(evidence, 'actionStartDelayMs') != expectedActionStartDelay ||
      _integerAt(evidence, 'actionCadenceMs') != expectedActionCadence) {
    return [
      EvaluationIssue(
        kind: 'invalid-raw-scenario-evidence',
        path: path,
        message: 'Raw scenario evidence does not satisfy action contract.',
      ),
    ];
  }

  if (actionStartDelay > 0 || actionCadence > 0) {
    final actionElapsedMs = _numericSamples(evidence['actionElapsedMs']);
    if (actionElapsedMs == null || actionElapsedMs.length != expectedActions) {
      return [
        EvaluationIssue(
          kind: 'invalid-action-timestamps',
          path: '$path.actionElapsedMs',
          message: 'Scheduled actions require one timestamp per action.',
        ),
      ];
    }
    const earlyToleranceMs = 25.0;
    const lateToleranceMs = 250.0;
    for (var index = 0; index < actionElapsedMs.length; index += 1) {
      final expectedTimestamp = actionStartDelay + actionCadence * index;
      if (actionElapsedMs[index] < expectedTimestamp - earlyToleranceMs ||
          actionElapsedMs[index] > expectedTimestamp + lateToleranceMs) {
        return [
          EvaluationIssue(
            kind: 'invalid-action-timestamps',
            path: '$path.actionElapsedMs[$index]',
            message: 'Action does not match its absolute schedule deadline.',
          ),
        ];
      }
    }
  }
  if (_visibleVideoScenarios.contains(scenarioId) &&
      (_integerAt(evidence, 'videoProgressEvents') == null ||
          _integerAt(evidence, 'videoProgressEvents')! < 2 ||
          _numAt(evidence, 'videoPositionAdvanceMs') == null ||
          _numAt(evidence, 'videoPositionAdvanceMs')! < 1000 ||
          _integerAt(evidence, 'videoPlayingSamples') == null ||
          _integerAt(evidence, 'videoPlayingSamples')! < 2)) {
    return [
      EvaluationIssue(
        kind: 'invalid-video-progress-evidence',
        path: path,
        message: 'Visible video scenario lacks sustained position evidence.',
      ),
    ];
  }
  if (scenarioId == 'minimize-video-five-minutes-restore') {
    final releaseMs = _numAt(evidence, 'videoControllerReleasedAfterHiddenMs');
    if (releaseMs == null || releaseMs < 400 || releaseMs > 1000) {
      return [
        EvaluationIssue(
          kind: 'invalid-video-release-evidence',
          path: '$path.videoControllerReleasedAfterHiddenMs',
          message:
              'Hidden video controller must be released near the 500 ms target.',
        ),
      ];
    }
  }
  return const [];
}

List<EvaluationIssue> _validateRawMetricSamples({
  required String path,
  required Map<String, Object?>? metric,
  required List<double> expected,
}) => _validateRawSampleList(
  path: path,
  actual: metric?['samples'],
  expected: expected,
);

List<EvaluationIssue> _validateRawSampleList({
  required String path,
  required Object? actual,
  required List<double> expected,
}) {
  final samples = _numericSamples(actual);
  if (samples == null ||
      samples.length != expected.length ||
      List.generate(
        expected.length,
        (index) => index,
      ).any((index) => !_nearlyEqual(samples[index], expected[index]))) {
    return [
      EvaluationIssue(
        kind: 'raw-metric-mismatch',
        path: path,
        message: 'Claimed run samples do not match recomputed raw-run values.',
      ),
    ];
  }
  return const [];
}

double? _rawWindowStatistic(
  List<_RawResourceSample> samples, {
  required double startMs,
  required double endMs,
  required double Function(_RawResourceSample sample) value,
  required String statistic,
}) {
  final values = samples
      .where(
        (sample) => sample.elapsedMs >= startMs && sample.elapsedMs < endMs,
      )
      .map(value)
      .toList();
  if (values.isEmpty) {
    return null;
  }
  return statistic == 'average' ? _average(values) : _median(values);
}

double _average(List<double> values) =>
    values.reduce((left, right) => left + right) / values.length;

List<EvaluationIssue> _validateScenarioEvidence({
  required String label,
  required String scenarioId,
  required Map<String, Object?> scenario,
}) {
  final path = '$label.scenarios.$scenarioId.scenarioEvidence';
  final evidence = _asMap(scenario['scenarioEvidence']);
  if (evidence == null) {
    return [
      EvaluationIssue(
        kind: 'missing-scenario-evidence',
        path: path,
        message: 'scenarioEvidence object is required.',
      ),
    ];
  }

  final issues = <EvaluationIssue>[];
  if (!_hasValidCaptureWindow(evidence, scenarioId)) {
    issues.add(
      EvaluationIssue(
        kind: 'invalid-capture-window',
        path: path,
        message:
            'Frame capture must be explicitly bounded to the resource window.',
      ),
    );
  }
  if (_stringAt(evidence, 'serverBaseUrl') != _benchmarkServerBaseUrl) {
    issues.add(
      EvaluationIssue(
        kind: 'invalid-scenario-evidence',
        path: '$path.serverBaseUrl',
        message: 'serverBaseUrl must use the isolated benchmark endpoint.',
      ),
    );
  }
  if (_visibleVideoScenarios.contains(scenarioId) &&
      (_integerAt(evidence, 'videoProgressEvents') == null ||
          _integerAt(evidence, 'videoProgressEvents')! < 2 ||
          _numAt(evidence, 'videoPositionAdvanceMs') == null ||
          _numAt(evidence, 'videoPositionAdvanceMs')! < 1000 ||
          _integerAt(evidence, 'videoPlayingSamples') == null ||
          _integerAt(evidence, 'videoPlayingSamples')! < 2)) {
    issues.add(
      EvaluationIssue(
        kind: 'invalid-video-progress-evidence',
        path: path,
        message: 'Visible video scenario lacks sustained position evidence.',
      ),
    );
  }
  if (scenarioId == 'minimize-video-five-minutes-restore') {
    final releaseMs = _numAt(evidence, 'videoControllerReleasedAfterHiddenMs');
    if (releaseMs == null || releaseMs < 400 || releaseMs > 1000) {
      issues.add(
        EvaluationIssue(
          kind: 'invalid-video-release-evidence',
          path: '$path.videoControllerReleasedAfterHiddenMs',
          message:
              'Hidden video controller must be released near the 500 ms target.',
        ),
      );
    }
  }
  if (evidence['ready'] != true) {
    issues.add(
      EvaluationIssue(
        kind: 'invalid-scenario-evidence',
        path: '$path.ready',
        message: 'ready must be true.',
      ),
    );
  }
  if (evidence['actionCompleted'] != true) {
    issues.add(
      EvaluationIssue(
        kind: 'invalid-scenario-evidence',
        path: '$path.actionCompleted',
        message: 'actionCompleted must be true.',
      ),
    );
  }

  final actionError = evidence['actionError'];
  if (actionError != null &&
      (actionError is! String || actionError.trim().isNotEmpty)) {
    issues.add(
      EvaluationIssue(
        kind: 'scenario-action-error',
        path: '$path.actionError',
        message: 'actionError must be absent or empty.',
      ),
    );
  }

  final expectedContract = _expectedScenarioActions[scenarioId];
  final expectedActions = _integerAt(evidence, 'expectedActions');
  final completedActions = _integerAt(evidence, 'completedActions');
  if (expectedActions == null ||
      expectedActions < 0 ||
      (expectedContract != null && expectedActions != expectedContract)) {
    issues.add(
      EvaluationIssue(
        kind: 'invalid-scenario-evidence',
        path: '$path.expectedActions',
        message: expectedContract == null
            ? 'expectedActions must be a non-negative integer.'
            : 'expectedActions must equal contract value $expectedContract.',
      ),
    );
  }
  if (completedActions == null ||
      completedActions < 0 ||
      completedActions != (expectedContract ?? expectedActions)) {
    issues.add(
      EvaluationIssue(
        kind: 'incomplete-scenario-action',
        path: '$path.completedActions',
        message: expectedContract == null
            ? 'completedActions must equal expectedActions.'
            : 'completedActions must equal expected contract value $expectedContract.',
      ),
    );
  }

  final expectedActionStartDelay = _requiredActionStartDelays[scenarioId];
  if (_integerAt(evidence, 'actionStartDelayMs') != expectedActionStartDelay) {
    issues.add(
      EvaluationIssue(
        kind: 'invalid-scenario-evidence',
        path: '$path.actionStartDelayMs',
        message:
            'actionStartDelayMs must equal contract value $expectedActionStartDelay.',
      ),
    );
  }
  final expectedActionCadence = _requiredActionCadences[scenarioId];
  if (_integerAt(evidence, 'actionCadenceMs') != expectedActionCadence) {
    issues.add(
      EvaluationIssue(
        kind: 'invalid-scenario-evidence',
        path: '$path.actionCadenceMs',
        message:
            'actionCadenceMs must equal contract value $expectedActionCadence.',
      ),
    );
  }

  return issues;
}

bool _hasValidCaptureWindow(Map<String, Object?> evidence, String scenarioId) {
  if (evidence['captureStarted'] != true || evidence['captureEnded'] != true) {
    return false;
  }
  final durationMs = _numAt(evidence, 'captureDurationMs');
  final expectedSeconds = _requiredScenarioDurations[scenarioId];
  if (durationMs == null || durationMs <= 0 || expectedSeconds == null) {
    return false;
  }
  final expectedMs = expectedSeconds * 1000.0;
  if (scenarioId == 'cold-start-server-offline') {
    return durationMs >= expectedMs - 5000 && durationMs <= expectedMs + 2000;
  }
  final maximumOverhead = scenarioId == 'minimize-video-five-minutes-restore'
      ? 15000.0
      : 2000.0;
  return durationMs >= expectedMs - 1000 &&
      durationMs <= expectedMs + maximumOverhead;
}

List<EvaluationIssue> _validateDecoderEvidence({
  required String metricPath,
  required Map<String, Object?> metric,
  required String? platform,
  required int? measuredRuns,
  required String scenarioId,
}) {
  final issues = <EvaluationIssue>[];
  final evidence = _stringAt(metric, 'evidence');
  if (evidence == null || evidence.trim().isEmpty) {
    issues.add(
      EvaluationIssue(
        kind: 'missing-evidence',
        path: '$metricPath.evidence',
        message: 'Decoder/backend evidence is required.',
      ),
    );
  }
  if (metric['runtimeVerified'] != true) {
    issues.add(
      EvaluationIssue(
        kind: 'unverified-decoder',
        path: '$metricPath.runtimeVerified',
        message: 'runtimeVerified must be true.',
      ),
    );
  }

  final probeKind = _stringAt(metric, 'probeKind');
  if (platform == 'windows') {
    if (probeKind != 'windows-gpu-engine-videodecode') {
      issues.add(
        EvaluationIssue(
          kind: 'invalid-decoder-probe',
          path: '$metricPath.probeKind',
          message:
              'Windows decoder probe must be "windows-gpu-engine-videodecode".',
        ),
      );
    }
  } else if (probeKind == null || probeKind.trim().isEmpty) {
    issues.add(
      EvaluationIssue(
        kind: 'invalid-decoder-probe',
        path: '$metricPath.probeKind',
        message: 'Decoder probe kind is required.',
      ),
    );
  }

  final positiveSamples = metric['positiveRunSamples'];
  if (positiveSamples is! List ||
      measuredRuns == null ||
      positiveSamples.length != measuredRuns ||
      positiveSamples.any(
        (sample) =>
            sample is! num || !sample.toDouble().isFinite || sample <= 0,
      )) {
    issues.add(
      EvaluationIssue(
        kind: 'invalid-decoder-samples',
        path: '$metricPath.positiveRunSamples',
        message:
            'positiveRunSamples must contain one positive numeric value per measured run.',
      ),
    );
  }

  if (scenarioId == 'minimize-video-five-minutes-restore') {
    final hiddenSamples = metric['hiddenMaximumRunSamples'];
    if (hiddenSamples is! List ||
        measuredRuns == null ||
        hiddenSamples.length != measuredRuns ||
        hiddenSamples.any(
          (sample) =>
              sample is! num ||
              !sample.toDouble().isFinite ||
              sample < 0 ||
              sample > 0.05,
        )) {
      issues.add(
        EvaluationIssue(
          kind: 'invalid-hidden-decoder-samples',
          path: '$metricPath.hiddenMaximumRunSamples',
          message:
              'hiddenMaximumRunSamples must contain one numeric value from 0 to 0.05% per measured run.',
        ),
      );
    }
  }

  return issues;
}

List<EvaluationIssue> _validateNumericMetric({
  required String metricPath,
  required Map<String, Object?> metric,
  required int? measuredRuns,
}) {
  final samples = _numericSamples(metric['samples']);
  if (samples == null ||
      samples.isEmpty ||
      measuredRuns == null ||
      samples.length != measuredRuns) {
    return [
      EvaluationIssue(
        kind: 'invalid-samples',
        path: '$metricPath.samples',
        message:
            'Metric must contain one finite numeric sample per measured run.',
      ),
    ];
  }

  final expectedStats = {
    'median': _median(samples),
    'p95': _nearestRankP95(samples),
  };
  final issues = <EvaluationIssue>[];
  for (final stat in expectedStats.entries) {
    final claimed = _numAt(metric, stat.key);
    if (claimed == null || !claimed.isFinite) {
      issues.add(
        EvaluationIssue(
          kind: 'missing-stat',
          path: '$metricPath.${stat.key}',
          message: 'Metric must contain a finite ${stat.key} statistic.',
        ),
      );
    } else if (!_nearlyEqual(claimed, stat.value)) {
      issues.add(
        EvaluationIssue(
          kind: 'stat-mismatch',
          path: '$metricPath.${stat.key}',
          message:
              'Claimed ${stat.key} $claimed does not match recomputed value ${stat.value}.',
        ),
      );
    }
  }
  return issues;
}

List<EvaluationIssue> _validateFrameCounts({
  required String scenarioId,
  required String metricPath,
  required Map<String, Object?> metric,
}) {
  final samples = _numericSamples(metric['samples']);
  if (samples == null) {
    return const [];
  }

  final requirePositive = _visibleFrameScenarios.contains(scenarioId);
  if (samples.any(
    (sample) =>
        sample < 0 ||
        sample != sample.truncateToDouble() ||
        (requirePositive && sample <= 0),
  )) {
    return [
      EvaluationIssue(
        kind: 'invalid-frame-count',
        path: '$metricPath.samples',
        message: requirePositive
            ? 'Every measured run must contain a positive integer Flutter frame count.'
            : 'Flutter frame counts must be non-negative integers.',
      ),
    ];
  }
  return const [];
}

List<EvaluationIssue> _validateIdleFrameConsistency({
  required String label,
  required Map<String, Object?> scenario,
}) {
  final metrics = _mapAt(scenario, 'metrics');
  final frameMetric = _asMap(metrics['flutterFrameCount']);
  final missedMetric = _asMap(metrics['missedFrameRatioPercent']);
  final frameSamples = _numericSamples(frameMetric?['samples']);
  final missedSamples = _numericSamples(missedMetric?['samples']);
  if (frameSamples == null ||
      missedSamples == null ||
      frameSamples.length != missedSamples.length) {
    return const [];
  }

  for (var index = 0; index < frameSamples.length; index += 1) {
    if (frameSamples[index] == 0 && missedSamples[index] != 0) {
      return [
        EvaluationIssue(
          kind: 'invalid-frame-ratio',
          path:
              '$label.scenarios.idle-home-five-minutes.metrics.missedFrameRatioPercent.samples[$index]',
          message: 'A zero frame count requires a zero missed-frame ratio.',
        ),
      ];
    }
  }
  return const [];
}

void _evaluateCandidateSafetyGates({
  required Map<String, Map<String, Object?>> baselineScenarios,
  required Map<String, Map<String, Object?>> candidateScenarios,
  required List<EvaluationIssue> issues,
  required List<MetricComparison> comparisons,
}) {
  for (final scenario in _requiredScenarioMetrics.keys) {
    _evaluateRelativeGate(
      baselineScenarios: baselineScenarios,
      candidateScenarios: candidateScenarios,
      scenario: scenario,
      metric: 'cpuPercent',
      stat: 'median',
      maximumRegressionPercent: 10,
      issues: issues,
      comparisons: comparisons,
    );
    _evaluateAbsoluteGate(
      baselineScenarios: baselineScenarios,
      candidateScenarios: candidateScenarios,
      scenario: scenario,
      metric: 'missedFrameRatioPercent',
      stat: 'p95',
      limit: 1,
      issues: issues,
      comparisons: comparisons,
    );
  }
  _evaluateRelativeGate(
    baselineScenarios: baselineScenarios,
    candidateScenarios: candidateScenarios,
    scenario: 'audio-only-ten-minutes',
    metric: 'rssMiB',
    stat: 'median',
    maximumRegressionPercent: 5,
    issues: issues,
    comparisons: comparisons,
  );
  for (final scenario in const [
    'local-video-30fps-ten-minutes',
    'local-video-60fps-ten-minutes',
  ]) {
    _evaluateRelativeGate(
      baselineScenarios: baselineScenarios,
      candidateScenarios: candidateScenarios,
      scenario: scenario,
      metric: 'rssMiB',
      stat: 'median',
      maximumRegressionPercent: 0,
      issues: issues,
      comparisons: comparisons,
    );
  }
  _evaluateRelativeGate(
    baselineScenarios: baselineScenarios,
    candidateScenarios: candidateScenarios,
    scenario: 'cold-start-server-offline',
    metric: 'startupTimeMs',
    stat: 'p95',
    maximumRegressionPercent: 10,
    issues: issues,
    comparisons: comparisons,
  );
  _evaluateRelativeGate(
    baselineScenarios: baselineScenarios,
    candidateScenarios: candidateScenarios,
    scenario: 'minimize-video-five-minutes-restore',
    metric: 'firstVideoFrameMs',
    stat: 'p95',
    maximumRegressionPercent: 10,
    issues: issues,
    comparisons: comparisons,
  );
  _evaluateAbsoluteGate(
    baselineScenarios: baselineScenarios,
    candidateScenarios: candidateScenarios,
    scenario: 'minimize-video-five-minutes-restore',
    metric: 'firstVideoFrameMs',
    stat: 'p95',
    limit: 1000,
    issues: issues,
    comparisons: comparisons,
  );
  _evaluateAbsoluteGate(
    baselineScenarios: baselineScenarios,
    candidateScenarios: candidateScenarios,
    scenario: 'minimize-video-five-minutes-restore',
    metric: 'hiddenFlutterFramesAfterRelease',
    stat: 'p95',
    limit: 0,
    issues: issues,
    comparisons: comparisons,
  );

  final candidateAudioRss = _metricStat(
    candidateScenarios,
    'audio-only-ten-minutes',
    'rssMiB',
    'median',
  );
  final candidateMinimizedRss = _metricStat(
    candidateScenarios,
    'minimize-video-five-minutes-restore',
    'rssAt15sMiB',
    'median',
  );
  if (candidateAudioRss != null && candidateMinimizedRss != null) {
    final limit = candidateAudioRss + 20;
    final status = candidateMinimizedRss <= limit ? 'pass' : 'regression';
    comparisons.add(
      MetricComparison(
        scenario: 'minimize-video-five-minutes-restore',
        metric: 'rssAt15sMiB-vs-candidate-audio',
        stat: 'median',
        baseline: candidateAudioRss,
        candidate: candidateMinimizedRss,
        limit: limit,
        status: status,
      ),
    );
    if (status == 'regression') {
      issues.add(
        EvaluationIssue(
          kind: 'regression',
          path:
              'candidate.scenarios.minimize-video-five-minutes-restore.metrics.rssAt15sMiB',
          message:
              'Minimized RSS $candidateMinimizedRss MiB exceeds candidate audio RSS plus 20 MiB ($limit MiB).',
        ),
      );
    }
  }

  _evaluateAbsoluteGate(
    baselineScenarios: baselineScenarios,
    candidateScenarios: candidateScenarios,
    scenario: 'minimize-video-five-minutes-restore',
    metric: 'backgroundCpuPercent',
    stat: 'median',
    limit: 1,
    issues: issues,
    comparisons: comparisons,
  );
  _evaluateAbsoluteGate(
    baselineScenarios: baselineScenarios,
    candidateScenarios: candidateScenarios,
    scenario: 'large-mp3-mp4-download',
    metric: 'downloadRssOverheadMiB',
    stat: 'p95',
    limit: 32,
    issues: issues,
    comparisons: comparisons,
  );
  for (final scenario in const [
    'rapid-track-switch-20',
    'video-enable-disable-30',
  ]) {
    _evaluateAbsoluteGate(
      baselineScenarios: baselineScenarios,
      candidateScenarios: candidateScenarios,
      scenario: scenario,
      metric: 'retainedRssGrowthMiB',
      stat: 'p95',
      limit: 10,
      issues: issues,
      comparisons: comparisons,
    );
  }
}

void _evaluateRelativeGate({
  required Map<String, Map<String, Object?>> baselineScenarios,
  required Map<String, Map<String, Object?>> candidateScenarios,
  required String scenario,
  required String metric,
  required String stat,
  required double maximumRegressionPercent,
  required List<EvaluationIssue> issues,
  required List<MetricComparison> comparisons,
}) {
  final baselineValue = _metricStat(baselineScenarios, scenario, metric, stat);
  final candidateValue = _metricStat(
    candidateScenarios,
    scenario,
    metric,
    stat,
  );
  if (baselineValue == null || candidateValue == null) {
    return;
  }
  final limit = baselineValue * (1 + maximumRegressionPercent / 100);
  final status = candidateValue <= limit ? 'pass' : 'regression';
  comparisons.add(
    MetricComparison(
      scenario: scenario,
      metric: '$metric-contract',
      stat: stat,
      baseline: baselineValue,
      candidate: candidateValue,
      limit: limit,
      status: status,
    ),
  );
  if (status == 'regression') {
    issues.add(
      EvaluationIssue(
        kind: 'regression',
        path: 'candidate.scenarios.$scenario.metrics.$metric',
        message:
            '$metric $stat regressed from $baselineValue to $candidateValue; contract limit is $limit.',
      ),
    );
  }
}

void _evaluateAbsoluteGate({
  required Map<String, Map<String, Object?>> baselineScenarios,
  required Map<String, Map<String, Object?>> candidateScenarios,
  required String scenario,
  required String metric,
  required String stat,
  required double limit,
  required List<EvaluationIssue> issues,
  required List<MetricComparison> comparisons,
}) {
  final baselineValue = _metricStat(baselineScenarios, scenario, metric, stat);
  final candidateValue = _metricStat(
    candidateScenarios,
    scenario,
    metric,
    stat,
  );
  if (baselineValue == null || candidateValue == null) {
    return;
  }

  final status = candidateValue <= limit ? 'pass' : 'regression';
  comparisons.add(
    MetricComparison(
      scenario: scenario,
      metric: metric,
      stat: stat,
      baseline: baselineValue,
      candidate: candidateValue,
      limit: limit,
      status: status,
    ),
  );
  if (status == 'regression') {
    issues.add(
      EvaluationIssue(
        kind: 'regression',
        path: 'candidate.scenarios.$scenario.metrics.$metric',
        message: '$metric $stat is $candidateValue; absolute limit is $limit.',
      ),
    );
  }
}

double? _metricStat(
  Map<String, Map<String, Object?>> scenarios,
  String scenario,
  String metric,
  String stat,
) => _numAt(
  _asMap(_mapAt(scenarios[scenario] ?? const {}, 'metrics')[metric]),
  stat,
);

List<double>? _numericSamples(Object? value) {
  if (value is! List) {
    return null;
  }
  final result = <double>[];
  for (final sample in value) {
    if (sample is! num || !sample.toDouble().isFinite) {
      return null;
    }
    result.add(sample.toDouble());
  }
  return result;
}

double _median(List<double> values) {
  final sorted = [...values]..sort();
  final middle = sorted.length ~/ 2;
  if (sorted.length.isOdd) {
    return sorted[middle];
  }
  return (sorted[middle - 1] + sorted[middle]) / 2;
}

double _nearestRankP95(List<double> values) {
  final sorted = [...values]..sort();
  final index = (sorted.length * 0.95).ceil() - 1;
  return sorted[index < 0 ? 0 : index];
}

bool _nearlyEqual(double left, double right) {
  final leftAbs = left.abs();
  final rightAbs = right.abs();
  final scale = leftAbs > rightAbs ? leftAbs : rightAbs;
  return (left - right).abs() <= 1e-6 * (scale < 1 ? 1 : scale);
}

List<EvaluationIssue> _validateCompatibility(
  Map<String, Object?> baseline,
  Map<String, Object?> candidate,
) {
  final issues = <EvaluationIssue>[];
  final baselineMetadata = _mapAt(baseline, 'metadata');
  final candidateMetadata = _mapAt(candidate, 'metadata');

  for (final field in [
    'platform',
    'buildMode',
    'flutterVersion',
    'os',
    'device',
    'cpu',
    'gpu',
    'driver',
    'frameInstrumentation',
    'contractSha256',
    'collectorSha256',
    'fixtureManifestSha256',
    'seedDataSha256',
  ]) {
    final baselineValue = baselineMetadata[field];
    final candidateValue = candidateMetadata[field];
    if (baselineValue != null &&
        candidateValue != null &&
        baselineValue != candidateValue) {
      issues.add(
        EvaluationIssue(
          kind: 'incompatible-runs',
          path: 'metadata.$field',
          message:
              'Baseline "$baselineValue" and candidate "$candidateValue" do not match.',
        ),
      );
    }
  }

  final baselineMeasurement = _mapAt(baseline, 'measurement');
  final candidateMeasurement = _mapAt(candidate, 'measurement');
  for (final field in [
    'warmupRuns',
    'warmupRunSeconds',
    'measuredRuns',
    'sampleIntervalMs',
    'frameBudgetMicros',
  ]) {
    final baselineValue = _numAt(baselineMeasurement, field);
    final candidateValue = _numAt(candidateMeasurement, field);
    if (baselineValue != null &&
        candidateValue != null &&
        baselineValue != candidateValue) {
      issues.add(
        EvaluationIssue(
          kind: 'incompatible-runs',
          path: 'measurement.$field',
          message:
              'Baseline $baselineValue and candidate $candidateValue do not match.',
        ),
      );
    }
  }
  for (final field in ['processIsolation', 'stateReset', 'runKind']) {
    final baselineValue = _stringAt(baselineMeasurement, field);
    final candidateValue = _stringAt(candidateMeasurement, field);
    if (baselineValue != null &&
        candidateValue != null &&
        baselineValue != candidateValue) {
      issues.add(
        EvaluationIssue(
          kind: 'incompatible-runs',
          path: 'measurement.$field',
          message:
              'Baseline "$baselineValue" and candidate "$candidateValue" do not match.',
        ),
      );
    }
  }

  final baselineFixtures = _mapAt(baselineMetadata, 'fixtureHashes');
  final candidateFixtures = _mapAt(candidateMetadata, 'fixtureHashes');
  if (!_mapsEqual(baselineFixtures, candidateFixtures)) {
    issues.add(
      const EvaluationIssue(
        kind: 'incompatible-runs',
        path: 'metadata.fixtureHashes',
        message: 'Baseline and candidate fixture hashes do not match.',
      ),
    );
  }

  final baselineScenarios = _scenarioMap(baseline);
  final candidateScenarios = _scenarioMap(candidate);
  for (final scenarioId in _requiredScenarioDurations.keys) {
    final baselineScenario = baselineScenarios[scenarioId];
    final candidateScenario = candidateScenarios[scenarioId];
    if (baselineScenario == null || candidateScenario == null) {
      continue;
    }
    final baselineDuration = _integerAt(baselineScenario, 'durationSeconds');
    final candidateDuration = _integerAt(candidateScenario, 'durationSeconds');
    if (baselineDuration != null &&
        candidateDuration != null &&
        baselineDuration != candidateDuration) {
      issues.add(
        EvaluationIssue(
          kind: 'incompatible-runs',
          path: 'scenarios.$scenarioId.durationSeconds',
          message:
              'Baseline duration $baselineDuration and candidate duration $candidateDuration do not match.',
        ),
      );
    }
    final baselineWarmup = _integerAt(baselineScenario, 'warmupSeconds');
    final candidateWarmup = _integerAt(candidateScenario, 'warmupSeconds');
    if (baselineWarmup != null &&
        candidateWarmup != null &&
        baselineWarmup != candidateWarmup) {
      issues.add(
        EvaluationIssue(
          kind: 'incompatible-runs',
          path: 'scenarios.$scenarioId.warmupSeconds',
          message:
              'Baseline warm-up $baselineWarmup and candidate warm-up $candidateWarmup do not match.',
        ),
      );
    }
  }

  return issues;
}

bool _mapsEqual(Map<String, Object?> left, Map<String, Object?> right) {
  if (left.length != right.length) {
    return false;
  }
  for (final entry in left.entries) {
    if (!right.containsKey(entry.key) || right[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

Map<String, Map<String, Object?>> _scenarioMap(Map<String, Object?> run) {
  final scenarios = run['scenarios'];
  if (scenarios is! List) {
    return const {};
  }

  final result = <String, Map<String, Object?>>{};
  for (final rawScenario in scenarios) {
    final scenario = _asMap(rawScenario);
    final id = scenario == null ? null : _stringAt(scenario, 'id');
    if (scenario != null && id != null) {
      result[id] = scenario;
    }
  }
  return result;
}

Map<String, Object?> _mapAt(Map<String, Object?> map, String key) =>
    _asMap(map[key]) ?? const {};

Map<String, Object?>? _asMap(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return null;
}

String? _stringAt(Map<String, Object?>? map, String key) {
  final value = map?[key];
  return value is String ? value : null;
}

bool? _boolAt(Map<String, Object?>? map, String key) {
  final value = map?[key];
  return value is bool ? value : null;
}

double? _numAt(Map<String, Object?>? map, String key) {
  final value = map?[key];
  if (value is num) {
    return value.toDouble();
  }
  return null;
}

int? _integerAt(Map<String, Object?>? map, String key) {
  final value = map?[key];
  if (value is! num || !value.toDouble().isFinite) {
    return null;
  }
  final asDouble = value.toDouble();
  if (asDouble != asDouble.truncateToDouble()) {
    return null;
  }
  return asDouble.toInt();
}
