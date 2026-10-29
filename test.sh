#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
CORE_SOURCES=("$ROOT"/Sources/Domain/*.swift "$ROOT/Sources/Application/Repositories.swift" "$ROOT/Sources/Infrastructure/ApplicationPaths.swift"
  "$ROOT/Sources/Infrastructure/TranscriptRepository.swift" "$ROOT/Sources/Infrastructure/Preferences.swift")
"$ROOT/Engine/.build/release/scribe" verify-attribution
mkdir -p "$ROOT/.cache/modules"
swiftc -target arm64-apple-macosx14.0 -parse-as-library -module-cache-path "$ROOT/.cache/modules" "${CORE_SOURCES[@]}" "$ROOT/Tests/CoreTests.swift" -o "$ROOT/.cache/core-tests"
"$ROOT/.cache/core-tests"
swiftc -target arm64-apple-macosx14.0 -parse-as-library -module-cache-path "$ROOT/.cache/modules" "$ROOT/Sources/Presentation/FileDrop.swift" "$ROOT/Tests/DropTests.swift" -o "$ROOT/.cache/drop-tests"
"$ROOT/.cache/drop-tests"
swiftc -target arm64-apple-macosx14.0 -parse-as-library -module-cache-path "$ROOT/.cache/modules" "$ROOT/Tests/AudioEOFTests.swift" -o "$ROOT/.cache/audio-eof-tests"
"$ROOT/.cache/audio-eof-tests" "$ROOT/Engine/.build/release/scribe"

swiftc -target arm64-apple-macosx14.0 -parse-as-library -module-cache-path "$ROOT/.cache/modules" "${CORE_SOURCES[@]}" "$ROOT/Tests/RepositoryTests.swift" -o "$ROOT/.cache/repository-tests"
"$ROOT/.cache/repository-tests"
if [[ -n "${VOICESCRIBE_TEST_PYTHON:-}" ]]; then
  "$VOICESCRIBE_TEST_PYTHON" "$ROOT/Tests/LocalModelTests.py"
else
  UV_CACHE_DIR="$ROOT/.cache/uv-tests" UV_PYTHON_INSTALL_DIR="$ROOT/.cache/test-python" \
    "$ROOT/Runtime/uv" run --frozen --no-dev --managed-python --python 3.12 \
    --project "$ROOT/Tests/Python" python "$ROOT/Tests/LocalModelTests.py"
fi

APP_TEST_SOURCES=("$ROOT"/Sources/Domain/*.swift "$ROOT"/Sources/Application/*.swift
  "$ROOT"/Sources/Infrastructure/*.swift "$ROOT/Sources/Presentation/Studio.swift"
  "$ROOT/Sources/Presentation/Theme.swift")
swiftc -target arm64-apple-macosx14.0 -parse-as-library -module-cache-path "$ROOT/.cache/modules" "${APP_TEST_SOURCES[@]}" "$ROOT/Tests/StudioTests.swift" -o "$ROOT/.cache/studio-tests"
"$ROOT/.cache/studio-tests"
swiftc -target arm64-apple-macosx14.0 -parse-as-library -module-cache-path "$ROOT/.cache/modules" "${APP_TEST_SOURCES[@]}" "$ROOT/Tests/PipelineTests.swift" -o "$ROOT/.cache/pipeline-tests"
"$ROOT/.cache/pipeline-tests" "$ROOT/examples/two-speakers-demo.mp4" "$ROOT/Engine/.build/release/scribe"

swiftc -target arm64-apple-macosx14.0 -parse-as-library -module-cache-path "$ROOT/.cache/modules" "${APP_TEST_SOURCES[@]}" "$ROOT/Tests/InfrastructureTests.swift" -o "$ROOT/.cache/infrastructure-tests"
"$ROOT/.cache/infrastructure-tests"
swiftc -target arm64-apple-macosx14.0 -parse-as-library -module-cache-path "$ROOT/.cache/modules" "${APP_TEST_SOURCES[@]}" "$ROOT/Tests/CloudTests.swift" -o "$ROOT/.cache/cloud-tests"
"$ROOT/.cache/cloud-tests"
