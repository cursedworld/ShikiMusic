[CmdletBinding()]
param(
  [string]$Output = ".omx/perf/baseline.json",

  [Parameter(Mandatory = $true)]
  [ValidateSet(
    "cold-start-server-offline",
    "idle-home-five-minutes",
    "audio-only-ten-minutes",
    "local-video-30fps-ten-minutes",
    "local-video-60fps-ten-minutes",
    "minimize-video-five-minutes-restore",
    "large-mp3-mp4-download",
    "rapid-track-switch-20",
    "lyrics-blur-five-minutes",
    "video-enable-disable-30"
  )]
  [string]$Scenario,

  [int]$TargetProcessId = 0,
  [string]$ProcessName = "Shiki",
  [string]$Executable = "",
  [switch]$AutoExitLaunchedApp,
  [switch]$ResetBenchmarkState,
  [switch]$AutomateMinimizeRestore,
  [string]$BenchmarkDataDirectory = ".omx\perf\data",
  [switch]$Smoke,

  [ValidateSet("profile", "release")]
  [string]$BuildMode = "release",

  [ValidateRange(-1, 86400)]
  [int]$DurationSeconds = -1,

  [ValidateRange(-1, 3600)]
  [int]$WarmupSeconds = -1,

  [ValidateRange(-1, 10)]
  [int]$WarmupRuns = -1,

  [ValidateRange(-1, 3600)]
  [int]$WarmupRunSeconds = -1,

  [ValidateRange(-1, 100)]
  [int]$MeasuredRuns = -1,

  [ValidateRange(-1, 60000)]
  [int]$SampleIntervalMs = -1,

  [double[]]$MissedFrameRatioSamples = @(),
  [double[]]$FirstVideoFrameSamples = @(),
  [double[]]$HiddenFlutterFrameSamples = @(),
  [string]$FrameEvidence = "",
  [switch]$CollectFlutterFrames,
  [string]$PerfControlDirectory = "$env:TEMP\ShikiMusicPerf",
  [string[]]$Fixture = @(),
  [switch]$NoPrompt
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$script:FixtureServerProcess = $null
$script:FixtureServerStartTime = $null
$script:LaunchRequestedUtc = $null
$script:LaunchedProcessId = 0
$script:LaunchedProcessStartTime = $null
$script:LaunchedExecutable = $null
$script:ActiveRunId = $null
$BenchmarkServerBaseUrl = "http://127.0.0.1:65534"

trap {
  if ($null -ne (Get-Command Stop-FixtureServer -ErrorAction SilentlyContinue)) {
    Stop-FixtureServer
  }
  if ($null -ne (Get-Command Stop-LaunchedBenchmark -ErrorAction SilentlyContinue)) {
    Stop-LaunchedBenchmark
  }
  [Console]::Error.WriteLine(
    "Infrastructure error at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
  )
  exit 2
}

$contractPath = Join-Path (Get-Location) "tool\perf\scenario_contract_v1.json"
$contract = Get-Content -Raw -LiteralPath $contractPath | ConvertFrom-Json
$scenarioContract = $contract.scenarios.PSObject.Properties[$Scenario].Value
if ($null -eq $scenarioContract) {
  throw "Scenario '$Scenario' is absent from scenario_contract_v1.json."
}
$actionStartDelayProperty = $scenarioContract.PSObject.Properties["actionStartDelayMs"]
if ($null -eq $actionStartDelayProperty) {
  throw "Scenario '$Scenario' has no actionStartDelayMs contract."
}
$ActionStartDelayMs = [int]$actionStartDelayProperty.Value
$ActionCadenceMs = [int]$scenarioContract.actionCadenceMs

function Resolve-ContractInteger {
  param(
    [int]$Supplied,
    [int]$Required,
    [string]$Name
  )

  if ($Supplied -lt 0) {
    return $Required
  }
  if (-not $Smoke -and $Supplied -ne $Required) {
    throw "-$Name must be $Required for an evaluable run. Use -Smoke for shortened diagnostics."
  }
  return $Supplied
}

$DurationSeconds = Resolve-ContractInteger -Supplied $DurationSeconds -Required ([int]$scenarioContract.durationSeconds) -Name "DurationSeconds"
$WarmupSeconds = Resolve-ContractInteger -Supplied $WarmupSeconds -Required ([int]$scenarioContract.warmupSeconds) -Name "WarmupSeconds"
$WarmupRuns = Resolve-ContractInteger -Supplied $WarmupRuns -Required ([int]$contract.measurement.warmupRuns) -Name "WarmupRuns"
$WarmupRunSeconds = Resolve-ContractInteger -Supplied $WarmupRunSeconds -Required ([int]$contract.measurement.warmupRunSeconds) -Name "WarmupRunSeconds"
$MeasuredRuns = Resolve-ContractInteger -Supplied $MeasuredRuns -Required ([int]$contract.measurement.measuredRuns) -Name "MeasuredRuns"
$SampleIntervalMs = Resolve-ContractInteger -Supplied $SampleIntervalMs -Required ([int]$contract.measurement.sampleIntervalMs) -Name "SampleIntervalMs"
$FrameBudgetMicros = [int]$contract.measurement.frameBudgetMicros
$RunKind = if ($Smoke) { "smoke" } else { [string]$contract.measurement.runKind }

$expectedActions = [int]$scenarioContract.expectedActions
if ($expectedActions -gt 0) {
  $lastScheduledActionMs = $ActionStartDelayMs + ($ActionCadenceMs * ($expectedActions - 1))
  if (($DurationSeconds * 1000) -le $lastScheduledActionMs) {
    throw "-DurationSeconds must extend past the last scheduled action at $lastScheduledActionMs ms."
  }
}

if ($AutomateMinimizeRestore -and -not ("PerfNativeMethods" -as [type])) {
  Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class PerfNativeMethods {
  private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

  [DllImport("user32.dll")]
  private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
  [DllImport("user32.dll")]
  private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern int GetClassName(IntPtr hwnd, StringBuilder value, int count);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern int GetWindowText(IntPtr hwnd, StringBuilder value, int count);
  [DllImport("user32.dll")]
  private static extern IntPtr GetWindow(IntPtr hwnd, uint command);
  [DllImport("user32.dll")]
  private static extern bool ShowWindowAsync(IntPtr hwnd, int command);
  [DllImport("user32.dll")]
  public static extern bool IsIconic(IntPtr hwnd);

  public static IntPtr FindUniqueBenchmarkWindow(int expectedProcessId) {
    var matches = new List<IntPtr>();
    EnumWindows((hwnd, _) => {
      uint processId;
      GetWindowThreadProcessId(hwnd, out processId);
      if (processId != (uint)expectedProcessId || GetWindow(hwnd, 4) != IntPtr.Zero) return true;
      var className = new StringBuilder(256);
      var title = new StringBuilder(512);
      GetClassName(hwnd, className, className.Capacity);
      GetWindowText(hwnd, title, title.Capacity);
      if (className.ToString() == "FLUTTER_RUNNER_WIN32_WINDOW" && title.ToString() == "Shiki'sMusic") {
        matches.Add(hwnd);
      }
      return true;
    }, IntPtr.Zero);
    if (matches.Count != 1) {
      throw new InvalidOperationException("Expected exactly one benchmark window; found " + matches.Count + ".");
    }
    return matches[0];
  }

  public static int WindowProcessId(IntPtr hwnd) {
    uint processId;
    GetWindowThreadProcessId(hwnd, out processId);
    return (int)processId;
  }

  public static bool Minimize(IntPtr hwnd) { return ShowWindowAsync(hwnd, 6); }
  public static bool RestoreWithoutActivation(IntPtr hwnd) { return ShowWindowAsync(hwnd, 4); }
}
"@
}

function Get-Median {
  param([double[]]$Values)

  if ($Values.Count -eq 0) {
    throw "Cannot calculate a median from an empty sample."
  }

  $sorted = @($Values | Sort-Object)
  $middle = [Math]::Floor($sorted.Count / 2)
  if (($sorted.Count % 2) -eq 1) {
    return [double]$sorted[$middle]
  }

  return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2
}

function Get-Percentile95 {
  param([double[]]$Values)

  if ($Values.Count -eq 0) {
    throw "Cannot calculate p95 from an empty sample."
  }

  $sorted = @($Values | Sort-Object)
  $index = [Math]::Max(0, [Math]::Ceiling($sorted.Count * 0.95) - 1)
  return [double]$sorted[$index]
}

function Get-ResourceWindowStatistic {
  param(
    [object[]]$Samples,
    [string]$Field,
    [double]$StartMs,
    [double]$EndMs,
    [ValidateSet("median", "average", "maximum")]
    [string]$Statistic
  )

  $values = @(
    $Samples |
      Where-Object { $_.elapsedMs -ge $StartMs -and $_.elapsedMs -lt $EndMs } |
      ForEach-Object { [double]$_.$Field }
  )
  if ($values.Count -eq 0) {
    throw "No $Field samples in resource window [$StartMs, $EndMs) ms."
  }
  switch ($Statistic) {
    "median" { return Get-Median -Values $values }
    "average" { return [double](($values | Measure-Object -Average).Average) }
    "maximum" { return [double](($values | Measure-Object -Maximum).Maximum) }
  }
}

function New-NumericMetric {
  param(
    [double[]]$Samples,
    [string]$CompareStat,
    [double]$MaxRegressionPercent = [double]::NaN,
    [double]$MaxAbsolute = [double]::NaN,
    [double]$Target = [double]::NaN,
    [double]$FailureAbove = [double]::NaN,
    [object[]]$IntervalSamples = @(),
    [string]$Evidence = ""
  )

  if ($Samples.Count -ne $MeasuredRuns) {
    throw "Metric has $($Samples.Count) run samples; expected $MeasuredRuns."
  }

  $metric = [ordered]@{
    required = $true
    samples = @($Samples)
    median = Get-Median -Values $Samples
    p95 = Get-Percentile95 -Values $Samples
    compareStat = $CompareStat
  }

  if (-not [double]::IsNaN($MaxRegressionPercent)) {
    $metric.maxRegressionPercent = $MaxRegressionPercent
  }
  if (-not [double]::IsNaN($MaxAbsolute)) {
    $metric.maxAbsolute = $MaxAbsolute
  }
  if (-not [double]::IsNaN($Target)) {
    $metric.target = $Target
  }
  if (-not [double]::IsNaN($FailureAbove)) {
    $metric.failureAbove = $FailureAbove
  }
  if ($IntervalSamples.Count -gt 0) {
    $metric.intervalSamples = @($IntervalSamples)
  }
  if (-not [string]::IsNullOrWhiteSpace($Evidence)) {
    $metric.evidence = $Evidence
  }

  return $metric
}

function Get-ProcessTreeSnapshot {
  param([int]$RootProcessId)

  $processRows = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId)
  $childrenByParent = @{}
  foreach ($row in $processRows) {
    $parentId = [int]$row.ParentProcessId
    if (-not $childrenByParent.ContainsKey($parentId)) {
      $childrenByParent[$parentId] = [System.Collections.Generic.List[int]]::new()
    }
    $childrenByParent[$parentId].Add([int]$row.ProcessId)
  }

  $ids = [System.Collections.Generic.HashSet[int]]::new()
  $queue = [System.Collections.Generic.Queue[int]]::new()
  $queue.Enqueue($RootProcessId)
  while ($queue.Count -gt 0) {
    $currentId = $queue.Dequeue()
    if (-not $ids.Add($currentId)) {
      continue
    }
    if ($childrenByParent.ContainsKey($currentId)) {
      foreach ($childId in $childrenByParent[$currentId]) {
        $queue.Enqueue($childId)
      }
    }
  }

  $snapshot = @{}
  foreach ($processId in $ids) {
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $process) {
      continue
    }
    $snapshot[$processId] = [pscustomobject]@{
      cpuSeconds = if ($null -eq $process.CPU) { 0.0 } else { [double]$process.CPU }
      rssBytes = [double]$process.WorkingSet64
    }
  }

  if (-not $snapshot.ContainsKey($RootProcessId)) {
    throw "Target process $RootProcessId exited during measurement."
  }

  return $snapshot
}

