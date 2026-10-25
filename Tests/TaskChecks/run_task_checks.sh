#!/bin/bash
# Mac checks for the pure motion-task rules. No sensor, no UI. Run from anywhere.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${TMPDIR:-/tmp}/task-checks"
mkdir -p "$OUT"
cd "$ROOT"
swiftc -swift-version 5 -o "$OUT/TaskChecks" \
  Tests/TaskChecks/MotionSampleStub.swift MyApp/Tasks/TaskModels.swift Tests/TaskChecks/main.swift
"$OUT/TaskChecks"
