#!/bin/bash
# Mac only. Redraws the app icon PNGs from MyApp/UI/Components/BlindspotMark.swift into the asset
# catalog. Run it after changing the mark, then commit the PNGs. Run from anywhere.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${TMPDIR:-/tmp}/app-icon"
mkdir -p "$OUT"
cd "$ROOT"
swiftc -swift-version 5 -o "$OUT/make_app_icon" \
  MyApp/UI/Components/BlindspotMark.swift Tools/AppIcon/main.swift
"$OUT/make_app_icon" "$ROOT/MyApp/Assets.xcassets/AppIcon.appiconset"
