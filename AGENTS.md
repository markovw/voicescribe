# Repository Guidelines

## Project Structure & Module Organization

VoiceScribe is a local transcription app for Apple Silicon Macs running macOS 14+.

- `Sources/Domain/`: transcript models, export formats and recognition policies.
- `Sources/Application/`: transcription use case, request and progress contracts.
- `Sources/Infrastructure/`: persistence, preferences, subprocesses, AVFoundation and local runtime adapters.
- `Sources/Presentation/`: SwiftUI views and the main-actor view model; `Sources/App.swift` is the application entry point.
- `Engine/`: modified Scribe Swift package; CLI commands live in `Sources/scribe/Commands/`, attribution and formatting in `Core/`.
- `Accurate/`: Python Qwen ASR/alignment code and frozen `uv.lock`; `Runtime/` supplies the bundled uv bootstrap.
- `Tests/`: standalone Swift regression executables. `examples/` contains synthetic media fixtures.
- `Assets/`, `Info.plist`, and `Licenses/`: app resources, metadata, and attribution notices.
- `dist/`, `.cache/`, `Engine/.build/`, and `work/` are ignored build or working directories.

## Build, Test, and Development Commands

Run from the repository root with Xcode command-line tools installed:

- `rtk proxy zsh build.sh`: build and sign `dist/VoiceScribe.app`, then automatically install/update `/Applications/VoiceScribe.app`. Quit VoiceScribe first; failed installation preserves `dist/`. Builds the engine if missing.
- `rtk proxy zsh build.sh --rebuild-engine`: rebuild the release engine after engine changes.
- `rtk proxy zsh test.sh`: run attribution, transcript/export, and native file-drop regressions; requires the built engine.
- `rtk proxy open /Applications/VoiceScribe.app`: launch the installed build.
- `rtk proxy zsh package-dmg.sh`: package the built app into `dist/VoiceScribe.dmg`.

## Coding Style & Naming Conventions

Use four-space indentation. Swift types use `UpperCamelCase`; functions and properties use `lowerCamelCase`. Python functions use `snake_case`. Match nearby code and keep UI strings English while preserving multilingual transcript content. No formatter or linter configuration is present. Preserve dependency locks and third-party notices when updating dependencies.

## Testing Guidelines

Tests use Swift assertions and the engine's `verify-attribution` command, without downloading speech models. Follow the `*Tests.swift` and `@main` executable pattern. Add regressions for changed persistence, exports, timestamps, or speaker assignment. No numeric coverage target is configured. Document manual UI or transcription checks and unverified behavior in `VALIDATION.md`.

## Commit & Pull Request Guidelines

The main branch is `master`. Use concise imperative subjects, such as `Fix speaker reassignment persistence`. PRs should describe behavior changes, validation performed, and limitations; link relevant issues and include screenshots for UI changes.

## Privacy & Agent Instructions

Keep personal recordings, transcripts, and runtime caches out of commits. Use synthetic fixtures and an isolated test library for manual checks; preserve user history and source media.

Prefix shell commands with `rtk` when available; use `rtk proxy` for commands that need unfiltered execution. No machine-specific configuration is required.

Keep work on a development branch until manual validation and explicit release approval. Do not publish, push, change repository visibility, or rewrite existing published Git history as part of a refactor.
