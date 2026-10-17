#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
APP="$ROOT/dist/VoiceScribe.app/Contents/MacOS/VoiceScribe"
if [[ ! -x "$APP" ]]; then
  echo "Build first: zsh build.sh --no-install" >&2
  exit 1
fi
mkdir -p "$ROOT/work/manual-validation/library"
export VOICESCRIBE_LIBRARY_DIR="$ROOT/work/manual-validation/library"
exec "$APP"
