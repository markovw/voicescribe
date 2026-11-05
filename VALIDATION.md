# Validation

## Release 2.1.0, build 3

Drops repeated audio sources in multi-track recordings (Deepgram and local), turns
on "One speaker per audio track" by default for multi-track files, and includes the
long-file reliability and Accurate speed work below. `zsh test.sh` passed and
`dist/VoiceScribe.app` was built, signed ad hoc and packaged into `VoiceScribe.dmg`.
The user ran the installed build with Deepgram on a real 3-track meeting recording;
the release author confirmed the same recording live through the app's cloud path
(2 sources, 1 redundant track skipped, no repeats). The full manual checklist in
`docs/MANUAL_TESTING.md` was not rerun for this release.

### Long-file reliability and Accurate speed

Verified on 2026-10-30 (M4 Pro, 24 GB) with an isolated library, synthetic
recordings and cached models; the installed app and history were not touched.

- Local extraction now decodes each track once to 16 kHz PCM WAV instead of
  re-encoding AAC. Before the change a 5-minute synthetic video failed in
  `inspect-audio` with `OSStatus -39` (AAC end-of-stream in the engine decoder);
  it now completes, as does a 60-minute one. Deepgram still uploads M4A.
- Accurate decodes up to eight similar-length Qwen fragments per batch. Rows are
  equalised with real neighbouring audio, never appended silence, because even
  0.2 s of silence changes Qwen output. WER over three chunkings was equivalent:
  EN 0.20% sequential vs 0.24% batched (2520 words), RU 9.06% vs 8.55% (1368
  words; mostly number/term normalisation such as «два ноль»/«2.0»).
- Parakeet no longer joins words before numbers («версии2.0» → «версии 2.0»):
  its standalone space token now separates words (`verify-attribution` covers it).
- Timings, whole pipeline including extraction: 5-minute EN — Accurate Qwen 1.7B
  23.3 s → 12.3 s, Fast Parakeet 1.9 s. 60-minute EN — Fast Auto 19.6 s,
  Accurate Qwen 1.7B 116 s with 2.5 GB peak resident memory.
- `zsh test.sh` passes, including new PCM export and batched-runner tests;
  `zsh build.sh --no-install` builds and signs `dist/VoiceScribe.app`.

Not verified: real (non-synthetic) Russian conversations, the Qwen 0.6B model
(weights not cached), and the app UI with this build.

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

### Deepgram: redundant tracks (automated checks passed; live API unverified)

Verified on 2026-11-05: `zsh test.sh` passes in full. When a file has several audio
tracks and "One speaker per audio track" is off, the cloud path now runs the engine's
`inspect-audio` before upload, same as local mode. Duplicate tracks and a full mix of
the other tracks are dropped. When independence is uncertain, the tracks are combined
into one source, so Deepgram numbers speakers once for the whole recording.
Inspection failure falls back to uploading every track; Stop cancels it.
With "One speaker per audio track" on, redundant tracks are dropped too, but only
when the remaining sources are whole container tracks; a combined result keeps all.

Automated: `Tests/InfrastructureTests.swift` runs the built engine on synthetic
microphone + remote + mix tracks (and a duplicate) and checks only the two stems
remain; plan mapping, fallback and cancellation use a fake runner.
`Tests/CloudTests.swift` checks that skipped tracks are never uploaded.
A manual check with synthetic AAC (48 kHz, 96 kbps) tracks also dropped the mix.

Manual: re-run a real multi-track meeting recording (Zoom/OBS) through Deepgram and
confirm the speaker list no longer repeats people under extra "Source N" labels.

Live check on 2026-11-05 (user's multi-track meeting, 3 container tracks, Deepgram):
the full-mix track was skipped ("2 sources · 1 redundant track skipped"). Deepgram
still splits each remaining track into 3 clusters: one dominant voice per track plus
short low-density fragments (backchannel or noise, not echo by text comparison).

"One speaker per audio track" is on by default for a fresh install; a saved choice
is kept. It applies only to files with several audio tracks: a single-track file is
always diarized (cloud and local), and voice model and speaker count stay editable.

### Repeated sources: stereo tracks and safety net (2026-11-05)

Regression: with "One speaker per audio track" on, the user's recording again repeated
every line. Its three container tracks are stereo, so inspection returns channel files
(`track-N-channel-0.wav`); the cloud path only mapped mono tracks back to their owners,
rejected the result and uploaded all three tracks including the full mix.

Fix: each inspected source records its container track (`AudioPlan.origin(of:)`), so
ownership holds for stereo channels. Local mode inspects with `automatic` too and keeps
the result when each source is its own track; otherwise it uses every track as before.
After recognition, `RepeatedSources` drops a source whose words mostly repeat other
sources at the same time (threshold 50%, at least 30 words), in both cloud and local
modes, and renumbers the remaining sources.

Checked on the user's file without network (recorded uploads, replayed text):
- Per-track on and off: 2 uploads (`source-0.m4a`, `source-1.m4a`), "1 redundant track skipped".
- Earlier duplicated run replayed through the safety net: the mix (6889 words, 93%
  repeated) is dropped; stems repeat 3–7% of words and stay.
- Inspection of the 82-minute file takes about 100 s before upload.
Unverified: a live Deepgram request with this build.