function Resolve-TargetProcessId {
  param([string]$RunId = "")

  if ($TargetProcessId -gt 0) {
    $null = Get-Process -Id $TargetProcessId -ErrorAction Stop
    return $TargetProcessId
  }

  if (-not [string]::IsNullOrWhiteSpace($Executable)) {
    $resolvedExecutable = (Resolve-Path -LiteralPath $Executable).Path
    if ($AutoExitLaunchedApp) {
      $existing = @(
        Get-Process -ErrorAction SilentlyContinue |
          Where-Object {
            try { $_.Path -eq $resolvedExecutable } catch { $false }
          }
      )
      if ($existing.Count -gt 0) {
        throw "Benchmark executable is already running (PID $($existing[0].Id)). Close that benchmark process before starting an isolated run."
      }
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $resolvedExecutable
    $startInfo.UseShellExecute = $false
    if (-not [string]::IsNullOrWhiteSpace($RunId)) {
      $startInfo.EnvironmentVariables["SHIKI_PERF_RUN_ID"] = $RunId
      $startInfo.EnvironmentVariables["SHIKI_PERF_CONTROL_DIR"] = [IO.Path]::GetFullPath($PerfControlDirectory)
      $startInfo.EnvironmentVariables["SHIKI_PERF_EXPECTED_DATA_DIR"] = $resolvedBenchmarkDataDirectory
      $startInfo.EnvironmentVariables["SHIKI_PERF_EXPECTED_SERVER_URL"] = $BenchmarkServerBaseUrl
    }
    $script:LaunchRequestedUtc = [DateTime]::UtcNow
    $started = [Diagnostics.Process]::Start($startInfo)
    if ($null -eq $started) {
      throw "Failed to start benchmark executable: $resolvedExecutable"
    }
    $script:LaunchedProcessId = $started.Id
    $script:LaunchedProcessStartTime = $started.StartTime
    $script:LaunchedExecutable = $resolvedExecutable
    return $started.Id
  }

  $matches = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending)
  if ($matches.Count -eq 0) {
    throw "No process named '$ProcessName' is running. Start the app or pass -Executable/-TargetProcessId."
  }
  if ($matches.Count -gt 1) {
    Write-Warning "Multiple '$ProcessName' processes found; using newest PID $($matches[0].Id)."
  }
  return [int]$matches[0].Id
}

function Measure-ProcessTreeRun {
  param(
    [int]$RootProcessId,
    [int]$CaptureSeconds,
    [int]$DiscardSeconds,
    [IntPtr]$ExpectedMinimizedWindow = [IntPtr]::Zero
  )

  $logicalProcessors = [Math]::Max(1, [Environment]::ProcessorCount)
  $rssSamples = [System.Collections.Generic.List[double]]::new()
  $cpuSamples = [System.Collections.Generic.List[double]]::new()
  $resourceSamples = [System.Collections.Generic.List[object]]::new()
  $totalDurationSeconds = $DiscardSeconds + $CaptureSeconds
  $sampleIntervalSeconds = $SampleIntervalMs / 1000.0
  $overall = [System.Diagnostics.Stopwatch]::StartNew()
  $previousAt = $overall.Elapsed.TotalSeconds
  $previous = Get-ProcessTreeSnapshot -RootProcessId $RootProcessId
  $nextSampleAt = $sampleIntervalSeconds

  while ($nextSampleAt -le $totalDurationSeconds) {
    $remainingMs = [Math]::Ceiling(($nextSampleAt - $overall.Elapsed.TotalSeconds) * 1000)
    if ($remainingMs -gt 0) {
      Start-Sleep -Milliseconds ([int]$remainingMs)
    }
    $current = Get-ProcessTreeSnapshot -RootProcessId $RootProcessId
    $currentAt = $overall.Elapsed.TotalSeconds
    $elapsedSeconds = [Math]::Max(0.001, $currentAt - $previousAt)

    $cpuDeltaSeconds = 0.0
    $rssBytes = 0.0
    foreach ($processId in $current.Keys) {
      $rssBytes += [double]$current[$processId].rssBytes
      if ($previous.ContainsKey($processId)) {
        $delta = [double]$current[$processId].cpuSeconds - [double]$previous[$processId].cpuSeconds
        if ($delta -gt 0) {
          $cpuDeltaSeconds += $delta
        }
      }
    }

    if ($currentAt -ge $DiscardSeconds) {
      $rssMiB = $rssBytes / 1MB
      $normalizedCpu = ($cpuDeltaSeconds / $elapsedSeconds / $logicalProcessors) * 100
      $cpuPercent = [Math]::Max(0.0, $normalizedCpu)
      $rssSamples.Add($rssMiB)
      $cpuSamples.Add($cpuPercent)
      $resourceSamples.Add([ordered]@{
        elapsedMs = [Math]::Round(($currentAt - $DiscardSeconds) * 1000)
        rssMiB = $rssMiB
        cpuPercent = $cpuPercent
      })
      if ($ExpectedMinimizedWindow -ne [IntPtr]::Zero -and -not [PerfNativeMethods]::IsIconic($ExpectedMinimizedWindow)) {
        throw "Benchmark window stopped being minimized during capture."
      }
    }

    $previous = $current
    $previousAt = $currentAt
    do {
      $nextSampleAt += $sampleIntervalSeconds
    } while ($nextSampleAt -le $currentAt)
  }

  if ($rssSamples.Count -eq 0 -or $cpuSamples.Count -eq 0) {
    throw "No samples were captured. Increase -DurationSeconds or reduce -SampleIntervalMs."
  }
  $expectedSamples = [Math]::Floor(($CaptureSeconds * 1000) / $SampleIntervalMs)
  $minimumSamples = [Math]::Max(1, [Math]::Floor($expectedSamples * 0.9))
  if ($resourceSamples.Count -lt $minimumSamples) {
    throw "Resource sampler captured only $($resourceSamples.Count) of about $expectedSamples expected samples."
  }
  $elapsedValues = @($resourceSamples | ForEach-Object { [double]$_.elapsedMs })
  if ($elapsedValues[0] -gt ($SampleIntervalMs * 2)) {
    throw "Resource sampler first sample arrived too late at $($elapsedValues[0]) ms."
  }
  if ($elapsedValues.Count -gt 1) {
    $sampleGaps = for ($index = 1; $index -lt $elapsedValues.Count; $index += 1) {
      $elapsedValues[$index] - $elapsedValues[$index - 1]
    }
    $maximumGap = [double](($sampleGaps | Measure-Object -Maximum).Maximum)
    $p95Gap = Get-Percentile95 -Values @($sampleGaps)
    if ($maximumGap -gt ($SampleIntervalMs * 2) -or $p95Gap -gt ($SampleIntervalMs * 1.5)) {
      throw "Resource sampler cadence is too sparse (p95=${p95Gap}ms, max=${maximumGap}ms)."
    }
  }

  return [pscustomobject]@{
    rss = @($rssSamples)
    cpu = @($cpuSamples)
    resourceSamples = @($resourceSamples)
    rssMedian = Get-Median -Values @($rssSamples)
    rssPeak = [double](($rssSamples | Measure-Object -Maximum).Maximum)
    cpuMedian = Get-Median -Values @($cpuSamples)
    cpuAverage = [double](($cpuSamples | Measure-Object -Average).Average)
  }
}

function Get-FlutterVersion {
  $flutter = Get-Command flutter -ErrorAction Stop
  $raw = & $flutter.Source --version --machine 2>$null | Out-String
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
    throw "Unable to read Flutter version."
  }
  $version = $raw | ConvertFrom-Json
  return "$($version.frameworkVersion) ($($version.channel))"
}

