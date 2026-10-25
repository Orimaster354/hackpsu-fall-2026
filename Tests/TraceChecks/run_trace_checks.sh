#!/bin/bash
# Mac checks for the lights-out drawing task's rules: the symbol recognizer and the panel geometry.
# No AR, no UI. Run from anywhere: bash Tests/TraceChecks/run_trace_checks.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${TMPDIR:-/tmp}/trace-checks"
mkdir -p "$OUT"
cd "$ROOT"
swiftc -swift-version 5 -O -o "$OUT/TraceChecks" MyApp/Tasks/GlyphTrace.swift Tests/TraceChecks/main.swift
"$OUT/TraceChecks"
