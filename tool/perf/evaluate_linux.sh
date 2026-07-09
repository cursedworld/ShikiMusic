#!/usr/bin/env bash
set -euo pipefail

baseline=""
candidate=""
platform="linux"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline)
      baseline="${2:-}"
      shift 2
      ;;
    --candidate)
      candidate="${2:-}"
      shift 2
      ;;
    --platform)
      platform="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$baseline" || -z "$candidate" ]]; then
  echo "Usage: tool/perf/evaluate_linux.sh --baseline <file> --candidate <file> [--platform linux]" >&2
  exit 2
fi

dart run tool/perf/evaluate.dart --baseline "$baseline" --candidate "$candidate" --platform "$platform"
