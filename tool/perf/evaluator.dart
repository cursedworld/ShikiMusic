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

EvaluationReport evaluatePerformance({
  required Map<String, Object?> baseline,
  required Map<String, Object?> candidate,
  String? platform,
}) {
  final infrastructureIssues = <EvaluationIssue>[
    ..._validateRun('baseline', baseline, platform: platform),
    ..._validateRun('candidate', candidate, platform: platform),
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
          _boolAt(candidateMetric, 'required') ??
          _boolAt(baselineMetric, 'required') ??
          false;

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

      if (_boolAt(candidateMetric, 'requiredEvidence') == true) {
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
          _stringAt(candidateMetric, 'compareStat') ??
          _stringAt(baselineMetric, 'compareStat') ??
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

      final maxRegressionPercent =
          _numAt(candidateMetric, 'maxRegressionPercent') ??
          _numAt(baselineMetric, 'maxRegressionPercent');
      final maxAbsolute =
          _numAt(candidateMetric, 'maxAbsolute') ??
          _numAt(baselineMetric, 'maxAbsolute');
      final failureAbove =
          _numAt(candidateMetric, 'failureAbove') ??
          _numAt(baselineMetric, 'failureAbove');

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
  for (final field in ['commit', 'platform', 'buildMode', 'flutterVersion']) {
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

  final measuredPlatform = _stringAt(metadata, 'platform');
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
  final measuredRuns = _numAt(measurement, 'measuredRuns');
  final sampleIntervalMs = _numAt(measurement, 'sampleIntervalMs');
  if (measuredRuns == null || measuredRuns < 3) {
    issues.add(
      EvaluationIssue(
        kind: 'insufficient-repetitions',
        path: '$label.measurement.measuredRuns',
        message: 'At least three measured repetitions are required.',
      ),
    );
  }
  if (sampleIntervalMs == null || sampleIntervalMs <= 0) {
    issues.add(
      EvaluationIssue(
        kind: 'invalid-sample-interval',
        path: '$label.measurement.sampleIntervalMs',
        message: 'sampleIntervalMs must be positive.',
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

  return issues;
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
