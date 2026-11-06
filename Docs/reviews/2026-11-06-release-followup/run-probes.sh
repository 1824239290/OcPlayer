#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
OUT=Docs/reviews/2026-11-06-release-followup
SIMULATOR_ID="${1:?Pass an existing booted iOS simulator UDID}"
python3 "$OUT/make-probes.py"
Scripts/clean.sh > "$OUT/clean-moviepilot-rerun.log"
mkdir -p .local-build/release-followup
swiftc -parse-as-library "$OUT/MoviePilotProbe.swift" \
  -o .local-build/release-followup/moviepilot-probe > "$OUT/moviepilot-build.log" 2>&1
.local-build/release-followup/moviepilot-probe > "$OUT/moviepilot-probe.log"
Scripts/clean.sh > "$OUT/clean-audio-rerun.log"
mkdir -p .local-build/release-followup
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator swiftc -sdk "$SDK" -target arm64-apple-ios26.0-simulator \
  -parse-as-library "$OUT/AudioCore.swift" "$OUT/AudioProbe.swift" \
  -o .local-build/release-followup/audio-probe > "$OUT/audio-build.log" 2>&1
xcrun simctl spawn "$SIMULATOR_ID" "$ROOT/.local-build/release-followup/audio-probe" \
  > "$OUT/audio-probe.log" 2>&1
Scripts/clean.sh > "$OUT/clean-final.log"
cat "$OUT/moviepilot-probe.log" "$OUT/audio-probe.log"
