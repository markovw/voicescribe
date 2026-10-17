# VoiceScribe Homebrew tap template

This is a publication template, not a published tap. Replace YOUR_GITHUB_USERNAME and the app repository name in Casks/voicescribe.rb.

1. Publish dist/VoiceScribe.dmg from the main project as an asset on the application repository release tagged v0.6.0. The cask SHA-256 matches that exact DMG.
2. Create a public GitHub repository named homebrew-tap and put Casks/voicescribe.rb at that path.
3. Friends with Homebrew installed can run:

```sh
brew install --cask YOUR_GITHUB_USERNAME/tap/voicescribe
```

For a new release, upload a newly versioned release asset and update version and sha256 in the cask. Users update with:

```sh
brew update
brew upgrade --cask YOUR_GITHUB_USERNAME/tap/voicescribe
```

The current build is Apple Silicon only, macOS 14+. It is ad-hoc signed, not Developer ID signed or notarized. Homebrew does not replace Apple signing and notarization. App launch/security behavior on a friend's Mac has not been tested.
