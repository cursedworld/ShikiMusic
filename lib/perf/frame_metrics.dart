import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

class FrameMetricsAccumulator {
  FrameMetricsAccumulator({
    required this.frameBudgetMicros,
    bool videoControllerAlreadyReleased = false,
  }) {
    if (videoControllerAlreadyReleased) {
      markVideoControllerReleased();
    }
  }

  final int frameBudgetMicros;
  int totalFrames = 0;
  int missedFrames = 0;
  int hiddenFlutterFrames = 0;
  int? _hiddenFlutterFramesAtVideoRelease;
  int? firstFrameAfterRestoreMicros;
  int? _restoreRequestedMicros;
  bool _lifecycleHiddenObserved = false;
  bool _visibleAfterRestoreRequestObserved = false;

  bool get canAcceptVideoFrame =>
      _restoreRequestedMicros != null &&
      _visibleAfterRestoreRequestObserved &&
      firstFrameAfterRestoreMicros == null;

  bool get isWaitingForVideoFrame => canAcceptVideoFrame;

  void requestRestore(int nowMicros) {
    _restoreRequestedMicros ??= nowMicros;
    _visibleAfterRestoreRequestObserved = false;
  }

  void markLifecycleHidden() {
    _lifecycleHiddenObserved = true;
  }

  void markLifecycleVisible() {
    if (_restoreRequestedMicros != null && _lifecycleHiddenObserved) {
      _visibleAfterRestoreRequestObserved = true;
    }
  }

  void markVideoControllerReleased() {
    _hiddenFlutterFramesAtVideoRelease ??= hiddenFlutterFrames;
  }

  int? get hiddenFlutterFramesAfterRelease {
    final atRelease = _hiddenFlutterFramesAtVideoRelease;
    return atRelease == null ? null : hiddenFlutterFrames - atRelease;
  }

  void recordFrame({
    required int totalSpanMicros,
    required bool hidden,
    required int nowMicros,
  }) {
    totalFrames += 1;
    if (totalSpanMicros > frameBudgetMicros) {
      missedFrames += 1;
    }
    if (hidden) {
      hiddenFlutterFrames += 1;
    }
  }

  bool recordVideoFrame(int nowMicros) {
    final restoreRequested = _restoreRequestedMicros;
    if (!canAcceptVideoFrame || restoreRequested == null) {
      return false;
    }
    firstFrameAfterRestoreMicros = nowMicros - restoreRequested;
    return true;
  }

  Map<String, Object?> toJson() => {
    'frameBudgetMicros': frameBudgetMicros,
    'totalFrames': totalFrames,
    'missedFrames': missedFrames,
    'missedFrameRatioPercent': totalFrames == 0
        ? null
        : missedFrames * 100 / totalFrames,
    'hiddenFlutterFrames': hiddenFlutterFrames,
    'hiddenFlutterFramesAfterRelease': hiddenFlutterFramesAfterRelease,
    'firstFrameAfterRestoreMs': firstFrameAfterRestoreMicros == null
        ? null
        : firstFrameAfterRestoreMicros! / 1000,
  };
}

class BenchmarkScenarioCommand {
  const BenchmarkScenarioCommand({
    required this.runId,
    required this.scenario,
    required this.dataDirectory,
    required this.expectedActions,
    required this.actionDelay,
    required this.actionCadence,
    required this.awaitCapture,
  });

  final String runId;
  final String scenario;
  final String dataDirectory;
  final int expectedActions;
  final Duration actionDelay;
  final Duration actionCadence;
  final bool awaitCapture;
}

class _ScenarioEvidence {
  _ScenarioEvidence({
    required this.actionStartDelayMs,
    required this.actionCadenceMs,
  });

