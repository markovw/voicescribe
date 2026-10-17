# VoiceScribe

Local audio and video transcription with speaker diarization.

- Apple Silicon, macOS 14+
- Fast: automatic model selection; Accurate: choose your model
- Parakeet, Qwen3 ASR, and experimental MOSS
- Mixed and separate audio tracks, text and subtitle export

## Installation

Download the DMG from [Releases](../../releases) and drag the app into Applications. The app is ad-hoc signed and not notarized by Apple.

Models download on first use. All transcription runs locally on your Mac.

## Development

```sh
zsh build.sh               # build and install; quit the app first
zsh build.sh --no-install  # build without replacing an installed app
zsh test.sh                # regression tests
zsh package-dmg.sh         # create a DMG
```

[Validation](VALIDATION.md) · [Model research](docs/research/transcription-models-2026-10-04.md) · [Licenses](Licenses/ATTRIBUTIONS.md)

Tests use temporary storage and synthetic media. On first run, the bundled `uv`
prepares a frozen minimal Python test environment (NumPy and SoundFile); no speech
weights are needed. Set `VOICESCRIBE_TEST_PYTHON` to use an existing compatible
interpreter instead.

## Architecture

SwiftUI views bind to a main-actor `Studio` view model. It delegates transcription
through `TranscriptionServicing`, persistence through `TranscriptRepository`, and
settings through `PreferencesStoring`. `AppDependencies` connects the production
adapters; tests inject isolated storage and controlled services.

The transcription pipeline owns track extraction, model selection, recognition,
and assembly for one operation. Process execution, AVFoundation export, and the
Python runtime each have a separate adapter. Domain types contain no SwiftUI or
AVFoundation dependencies. Version 1 history and preference keys remain readable.

Optional real-model smoke test: after building, `zsh scripts/smoke-local-models.sh`
uses the installed runtime and cached Parakeet/Qwen weights on the synthetic demo.
It requires those runtime files to match the candidate and never opens history.

See [architecture](docs/ARCHITECTURE.md) and [manual validation](docs/MANUAL_TESTING.md).