function Get-SourceTreeFingerprint {
  $relativePaths = @(
    & git ls-files --cached --others --exclude-standard -- lib windows linux android assets test tool/perf pubspec.yaml pubspec.lock
  )
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to enumerate the Git source tree."
  }

  $manifestLines = [System.Collections.Generic.List[string]]::new()
  foreach ($relativePath in @($relativePaths | Sort-Object)) {
    $absolutePath = Join-Path (Get-Location) $relativePath
    if ([IO.File]::Exists($absolutePath)) {
      $hash = (Get-FileHash -LiteralPath $absolutePath -Algorithm SHA256).Hash.ToLowerInvariant()
      $manifestLines.Add("$relativePath`t$hash")
    }
    else {
      $manifestLines.Add("$relativePath`t<deleted>")
    }
  }

  $manifest = $manifestLines -join "`n"
  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($manifest)
    return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
  }
  finally {
    $sha256.Dispose()
  }
}

function Get-PathManifestFingerprint {
  param([string[]]$Paths)

  $manifestLines = [System.Collections.Generic.List[string]]::new()
  foreach ($path in @($Paths | Sort-Object)) {
    $resolved = (Resolve-Path -LiteralPath $path).Path
    $item = Get-Item -LiteralPath $resolved
    if ($item.PSIsContainer) {
      $files = @(Get-ChildItem -LiteralPath $resolved -Recurse -File | Sort-Object FullName)
      foreach ($file in $files) {
        $relative = $file.FullName.Substring($resolved.Length).TrimStart('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifestLines.Add("$relative`t$($file.Length)`t$hash")
      }
    }
    else {
      $hash = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
      $manifestLines.Add("$($item.Name)`t$($item.Length)`t$hash")
    }
  }

  $manifest = $manifestLines -join "`n"
  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($manifest)
    return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
  }
  finally {
    $sha256.Dispose()
  }
}

function Get-CollectorFingerprint {
  return Get-PathManifestFingerprint -Paths @(
    "tool\perf\measure_windows.ps1",
    "tool\perf\evaluator.dart",
    "tool\perf\fixture_server.dart",
    "tool\perf\perf_schema_v1.json",
    "tool\perf\prepare_windows_fixtures.ps1",
    "tool\perf\scenario_contract_v1.json",
    "lib\perf\frame_metrics.dart"
  )
}

function Get-SeedDataFingerprint {
  param([string]$DataDirectory)

  $templates = @(
    Get-ChildItem -LiteralPath $DataDirectory -Filter "*.template.json" -File |
      Select-Object -ExpandProperty FullName
  )
  if ($templates.Count -lt 5) {
    throw "Benchmark seed data is incomplete in $DataDirectory. Run prepare_windows_fixtures.ps1."
  }
  return Get-PathManifestFingerprint -Paths $templates
}

function Get-BenchmarkFixtureManifestPaths {
  param([string]$DataDirectory)

  $video30TrackId = [int]$contract.fixtures.video30TrackId
  $video60TrackId = [int]$contract.fixtures.video60TrackId
  $requiredNames = @(
    "app_state.template.json",
    "liked_tracks.template.json",
    "my_playlists.template.json",
    "offline_tracks.template.json",
    "shiki_settings.template.json",
    "track_$video30TrackId.mp3",
    "track_$video30TrackId.lrc",
    "video_$video30TrackId.mp4",
    "track_$video60TrackId.mp3",
    "track_$video60TrackId.lrc",
    "video_$video60TrackId.mp4",
    "download_fixture.mp3",
    "download_fixture.mp4",
    "download_fixture_cover.jpg"
  )
  $paths = [System.Collections.Generic.List[string]]::new()
  foreach ($name in $requiredNames) {
    $path = Join-Path $DataDirectory $name
    if (-not [IO.File]::Exists($path)) {
      throw "Benchmark fixture manifest is missing $name."
    }
    $paths.Add([IO.Path]::GetFullPath($path))
  }
  foreach ($trackId in @($video30TrackId, $video60TrackId)) {
    $covers = @(Get-ChildItem -LiteralPath $DataDirectory -Filter "cover_$trackId`_*" -File)
    if ($covers.Count -ne 1) {
      throw "Benchmark fixture manifest requires exactly one cover for track $trackId."
    }
    $paths.Add($covers[0].FullName)
  }
  return @($paths | Sort-Object)
}

function Write-PerfControl {
  param(
    [string]$Command,
    [string]$RunId,
    [bool]$Shutdown = $false,
    [bool]$AwaitCapture = $false
  )

  [IO.Directory]::CreateDirectory($PerfControlDirectory) | Out-Null
  $controlPath = Join-Path $PerfControlDirectory "control.json"
  $temporaryPath = "$controlPath.$([Guid]::NewGuid().ToString('N')).tmp"
  $backupPath = "$controlPath.$([Guid]::NewGuid().ToString('N')).bak"
  $payload = [ordered]@{
    command = $Command
    runId = $RunId
    scenario = $Scenario
    frameBudgetMicros = $FrameBudgetMicros
    awaitCapture = $AwaitCapture
    expectedActions = [int]$scenarioContract.expectedActions
    actionCadenceMs = $ActionCadenceMs
    actionStartDelayMs = $ActionStartDelayMs
    dataDirectory = $resolvedBenchmarkDataDirectory
    shutdown = $Shutdown
  } | ConvertTo-Json -Compress

  try {
    [IO.File]::WriteAllText($temporaryPath, $payload, [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($controlPath)) {
      [IO.File]::Replace($temporaryPath, $controlPath, $backupPath)
    }
    else {
      [IO.File]::Move($temporaryPath, $controlPath)
    }
  }
  finally {
    if ([IO.File]::Exists($temporaryPath)) {
      [IO.File]::Delete($temporaryPath)
    }
    if ([IO.File]::Exists($backupPath)) {
      [IO.File]::Delete($backupPath)
    }
  }
}

function Wait-PerfJsonFile {
  param(
    [string]$Path,
    [int]$TimeoutSeconds,
    [string]$Description
  )

  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    if ([IO.File]::Exists($Path)) {
      try {
        return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
      }
      catch {
        # Atomic writers should make this rare; retry a transient replacement.
      }
    }
    Start-Sleep -Milliseconds 100
  }

  throw "Timed out waiting for $Description."
}

function Assert-PerfEnvelope {
  param(
    [object]$Data,
    [string]$RunId,
    [string]$Description
  )

  if ($Data.runId -ne $RunId -or $Data.scenario -ne $Scenario) {
    throw "$Description belongs to run '$($Data.runId)' / scenario '$($Data.scenario)', expected '$RunId' / '$Scenario'."
  }
}

function Wait-PerfReady {
  param([string]$RunId)

  $readyPath = Join-Path $PerfControlDirectory "ready_$RunId.json"
  $data = Wait-PerfJsonFile -Path $readyPath -TimeoutSeconds 20 -Description "benchmark ready acknowledgement for run $RunId"
  Assert-PerfEnvelope -Data $data -RunId $RunId -Description "Ready acknowledgement"
  $evidence = $data.scenarioEvidence
  if (-not [string]::IsNullOrWhiteSpace([string]$evidence.actionError)) {
    throw "Benchmark scenario setup failed: $($evidence.actionError)"
  }
  if ($evidence.ready -ne $true) {
    throw "Benchmark scenario did not report ready=true for run $RunId."
  }
  if ([string]$evidence.serverBaseUrl -ne $BenchmarkServerBaseUrl) {
    throw "Benchmark app server URL is not isolated: $($evidence.serverBaseUrl)"
  }
  return [pscustomobject]@{
    path = [IO.Path]::GetFullPath($readyPath)
    data = $data
  }
}

function Wait-PerfStatus {
  param(
    [string]$RunId,
    [ValidateSet("hidden", "visible")]
    [string]$State
  )

  $statusPath = Join-Path $PerfControlDirectory "status_$RunId.json"
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  while ([DateTime]::UtcNow -lt $deadline) {
    if ([IO.File]::Exists($statusPath)) {
      try {
        $data = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
        Assert-PerfEnvelope -Data $data -RunId $RunId -Description "Lifecycle status"
        if (($State -eq "hidden" -and $data.lifecycleHiddenObserved -eq $true -and $data.visibleAfterRestoreRequestObserved -ne $true) -or ($State -eq "visible" -and $data.lifecycleRestoredObserved -eq $true -and $data.visibleAfterRestoreRequestObserved -eq $true)) {
          return $data
        }
      }
      catch {
        # Retry while the atomic status file is being replaced.
      }
    }
    Start-Sleep -Milliseconds 100
  }
  throw "Timed out waiting for lifecycle state '$State' for run $RunId."
}

function Wait-PerfProtocolState {
  param(
    [string]$RunId,
    [ValidateSet("capture", "captureEnded", "minimized", "restore")]
    [string]$State
  )

  $statusPath = Join-Path $PerfControlDirectory "status_$RunId.json"
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  while ([DateTime]::UtcNow -lt $deadline) {
    if ([IO.File]::Exists($statusPath)) {
      try {
        $data = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
        Assert-PerfEnvelope -Data $data -RunId $RunId -Description "Protocol status"
        if (($State -eq "capture" -and $data.scenarioEvidence.captureStarted -eq $true) -or
            ($State -eq "captureEnded" -and $data.scenarioEvidence.captureEnded -eq $true) -or
            ($State -eq "minimized" -and [int]$data.scenarioEvidence.completedActions -ge 1) -or
            ($State -eq "restore" -and $data.restoreRequested -eq $true)) {
          return $data
        }
      }
      catch {
        # Retry a transient status replacement.
      }
    }
    Start-Sleep -Milliseconds 50
  }
  throw "Timed out waiting for protocol state '$State' for run $RunId."
}

function Wait-PerfResult {
  param([string]$RunId)

  $resultPath = Join-Path $PerfControlDirectory "result_$RunId.json"
  $data = Wait-PerfJsonFile -Path $resultPath -TimeoutSeconds 10 -Description "instrumented frame result for run $RunId"
  Assert-PerfEnvelope -Data $data -RunId $RunId -Description "Frame result"

  return [pscustomobject]@{
    path = [IO.Path]::GetFullPath($resultPath)
    data = $data
  }
}

function Get-BenchmarkProcessDecoderFilter {
  param([int]$RootProcessId)

  $processIds = @((Get-ProcessTreeSnapshot -RootProcessId $RootProcessId).Keys | ForEach-Object { [int]$_ })
  if ($processIds.Count -eq 0) {
    throw "Benchmark process tree is empty for PID $RootProcessId."
  }
  $escapedProcessIds = @($processIds | ForEach-Object { [regex]::Escape([string]$_) })
  return [pscustomobject]@{
    processIds = $processIds
    pattern = "(?:^|_)pid_(?:$($escapedProcessIds -join '|'))(?:_|$)"
  }
}

