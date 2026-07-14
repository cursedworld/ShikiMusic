# ShikiMusic performance scenarios

`scenario_contract_v1.json` is the immutable Windows baseline contract. The
collector rejects shortened durations, changed warm-ups, a non-500 ms sampling
interval, or a frame budget other than 16,667 microseconds. `-Smoke` is the only
way to override those values, and smoke JSON is intentionally not evaluable.

## Safety and isolation

- Every evaluable repetition starts a fresh instrumented benchmark process.
- Benchmark data stays under `.omx/perf`; the app rejects another data root.
- Mutable JSON is atomically restored from `*.template.json` before every run.
- Download outputs from the synthetic track are moved to `.omx/perf/archive`,
  never deleted. User library files, server media, and DB rows are untouched.
- Run IDs and control directories are passed through the launched process
  environment. A stale instrumented process cannot consume another run's
  commands.
- Benchmark builds point the app at the reserved unused loopback port `65534`;
  the collector checks it before each launch. The user's LAN/Django server is
  never contacted or stopped. Only the private loopback fixture server is
  started for the download scenario.
- The ordinary installed/running Shiki executable is never selected when
  `-Executable` is supplied.

## Required fixtures

Prepare copies of a local track/video plus fixed large MP3/MP4 files:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File tool/perf/prepare_windows_fixtures.ps1
```

The generator validates both playback MP4 files with ffprobe as H.264,
`yuv420p`, at most 480p, and at the required 30/60 FPS ranges. It writes active
and seed JSON files to `.omx/perf/data`. Large-download traffic is served only
from `127.0.0.1` by `fixture_server.dart`; no Internet or public server is used.

## Benchmark build

```powershell
flutter build windows --release `
  --dart-define=SHIKI_PERF_METRICS=true `
  --dart-define=SHIKI_DATA_DIR=E:/music_player/.omx/perf/data `
  --dart-define=SHIKI_SERVER_URL=http://127.0.0.1:65534
```

Normal builds omit `SHIKI_PERF_METRICS`; no monitor, control timer, scenario
driver, or benchmark file I/O runs in production.

## Contract scenarios

| Scenario | Ready warm-up | Capture | Required action |
|---|---:|---:|---|
| `cold-start-server-offline` | 0 s | 30 s | fresh launch; app server verified offline |
| `idle-home-five-minutes` | 10 s | 300 s | no interaction |
| `audio-only-ten-minutes` | 15 s | 600 s | local MP3 playing; video disabled |
| `local-video-30fps-ten-minutes` | 15 s | 600 s | local 30 FPS MP4 playing |
| `local-video-60fps-ten-minutes` | 15 s | 600 s | local 60 FPS MP4 playing |
| `minimize-video-five-minutes-restore` | 15 s | 300 s | exact benchmark HWND minimized/restored |
| `large-mp3-mp4-download` | 15 s | 600 s | loopback MP3 and MP4 download |
| `rapid-track-switch-20` | 10 s | 60 s | 20 switches, 250 ms cadence |
| `lyrics-blur-five-minutes` | 10 s | 300 s | local lyrics blur route visible |
| `video-enable-disable-30` | 10 s | 120 s | 30 toggles, 2 s cadence |

Global contract: one discarded 30-second warm-up run, three measured runs,
500 ms resource samples, and a 16,667-microsecond Flutter frame budget.

## Capture

Run each scenario against the same freshly built executable and output file:

```powershell
$exe = 'build/windows/x64/runner/Release/Shiki.exe'
$scenarios = @(
  'cold-start-server-offline',
  'idle-home-five-minutes',
  'audio-only-ten-minutes',
  'local-video-30fps-ten-minutes',
  'local-video-60fps-ten-minutes',
  'minimize-video-five-minutes-restore',
  'large-mp3-mp4-download',
  'rapid-track-switch-20',
  'lyrics-blur-five-minutes',
  'video-enable-disable-30'
)
foreach ($scenario in $scenarios) {
  $extra = if ($scenario -eq 'minimize-video-five-minutes-restore') {
    @{ AutomateMinimizeRestore = $true }
  } else {
    @{}
  }
  & tool/perf/measure_windows.ps1 `
    -Scenario $scenario `
    -Executable $exe `
    -CollectFlutterFrames `
    -AutoExitLaunchedApp `
    -ResetBenchmarkState `
    -NoPrompt `
    -Output .omx/perf/baseline.json `
    @extra
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
```

Minimize automation identifies exactly one top-level
`FLUTTER_RUNNER_WIN32_WINDOW` owned by the launched PID and checks its executable
path before each action. Restore uses `SW_SHOWNOACTIVATE`, so another user window
does not lose focus.

## Evidence and gates

Each scenario stores three raw process/resource runs plus derived median and
nearest-rank p95 values. Evaluator recomputes aggregates from samples.

Mandatory evidence includes:

- process-tree RSS and run-average CPU;
- Flutter frame count and missed-frame ratio;
- startup-to-ready time;
- per-run Windows GPU `VideoDecode` activity for video scenarios;
- RSS 15 seconds after minimize, hidden frames after controller release,
  background CPU, and restore
  video-frame proxy;
- download peak overhead versus pre-action RSS;
- retained RSS growth after rapid switches and video toggles;
- exact action counts and successful final state.

Restore evidence is the strongest Dart/plugin-level proxy available: lifecycle
visible, initialized/playing/non-buffering local controller, video position
advanced, then a Flutter post-frame callback. It is not claimed as a native GPU
texture-present timestamp.

Hard candidate gates include download overhead <=32 MiB, background CPU <=1%,
post-release hidden frames 0, restore <=1 second, retained growth <=10 MiB,
minimized RSS <=
candidate audio RSS +20 MiB, no visible-video RSS regression, and <1% missed
frames.

## Evaluation

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File tool/perf/evaluate.ps1 `
  -Baseline .omx/perf/baseline.json `
  -Candidate .omx/perf/after-phase.json `
  -Platform windows
```

Exit codes: `0` pass, `1` regression, `2` infrastructure/invalid evidence.

Short diagnostic example (never accepted as baseline):

```powershell
& tool/perf/measure_windows.ps1 `
  -Smoke `
  -Scenario idle-home-five-minutes `
  -TargetProcessId $PID `
  -DurationSeconds 1 `
  -WarmupSeconds 0 `
  -WarmupRuns 0 `
  -WarmupRunSeconds 1 `
  -MeasuredRuns 3 `
  -SampleIntervalMs 250 `
  -NoPrompt `
  -Output .omx/perf/sampler-smoke.json
```
