import SwiftUI
import AVKit

private final class PlayerInteraction: ObservableObject {
    @Published var hovering = false
    @Published var scrubbing = false
    @Published var scrubTime = 0.0
}

struct RecordingPlayer: View {
    @EnvironmentObject var s: Studio
    @StateObject private var interaction = PlayerInteraction()

    var body: some View {
        VStack(spacing: 0) {
            NativeVideoPlayer(player: s.player).frame(height: 170).allowsHitTesting(false)
                .overlay {
                    Button { s.togglePlayback() } label: {
                        ZStack {
                            Color.clear
                            if !s.isPlaying || interaction.hovering {
                                Image(systemName: s.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 22, weight: .medium)).foregroundStyle(textColor)
                                    .frame(width: 52, height: 52)
                                    .background(ink.opacity(0.85), in: Circle())
                                    .overlay(Circle().stroke(rule, lineWidth: 1))
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(s.isPlaying ? "Pause video" : "Play video")
                        .help("Click the video to play or pause")
                        .onHover { interaction.hovering = $0 }
                }
            Rectangle().fill(rule).frame(height: 1)
            VStack(spacing: 8) {
                Slider(value: Binding(
                    get: { interaction.scrubbing ? interaction.scrubTime : min(s.currentTime, s.playbackDuration) },
                    set: { interaction.scrubTime = $0 }),
                    in: 0...max(0.01, s.playbackDuration),
                    onEditingChanged: { editing in
                        if editing { interaction.scrubTime = s.currentTime }
                        interaction.scrubbing = editing
                        if !editing { s.seekPlayback(to: interaction.scrubTime) }
                    })
                    .controlSize(.mini).tint(accent).disabled(s.playbackDuration <= 0)
                    .accessibilityLabel("Playback position")
                HStack(spacing: 10) {
                    Button { s.togglePlayback() } label: {
                        Image(systemName: s.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 22, height: 22)
                    }.buttonStyle(.plain).foregroundStyle(textColor)
                        .help(s.isPlaying ? "Pause" : "Play")
                        .accessibilityLabel(s.isPlaying ? "Pause" : "Play")
                    Text("\(stamp(interaction.scrubbing ? interaction.scrubTime : s.currentTime)) / \(stamp(s.playbackDuration))")
                        .font(uiFont(11)).monospacedDigit().foregroundStyle(muted)
                    Spacer(minLength: 0)
                    Button { s.playbackVolume = s.playbackVolume == 0 ? 1 : 0 } label: {
                        Image(systemName: s.playbackVolume == 0 ? "speaker.slash" : "speaker.wave.2")
                            .frame(width: 20, height: 22)
                    }.buttonStyle(.plain).foregroundStyle(muted)
                        .help(s.playbackVolume == 0 ? "Unmute" : "Mute")
                        .accessibilityLabel(s.playbackVolume == 0 ? "Unmute" : "Mute")
                    Slider(value: $s.playbackVolume, in: 0...1).controlSize(.mini).tint(muted)
                        .frame(width: 42).accessibilityLabel("Volume")
                }
            }.padding(.horizontal, 10).padding(.vertical, 10).background(soft)
        }.overlay(Rectangle().stroke(rule, lineWidth: 1))
            .onChange(of: s.source) { _, _ in interaction.scrubbing = false; interaction.hovering = false }
    }
}