function Get-VideoDecoderEvidence {
  param([int]$RootProcessId)

  $filter = Get-BenchmarkProcessDecoderFilter -RootProcessId $RootProcessId
  $counterRuns = Get-Counter '\GPU Engine(*)\Utilization Percentage' -SampleInterval 1 -MaxSamples 3
  $decodeSamples = @(
    $counterRuns.CounterSamples |
      Where-Object {
        $_.InstanceName -match $filter.pattern -and
        $_.InstanceName -like "*engtype_VideoDecode*"
      }
  )
  $positiveSamples = @($decodeSamples | Where-Object { $_.CookedValue -gt 0 })
  if ($positiveSamples.Count -eq 0) {
    throw "No GPU VideoDecode activity was observed for benchmark PID $RootProcessId."
  }

  $values = @($positiveSamples | ForEach-Object { [Math]::Round([double]$_.CookedValue, 3) })
  $instances = @($positiveSamples.InstanceName | Sort-Object -Unique)
  return [pscustomobject]@{
    maximumUtilizationPercent = [double](($values | Measure-Object -Maximum).Maximum)
    values = $values
    instances = $instances
    evidence = "Windows GPU Engine VideoDecode runtime samples for verified process-tree PIDs $($filter.processIds -join ', '): $($values -join ', ')%; instances: $($instances -join ', '). Backend source: video_player_win Media Foundation + D3D11 texture renderer."
  }
}

function Assert-NoVideoDecoderActivity {
  param([int]$RootProcessId)

  $filter = Get-BenchmarkProcessDecoderFilter -RootProcessId $RootProcessId
  $counterRuns = Get-Counter '\GPU Engine(*)\Utilization Percentage' -SampleInterval 1 -MaxSamples 3
  $decodeSamples = @(
    $counterRuns.CounterSamples |
      Where-Object {
        $_.InstanceName -match $filter.pattern -and
        $_.InstanceName -like "*engtype_VideoDecode*"
      } |
      ForEach-Object { [double]$_.CookedValue }
  )
  $maximum = if ($decodeSamples.Count -eq 0) { 0.0 } else { [double](($decodeSamples | Measure-Object -Maximum).Maximum) }
  if ($maximum -gt 0.05) {
    throw "Hidden benchmark still uses GPU VideoDecode at $maximum%."
  }
  return [pscustomobject]@{
    maximumUtilizationPercent = $maximum
    evidence = "Hidden VideoDecode verified idle (maximum $maximum%) for process-tree PIDs $($filter.processIds -join ', ')."
  }
}

function Wait-VideoDecoderEvidence {
  param(
    [int]$RootProcessId,
    [int]$TimeoutSeconds = 12
  )

  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $lastError = $null
  while ([DateTime]::UtcNow -lt $deadline) {
    try {
      return Get-VideoDecoderEvidence -RootProcessId $RootProcessId
    }
    catch {
      $lastError = $_.Exception
      Start-Sleep -Milliseconds 250
    }
  }
  throw "Hardware VideoDecode evidence was not observed within $TimeoutSeconds seconds for PID $RootProcessId. Last probe: $($lastError.Message)"
}

