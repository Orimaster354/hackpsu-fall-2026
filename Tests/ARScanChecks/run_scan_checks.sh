#!/bin/bash
# Mac-side checks for the host scan: compiles the ARKit-free capture logic with the real Models/Net/UI-model
# sources and runs it, then verifies the produced uploads and the pose/intrinsics convention with Node.
# These prove logic and bookkeeping only. They cannot prove ARKit's real axes or anything about a room.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${TMPDIR:-/tmp}/arscan-checks"
mkdir -p "$OUT"
cd "$ROOT"
swiftc -swift-version 5 -Xfrontend -default-isolation -Xfrontend MainActor -o "$OUT/ScanChecks" \
  MyApp/Models/*.swift \
  MyApp/Net/GameClient.swift MyApp/Net/ServerConfig.swift MyApp/Net/ScanClient.swift \
  MyApp/UI/Session/SessionModels.swift \
  MyApp/AR/ScanGeometry.swift MyApp/AR/SweepFrameEncoder.swift MyApp/AR/RoomScanFlow.swift \
  Tests/ARScanChecks/main.swift
"$OUT/ScanChecks" "$ROOT" "$OUT"
node Tests/ARScanChecks/check_uploads.js "$ROOT" "$OUT"
node Tests/ARScanChecks/standin/selftest.js
