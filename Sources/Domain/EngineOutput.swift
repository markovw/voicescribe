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

    /// The container track an engine file came from: `track-N-channel-C.wav`
    /// or `track-N-mono.wav`. A combined recording has none.
    static func origin(of path: String) -> Int? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard name.hasPrefix("track-") else { return nil }
        let rest = name.dropFirst("track-".count)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        return Int(rest[..<dash])
    }

    /// Separate sources, each from its own container track: track ownership holds.
    var ownsTracks: Bool {
        let origins = paths.map(Self.origin(of:))
        return separate && paths.count > 1 && origins.allSatisfy { $0 != nil } && Set(origins.compactMap { $0 }).count == origins.count
    }
}

