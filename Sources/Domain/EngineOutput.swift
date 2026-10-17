import Foundation

struct EngineOutput: Decodable {
    struct Metadata: Decodable { var duration: Double; var diarization: Bool; var coverageWarnings: [String]? = nil }
    struct Segment: Decodable {
        var start: Double; var end: Double; var text: String
        var speaker: String?; var needsReview: Bool?
    }
    var metadata: Metadata
    var segments: [Segment]
    func transcript(source: URL) -> Transcript {
        Transcript(title: source.deletingPathExtension().lastPathComponent + "-transcribed", sourcePath: source.path,
            duration: metadata.duration, segments: segments.filter { !$0.text.isEmpty }.map {
                Utterance(start: $0.start, end: $0.end, text: $0.text,
                    speaker: $0.speaker ?? "Unknown", needsReview: $0.needsReview ?? ($0.speaker == nil))
            }, coverageWarnings: metadata.coverageWarnings)
    }
}

struct AudioPlan: Decodable {
    var separate: Bool
    var paths: [String]
    var containerTracks: Int
    var channels: Int
    var quality: [AudioQuality]? = nil
    var description: String { separate ? "Separate audio · \(paths.count) sources · Voices detected within each" : "Mixed audio · All voices detected together" }
}

