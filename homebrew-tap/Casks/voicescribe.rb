# Replace YOUR_GITHUB_USERNAME and the app repository name before publishing.
cask "voicescribe" do
  version "0.6.0"
  sha256 "3e2a5ddb3f1cb27a5262cc4622958078c48f962ddd072fb83946798f052d9b43"

  url "https://github.com/YOUR_GITHUB_USERNAME/voicescribe/releases/download/v#{version}/VoiceScribe.dmg"
  name "VoiceScribe"
  desc "Local audio and video transcription with speaker identification"
  homepage "https://github.com/YOUR_GITHUB_USERNAME/voicescribe"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "VoiceScribe.app"
end
