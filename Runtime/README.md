# Bundled bootstrap

`uv` is the Apple Silicon binary from Astral uv 0.12.22:
https://github.com/astral-sh/uv/releases/tag/0.12.22

The release archive SHA-256 is recorded in `uv-archive.sha256`. The app ships
this bootstrap so users do not need Homebrew, Python, FFmpeg, or Xcode.
On first Accurate use, it installs managed Python 3.12 and the frozen
`Accurate/uv.lock` dependencies into VoiceScribe's Application Support folder.
Speech models download separately; recordings are processed locally.

To replace a missing binary, download the `uv-aarch64-apple-darwin.tar.gz`
release archive, verify its published checksum, extract it, and copy `uv`
into this directory. Preserve the MIT/Apache license notices in `Licenses`.
