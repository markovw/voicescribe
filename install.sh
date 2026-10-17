#!/bin/bash
set -euo pipefail

# Run from a cloned GitHub repository. Private releases require gh authentication. No build tools required.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="${VOICESCRIBE_REPO:-}"
if [[ -z "$REPO" ]]; then
  ORIGIN="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)"
  case "$ORIGIN" in
    https://github.com/*) REPO="${ORIGIN#https://github.com/}" ;;
    git@github.com:*) REPO="${ORIGIN#git@github.com:}" ;;
    ssh://git@github.com/*) REPO="${ORIGIN#ssh://git@github.com/}" ;;
    *) echo "Run this script from the cloned GitHub repository." >&2; exit 1 ;;
  esac
fi
REPO="${REPO%.git}"
if [[ ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Invalid GitHub repository. Expected OWNER/REPO." >&2
  exit 1
fi
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "VoiceScribe requires a Mac with Apple Silicon (M1 or later)." >&2
  exit 1
fi
OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if (( OS_MAJOR < 14 )); then
  echo "VoiceScribe requires macOS 14 or later." >&2
  exit 1
fi

TARGET="/Applications/VoiceScribe.app"
if pgrep -x VoiceScribe >/dev/null; then
  echo "Quit VoiceScribe first, then run this installer again." >&2
  exit 1
fi
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/VoiceScribe-install.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
URL="https://github.com/$REPO/releases/latest/download/VoiceScribe-macOS.zip"
echo "Downloading VoiceScribe…"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  gh release download --repo "$REPO" --pattern VoiceScribe-macOS.zip --output "$TEMP_DIR/app.zip"
else
  if ! curl --fail --location --retry 2 --proto '=https' --proto-redir '=https' "$URL" -o "$TEMP_DIR/app.zip"; then
    echo "Download failed. For a private repository, install GitHub CLI and run gh auth login." >&2
    exit 1
  fi
fi
ditto -x -k "$TEMP_DIR/app.zip" "$TEMP_DIR/unpacked"
APP="$TEMP_DIR/unpacked/VoiceScribe.app"
if [[ ! -f "$APP/Contents/Info.plist" || ! -x "$APP/Contents/MacOS/VoiceScribe" ]]; then
  echo "The release does not contain a valid VoiceScribe.app." >&2
  exit 1
fi
echo "Installing in Applications…"
if [[ -w /Applications && ( ! -e "$TARGET" || -w "$TARGET" ) ]]; then
  ditto "$APP" "$TARGET"
else
  echo "macOS may ask for your password to copy the app to Applications."
  sudo ditto "$APP" "$TARGET"
fi
echo "Installed: /Applications/VoiceScribe.app"
echo "Launch it with Spotlight: Command-Space, then type VoiceScribe."
