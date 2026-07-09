param(
  [string]$Output = ".omx/perf/baseline-android.json"
)

$ErrorActionPreference = "Stop"

Write-Error "Android measurement capture is not implemented yet. Capture scenarios from tool/perf/scenarios.md into schema v1 JSON, then run tool/perf/evaluate.ps1 -Platform android. Intended output: $Output"
exit 2
