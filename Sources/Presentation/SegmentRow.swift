import SwiftUI

private final class RowInteraction: ObservableObject {
    @Published var hovered = false
}

struct SegmentRow: View {
    @EnvironmentObject var s: Studio
    let segment: Utterance
    @StateObject private var interaction = RowInteraction()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Label(stamp(segment.start), systemImage: "play.circle")
                    .font(uiFont(12)).foregroundStyle(muted).allowsHitTesting(false)
                Menu {
                    ForEach(s.speakers.filter { !Transcript.isUnknown($0) }, id: \.self) { speaker in
                        Button(s.document?.name(speaker) ?? speaker) { s.update(segment.id, speaker: speaker, reviewed: true) }
                    }
                    Divider()
                    Button("Unknown speaker") { s.update(segment.id, speaker: "Unknown") }
                } label: {
                    Text(s.document?.name(segment.speaker) ?? segment.speaker)
                        .font(uiFont(12, weight: .medium)).foregroundStyle(s.color(segment.speaker)).lineLimit(1)
                }.menuStyle(.borderlessButton).fixedSize().help("Change speaker")
                Spacer()
                if segment.needsReview {
                    Button { s.update(segment.id, reviewed: true) } label: {
                        Label("Confirm", systemImage: "checkmark").font(uiFont(12)).foregroundStyle(accent)
                    }.buttonStyle(.plain).help("Uncertain speaker assignment. Click to confirm this segment.")
                }
            }
            Text(segment.text)
                .font(uiFont(17)).lineSpacing(6).foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: .leading).allowsHitTesting(false)
        }.padding(.horizontal, 14).padding(.vertical, 21).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                Button { s.seek(segment) } label: {
                    Rectangle().fill(s.selected == segment.id || interaction.hovered ? soft : ink)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("Play segment at \(stamp(segment.start))")
                    .help("Click to play this segment")
            }
            .onHover { interaction.hovered = $0 }
            .overlay(alignment: .leading) {
                if s.selected == segment.id { Rectangle().fill(s.color(segment.speaker)).frame(width: 2).allowsHitTesting(false) }
            }
            .overlay(alignment: .bottom) { Rectangle().fill(rule).frame(height: 1).allowsHitTesting(false) }
    }
}
