param(
  [Parameter(Mandatory = $true)]
  [string]$Baseline,

  [Parameter(Mandatory = $true)]
  [string]$Candidate,

  [ValidateSet("windows", "linux", "android")]
  [string]$Platform = "windows"
)

$ErrorActionPreference = "Stop"

& dart run tool/perf/evaluate.dart --baseline $Baseline --candidate $Candidate --platform $Platform
exit $LASTEXITCODE
