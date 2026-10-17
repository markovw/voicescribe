#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
SOURCES=("$ROOT"/Sources/Domain/*.swift "$ROOT"/Sources/Application/*.swift
  "$ROOT"/Sources/Infrastructure/*.swift "$ROOT/Sources/Presentation/Studio.swift"
  "$ROOT/Sources/Presentation/Theme.swift")
mkdir -p "$ROOT/.cache/modules"
swiftc -target arm64-apple-macosx14.0 -parse-as-library -module-cache-path "$ROOT/.cache/modules" \
  "${SOURCES[@]}" "$ROOT/Tests/TranscriptionSmoke.swift" -o "$ROOT/.cache/transcription-smoke"
HF_HUB_OFFLINE=1 HF_DATASETS_OFFLINE=1 UV_OFFLINE=1 "$ROOT/.cache/transcription-smoke" "$ROOT"