  bool ready = false;
  bool captureStarted = false;
  bool captureEnded = false;
  double? captureDurationMs;
  int? expectedActions;
  int completedActions = 0;
  bool actionCompleted = false;
  String? actionError;
  String? dataDirectory;
  String? serverBaseUrl;
  int videoProgressEvents = 0;
  double videoPositionAdvanceMs = 0;
  int videoPlayingSamples = 0;
  int videoBufferingSamples = 0;
  double? videoControllerReleasedAfterHiddenMs;
  final int actionStartDelayMs;
  final int actionCadenceMs;
  final List<double> actionElapsedMs = <double>[];

  Map<String, Object?> toJson() => {
    'ready': ready,
    'captureStarted': captureStarted,
    'captureEnded': captureEnded,
    'captureDurationMs': captureDurationMs,
    'expectedActions': expectedActions,
    'completedActions': completedActions,
    'actionCompleted': actionCompleted,
    'actionError': actionError,
    'dataDirectory': dataDirectory,
    'serverBaseUrl': serverBaseUrl,
    'videoProgressEvents': videoProgressEvents,
    'videoPositionAdvanceMs': videoPositionAdvanceMs,
    'videoPlayingSamples': videoPlayingSamples,
    'videoBufferingSamples': videoBufferingSamples,
    'videoControllerReleasedAfterHiddenMs':
        videoControllerReleasedAfterHiddenMs,
    'actionStartDelayMs': actionStartDelayMs,
    'actionCadenceMs': actionCadenceMs,
    'actionElapsedMs': actionElapsedMs,
  };
}

class _BenchmarkRun {
  _BenchmarkRun({
    required this.runId,
    required this.scenario,
    required this.dataDirectory,
    required this.frameBudgetMicros,
    required this.contractExpectedActions,
    required this.actionDelay,
    required this.actionCadence,
    required this.awaitCapture,
    required int startedAtMicros,
    required bool startedHidden,
  }) : evidence = _ScenarioEvidence(
         actionStartDelayMs: actionDelay.inMilliseconds,
         actionCadenceMs: actionCadence.inMilliseconds,
       ) {
    if (startedHidden) {
      lifecycleHiddenObserved = true;
    }
    if (!awaitCapture) {
      startCapture(startedAtMicros);
    }
  }

  final String runId;
  final String scenario;
  final String dataDirectory;
  final int frameBudgetMicros;
  final int contractExpectedActions;
  final Duration actionDelay;
  final Duration actionCadence;
  final bool awaitCapture;
  final _ScenarioEvidence evidence;
  FrameMetricsAccumulator? metrics;
  bool commandDelivered = false;
  bool lifecycleHiddenObserved = false;
  bool lifecycleRestoredObserved = false;
  bool restoreRequested = false;
  bool visibleAfterRestoreRequestObserved = false;
  bool stopped = false;
  int? captureStartedMicros;
  int? restoreRequestedMicros;
  int? hiddenAtMicros;

  void startCapture(int nowMicros) {
    if (evidence.captureStarted) {
      return;
    }
    evidence.captureStarted = true;
    captureStartedMicros = nowMicros;
    metrics = FrameMetricsAccumulator(
      frameBudgetMicros: frameBudgetMicros,
      videoControllerAlreadyReleased:
          evidence.videoControllerReleasedAfterHiddenMs != null,
    );
    if (lifecycleHiddenObserved) {
      metrics!.markLifecycleHidden();
    }
    final requestedAt = restoreRequestedMicros;
    if (requestedAt != null) {
      metrics!.requestRestore(requestedAt);
      if (visibleAfterRestoreRequestObserved) {
        metrics!.markLifecycleVisible();
      }
    }
  }

  void endCapture(int nowMicros) {
    final startedAt = captureStartedMicros;
    if (!evidence.captureStarted ||
        startedAt == null ||
        evidence.captureEnded) {
      return;
    }
    evidence.captureEnded = true;
    evidence.captureDurationMs = (nowMicros - startedAt) / 1000;
  }

  void markHidden(int nowMicros) {
    hiddenAtMicros ??= nowMicros;
    lifecycleHiddenObserved = true;
    metrics?.markLifecycleHidden();
  }

