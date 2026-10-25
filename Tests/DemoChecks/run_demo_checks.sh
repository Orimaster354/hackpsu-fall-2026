#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${TMPDIR:-/tmp}/demo-checks"
mkdir -p "$OUT"
cd "$ROOT"
swiftc -swift-version 5 -parse-as-library -o "$OUT/DemoChecks" \
  MyApp/Models/*.swift MyApp/Net/ServerConfig.swift MyApp/Net/GameClient.swift MyApp/Net/LiveConnection.swift \
  MyApp/UI/Session/SessionModels.swift MyApp/UI/Session/GameSession.swift \
  MyApp/UI/Session/GameSession+Gameplay.swift MyApp/UI/Position/PositionProvider.swift \
  Tests/DemoChecks/main.swift
"$OUT/DemoChecks"
