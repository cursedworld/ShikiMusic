[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Executable,
  [Parameter(Mandatory = $true)][string]$Output,
  [ValidateSet('focused-audio', 'focused-video', 'focused-settings', 'focused-artist')]
  [string[]]$Scenarios = @('focused-audio', 'focused-video', 'focused-settings', 'focused-artist'),
  [ValidateRange(10, 120)][int]$CaptureSeconds = 30,
  [ValidateRange(1, 5)][int]$Runs = 3,
  [ValidateRange(1, 30)][int]$WarmupSeconds = 8
)

# Focused diagnostics, NOT a replacement for scenario_contract_v1 baselines.
# Every sample uses a fresh hidden process, identical isolated fixture state,
# and a benchmark-only build. This is not a displayed-video FPS benchmark.
# The installed app and personal library are never used.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$exe = (Resolve-Path -LiteralPath $Executable).Path
$data = (Resolve-Path -LiteralPath '.omx/perf/data').Path
$results = [Collections.Generic.List[object]]::new()
$logicalProcessors = [Environment]::ProcessorCount
$server = 'http://127.0.0.1:65534'
$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
$outputPath = [IO.Path]::GetFullPath($Output)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($outputPath)) | Out-Null
if (Test-Path -LiteralPath $outputPath) {
  $previous = Get-Content -Raw -LiteralPath $outputPath | ConvertFrom-Json
  if ($previous.executableSha256 -ne $hash) { throw 'Cannot mix executable versions in one report.' }
  foreach ($item in $previous.runs) {
    if ($item.scenario -notin $Scenarios) { $results.Add($item) }
  }
}
function Read-Json([string]$Path) {
  try {
    if (Test-Path -LiteralPath $Path) {
      return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    }
  } catch { }
  return $null
}

function Wait-Json([string]$Path, [scriptblock]$Ready, [int]$Timeout = 30) {
  $clock = [Diagnostics.Stopwatch]::StartNew()
  while ($clock.Elapsed.TotalSeconds -lt $Timeout) {
    $value = Read-Json $Path
    if ($null -ne $value -and (& $Ready $value)) { return $value }
    Start-Sleep -Milliseconds 50
  }
  throw "Timed out: $Path"
}

