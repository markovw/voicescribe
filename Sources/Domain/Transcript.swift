import Foundation

struct Transcript: Codable, Identifiable {
    var id = UUID()
    var title: String
    var sourcePath: String
    var created = Date()
    var duration: Double
    var segments: [Utterance]
    var names: [String: String] = [:]
    var audioLayout: String? = nil
    var processingDuration: Double? = nil
    var modelSummary: String? = nil
    var coverageWarnings: [String]? = nil
    var processingTimeLabel: String? {
        guard let duration = processingDuration, duration.isFinite, duration >= 0 else { return nil }
        let seconds = max(1, Int(duration.rounded()))
        return seconds < 60 ? "Transcribed in \(seconds)s" : "Transcribed in \(seconds / 60)m \(seconds % 60)s"
    }
    var speakers: [String] { Array(Set(segments.map { $0.speaker })).sorted() }
    static func isUnknown(_ speaker: String) -> Bool { speaker == "Не определён" || speaker == "Unknown" }
    var speakerCount: Int { speakers.filter { !Self.isUnknown($0) }.count }
    var reviewCount: Int { segments.filter(\.needsReview).count }
    func name(_ speaker: String) -> String { names[speaker] ?? (Self.isUnknown(speaker) ? "Unknown speaker" : speaker) }
    mutating func normalizeGeneratedTitle() {
        let base = URL(fileURLWithPath: sourcePath).deletingPathExtension().lastPathComponent
        var old = title
        while old.hasSuffix(" · улучшено") { old.removeLast(" · улучшено".count) }
        if old == base { title = base + "-transcribed" }
    }
    mutating func updateSegment(_ id: UUID, text: String? = nil, speaker: String? = nil, reviewed: Bool = false) {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
        if let text { segments[i].text = text }
        if let speaker { segments[i].speaker = speaker }
        if let speaker { segments[i].needsReview = Self.isUnknown(speaker) }
        else if reviewed { segments[i].needsReview = false }
    }
    mutating func removeSpeaker(_ speaker: String) {
        guard !Self.isUnknown(speaker) else { return }
        names.removeValue(forKey: speaker)
        for i in segments.indices where segments[i].speaker == speaker {
            segments[i].speaker = "Unknown"
            segments[i].needsReview = true
        }
    }
    mutating func confirmAllReviews() {
        for i in segments.indices { segments[i].needsReview = false }
    }
    /// Cluster IDs may swap on a fresh pass. Match names by common speaking
    /// time, once per speaker, rather than copying numeric labels blindly.
    mutating func copySpeakerNames(from previous: Transcript) {
        var weights: [String: [String: Double]] = [:]
        for fresh in segments where !Self.isUnknown(fresh.speaker) {
            for old in previous.segments where !Self.isUnknown(old.speaker) {
                let overlap = max(0, min(fresh.end, old.end) - max(fresh.start, old.start))
                weights[fresh.speaker, default: [:]][old.speaker, default: 0] += overlap
            }
        }
        var pairs: [(fresh: String, old: String, weight: Double)] = []
        for (fresh, scores) in weights {
            for (old, score) in scores where score > 0 { pairs.append((fresh, old, score)) }
        }
        pairs.sort { $0.weight > $1.weight }
        var assigned = Set<String>(), used = Set<String>()
        for pair in pairs where !assigned.contains(pair.fresh) && !used.contains(pair.old) {
            assigned.insert(pair.fresh); used.insert(pair.old)
            if let name = previous.names[pair.old] { names[pair.fresh] = name }
        }
    }

}

struct Utterance: Codable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    var speaker: String
    var needsReview: Bool
}

extension Transcript {
    mutating func copySourceSpeakerNames(from previous: Transcript) {
        guard previous.sourcePath == sourcePath, previous.audioLayout == audioLayout else { return }
        let current = Set(segments.map(\.speaker))
        names = previous.names.filter { current.contains($0.key) }
    }

    /// Track identity is not person identity. Keep all local clusters and review flags.
    mutating func namespaceSpeakers(sourceIndex: Int) {
        for i in segments.indices where !Self.isUnknown(segments[i].speaker) {
            segments[i].speaker = "Source \(sourceIndex + 1) · \(segments[i].speaker)"
        }
    }
}