  void markVideoControllerReleased(int nowMicros) {
    final hiddenAt = hiddenAtMicros;
    if (hiddenAt == null ||
        visibleAfterRestoreRequestObserved ||
        evidence.videoControllerReleasedAfterHiddenMs != null) {
      return;
    }
    evidence.videoControllerReleasedAfterHiddenMs =
        (nowMicros - hiddenAt) / 1000;
    metrics?.markVideoControllerReleased();
  }

  void markVisibleAfterHidden() {
    if (lifecycleHiddenObserved) {
      lifecycleRestoredObserved = true;
    }
    if (restoreRequested && lifecycleHiddenObserved) {
      visibleAfterRestoreRequestObserved = true;
    }
    metrics?.markLifecycleVisible();
  }

  void requestRestore(int nowMicros) {
    if (restoreRequested) {
      return;
    }
    restoreRequested = true;
    restoreRequestedMicros = nowMicros;
    visibleAfterRestoreRequestObserved = false;
    metrics?.requestRestore(nowMicros);
    recordAction(nowMicros);
  }

  bool recordVideoFrame(int nowMicros) {
    final accepted = metrics?.recordVideoFrame(nowMicros) ?? false;
    if (!accepted || !restoreRequested) {
      return accepted;
    }
    final expected = evidence.expectedActions;
    if (expected != null) {
      evidence.completedActions = expected;
      evidence.actionCompleted = true;
      evidence.actionError = null;
    }
    return true;
  }

  void recordVideoProgress({
    required Duration previousPosition,
    required Duration position,
    required Duration duration,
    required bool isPlaying,
    required bool isBuffering,
  }) {
    if (!evidence.captureStarted || evidence.captureEnded) return;
    if (isPlaying) evidence.videoPlayingSamples += 1;
    if (isBuffering) evidence.videoBufferingSamples += 1;
    if (!isPlaying || isBuffering) return;

    var deltaMs = position.inMilliseconds - previousPosition.inMilliseconds;
    if (deltaMs < 0 && duration.inMilliseconds > 0) {
      deltaMs += duration.inMilliseconds;
    }
    if (deltaMs < 10 || deltaMs > 5000) return;
    evidence.videoProgressEvents += 1;
    evidence.videoPositionAdvanceMs += deltaMs;
  }

  void markMinimized(int nowMicros) {
    if (evidence.completedActions < 1) {
      recordAction(nowMicros);
    }
    final expected = evidence.expectedActions;
    evidence.actionCompleted =
        expected != null && evidence.completedActions >= expected;
  }

  void recordAction(int nowMicros) {
    final captureStarted = captureStartedMicros;
    final expected = evidence.expectedActions;
    if (!evidence.ready ||
        !evidence.captureStarted ||
        evidence.captureEnded ||
        captureStarted == null) {
      throw StateError('Scenario must be ready and capturing before actions.');
    }
    if (expected == null || evidence.actionElapsedMs.length >= expected) {
      throw StateError('Scenario action count exceeds contract.');
    }
    evidence.actionElapsedMs.add((nowMicros - captureStarted) / 1000);
    evidence.completedActions = evidence.actionElapsedMs.length;
    evidence.actionCompleted = evidence.completedActions == expected;
    evidence.actionError = null;
  }

  Map<String, Object?> scenarioEvidenceJson() => evidence.toJson();

  Map<String, Object?> statusJson() => {
    'runId': runId,
    'scenario': scenario,
    'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
    'awaitCapture': awaitCapture,
    'requestedDataDirectory': dataDirectory,
    'stopped': stopped,
    'lifecycleHiddenObserved': lifecycleHiddenObserved,
    'lifecycleRestoredObserved': lifecycleRestoredObserved,
    'restoreRequested': restoreRequested,
    'visibleAfterRestoreRequestObserved': visibleAfterRestoreRequestObserved,
    'scenarioEvidence': scenarioEvidenceJson(),
  };
}

class PerformanceFrameMonitor with WidgetsBindingObserver {
  PerformanceFrameMonitor._({
    required Directory directory,
    required String? expectedRunId,
  }) : _directory = directory,
       _expectedRunId = expectedRunId;

