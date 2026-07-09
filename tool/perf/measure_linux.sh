#!/usr/bin/env bash
set -euo pipefail

output="${1:-.omx/perf/baseline-linux.json}"

echo "Linux measurement capture is not implemented yet. Capture scenarios from tool/perf/scenarios.md into schema v1 JSON, then run tool/perf/evaluate_linux.sh. Intended output: $output" >&2
exit 2
