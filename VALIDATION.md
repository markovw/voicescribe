# Validation

## Release 2.0.0, build 2

Adds the optional Deepgram cloud mode and the refactored sidebar (see the Deepgram
section below). `zsh test.sh` passed and `dist/VoiceScribe.app` was built, signed
ad hoc and packaged into `VoiceScribe.dmg`. The sidebar layout and the Deepgram
mode picker were checked by hand in the installed build; no live Deepgram
transcription was run by the release author.

## Initial public release — 1.0.0, build 1

The release preserves the existing history schema, preference keys, transcript
formats, model policy, source namespaces and track offsets. Source layers now
separate domain rules, the transcription use case, infrastructure and SwiftUI.
Library read failures are visible, and restoring settings does not rewrite them.

### Automated results

- Release engine and application build successfully; ad-hoc signature verification
  passes. SwiftPM's native build system is retained for the current toolchain.
- The ordinary `zsh test.sh` passes, including engine attribution, Core/export,
  native file drop, AAC EOF/channel inspection and the six Python runner tests.
- Added repository/preferences, view-model, pipeline and infrastructure suites
  pass: legacy history, atomic writes, failed Clear, edit/undo, request snapshots,
  progress cleanup, failed models, Auto-only fallback and active process cancellation.
- The pipeline suite uses real AVFoundation extraction of the synthetic demo and
  controlled model outputs to check separate-source labels, warnings and cleanup.
- A separate real-model smoke run processes the synthetic 31.42-second demo through
  the complete pipeline: Parakeet produces 10 segments and Qwen produces 11. Text
  is nonempty and timestamps are finite and ordered within each segment. These
  checks do not measure word accuracy or speaker recognition quality. The run uses
  cached models/runtime, explicitly assigns one speaker per container track, and
  never reads or writes the normal transcript history.
- The frozen Python test environment bootstraps without a machine-specific Python
  path. Speech weights are not required for the regular regression suite.
- Public-file checking passes for source and the built app. Personal home paths,
  author addresses and checked token/key patterns were not found. Third-party
  binary notices and upstream CI paths remain unchanged.
- Shell syntax and whitespace checks pass. The macOS 14 deployment target compiles;
  execution on macOS 14 itself has not been verified.

### Manual and publication status

Native accessibility confirms that the app launches with an empty isolated
library and available model/file controls. On 2026-10-17 the user reported normal
operation after manual testing and explicitly approved release publication. The
[manual checklist](docs/MANUAL_TESTING.md) remains available for future checks.
The validation build starts with an isolated library and settings. Personal recordings,
transcripts, runtime caches and historical validation notes are excluded from Git.

Publication uses a clean repository with a neutral commit author and no inherited
history. The prior repository, its history and old release assets remain in a
private archive. Only the reviewed source and newly packaged artifacts belong to
the initial public release. The hosting account name remains visible on GitHub.

## Deepgram mode (automated checks passed; live API unverified)

Verified on 2026-10-29 (Apple Silicon, macOS toolchain): `zsh test.sh` passes in full,
including `Cloud tests passed`, and `zsh build.sh --no-install` builds and signs
`dist/VoiceScribe.app`. The app was not launched and no Deepgram request was sent.

Automated: `Tests/CloudTests.swift` covers the request query, response parsing,
offsets, per-source speakers, error messages, routing and key storage with fakes.
No network call is made by the tests.

Manual checks to run before release:
- Save, replace and remove the API key; relaunch and confirm it persists.
- Transcribe the synthetic demo in Russian and English; check speaker labels.
- Wrong key → readable 401 message; offline → connection message; Stop cancels the upload.
- Video with several audio tracks keeps per-source timing.
- Ad-hoc signing changes on every build, so macOS may ask once to allow Keychain access.
- Stereo in one track is sent as-is; Deepgram mixes channels (assumed, not verified).
