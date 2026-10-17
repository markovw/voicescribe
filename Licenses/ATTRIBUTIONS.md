# Attribution and modifications

VoiceScribe includes Scribe by The Agile Monkeys Inc. (Apache-2.0), based on upstream commit `e951d6181e214475629fda329177746e2f8f4821`.
Source: https://github.com/theam/scribe

VoiceScribe modifications: FluidAudio pinned to 0.17.5; updated ASR API; Nemotron 3 offline diarization; 0.15-second minimum voice turns; bounded timestamp-gap recovery; ASR-guided WeSpeaker acoustic recovery; word-level speaker attribution by maximum overlap; speaker-change segment splitting; review flags; normalized speaker labels; attribution verification command. Upstream copyrights and licenses are preserved.

FluidAudio 0.17.5: https://github.com/FluidInference/FluidAudio/tree/v0.17.5 (Apache-2.0).
swift-argument-parser 1.7.1: https://github.com/apple/swift-argument-parser (Apache-2.0).

Model attribution:
- OpenMOSS MOSS-Transcribe-Diarize 0.9B (downloaded, not bundled), Apache-2.0: https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize
- Qwen3-ASR 0.6B MLX 8-bit conversion (downloaded, not bundled), Apache-2.0: https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-8bit
- Qwen3-ASR 1.7B and Qwen3-ForcedAligner 0.6B, Apache-2.0: https://github.com/QwenLM/Qwen3-ASR
- MLX 8-bit conversions (downloaded, not bundled): https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit and https://huggingface.co/mlx-community/Qwen3-ForcedAligner-0.6B-8bit
- NVIDIA Nemotron 3 Diarization, OpenMDW-1.1: https://huggingface.co/nvidia/Nemotron-3-Diarization
- FluidInference Nemotron 3 CoreML conversion: https://huggingface.co/FluidInference/nemotron-3-diarization-coreml
- NVIDIA Parakeet TDT 0.6b v3, CC-BY-4.0: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- pyannote speaker-diarization community-1, CC-BY-4.0: https://huggingface.co/pyannote/speaker-diarization-community-1
- FluidInference CoreML model conversions: https://huggingface.co/FluidInference

FluidAudio also includes third-party components. Their license notices are copied under `FluidAudioThirdParty/`. Models are downloaded independently into FluidAudio's cache, not bundled in the application.

Geist Mono font, Copyright 2024 The Geist Project Authors (https://github.com/vercel/geist-font.git). SIL Open Font License 1.1: https://github.com/google/fonts/tree/main/ofl/geistmono. Included in Assets/Fonts; license: GeistMono-OFL.txt.

Accurate runner uses MLX Audio 0.5.7 (MIT, Prince Canuma and contributors): https://github.com/Blaizzy/mlx-audio. License: MLX-Audio.txt. Dependencies are downloaded separately using Accurate/uv.lock; their distributions retain upstream license notices.

Bundled Astral uv 0.12.22 (MIT/Apache-2.0): https://github.com/astral-sh/uv/tree/0.12.22. Licenses: uv-MIT.txt and uv-Apache.txt. The upstream release archive checksum is preserved in Runtime/uv-archive.sha256.
