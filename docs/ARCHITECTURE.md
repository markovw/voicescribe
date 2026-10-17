# Architecture

VoiceScribe uses a small layered architecture with a SwiftUI view model and
constructor injection. The goal is to isolate effects and preserve the existing
media workflow, rather than introduce a framework or a protocol for every type.

| Layer | Responsibility | Dependencies |
| --- | --- | --- |
| Domain | Transcript editing, export, recognition policy, engine DTOs | Foundation |
| Application | One transcription operation and its request/progress contract | Domain and adapter contracts |
| Infrastructure | JSON storage, defaults, process execution, AVFoundation export, Python bootstrap | Foundation, AVFoundation |
| Presentation | View state, user actions, playback, file dialogs and SwiftUI rendering | Application and Domain |

`AppDependencies` is the composition root. `Studio` receives a repository, settings
store and service factory. Each Start creates a fresh `TranscriptionPipeline`
with its own cancellable process runner and audio exporter. Playback stays on the
main actor; blocking subprocess waits execute in detached tasks. Temporary media
is deleted when an operation completes or fails. Cancellation terminates the
active subprocess and export before the view model accepts a result.

The pipeline keeps source layout, explicit one-speaker-per-track ownership,
voice clustering and recognition model selection distinct. Auto can retry a
failed MOSS job with Qwen Small; a manually selected model fails visibly. Domain
code namespaces speakers per source and retains text/timing review warnings.

The version 1 JSON schema, identity fields and preference keys are preserved.
Library writes remain atomic. Clear persists an empty library before changing UI
state, so a write failure leaves records available. Read failures are visible.

Protocols sit at changeable boundaries: `TranscriptRepository`,
`PreferencesStoring`, `TranscriptionServicing`, `ProcessRunning`, `AudioPreparing`, `AudioExporting`
and `LocalBatchRunning`. Value types implement the transcript and model policies.
Tests replace effects with controlled adapters and use temporary storage; pipeline
tests also export real synthetic media through AVFoundation. Those tests check
orchestration, not speech recognition accuracy or model quality.

## Publication privacy

Source files contain no developer home paths or personal repository URLs. Build
prefix maps and stripped debug symbols remove local source/object paths from the
distributed Swift executables. Upstream binaries and license notices retain their
original third-party attribution and may contain upstream CI paths.

`scripts/check-public-files.py --app dist/VoiceScribe.app` checks the current
snapshot and optional built app. It is a targeted check, not a vulnerability audit.
`scripts/prepare-public-snapshot.py work/public-candidate` creates a separate local
repository with one neutral commit and no remote, excluding the original history,
ignored caches, recordings and build outputs. Existing remote history, old release
assets, issue discussions and the GitHub account identity are outside that snapshot.
Publication requires a separate decision after manual validation.
