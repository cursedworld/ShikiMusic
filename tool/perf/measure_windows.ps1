param(
  [string]$Output = ".omx/perf/baseline.json"
)

$ErrorActionPreference = "Stop"

Write-Error "Windows measurement capture is not implemented yet. Capture scenarios from tool/perf/scenarios.md into schema v1 JSON, then run tool/perf/evaluate.ps1. Intended output: $Output"
exit 2