foreach ($scenario in $Scenarios) {
  for ($run = 1; $run -le $Runs; $run++) {
    if (Get-NetTCPConnection -LocalPort 65534 -State Listen -ErrorAction SilentlyContinue) {
      throw 'Reserved offline benchmark server port is in use.'
    }
    foreach ($name in @('app_state', 'offline_tracks', 'my_playlists', 'liked_tracks', 'shiki_settings')) {
      Copy-Item -LiteralPath (Join-Path $data "$name.template.json") -Destination (Join-Path $data "$name.json")
    }
    # Settings reload persisted values on open; match the scenario before launch.
    $settingsPath = Join-Path $data 'shiki_settings.json'
    $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
    $settings.playVideoClip = $scenario -ne 'focused-audio'
    [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    $id = 'focused_' + [Guid]::NewGuid().ToString('N')
    $control = Join-Path ([IO.Path]::GetDirectoryName($outputPath)) $id
    [IO.Directory]::CreateDirectory($control) | Out-Null
    $payload = [ordered]@{
      command = 'start'; runId = $id; scenario = $scenario
      dataDirectory = $data; frameBudgetMicros = 16667
      expectedActions = 1; actionStartDelayMs = 0; actionCadenceMs = 0
      awaitCapture = $true; shutdown = $false
    }
    function Send-Control([string]$Command, [bool]$Shutdown = $false) {
      $payload.command = $Command
      $payload.shutdown = $Shutdown
      $temp = Join-Path $control 'next.json'
      [IO.File]::WriteAllText($temp, ($payload | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
      Move-Item -LiteralPath $temp -Destination (Join-Path $control 'control.json') -Force
    }
    Send-Control 'start'
    $info = [Diagnostics.ProcessStartInfo]::new($exe)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $info.WorkingDirectory = [IO.Path]::GetDirectoryName($exe)
    $info.EnvironmentVariables['SHIKI_PERF_RUN_ID'] = $id
    $info.EnvironmentVariables['SHIKI_PERF_CONTROL_DIR'] = $control
    $info.EnvironmentVariables['SHIKI_PERF_EXPECTED_DATA_DIR'] = $data
    $info.EnvironmentVariables['SHIKI_PERF_EXPECTED_SERVER_URL'] = $server
    $process = [Diagnostics.Process]::Start($info)
    $startTime = $process.StartTime
    try {
      $ready = Wait-Json (Join-Path $control "ready_$id.json") { param($v) $v.scenarioEvidence.ready }
      if ($ready.scenarioEvidence.actionError -or $ready.scenarioEvidence.serverBaseUrl -ne $server) {
        throw 'Fixture setup failed or server isolation mismatch.'
      }
      Start-Sleep -Seconds $WarmupSeconds
      Send-Control 'capture'
      $null = Wait-Json (Join-Path $control "status_$id.json") { param($v) $v.scenarioEvidence.captureStarted }
      $process.Refresh()
      $cpuStart = $process.TotalProcessorTime.TotalSeconds
      $clock = [Diagnostics.Stopwatch]::StartNew()
      $samples = [Collections.Generic.List[object]]::new()
      while ($clock.Elapsed.TotalSeconds -lt $CaptureSeconds) {
        Start-Sleep -Milliseconds 500
        $process.Refresh()
        if ($process.HasExited) { throw 'Benchmark exited during capture.' }
        $samples.Add([pscustomobject]@{
          elapsedSeconds = $clock.Elapsed.TotalSeconds
          workingSetBytes = $process.WorkingSet64
          privateBytes = $process.PrivateMemorySize64
        })
      }
      $captureElapsedSeconds = $clock.Elapsed.TotalSeconds
      $cpu = ($process.TotalProcessorTime.TotalSeconds - $cpuStart) / $captureElapsedSeconds / $logicalProcessors * 100
      Send-Control 'endCapture'
      $diagnostic = Wait-Json (Join-Path $data "focused_$id.json") { param($v) $v.runId } 20
      Send-Control 'stop' $true
      $frames = Wait-Json (Join-Path $control "result_$id.json") { param($v) $v.runId }
      if (-not $process.WaitForExit(10000)) { throw 'Benchmark did not exit.' }
      $result = [ordered]@{
        scenario = $scenario; run = $run; runId = $id
        cpuPercent = $cpu; durationSeconds = $captureElapsedSeconds
        meanWorkingSetMiB = ($samples | Measure-Object workingSetBytes -Average).Average / 1MB
        meanPrivateMiB = ($samples | Measure-Object privateBytes -Average).Average / 1MB
        samples = $samples; frames = $frames; diagnostic = $diagnostic
      }
      $results.Add($result)
      Write-Host ("{0} #{1}: CPU {2:N3}%, WS {3:N1} MiB, positions {4}, return {5} ms" -f $scenario, $run, $cpu, $result.meanWorkingSetMiB, $diagnostic.positionEvents, $diagnostic.restoreVideoMs)
      [IO.File]::WriteAllText($outputPath, (@{
        kind = 'focused-ab-diagnostic-v1'; executableSha256 = $hash
        windowPresentation = 'hidden-startup; native playback remains active'
        captureSeconds = $CaptureSeconds; warmupSeconds = $WarmupSeconds
        logicalProcessors = $logicalProcessors; runs = $results
      } | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
    } finally {
      # Only the exact process launched for this run may be stopped.
      $current = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
      if ($null -ne $current -and $current.StartTime -eq $startTime -and $current.Path -eq $exe) {
        Stop-Process -Id $current.Id
      }
      $process.Dispose()
    }
  }
}
exit 0
