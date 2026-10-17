#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
REBUILD_ENGINE=false
INSTALL=true
for option in "$@"; do
  case "$option" in
    --rebuild-engine) REBUILD_ENGINE=true ;;
    --no-install) INSTALL=false ;;
    *) echo "Unknown option: $option" >&2; exit 1 ;;
  esac
done
APP="$ROOT/dist/VoiceScribe.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/.cache"
chmod -R u+w "$APP/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="$ROOT/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.cache/swiftpm-modules"
if [[ "$REBUILD_ENGINE" == true || ! -x "$ROOT/Engine/.build/release/scribe" ]]; then
  # SwiftPM embeds its resource-bundle fallback path as a string literal. Build
  # in a neutral scratch directory so it cannot disclose a developer home path.
  ENGINE_SCRATCH=""
  SCRATCH_POINTER="$ROOT/.cache/engine-scratch-path"
  if [[ -f "$SCRATCH_POINTER" ]]; then
    IFS= read -r ENGINE_SCRATCH < "$SCRATCH_POINTER" || ENGINE_SCRATCH=""
  fi
  if [[ "$ENGINE_SCRATCH" != /private/tmp/VoiceScribe-engine.* || ! -d "$ENGINE_SCRATCH" || -L "$ENGINE_SCRATCH" || ! -O "$ENGINE_SCRATCH" ]]; then
    ENGINE_SCRATCH=$(mktemp -d /private/tmp/VoiceScribe-engine.XXXXXX)
    print -r -- "$ENGINE_SCRATCH" > "$SCRATCH_POINTER"
  fi
  swift build --build-system native -c release --scratch-path "$ENGINE_SCRATCH" \
    -Xswiftc -gnone -Xswiftc -file-prefix-map -Xswiftc "$ROOT=." \
    --package-path "$ROOT/Engine" --cache-path "$ROOT/.cache/spm" \
    --config-path "$ROOT/.cache/config" --security-path "$ROOT/.cache/security"
  mkdir -p "$ROOT/Engine/.build/release"
  cp "$ENGINE_SCRATCH/release/scribe" "$ROOT/Engine/.build/release/scribe"
  for bundle in "$ENGINE_SCRATCH/release/"*.bundle(N); do
    DESTINATION="$ROOT/Engine/.build/release/${bundle:t}"
    if [[ -d "$DESTINATION" ]]; then chmod -R u+w "$DESTINATION"; fi
    cp -R "$bundle" "$ROOT/Engine/.build/release/"
  done
fi
swiftc -debug-prefix-map "$ROOT=." -file-prefix-map "$ROOT=." -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 -module-cache-path "$ROOT/.cache/modules" "$ROOT"/Sources/**/*.swift -o "$APP/Contents/MacOS/VoiceScribe"
cp "$ROOT/Engine/.build/release/scribe" "$APP/Contents/Resources/scribe"
if [[ ! -x "$ROOT/Runtime/uv" ]]; then
  echo "Missing bundled uv. See Runtime/README.md." >&2
  exit 1
fi
cp "$ROOT/Runtime/uv" "$APP/Contents/Resources/uv"
mkdir -p "$APP/Contents/Resources/Accurate"
cp "$ROOT/Accurate/pyproject.toml" "$ROOT/Accurate/uv.lock" "$ROOT/Accurate/transcribe.py" "$APP/Contents/Resources/Accurate/"
for bundle in "$ROOT/Engine/.build/release/"*.bundle(N); do
  cp -R "$bundle" "$APP/Contents/Resources/"
done
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Assets/AppIcon.icns" ]]; then
  cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
if [[ -d "$ROOT/Assets" ]]; then
  cp -R "$ROOT/Assets" "$APP/Contents/Resources/"
fi
if [[ -d "$APP/Contents/Resources/Licenses" ]]; then
  chmod -R u+w "$APP/Contents/Resources/Licenses"
fi
cp -R "$ROOT/Licenses" "$APP/Contents/Resources/"
# Remove linker object paths and debug symbols from distributed executables.
strip -S "$APP/Contents/MacOS/VoiceScribe" "$APP/Contents/Resources/scribe"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
if [[ "$INSTALL" == false ]]; then
  exit 0
fi

TARGET="/Applications/VoiceScribe.app"
if pgrep -x VoiceScribe >/dev/null; then
  echo "Quit VoiceScribe, then rerun zsh build.sh to update $TARGET. Build saved in dist/." >&2
  exit 1
else
  PROCESS_STATUS=$?
  if (( PROCESS_STATUS != 1 )); then
    echo "Could not check whether VoiceScribe is running. Build saved in dist/; installation skipped." >&2
    exit 1
  fi
fi
if [[ ! -w /Applications || ( -e "$TARGET" && ! -w "$TARGET" ) ]]; then
  echo "Cannot write to $TARGET. Build saved in dist/; copy it manually with Finder." >&2
  exit 1
fi

# Stage a complete bundle so removed resources do not survive an update.
STAGING=$(mktemp -d /Applications/.VoiceScribe-update.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/VoiceScribe.app"
codesign --verify --deep --strict "$STAGING/VoiceScribe.app"
if [[ -e "$TARGET" ]]; then
  mv "$TARGET" "$STAGING/previous.app"
fi
if ! mv "$STAGING/VoiceScribe.app" "$TARGET"; then
  if [[ -e "$STAGING/previous.app" ]]; then
    mv "$STAGING/previous.app" "$TARGET"
  fi
  exit 1
fi
echo "Updated: $TARGET"
