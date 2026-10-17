#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
APP="$ROOT/dist/VoiceScribe.app"
if [[ ! -d "$APP" ]]; then
  echo "Build the app first: zsh build.sh" >&2
  exit 1
fi
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/VoiceScribe-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/VoiceScribe.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname VoiceScribe -srcfolder "$STAGING" -format UDZO -ov "$ROOT/dist/VoiceScribe.dmg"