  static const enabled = bool.fromEnvironment('SHIKI_PERF_METRICS');
  static PerformanceFrameMonitor? _instance;

  static bool get canAcceptVideoFrame =>
      enabled &&
      _instance?._activeRun?.evidence.captureEnded != true &&
      (_instance?._activeRun?.metrics?.canAcceptVideoFrame ?? false);

  static bool get isWaitingForVideoFrame => canAcceptVideoFrame;

  static void markVideoFramePresented() {
    if (!enabled) {
      return;
    }
    final monitor = _instance;
    final run = monitor?._activeRun;
    if (monitor == null || run == null) {
      return;
    }
    if (run.recordVideoFrame(monitor._clock.elapsedMicroseconds)) {
      unawaited(monitor._queueStatusWrite(run));
    }
  }

  static void recordVideoProgress({
    required Duration previousPosition,
    required Duration position,
    required Duration duration,
    required bool isPlaying,
    required bool isBuffering,
  }) {
    if (!enabled) return;
    _instance?._activeRun?.recordVideoProgress(
      previousPosition: previousPosition,
      position: position,
      duration: duration,
      isPlaying: isPlaying,
      isBuffering: isBuffering,
    );
  }

  static void markVideoControllerReleased() {
    if (!enabled) return;
    final monitor = _instance;
    monitor?._activeRun?.markVideoControllerReleased(
      monitor._clock.elapsedMicroseconds,
    );
  }

  static bool isCurrentBenchmarkRun(String runId) =>
      enabled && _instance?._activeRun?.runId == runId;

