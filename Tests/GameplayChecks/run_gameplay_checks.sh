#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${TMPDIR:-/tmp}/gameplay-checks"
mkdir -p "$OUT"
cd "$ROOT"
swiftc -swift-version 5 -o "$OUT/GameplayChecks" \
  MyApp/Models/GameModels.swift MyApp/Models/Messages.swift MyApp/UI/Session/SessionModels.swift \
  MyApp/UI/Session/GameSession.swift MyApp/UI/Session/GameSession+Gameplay.swift \
  Tests/GameplayChecks/main.swift
"$OUT/GameplayChecks"
