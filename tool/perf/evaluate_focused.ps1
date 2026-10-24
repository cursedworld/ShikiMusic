[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Before,
  [Parameter(Mandatory = $true)][string]$After,
  [Parameter(Mandatory = $true)][string]$Output
)

# Deliberately separate from the strict long-duration baseline evaluator.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$beforeData = Get-Content -Raw -LiteralPath $Before | ConvertFrom-Json
$afterData = Get-Content -Raw -LiteralPath $After | ConvertFrom-Json
$failures = [Collections.Generic.List[string]]::new()
$summary = [Collections.Generic.List[object]]::new()
function Median([double[]]$Values) {
  $sorted = @($Values | Sort-Object)
  return $sorted[[int][Math]::Floor($sorted.Count / 2)]
}
if ($beforeData.kind -ne 'focused-ab-diagnostic-v1' -or $afterData.kind -ne $beforeData.kind -or
    $beforeData.captureSeconds -ne 30 -or $afterData.captureSeconds -ne 30 -or
    $beforeData.warmupSeconds -ne $afterData.warmupSeconds -or
    $beforeData.logicalProcessors -ne $afterData.logicalProcessors) {
  throw 'Incompatible focused A/B reports.'
}
foreach ($scenario in @('focused-audio', 'focused-video', 'focused-settings', 'focused-artist')) {
  $old = @($beforeData.runs | Where-Object scenario -eq $scenario)
  $new = @($afterData.runs | Where-Object scenario -eq $scenario)
  if ($old.Count -ne 3 -or $new.Count -ne 3) { throw "Expected three runs: $scenario" }
  foreach ($sample in @($old + $new)) {
    if ($sample.durationSeconds -lt 29.5 -or $sample.samples.Count -lt 50 -or
        -not $sample.diagnostic.audioPlaying -or $sample.diagnostic.audioAdvanceMs -lt 27000 -or
        $sample.frames.scenarioEvidence.actionError) {
      throw "Invalid capture: $($sample.runId)"
    }
  }
  foreach ($sample in $new) {
    if (-not $sample.diagnostic.playbackControlsPassed) { $failures.Add("Playback controls failed: $scenario") }
  }
  $oldCpu = Median @($old.cpuPercent)
  $newCpu = Median @($new.cpuPercent)
  $oldMemory = Median @($old.meanWorkingSetMiB)
  $newMemory = Median @($new.meanWorkingSetMiB)
  $oldEvents = Median @($old | ForEach-Object { $_.diagnostic.positionEvents })
  $newEvents = Median @($new | ForEach-Object { $_.diagnostic.positionEvents })
  $cpuReduction = (1 - $newCpu / $oldCpu) * 100
  $eventReduction = (1 - $newEvents / $oldEvents) * 100
  if ($scenario -eq 'focused-audio' -and ($cpuReduction -lt 20 -or $eventReduction -lt 80)) {
    $failures.Add('Position polling did not meet CPU/callback reduction gates.')
  }
  if ($scenario -eq 'focused-video' -and ($newMemory -gt $oldMemory + 5 -or $newCpu -gt $oldCpu + 0.15)) {
    $failures.Add('Visible-video CPU/RAM regression exceeds focused tolerance.')
  }
  if ($scenario -eq 'focused-video') {
    foreach ($sample in @($old + $new)) {
      if (-not $sample.diagnostic.videoPlaying -or
          $sample.frames.scenarioEvidence.videoPositionAdvanceMs -lt 27000) {
        $failures.Add("Visible video failed to advance: $($sample.runId)")
      }
    }
  }
  if ($scenario -in @('focused-settings', 'focused-artist')) {
    foreach ($sample in $new) {
      if ($sample.diagnostic.videoControllerAlive -or $sample.diagnostic.videoPlaying -or
          $sample.diagnostic.restoreVideoMs -gt 1000 -or $null -eq $sample.diagnostic.restoreVideoMs) {
        $failures.Add("Hidden video / return latency failed: $($sample.runId)")
      }
    }
    if ($cpuReduction -lt 20 -and $oldMemory - $newMemory -lt 5) {
      $failures.Add('Covered video did not meet CPU or working-set benefit gate.')
    }
  }
  $summary.Add([pscustomobject]@{
    scenario = $scenario
    beforeCpuPercent = $oldCpu; afterCpuPercent = $newCpu; cpuReductionPercent = $cpuReduction
    beforeWorkingSetMiB = $oldMemory; afterWorkingSetMiB = $newMemory
    workingSetSavedMiB = $oldMemory - $newMemory
    beforePositionEvents = $oldEvents; afterPositionEvents = $newEvents
    positionEventReductionPercent = $eventReduction
    beforeMissedFrames = Median @($old | ForEach-Object { $_.frames.missedFrames })
    afterMissedFrames = Median @($new | ForEach-Object { $_.frames.missedFrames })
  })
}
$result = [ordered]@{
  kind = 'focused-ab-verdict-v1'
  pass = $failures.Count -eq 0
  failures = $failures
  summary = $summary
  limits = 'Windows, synthetic local media, three 30-second captures per scenario. Not a full baseline or leak test. Image codec/regression tests are a separate mandatory gate.'
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($Output), ($result | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
$summary | Format-Table scenario, beforeCpuPercent, afterCpuPercent, beforeWorkingSetMiB, afterWorkingSetMiB
if ($failures.Count -gt 0) { $failures | ForEach-Object { Write-Host $_ }; exit 1 }
Write-Host 'Focused performance gates passed. Codec/regression tests still required.'
exit 0