  static Future<BenchmarkScenarioCommand?> waitForScenarioCommand({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!enabled) {
      return null;
    }
    final monitor = _instance;
    if (monitor == null) {
      throw StateError('PerformanceFrameMonitor is not installed.');
    }
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final run = monitor._activeRun;
      if (run != null && !run.commandDelivered) {
        run.commandDelivered = true;
        return BenchmarkScenarioCommand(
          runId: run.runId,
          scenario: run.scenario,
          dataDirectory: run.dataDirectory,
          expectedActions: run.contractExpectedActions,
          actionDelay: run.actionDelay,
          actionCadence: run.actionCadence,
          awaitCapture: run.awaitCapture,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return null;
  }

  static Future<void> markScenarioReady(
    String runId,
    int expectedActions, {
    String? dataDirectory,
    required String serverBaseUrl,
  }) async {
    if (!enabled) {
      return;
    }
    if (expectedActions < 0) {
      throw ArgumentError.value(
        expectedActions,
        'expectedActions',
        'must be non-negative',
      );
    }
    final monitor = _requireInstalled();
    final run = monitor._requireActiveRun(runId);
    final normalizedDataDirectory = dataDirectory?.trim();
    if (dataDirectory != null &&
        (normalizedDataDirectory == null || normalizedDataDirectory.isEmpty)) {
      throw ArgumentError.value(
        dataDirectory,
        'dataDirectory',
        'must be non-empty when supplied',
      );
    }
    final previousExpected = run.evidence.expectedActions;
    final normalizedServerBaseUrl = serverBaseUrl.trim();
    if (normalizedServerBaseUrl.isEmpty) {
      throw ArgumentError.value(
        serverBaseUrl,
        'serverBaseUrl',
        'must be non-empty',
      );
    }
    if (expectedActions != run.contractExpectedActions) {
      throw StateError(
        'Scenario expected $expectedActions actions, control requires '
        '${run.contractExpectedActions}.',
      );
    }
    if (previousExpected != null && previousExpected != expectedActions) {
      throw StateError(
        'Scenario already declared $previousExpected expected actions.',
      );
    }
    if (expectedActions < run.evidence.completedActions) {
      throw StateError(
        'Expected action count cannot be lower than completed actions.',
      );
    }
    run.evidence
      ..ready = true
      ..expectedActions = expectedActions
      ..actionCompleted = run.evidence.completedActions >= expectedActions
      ..actionError = null
      ..dataDirectory = normalizedDataDirectory
      ..serverBaseUrl = normalizedServerBaseUrl;
    final readyPayload = <String, Object?>{
      'runId': run.runId,
      'scenario': run.scenario,
      'readyAtUtc': DateTime.now().toUtc().toIso8601String(),
      'scenarioEvidence': run.scenarioEvidenceJson(),
    };
    await monitor._writeAtomicJson(
      monitor._runFile('ready', run.runId),
      readyPayload,
    );
    await monitor._queueStatusWrite(run);
  }

  static void markScenarioActionPerformed(String runId) {
    if (!enabled) {
      return;
    }
    final monitor = _requireInstalled();
    final run = monitor._requireActiveRun(runId);
    run.recordAction(monitor._clock.elapsedMicroseconds);
  }

  static Future<void> markScenarioActionComplete(
    String runId,
    int completedActions,
  ) async {
    if (!enabled) {
      return;
    }
    if (completedActions < 0) {
      throw ArgumentError.value(
        completedActions,
        'completedActions',
        'must be non-negative',
      );
    }
    final monitor = _requireInstalled();
    final run = monitor._requireActiveRun(runId);
    final expected = run.evidence.expectedActions;
    if (!run.evidence.ready || expected == null) {
      throw StateError('Scenario must be ready before reporting actions.');
    }
    if (completedActions < run.evidence.completedActions) {
      throw StateError('Completed action count cannot decrease.');
    }
    if (completedActions > expected) {
      throw StateError(
        'Completed action count $completedActions exceeds expected $expected.',
      );
    }
    run.evidence
      ..completedActions = completedActions
      ..actionCompleted = completedActions == expected
      ..actionError = null;
    await monitor._queueStatusWrite(run);
  }

  static Future<void> markScenarioActionFailed(
    String runId,
    Object error,
  ) async {
    if (!enabled) {
      return;
    }
    final monitor = _requireInstalled();
    final run = monitor._requireActiveRun(runId);
    final text = error.toString().trim();
    final normalizedError = text.isEmpty
        ? 'Unknown scenario action error.'
        : text;
    run.evidence
      ..actionCompleted = false
      ..actionError = normalizedError.substring(
        0,
        normalizedError.length > 2048 ? 2048 : normalizedError.length,
      );
    await monitor._writeAtomicJson(
      monitor._runFile('ready', run.runId),
      <String, Object?>{
        'runId': run.runId,
        'scenario': run.scenario,
        'readyAtUtc': DateTime.now().toUtc().toIso8601String(),
        'scenarioEvidence': run.scenarioEvidenceJson(),
      },
    );
    await monitor._queueStatusWrite(run);
  }

  static Future<void> waitForCapture(
    String runId, {
    Duration timeout = const Duration(minutes: 2),
  }) async {
    if (!enabled) {
      return;
    }
    final monitor = _requireInstalled();
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final run = monitor._activeRun;
      if (run == null || run.runId != runId) {
        throw StateError('Benchmark run $runId is no longer active.');
      }
      if (run.evidence.captureStarted) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException('Timed out waiting for capture for run $runId.');
  }

  static Future<void> install() async {
    if (!enabled || _instance != null) {
      return;
    }

    final configuredDirectory = Platform.environment['SHIKI_PERF_CONTROL_DIR']
        ?.trim();
    final directory = Directory(
      configuredDirectory == null || configuredDirectory.isEmpty
          ? '${Directory.systemTemp.path}${Platform.pathSeparator}ShikiMusicPerf'
          : configuredDirectory,
    ).absolute;
    await directory.create(recursive: true);
    final configuredRunId = Platform.environment['SHIKI_PERF_RUN_ID']?.trim();
    final expectedRunId = configuredRunId == null || configuredRunId.isEmpty
        ? null
        : configuredRunId;
    if (expectedRunId != null && !_validRunId.hasMatch(expectedRunId)) {
      throw StateError('SHIKI_PERF_RUN_ID has an invalid value.');
    }
    final monitor = PerformanceFrameMonitor._(
      directory: directory,
      expectedRunId: expectedRunId,
    );
    _instance = monitor;
    await monitor._readControl();
    monitor._start();
  }

  static final RegExp _validRunId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
  static const int _defaultFrameBudgetMicros = 16667;
  static const int _maximumActionScheduleMs = 600000;

  final Directory _directory;
  final String? _expectedRunId;
  final Stopwatch _clock = Stopwatch()..start();
  _BenchmarkRun? _activeRun;
  String? _lastControlContents;
  bool _readingControl = false;
  bool _hidden = false;
  Future<void> _statusWriteTail = Future<void>.value();

  File get _controlFile =>
      File('${_directory.path}${Platform.pathSeparator}control.json');

  static PerformanceFrameMonitor _requireInstalled() {
    final monitor = _instance;
    if (monitor == null) {
      throw StateError('PerformanceFrameMonitor is not installed.');
    }
    return monitor;
  }

  _BenchmarkRun _requireActiveRun(String runId) {
    final run = _activeRun;
    if (run == null || run.runId != runId) {
      throw StateError('Benchmark run $runId is not active.');
    }
    return run;
  }

  void _start() {
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addTimingsCallback(_recordTimings);
    _hidden = _isHiddenState(WidgetsBinding.instance.lifecycleState);
    Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => unawaited(_readControl()),
    );
  }

  Future<void> _readControl() async {
    if (_readingControl || !await _controlFile.exists()) {
      return;
    }
    _readingControl = true;
    try {
      final contents = await _controlFile.readAsString();
      if (contents == _lastControlContents) {
        return;
      }
      _lastControlContents = contents;
      final decoded = jsonDecode(contents);
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      final command = decoded['command'];
      final rawRunId = decoded['runId'];
      if (command is! String || rawRunId is! String) {
        return;
      }
      final runId = rawRunId.trim();
      if (!_acceptsRunId(runId)) {
        return;
      }
      if (command == 'start') {
        await _startRun(decoded, runId);
        return;
      }
      final run = _activeRun;
      if (run == null || run.runId != runId) {
        return;
      }
      if (command == 'capture') {
        run.startCapture(_clock.elapsedMicroseconds);
        await _queueStatusWrite(run);
      } else if (command == 'endCapture') {
        run.endCapture(_clock.elapsedMicroseconds);
        await _queueStatusWrite(run);
      } else if (command == 'minimized') {
        run.markMinimized(_clock.elapsedMicroseconds);
        await _queueStatusWrite(run);
      } else if (command == 'restore') {
        run.requestRestore(_clock.elapsedMicroseconds);
        await _queueStatusWrite(run);
      } else if (command == 'stop') {
        await _finishRun(run, shutdown: decoded['shutdown'] == true);
      }
    } on FormatException {
      // Control is local benchmark infrastructure. Ignore malformed/stale data.
    } on FileSystemException {
      // Atomic replacement can briefly invalidate a Windows read handle.
    } finally {
      _readingControl = false;
    }
  }

  Future<void> _startRun(Map<String, dynamic> decoded, String runId) async {
    if (_activeRun != null) {
      return;
    }
    final rawScenario = decoded['scenario'];
    final rawDataDirectory = decoded['dataDirectory'];
    if (rawScenario is! String ||
        rawScenario.trim().isEmpty ||
        rawScenario.length > 128 ||
        rawDataDirectory is! String ||
        rawDataDirectory.trim().isEmpty) {
      return;
    }
    final rawBudget = decoded['frameBudgetMicros'];
    final budget = rawBudget is int ? rawBudget : _defaultFrameBudgetMicros;
    if (budget != _defaultFrameBudgetMicros) {
      return;
    }
    final actionDelay = _parseActionScheduleMs(decoded['actionStartDelayMs']);
    final actionCadence = _parseActionScheduleMs(decoded['actionCadenceMs']);
    final expectedActions = decoded['expectedActions'];
    if (actionDelay == null ||
        actionCadence == null ||
        expectedActions is! int ||
        expectedActions < 0 ||
        expectedActions > 10000) {
      return;
    }
    final run = _BenchmarkRun(
      runId: runId,
      scenario: rawScenario.trim(),
      dataDirectory: rawDataDirectory.trim(),
      frameBudgetMicros: budget,
      contractExpectedActions: expectedActions,
      actionDelay: actionDelay,
      actionCadence: actionCadence,
      awaitCapture: decoded['awaitCapture'] == true,
      startedAtMicros: _clock.elapsedMicroseconds,
      startedHidden: _hidden,
    );
    _activeRun = run;
    await _queueStatusWrite(run);
  }

  Duration? _parseActionScheduleMs(Object? value) {
    if (value is! int || value < 0 || value > _maximumActionScheduleMs) {
      return null;
    }
    return Duration(milliseconds: value);
  }

  bool _acceptsRunId(String runId) =>
      _validRunId.hasMatch(runId) &&
      (_expectedRunId == null || _expectedRunId == runId);

  void _recordTimings(List<FrameTiming> timings) {
    final run = _activeRun;
    final metrics = run?.metrics;
    if (run == null || metrics == null || run.evidence.captureEnded) {
      return;
    }
    for (final timing in timings) {
      metrics.recordFrame(
        totalSpanMicros: timing.totalSpan.inMicroseconds,
        hidden: _hidden,
        nowMicros: _clock.elapsedMicroseconds,
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasHidden = _hidden;
    _hidden = _isHiddenState(state);
    final run = _activeRun;
    if (run == null) {
      return;
    }
    if (_hidden) {
      run.markHidden(_clock.elapsedMicroseconds);
      unawaited(_queueStatusWrite(run));
    } else if (wasHidden) {
      run.markVisibleAfterHidden();
      unawaited(_queueStatusWrite(run));
    }
  }

  bool _isHiddenState(AppLifecycleState? state) =>
      state == AppLifecycleState.hidden ||
      state == AppLifecycleState.paused ||
      state == AppLifecycleState.detached;

  Future<void> _finishRun(_BenchmarkRun run, {required bool shutdown}) async {
    if (_activeRun != run) {
      return;
    }
    run.stopped = true;
    _activeRun = null;
    await _queueStatusWrite(run);
    final metrics =
        run.metrics ??
        FrameMetricsAccumulator(frameBudgetMicros: run.frameBudgetMicros);
    final result = <String, Object?>{
      'runId': run.runId,
      'scenario': run.scenario,
      'capturedAtUtc': DateTime.now().toUtc().toIso8601String(),
      ...metrics.toJson(),
      'lifecycleHiddenObserved': run.lifecycleHiddenObserved,
      'lifecycleRestoredObserved': run.lifecycleRestoredObserved,
      'restoreRequested': run.restoreRequested,
      'visibleAfterRestoreRequestObserved':
          run.visibleAfterRestoreRequestObserved,
      'scenarioEvidence': run.scenarioEvidenceJson(),
    };
    await _writeAtomicJson(_runFile('result', run.runId), result);
    if (shutdown) {
      exit(0);
    }
  }

  File _runFile(String prefix, String runId) =>
      File('${_directory.path}${Platform.pathSeparator}${prefix}_$runId.json');

  Future<void> _queueStatusWrite(_BenchmarkRun run) {
    final payload = run.statusJson();
    final write = _statusWriteTail.then(
      (_) => _writeAtomicJson(_runFile('status', run.runId), payload),
    );
    _statusWriteTail = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return write;
  }

  Future<void> _writeAtomicJson(
    File destination,
    Map<String, Object?> payload,
  ) async {
    final temporary = File(
      '${destination.path}.${pid}_${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsString(
        jsonEncode(payload),
        encoding: utf8,
        flush: true,
      );
      for (var attempt = 0; ; attempt += 1) {
        try {
          await temporary.rename(destination.path);
          break;
        } on FileSystemException {
          if (attempt >= 4) {
            rethrow;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }
}