function Get-FixtureHashes {
  param([string[]]$Paths)

  $hashes = [ordered]@{}
  foreach ($fixturePath in $Paths) {
    $resolved = (Resolve-Path -LiteralPath $fixturePath).Path
    $name = [IO.Path]::GetFileName($resolved)
    if ($hashes.Contains($name)) {
      throw "Fixture file name '$name' is duplicated. Use uniquely named fixtures."
    }
    $hashes[$name] = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  return $hashes
}

function Copy-FileAtomic {
  param(
    [string]$Source,
    [string]$Destination
  )

  $temporaryPath = "$Destination.$([Guid]::NewGuid().ToString('N')).tmp"
  $backupPath = "$Destination.$([Guid]::NewGuid().ToString('N')).bak"
  try {
    [IO.File]::WriteAllBytes($temporaryPath, [IO.File]::ReadAllBytes($Source))
    if ([IO.File]::Exists($Destination)) {
      [IO.File]::Replace($temporaryPath, $Destination, $backupPath)
    }
    else {
      [IO.File]::Move($temporaryPath, $Destination)
    }
  }
  finally {
    if ([IO.File]::Exists($temporaryPath)) {
      [IO.File]::Delete($temporaryPath)
    }
    if ([IO.File]::Exists($backupPath)) {
      [IO.File]::Delete($backupPath)
    }
  }
}

function Reset-BenchmarkData {
  param([string]$RunId)

  if (-not $ResetBenchmarkState) {
    return
  }

  $archiveRoot = Join-Path ([IO.Path]::GetDirectoryName($resolvedBenchmarkDataDirectory)) "archive"
  $archiveDirectory = Join-Path $archiveRoot $RunId
  $downloadTrackId = [int]$contract.fixtures.downloadTrackId
  $downloadOutputs = @(
    Get-ChildItem -LiteralPath $resolvedBenchmarkDataDirectory -File |
      Where-Object {
        $_.Name -eq "track_$downloadTrackId.mp3" -or
        $_.Name -eq "track_$downloadTrackId.lrc" -or
        $_.Name -eq "video_$downloadTrackId.mp4" -or
        $_.Name -like "cover_$downloadTrackId`_*"
      }
  )
  if ($downloadOutputs.Count -gt 0) {
    [IO.Directory]::CreateDirectory($archiveDirectory) | Out-Null
    foreach ($file in $downloadOutputs) {
      Move-Item -LiteralPath $file.FullName -Destination (Join-Path $archiveDirectory $file.Name)
    }
  }

  $templates = @(Get-ChildItem -LiteralPath $resolvedBenchmarkDataDirectory -Filter "*.template.json" -File)
  if ($templates.Count -lt 5) {
    throw "Benchmark templates are missing. Run tool/perf/prepare_windows_fixtures.ps1."
  }
  foreach ($template in $templates) {
    $destinationName = $template.Name.Replace(".template.json", ".json")
    Copy-FileAtomic -Source $template.FullName -Destination (Join-Path $resolvedBenchmarkDataDirectory $destinationName)
  }
}

function Assert-DownloadedFixtures {
  $downloadTrackId = [int]$contract.fixtures.downloadTrackId
  $downloadedAudio = Join-Path $resolvedBenchmarkDataDirectory "track_$downloadTrackId.mp3"
  $downloadedVideo = Join-Path $resolvedBenchmarkDataDirectory "video_$downloadTrackId.mp4"
  $sourceAudio = Join-Path $resolvedBenchmarkDataDirectory "download_fixture.mp3"
  $sourceVideo = Join-Path $resolvedBenchmarkDataDirectory "download_fixture.mp4"
  foreach ($pair in @(@($sourceAudio, $downloadedAudio), @($sourceVideo, $downloadedVideo))) {
    if (-not [IO.File]::Exists($pair[1])) {
      throw "Download scenario did not create $($pair[1])."
    }
    $sourceHash = (Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash
    $downloadHash = (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash
    if ($sourceHash -ne $downloadHash) {
      throw "Downloaded fixture hash does not match source fixture: $($pair[1])."
    }
  }
}

function Wait-BenchmarkWindow {
  param([int]$RootProcessId)

  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  while ([DateTime]::UtcNow -lt $deadline) {
    try {
      return [PerfNativeMethods]::FindUniqueBenchmarkWindow($RootProcessId)
    }
    catch {
      Start-Sleep -Milliseconds 100
    }
  }
  throw "Timed out waiting for the exact benchmark Flutter window for PID $RootProcessId."
}

function Assert-BenchmarkWindowIdentity {
  param(
    [IntPtr]$Window,
    [int]$RootProcessId
  )

  if ([PerfNativeMethods]::WindowProcessId($Window) -ne $RootProcessId) {
    throw "Benchmark window PID changed before automation action."
  }
  $process = Get-Process -Id $RootProcessId -ErrorAction Stop
  $expectedExecutable = (Resolve-Path -LiteralPath $Executable).Path
  if ($process.Path -ne $expectedExecutable) {
    throw "Benchmark process executable changed before automation action."
  }
}

function Wait-WindowIconicState {
  param(
    [IntPtr]$Window,
    [bool]$Expected
  )

  $deadline = [DateTime]::UtcNow.AddSeconds(5)
  while ([DateTime]::UtcNow -lt $deadline) {
    if ([PerfNativeMethods]::IsIconic($Window) -eq $Expected) {
      return
    }
    Start-Sleep -Milliseconds 50
  }
  throw "Benchmark window did not reach expected minimized state '$Expected'."
}

function Start-FixtureServer {
  $port = [int]$contract.fixtures.fixtureServerPort
  $probeUri = "http://127.0.0.1:$port/download_fixture.mp3"
  try {
    $existingRequest = [Net.HttpWebRequest]::Create($probeUri)
    $existingRequest.Method = "HEAD"
    $existingRequest.Timeout = 500
    $existingResponse = $existingRequest.GetResponse()
    $existingResponse.Close()
    throw "Port $port already serves benchmark fixtures. Stop the existing server so this run owns its fixture source."
  }
  catch [Net.WebException] {
    # Expected when no server owns the loopback port.
  }

  $dartCommand = (Get-Command dart -ErrorAction Stop).Source
  $dart = if ([IO.Path]::GetExtension($dartCommand) -ieq ".exe") {
    $dartCommand
  }
  else {
    Join-Path ([IO.Path]::GetDirectoryName($dartCommand)) "cache\dart-sdk\bin\dart.exe"
  }
  $dart = (Resolve-Path -LiteralPath $dart).Path
  $stdoutPath = Join-Path $repositoryPerfRoot "fixture-server.stdout.log"
  $stderrPath = Join-Path $repositoryPerfRoot "fixture-server.stderr.log"
  $arguments = @(
    "run",
    "tool/perf/fixture_server.dart",
    "--directory",
    "`"$resolvedBenchmarkDataDirectory`"",
    "--port",
    $port.ToString()
  )
  $script:FixtureServerProcess = Start-Process -FilePath $dart -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
  $script:FixtureServerStartTime = $script:FixtureServerProcess.StartTime

  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  while ([DateTime]::UtcNow -lt $deadline) {
    if ($script:FixtureServerProcess.HasExited) {
      $errorText = if ([IO.File]::Exists($stderrPath)) { Get-Content -Raw -LiteralPath $stderrPath } else { "" }
      throw "Fixture server exited during startup. $errorText"
    }
    try {
      $request = [Net.HttpWebRequest]::Create($probeUri)
      $request.Method = "HEAD"
      $request.Timeout = 500
      $response = $request.GetResponse()
      $response.Close()
      return
    }
    catch [Net.WebException] {
      Start-Sleep -Milliseconds 100
    }
  }
  throw "Timed out starting loopback fixture server on port $port."
}

function Stop-FixtureServer {
  if ($null -eq $script:FixtureServerProcess) {
    return
  }
  $process = Get-Process -Id $script:FixtureServerProcess.Id -ErrorAction SilentlyContinue
  if ($null -ne $process -and $process.StartTime -eq $script:FixtureServerStartTime) {
    Stop-Process -Id $process.Id
    Wait-Process -Id $process.Id -Timeout 5 -ErrorAction SilentlyContinue
  }
  $script:FixtureServerProcess = $null
}

function Assert-AppServerOffline {
  $serverOnline = $false
  try {
    $request = [Net.HttpWebRequest]::Create("$BenchmarkServerBaseUrl/api/tracks/")
    $request.Method = "HEAD"
    $request.Timeout = 1000
    $response = $request.GetResponse()
    $response.Close()
    $serverOnline = $true
  }
  catch [Net.WebException] {
    if ($null -ne $_.Exception.Response) {
      $_.Exception.Response.Close()
      $serverOnline = $true
    }
  }
  if ($serverOnline) {
    throw "Benchmark isolation port 127.0.0.1:65534 must be unused."
  }
}

function New-Metadata {
  param([string]$MeasuredAppExecutable)

  $commit = (& git rev-parse HEAD | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commit)) {
    throw "Unable to resolve the current Git commit."
  }
  $gitStatus = (& git status --porcelain=v1 | Out-String).Trim()
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to read Git worktree status."
  }
  $isDirty = -not [string]::IsNullOrWhiteSpace($gitStatus)

  $appExecutable = $MeasuredAppExecutable
  if ([string]::IsNullOrWhiteSpace($appExecutable) -or -not [IO.File]::Exists($appExecutable)) {
    throw "Unable to resolve the measured app executable."
  }

  $os = Get-CimInstance Win32_OperatingSystem
  $computer = Get-CimInstance Win32_ComputerSystem
  $processors = @(Get-CimInstance Win32_Processor | ForEach-Object { $_.Name.Trim() })
  $videoControllers = @(Get-CimInstance Win32_VideoController)
  $gpuNames = @($videoControllers | ForEach-Object { $_.Name }) -join "; "
  $drivers = @($videoControllers | ForEach-Object { $_.DriverVersion }) -join "; "

  return [ordered]@{
    commit = if ($isDirty) { "$commit+dirty" } else { $commit }
    gitDirty = $isDirty
    sourceTreeSha256 = Get-SourceTreeFingerprint
    appExecutable = $appExecutable
    appExecutableSha256 = (Get-FileHash -LiteralPath $appExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
    appBundleSha256 = Get-PathManifestFingerprint -Paths @([IO.Path]::GetDirectoryName($appExecutable))
    contractSha256 = (Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash.ToLowerInvariant()
    collectorSha256 = Get-CollectorFingerprint
    fixtureManifestSha256 = Get-PathManifestFingerprint -Paths $FixtureManifestPaths
    seedDataSha256 = Get-SeedDataFingerprint -DataDirectory $resolvedBenchmarkDataDirectory
    platform = "windows"
    buildMode = $BuildMode
    flutterVersion = Get-FlutterVersion
    os = "$($os.Caption) $($os.Version)"
    device = "$($computer.Manufacturer) $($computer.Model)"
    cpu = $processors -join "; "
    gpu = $gpuNames
    driver = $drivers
    videoBackend = "video_player_win"
    frameInstrumentation = [bool]$CollectFlutterFrames
    decoder = "Per-video-scenario Windows GPU Engine runtime probe"
    fixtureHashes = Get-FixtureHashes -Paths $FixtureManifestPaths
  }
}

function Assert-OptionalSamples {
  param([double[]]$Samples, [string]$Name)
  if ($Samples.Count -ne 0 -and $Samples.Count -ne $MeasuredRuns) {
    throw "$Name requires either zero values or exactly $MeasuredRuns values."
  }
}

$repositoryPerfRoot = [IO.Path]::GetFullPath((Join-Path (Get-Location) ".omx\perf"))
$resolvedBenchmarkDataDirectory = [IO.Path]::GetFullPath((Join-Path (Get-Location) $BenchmarkDataDirectory))
$requiredDataPrefix = $repositoryPerfRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if (-not $resolvedBenchmarkDataDirectory.StartsWith($requiredDataPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Benchmark data directory must stay under $repositoryPerfRoot."
}
if (-not [IO.Directory]::Exists($resolvedBenchmarkDataDirectory)) {
  throw "Benchmark data directory does not exist: $resolvedBenchmarkDataDirectory"
}
$PerfControlDirectory = [IO.Path]::GetFullPath($PerfControlDirectory)

if ($Fixture.Count -eq 0) {
  $Fixture = @(
    (Join-Path $resolvedBenchmarkDataDirectory "video_$([int]$contract.fixtures.video30TrackId).mp4"),
    (Join-Path $resolvedBenchmarkDataDirectory "video_$([int]$contract.fixtures.video60TrackId).mp4"),
    (Join-Path $resolvedBenchmarkDataDirectory "download_fixture.mp3"),
    (Join-Path $resolvedBenchmarkDataDirectory "download_fixture.mp4")
  )
}
if (-not $Smoke -and $Fixture.Count -ne 4) {
  throw "Evaluable runs require exactly four fixed fixtures: 30 FPS MP4, 60 FPS MP4, large MP3, and large MP4."
}
foreach ($fixturePath in $Fixture) {
  $null = Resolve-Path -LiteralPath $fixturePath
}
$FixtureManifestPaths = Get-BenchmarkFixtureManifestPaths -DataDirectory $resolvedBenchmarkDataDirectory
$largeDownloadAudio = Join-Path $resolvedBenchmarkDataDirectory "download_fixture.mp3"
if ((Get-Item -LiteralPath $largeDownloadAudio).Length -lt 128MB) {
  throw "download_fixture.mp3 must be at least 128 MiB. Run prepare_windows_fixtures.ps1."
}
$largeDownloadVideo = Join-Path $resolvedBenchmarkDataDirectory "download_fixture.mp4"
if ((Get-Item -LiteralPath $largeDownloadVideo).Length -lt 128MB) {
  throw "download_fixture.mp4 must be at least 128 MiB. Run prepare_windows_fixtures.ps1."
}

if (-not $Smoke -and (-not $CollectFlutterFrames -or -not $AutoExitLaunchedApp -or -not $ResetBenchmarkState -or -not $NoPrompt)) {
  throw "Evaluable runs require -CollectFlutterFrames -AutoExitLaunchedApp -ResetBenchmarkState -NoPrompt and a fresh benchmark process per repetition."
}
if ($ResetBenchmarkState -and -not $AutoExitLaunchedApp) {
  throw "-ResetBenchmarkState is allowed only with -AutoExitLaunchedApp."
}
if ($AutomateMinimizeRestore -and ($Scenario -ne "minimize-video-five-minutes-restore" -or -not $AutoExitLaunchedApp)) {
  throw "-AutomateMinimizeRestore requires the minimize scenario and -AutoExitLaunchedApp."
}
if (-not $Smoke -and $Scenario -eq "minimize-video-five-minutes-restore" -and -not $AutomateMinimizeRestore) {
  throw "The evaluable minimize scenario requires -AutomateMinimizeRestore."
}
if ($AutoExitLaunchedApp -and $TargetProcessId -ne 0) {
  throw "An auto-exit benchmark cannot target an existing PID."
}

Assert-OptionalSamples -Samples $MissedFrameRatioSamples -Name "MissedFrameRatioSamples"
Assert-OptionalSamples -Samples $FirstVideoFrameSamples -Name "FirstVideoFrameSamples"
Assert-OptionalSamples -Samples $HiddenFlutterFrameSamples -Name "HiddenFlutterFrameSamples"
if (($MissedFrameRatioSamples.Count -gt 0 -or $FirstVideoFrameSamples.Count -gt 0 -or $HiddenFlutterFrameSamples.Count -gt 0) -and [string]::IsNullOrWhiteSpace($FrameEvidence)) {
  throw "-FrameEvidence is required when external frame/restore samples are supplied."
}
if ($CollectFlutterFrames -and ($MissedFrameRatioSamples.Count -gt 0 -or $FirstVideoFrameSamples.Count -gt 0 -or $HiddenFlutterFrameSamples.Count -gt 0)) {
  throw "Use either -CollectFlutterFrames or manually supplied frame samples, not both."
}
if ($CollectFlutterFrames -and $Scenario -eq "minimize-video-five-minutes-restore" -and $NoPrompt -and -not $AutomateMinimizeRestore) {
  throw "The minimize/restore frame scenario requires an interactive restore step."
}
if ($NoPrompt -and -not [string]::IsNullOrWhiteSpace($Executable) -and -not $AutoExitLaunchedApp) {
  throw "-Executable cannot be combined with -NoPrompt because repeated cold-start runs must be closed between launches."
}
if ($AutoExitLaunchedApp -and ([string]::IsNullOrWhiteSpace($Executable) -or -not $CollectFlutterFrames)) {
  throw "-AutoExitLaunchedApp requires both -Executable and -CollectFlutterFrames."
}

$scenarioInstructions = @{
  "cold-start-server-offline" = "Use the isolated benchmark build so each measured run begins offline at process launch."
  "idle-home-five-minutes" = "Leave Shiki open on the home screen without playback or interaction."
  "audio-only-ten-minutes" = "Play a local audio track with video disabled."
  "local-video-30fps-ten-minutes" = "Play the fixed local 30 FPS H.264 MP4 fixture."
  "local-video-60fps-ten-minutes" = "Play the fixed local 60 FPS H.264 MP4 fixture."
  "minimize-video-five-minutes-restore" = "Play local video, minimize the window, keep it minimized during capture, then restore after capture."
  "large-mp3-mp4-download" = "Start the fixed large MP3/MP4 download immediately before capture."
  "rapid-track-switch-20" = "Switch tracks 20 times during capture, using the same sequence on every run."
  "lyrics-blur-five-minutes" = "Open the lyrics view with blur enabled and leave it visible."
  "video-enable-disable-30" = "Toggle video on/off 30 times during capture, using the same cadence on every run."
}

$rssRunSamples = [System.Collections.Generic.List[double]]::new()
$cpuRunSamples = [System.Collections.Generic.List[double]]::new()
$rssIntervals = [System.Collections.Generic.List[object]]::new()
$cpuIntervals = [System.Collections.Generic.List[object]]::new()
$rawRuns = [System.Collections.Generic.List[object]]::new()
$flutterFrameCountSamples = [System.Collections.Generic.List[double]]::new()
$startupTimeSamples = [System.Collections.Generic.List[double]]::new()
$downloadOverheadSamples = [System.Collections.Generic.List[double]]::new()
$rssAt15SecondsSamples = [System.Collections.Generic.List[double]]::new()
$backgroundCpuSamples = [System.Collections.Generic.List[double]]::new()
$retainedGrowthSamples = [System.Collections.Generic.List[double]]::new()
$decoderRunSamples = [System.Collections.Generic.List[double]]::new()
$hiddenDecoderRunSamples = [System.Collections.Generic.List[double]]::new()
$decoderEvidenceLines = [System.Collections.Generic.List[string]]::new()
$capturedMissedFrameSamples = [System.Collections.Generic.List[double]]::new()
$capturedFirstFrameSamples = [System.Collections.Generic.List[double]]::new()
$capturedHiddenFrameSamples = [System.Collections.Generic.List[double]]::new()
$frameEvidencePaths = [System.Collections.Generic.List[string]]::new()
$measuredAppExecutable = ""
$videoScenarios = @(
  "local-video-30fps-ten-minutes",
  "local-video-60fps-ten-minutes",
  "minimize-video-five-minutes-restore",
  "rapid-track-switch-20",
  "video-enable-disable-30"
)

Write-Host "Scenario: $Scenario"
Write-Host $scenarioInstructions[$Scenario]
Write-Host "Sampling every $SampleIntervalMs ms; $WarmupRuns discarded warm-up run(s), then $MeasuredRuns measured runs."

function Wait-LaunchedBenchmarkExit {
  param([int]$RootProcessId)

  $process = Get-Process -Id $RootProcessId -ErrorAction SilentlyContinue
  if ($null -ne $process) {
    try {
      Wait-Process -Id $RootProcessId -Timeout 10 -ErrorAction Stop
    }
    catch {
      if ($null -ne (Get-Process -Id $RootProcessId -ErrorAction SilentlyContinue)) {
        throw "Instrumented benchmark PID $RootProcessId did not exit after the stop command."
      }
    }
  }
  $script:LaunchedProcessId = 0
  $script:LaunchedProcessStartTime = $null
  $script:LaunchedExecutable = $null
  $script:ActiveRunId = $null
}

function Stop-LaunchedBenchmark {
  $processId = $script:LaunchedProcessId
  if ($processId -le 0) {
    return
  }
  $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
  if ($null -eq $process) {
    $script:LaunchedProcessId = 0
    return
  }
  $identityMatches =
    $null -ne $script:LaunchedProcessStartTime -and
    $process.StartTime -eq $script:LaunchedProcessStartTime -and
    -not [string]::IsNullOrWhiteSpace([string]$script:LaunchedExecutable) -and
    $process.Path -eq $script:LaunchedExecutable
  if (-not $identityMatches) {
    return
  }

  if (-not [string]::IsNullOrWhiteSpace([string]$script:ActiveRunId) -and
      $null -ne (Get-Command Write-PerfControl -ErrorAction SilentlyContinue)) {
    try {
      Write-PerfControl -Command "stop" -RunId $script:ActiveRunId -Shutdown $true
      Wait-Process -Id $processId -Timeout 3 -ErrorAction SilentlyContinue
    }
    catch {
      # Continue to exact-PID cleanup below.
    }
  }

  $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
  if ($null -ne $process -and
      $process.StartTime -eq $script:LaunchedProcessStartTime -and
      $process.Path -eq $script:LaunchedExecutable) {
    Stop-Process -Id $processId -Force
    Wait-Process -Id $processId -Timeout 5 -ErrorAction SilentlyContinue
  }
  $script:LaunchedProcessId = 0
}

function Invoke-AutomatedRun {
  param(
    [string]$RunId,
    [int]$CaptureSeconds,
    [bool]$Measured
  )

  Assert-AppServerOffline
  Reset-BenchmarkData -RunId $RunId
  $script:ActiveRunId = $RunId
  $awaitCapture = $Scenario -ne "cold-start-server-offline"
  Write-PerfControl -Command "start" -RunId $RunId -AwaitCapture $awaitCapture
  $rootId = Resolve-TargetProcessId -RunId $RunId
  $appExecutable = (Get-Process -Id $rootId -ErrorAction Stop).Path
  $ready = $null
  $preCapture = $null
  $window = [IntPtr]::Zero
  $decoderEvidence = $null
  $hiddenDecoderEvidence = $null

  if ($Scenario -eq "cold-start-server-offline") {
    $captureResult = Measure-ProcessTreeRun -RootProcessId $rootId -CaptureSeconds $CaptureSeconds -DiscardSeconds 0
    Write-PerfControl -Command "endCapture" -RunId $RunId -AwaitCapture $false
    $null = Wait-PerfProtocolState -RunId $RunId -State "captureEnded"
    $ready = Wait-PerfReady -RunId $RunId
  }
  else {
    $ready = Wait-PerfReady -RunId $RunId
    if ($Scenario -eq "minimize-video-five-minutes-restore" -and $Measured) {
      $decoderEvidence = Wait-VideoDecoderEvidence -RootProcessId $rootId
    }
    if ($WarmupSeconds -gt 0) {
      $preCapture = Measure-ProcessTreeRun -RootProcessId $rootId -CaptureSeconds $WarmupSeconds -DiscardSeconds 0
    }

    if ($AutomateMinimizeRestore) {
      $window = Wait-BenchmarkWindow -RootProcessId $rootId
      Assert-BenchmarkWindowIdentity -Window $window -RootProcessId $rootId
      if (-not [PerfNativeMethods]::Minimize($window)) {
        throw "ShowWindowAsync failed to minimize benchmark window."
      }
      Wait-WindowIconicState -Window $window -Expected $true
      $null = Wait-PerfStatus -RunId $RunId -State "hidden"
    }

    Write-PerfControl -Command "capture" -RunId $RunId -AwaitCapture $true
    $null = Wait-PerfProtocolState -RunId $RunId -State "capture"
    if ($AutomateMinimizeRestore) {
      Write-PerfControl -Command "minimized" -RunId $RunId -AwaitCapture $true
      $null = Wait-PerfProtocolState -RunId $RunId -State "minimized"
    }
    $captureResult = Measure-ProcessTreeRun -RootProcessId $rootId -CaptureSeconds $CaptureSeconds -DiscardSeconds 0 -ExpectedMinimizedWindow $window

    if (-not $AutomateMinimizeRestore) {
      Write-PerfControl -Command "endCapture" -RunId $RunId -AwaitCapture $true
      $null = Wait-PerfProtocolState -RunId $RunId -State "captureEnded"
    }

    if ($videoScenarios -contains $Scenario -and
        $Scenario -ne "minimize-video-five-minutes-restore" -and
        $Measured) {
      $decoderEvidence = Wait-VideoDecoderEvidence -RootProcessId $rootId
      $decoderEvidence = [pscustomobject]@{
        maximumUtilizationPercent = [double]$decoderEvidence.maximumUtilizationPercent
        evidence = "End-of-capture: $($decoderEvidence.evidence)"
      }
    }

    if ($AutomateMinimizeRestore) {
      $hiddenDecoderEvidence = Assert-NoVideoDecoderActivity -RootProcessId $rootId
      Assert-BenchmarkWindowIdentity -Window $window -RootProcessId $rootId
      Write-PerfControl -Command "restore" -RunId $RunId -AwaitCapture $true
      $null = Wait-PerfProtocolState -RunId $RunId -State "restore"
      if (-not [PerfNativeMethods]::RestoreWithoutActivation($window)) {
        throw "ShowWindowAsync failed to restore benchmark window."
      }
      Wait-WindowIconicState -Window $window -Expected $false
      $null = Wait-PerfStatus -RunId $RunId -State "visible"
      if ($Measured) {
        $postRestoreDecoder = Wait-VideoDecoderEvidence -RootProcessId $rootId
        $decoderEvidence = [pscustomobject]@{
          maximumUtilizationPercent = [Math]::Max([double]$decoderEvidence.maximumUtilizationPercent, [double]$postRestoreDecoder.maximumUtilizationPercent)
          evidence = "$($decoderEvidence.evidence) $($hiddenDecoderEvidence.evidence) Post-restore: $($postRestoreDecoder.evidence)"
        }
      }
      Write-PerfControl -Command "endCapture" -RunId $RunId -AwaitCapture $true
      $null = Wait-PerfProtocolState -RunId $RunId -State "captureEnded"
    }
  }

  Write-PerfControl -Command "stop" -RunId $RunId -Shutdown $true -AwaitCapture $awaitCapture
  $frameResult = Wait-PerfResult -RunId $RunId
  Wait-LaunchedBenchmarkExit -RootProcessId $rootId
  if ($Scenario -eq "large-mp3-mp4-download") {
    Assert-DownloadedFixtures
  }

  if ($Measured) {
    $scenarioEvidence = $frameResult.data.scenarioEvidence
    if ($scenarioEvidence.captureEnded -ne $true -or $null -eq $scenarioEvidence.captureDurationMs) {
      throw "Benchmark frame capture was not closed explicitly."
    }
    if ($Scenario -eq "minimize-video-five-minutes-restore" -and
        ($null -eq $scenarioEvidence.videoControllerReleasedAfterHiddenMs -or
         [double]$scenarioEvidence.videoControllerReleasedAfterHiddenMs -lt 400 -or
         [double]$scenarioEvidence.videoControllerReleasedAfterHiddenMs -gt 1000)) {
      throw "Video controller release did not meet the 500 ms hidden-lifecycle target."
    }
    $expectedCaptureMs = $CaptureSeconds * 1000
    $minimumCaptureMs = if ($Scenario -eq "cold-start-server-offline") { $expectedCaptureMs - 5000 } else { $expectedCaptureMs - 1000 }
    $maximumCaptureOverheadMs = if ($Scenario -eq "minimize-video-five-minutes-restore") { 15000 } else { 2000 }
    if ([double]$scenarioEvidence.captureDurationMs -lt $minimumCaptureMs -or
        [double]$scenarioEvidence.captureDurationMs -gt ($expectedCaptureMs + $maximumCaptureOverheadMs)) {
      throw "Benchmark frame capture duration does not match the resource window."
    }
    if ($videoScenarios -contains $Scenario -and $Scenario -ne "minimize-video-five-minutes-restore") {
      if ([int]$scenarioEvidence.videoProgressEvents -lt 2 -or
          [double]$scenarioEvidence.videoPositionAdvanceMs -lt 1000 -or
          [int]$scenarioEvidence.videoPlayingSamples -lt 2) {
        throw "Benchmark video did not prove sustained position advancement during capture."
      }
    }
    if ($scenarioEvidence.ready -ne $true -or $scenarioEvidence.actionCompleted -ne $true -or -not [string]::IsNullOrWhiteSpace([string]$scenarioEvidence.actionError)) {
      throw "Benchmark action evidence is incomplete for run $RunId."
    }
    if ([int]$scenarioEvidence.expectedActions -ne [int]$scenarioContract.expectedActions -or [int]$scenarioEvidence.completedActions -ne [int]$scenarioContract.expectedActions) {
      throw "Benchmark action count mismatch for run $RunId."
    }
    if ([int]$scenarioEvidence.actionStartDelayMs -ne $ActionStartDelayMs -or [int]$scenarioEvidence.actionCadenceMs -ne $ActionCadenceMs) {
      throw "Benchmark action schedule mismatch for run $RunId."
    }
    if ($ActionStartDelayMs -gt 0 -or $ActionCadenceMs -gt 0) {
      $actionElapsedMs = @($scenarioEvidence.actionElapsedMs)
      if ($actionElapsedMs.Count -ne [int]$scenarioContract.expectedActions) {
        throw "Benchmark action timestamp count mismatch for run $RunId."
      }
      for ($actionIndex = 0; $actionIndex -lt $actionElapsedMs.Count; $actionIndex += 1) {
        $expectedActionMs = $ActionStartDelayMs + ($ActionCadenceMs * $actionIndex)
        $actualActionMs = [double]$actionElapsedMs[$actionIndex]
        if ($actualActionMs -lt ($expectedActionMs - 25) -or $actualActionMs -gt ($expectedActionMs + 250)) {
          throw "Benchmark action absolute schedule mismatch for run $RunId."
        }
      }
    }
    if (-not [string]::Equals([IO.Path]::GetFullPath([string]$scenarioEvidence.dataDirectory), $resolvedBenchmarkDataDirectory, [StringComparison]::OrdinalIgnoreCase)) {
      throw "Benchmark app used a different data directory for run $RunId."
    }
  }

  $startupMs = $null
  if ($null -ne $script:LaunchRequestedUtc) {
    $readyAtUtc = [DateTime]::Parse([string]$ready.data.readyAtUtc).ToUniversalTime()
    $startupMs = [Math]::Max(0.0, ($readyAtUtc - $script:LaunchRequestedUtc).TotalMilliseconds)
  }

  return [pscustomobject]@{
    processId = $rootId
    appExecutable = $appExecutable
    resources = $captureResult
    preCapture = $preCapture
    frame = $frameResult
    startupMs = $startupMs
    decoder = $decoderEvidence
    hiddenDecoder = $hiddenDecoderEvidence
  }
}

if ($Scenario -eq "large-mp3-mp4-download" -and $AutoExitLaunchedApp) {
  Start-FixtureServer
}

if ($AutoExitLaunchedApp) {
  for ($warmupRun = 1; $warmupRun -le $WarmupRuns; $warmupRun += 1) {
    $warmupRunId = [Guid]::NewGuid().ToString("N")
    Write-Host "Warm-up $warmupRun/${WarmupRuns}: fresh process, $WarmupRunSeconds s (discarded)..."
    $null = Invoke-AutomatedRun -RunId $warmupRunId -CaptureSeconds $WarmupRunSeconds -Measured $false
  }

  for ($run = 1; $run -le $MeasuredRuns; $run += 1) {
    $runId = [Guid]::NewGuid().ToString("N")
    Write-Host "Run $run/${MeasuredRuns}: fresh process, measuring for $DurationSeconds s..."
    $runResult = Invoke-AutomatedRun -RunId $runId -CaptureSeconds $DurationSeconds -Measured $true
    $measuredAppExecutable = $runResult.appExecutable
    $result = $runResult.resources
    $frameData = $runResult.frame.data

    $rssRunSamples.Add([double]$result.rssMedian)
    $cpuRunSamples.Add([double]$result.cpuAverage)
    $rssIntervals.Add(@($result.rss))
    $cpuIntervals.Add(@($result.cpu))
    $flutterFrameCountSamples.Add([double]$frameData.totalFrames)
    if ($null -eq $frameData.missedFrameRatioPercent) {
      if ($Scenario -ne "idle-home-five-minutes") {
        throw "No Flutter frames were captured for visible scenario run $run."
      }
      $capturedMissedFrameSamples.Add(0.0)
    }
    else {
      $capturedMissedFrameSamples.Add([double]$frameData.missedFrameRatioPercent)
    }
    if ($Scenario -eq "minimize-video-five-minutes-restore") {
      if ($null -eq $frameData.hiddenFlutterFramesAfterRelease) {
        throw "No post-release hidden Flutter-frame evidence was observed for run $run."
      }
      $capturedHiddenFrameSamples.Add([double]$frameData.hiddenFlutterFramesAfterRelease)
    }
    $frameEvidencePaths.Add([string]$runResult.frame.path)

    if ($Scenario -eq "cold-start-server-offline") {
      $startupTimeSamples.Add([double]$runResult.startupMs)
    }
    if ($Scenario -eq "large-mp3-mp4-download") {
      if ($null -eq $runResult.preCapture) {
        throw "Download scenario lacks pre-action resource samples."
      }
      $downloadOverheadSamples.Add([Math]::Max(0.0, [double]$result.rssPeak - [double]$runResult.preCapture.rssMedian))
    }
    if ($Scenario -eq "minimize-video-five-minutes-restore") {
      if ($null -eq $frameData.firstFrameAfterRestoreMs) {
        throw "No first video-frame proxy after restore was observed for run $run."
      }
      $capturedFirstFrameSamples.Add([double]$frameData.firstFrameAfterRestoreMs)
      if (($DurationSeconds * 1000) -gt 15000) {
        $rssAt15SecondsSamples.Add((Get-ResourceWindowStatistic -Samples @($result.resourceSamples) -Field "rssMiB" -StartMs 13000 -EndMs 15000 -Statistic "median"))
        $backgroundCpuSamples.Add((Get-ResourceWindowStatistic -Samples @($result.resourceSamples) -Field "cpuPercent" -StartMs 15000 -EndMs ($DurationSeconds * 1000) -Statistic "average"))
      }
      elseif ($Smoke) {
        Write-Warning "Smoke capture is too short for the contract-only 15-second minimize resource metrics; raw metrics are still recorded."
      }
      else {
        throw "Minimize resource metrics require a capture longer than 15 seconds."
      }
    }
    if ($Scenario -eq "rapid-track-switch-20" -or $Scenario -eq "video-enable-disable-30") {
      if ($null -eq $runResult.preCapture) {
        throw "Retained-growth scenario lacks pre-action resource samples."
      }
      $windowStartMs = if ($Scenario -eq "rapid-track-switch-20") { 30000 } else { 90000 }
      if (($DurationSeconds * 1000) -gt $windowStartMs) {
        $settledRss = Get-ResourceWindowStatistic -Samples @($result.resourceSamples) -Field "rssMiB" -StartMs $windowStartMs -EndMs ($DurationSeconds * 1000) -Statistic "median"
        $retainedGrowthSamples.Add([Math]::Max(0.0, $settledRss - [double]$runResult.preCapture.rssMedian))
      }
      elseif ($Smoke) {
        Write-Warning "Smoke capture is too short for the contract-only retained-growth window beginning at $windowStartMs ms; raw metrics are still recorded."
      }
      else {
        throw "Retained-growth metrics require a capture longer than $windowStartMs ms."
      }
    }
    if ($videoScenarios -contains $Scenario) {
      if ($null -eq $runResult.decoder) {
        throw "Video scenario lacks per-run hardware decoder evidence."
      }
      $decoderRunSamples.Add([double]$runResult.decoder.maximumUtilizationPercent)
      $decoderEvidenceLines.Add([string]$runResult.decoder.evidence)
    }
    if ($Scenario -eq "minimize-video-five-minutes-restore") {
      if ($null -eq $runResult.hiddenDecoder) {
        throw "Minimize scenario lacks per-run hidden decoder evidence."
      }
      $hiddenDecoderRunSamples.Add([double]$runResult.hiddenDecoder.maximumUtilizationPercent)
    }

    $rawRuns.Add([ordered]@{
      index = $run
      runId = $runId
      processId = $runResult.processId
      actualDurationMs = [double]$result.resourceSamples[-1].elapsedMs
      resourceSamples = @($result.resourceSamples)
      preCaptureResourceSamples = if ($null -eq $runResult.preCapture) { @() } else { @($runResult.preCapture.resourceSamples) }
      startupTimeMs = $runResult.startupMs
      frameResult = $frameData
      decoderMaximumUtilizationPercent = if ($null -eq $runResult.decoder) { $null } else { [double]$runResult.decoder.maximumUtilizationPercent }
      hiddenDecoderMaximumUtilizationPercent = if ($null -eq $runResult.hiddenDecoder) { $null } else { [double]$runResult.hiddenDecoder.maximumUtilizationPercent }
    })
    Write-Host ("Run {0}: RSS median {1:N2} MiB, CPU average {2:N2}%" -f $run, $result.rssMedian, $result.cpuAverage)
  }
}
else {
  for ($run = 1; $run -le $MeasuredRuns; $run += 1) {
    if (-not $NoPrompt) {
      $null = Read-Host "Prepare diagnostic run $run/$MeasuredRuns, then press Enter"
    }
    $rootId = Resolve-TargetProcessId
    $measuredAppExecutable = (Get-Process -Id $rootId -ErrorAction Stop).Path
    $result = Measure-ProcessTreeRun -RootProcessId $rootId -CaptureSeconds $DurationSeconds -DiscardSeconds $WarmupSeconds
    $rssRunSamples.Add([double]$result.rssMedian)
    $cpuRunSamples.Add([double]$result.cpuAverage)
    $rssIntervals.Add(@($result.rss))
    $cpuIntervals.Add(@($result.cpu))
  }
}

Stop-FixtureServer

if ($CollectFlutterFrames) {
  $MissedFrameRatioSamples = @($capturedMissedFrameSamples)
  if ($Scenario -eq "minimize-video-five-minutes-restore") {
    $FirstVideoFrameSamples = @($capturedFirstFrameSamples)
    $HiddenFlutterFrameSamples = @($capturedHiddenFrameSamples)
  }
  $FrameEvidence = $frameEvidencePaths -join "; "
}

$rssRegressionPercent = if ($Scenario -eq "local-video-30fps-ten-minutes" -or $Scenario -eq "local-video-60fps-ten-minutes") { 0 } else { 5 }
$metrics = [ordered]@{
  rssMiB = New-NumericMetric -Samples @($rssRunSamples) -CompareStat "median" -MaxRegressionPercent $rssRegressionPercent -IntervalSamples @($rssIntervals)
  cpuPercent = New-NumericMetric -Samples @($cpuRunSamples) -CompareStat "median" -MaxRegressionPercent 10 -IntervalSamples @($cpuIntervals)
}

if ($MissedFrameRatioSamples.Count -gt 0) {
  $metrics.missedFrameRatioPercent = New-NumericMetric -Samples $MissedFrameRatioSamples -CompareStat "p95" -MaxAbsolute 1 -Evidence $FrameEvidence
}
if ($flutterFrameCountSamples.Count -gt 0) {
  $metrics.flutterFrameCount = New-NumericMetric -Samples @($flutterFrameCountSamples) -CompareStat "median" -Evidence $FrameEvidence
}
if ($startupTimeSamples.Count -gt 0) {
  $metrics.startupTimeMs = New-NumericMetric -Samples @($startupTimeSamples) -CompareStat "p95" -MaxRegressionPercent 10 -Evidence $FrameEvidence
}
if ($downloadOverheadSamples.Count -gt 0) {
  $metrics.downloadRssOverheadMiB = New-NumericMetric -Samples @($downloadOverheadSamples) -CompareStat "p95" -MaxAbsolute 32 -Evidence $FrameEvidence
}
if ($rssAt15SecondsSamples.Count -gt 0) {
  $metrics.rssAt15sMiB = New-NumericMetric -Samples @($rssAt15SecondsSamples) -CompareStat "median" -Evidence $FrameEvidence
}
if ($backgroundCpuSamples.Count -gt 0) {
  $metrics.backgroundCpuPercent = New-NumericMetric -Samples @($backgroundCpuSamples) -CompareStat "median" -MaxAbsolute 1 -Evidence $FrameEvidence
}
if ($retainedGrowthSamples.Count -gt 0) {
  $metrics.retainedRssGrowthMiB = New-NumericMetric -Samples @($retainedGrowthSamples) -CompareStat "p95" -MaxAbsolute 10 -Evidence $FrameEvidence
}
if ($FirstVideoFrameSamples.Count -gt 0) {
  $metrics.firstVideoFrameMs = New-NumericMetric -Samples $FirstVideoFrameSamples -CompareStat "p95" -MaxRegressionPercent 10 -Target 500 -FailureAbove 1000 -Evidence $FrameEvidence
}
if ($HiddenFlutterFrameSamples.Count -gt 0) {
  $metrics.hiddenFlutterFramesAfterRelease = New-NumericMetric -Samples $HiddenFlutterFrameSamples -CompareStat "p95" -MaxAbsolute 0 -Evidence $FrameEvidence
}
if ($decoderRunSamples.Count -gt 0) {
  $metrics.decoderEvidence = [ordered]@{
    requiredEvidence = $true
    runtimeVerified = $true
    probeKind = "windows-gpu-engine-videodecode"
    positiveRunSamples = @($decoderRunSamples)
    hiddenMaximumRunSamples = if ($hiddenDecoderRunSamples.Count -gt 0) { @($hiddenDecoderRunSamples) } else { @() }
    evidence = ($decoderEvidenceLines -join " | ")
  }
}

$scenarioResult = [ordered]@{
  id = $Scenario
  warmupSeconds = $WarmupSeconds
  durationSeconds = $DurationSeconds
  actionStartDelayMs = $ActionStartDelayMs
  actionCadenceMs = $ActionCadenceMs
  capturedAtUtc = [DateTime]::UtcNow.ToString("o")
  runs = @($rawRuns)
  scenarioEvidence = if ($AutoExitLaunchedApp) {
    $rawRuns[0].frameResult.scenarioEvidence
  } else { $null }
  metrics = $metrics
}

$outputPath = [IO.Path]::GetFullPath((Join-Path (Get-Location) $Output))
$outputDirectory = [IO.Path]::GetDirectoryName($outputPath)
[IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
$metadata = New-Metadata -MeasuredAppExecutable $measuredAppExecutable

if ([IO.File]::Exists($outputPath)) {
  $document = Get-Content -Raw -LiteralPath $outputPath | ConvertFrom-Json
  if ($document.schemaVersion -ne 1) {
    throw "Existing output uses an unsupported schema version."
  }
  foreach ($field in @(
    "commit",
    "sourceTreeSha256",
    "appExecutableSha256",
    "appBundleSha256",
    "contractSha256",
    "collectorSha256",
    "fixtureManifestSha256",
    "seedDataSha256",
    "platform",
    "buildMode",
    "flutterVersion",
    "os",
    "device",
    "cpu",
    "gpu",
    "driver",
    "frameInstrumentation"
  )) {
    if ($document.metadata.$field -ne $metadata.$field) {
      throw "Existing output metadata does not match this run ($field). Output was not modified."
    }
  }
  $existingFixtureJson = $document.metadata.fixtureHashes | ConvertTo-Json -Compress
  $currentFixtureJson = $metadata.fixtureHashes | ConvertTo-Json -Compress
  if ($existingFixtureJson -ne $currentFixtureJson) {
    throw "Existing output fixture hashes do not match this run. Output was not modified."
  }
  $expectedMeasurement = [ordered]@{
    runKind = $RunKind
    warmupRuns = $WarmupRuns
    warmupRunSeconds = $WarmupRunSeconds
    measuredRuns = $MeasuredRuns
    sampleIntervalMs = $SampleIntervalMs
    frameBudgetMicros = $FrameBudgetMicros
    processIsolation = if ($AutoExitLaunchedApp) { "fresh-process-per-run" } else { "diagnostic-existing-process" }
    stateReset = if ($ResetBenchmarkState) { "seed-copy-v1" } else { "none" }
  }
  foreach ($field in $expectedMeasurement.Keys) {
    if ($document.measurement.$field -ne $expectedMeasurement[$field]) {
      throw "Existing output measurement settings do not match this run ($field). Output was not modified."
    }
  }
  $remainingScenarios = @($document.scenarios | Where-Object { $_.id -ne $Scenario })
  $document.scenarios = @($remainingScenarios) + @($scenarioResult)
}
else {
  $document = [ordered]@{
    schemaVersion = 1
    metadata = $metadata
    measurement = [ordered]@{
      runKind = $RunKind
      warmupRuns = $WarmupRuns
      warmupRunSeconds = $WarmupRunSeconds
      measuredRuns = $MeasuredRuns
      sampleIntervalMs = $SampleIntervalMs
      frameBudgetMicros = $FrameBudgetMicros
      processIsolation = if ($AutoExitLaunchedApp) { "fresh-process-per-run" } else { "diagnostic-existing-process" }
      stateReset = if ($ResetBenchmarkState) { "seed-copy-v1" } else { "none" }
    }
    scenarios = @($scenarioResult)
  }
}

$json = $document | ConvertTo-Json -Depth 100
$temporaryPath = "$outputPath.$([Guid]::NewGuid().ToString('N')).tmp"
$backupPath = "$outputPath.$([Guid]::NewGuid().ToString('N')).bak"
try {
  [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
  if ([IO.File]::Exists($outputPath)) {
    [IO.File]::Replace($temporaryPath, $outputPath, $backupPath)
  }
  else {
    [IO.File]::Move($temporaryPath, $outputPath)
  }
}
finally {
  if ([IO.File]::Exists($temporaryPath)) {
    [IO.File]::Delete($temporaryPath)
  }
  if ([IO.File]::Exists($backupPath)) {
    [IO.File]::Delete($backupPath)
  }
}

Write-Host "Wrote $outputPath"
Write-Host "Run the evaluator after all mandatory scenarios and metrics have been captured."
exit 0
