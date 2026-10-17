import ArgumentParser
import Foundation

struct JointTranscript: Decodable {
    struct Segment: Decodable {
        let start: Double
        let end: Double
        let text: String
        let speaker: String?
        let chunk: Int
        let needsReview: Bool
    }
    let duration: Double
    let segments: [Segment]
    var reviewRanges: [TranscriptReviewRange]? = nil

    func validate(duration actual: Double) throws {
        guard duration.isFinite, abs(duration - actual) < 0.2,
              (reviewRanges ?? []).allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= actual + 0.1 }),
              segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= actual + 0.1 && $0.chunk >= 0 }) else {
            throw ValidationError("Invalid MOSS timestamps. No partial transcript was exported.")
        }
    }

    /// MOSS labels restart at every bounded chunk. Match those labels against
    /// the recording-wide acoustic timeline; never concatenate chunk IDs.
    func reconciled(timeline: [DiarizationSegment]) -> [(segment: Segment, speaker: String?, review: Bool)] {
        var mappings: [Int: [String: String]] = [:]
        for (chunk, pieces) in Dictionary(grouping: segments, by: \.chunk) {
            var scores: [String: [String: Double]] = [:]
            for piece in pieces {
                guard let label = piece.speaker else { continue }
                // Only unopposed voice intervals establish identities. During
                // overlap the text's own labels are useful, but timing alone
                // cannot tell which voice uttered it.
                let boundaries = Set(([piece.start, piece.end] + timeline.flatMap { [max(piece.start, $0.start), min(piece.end, $0.end)] })
                    .filter { $0 >= piece.start && $0 <= piece.end }).sorted()
                for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
                    let middle = (start + end) / 2
                    let active = Set(timeline.filter { $0.start <= middle && $0.end > middle }.map(\.speaker))
                    if active.count == 1, let voice = active.first { scores[label, default: [:]][voice, default: 0] += end - start }
                }
            }
            var candidates: [(label: String, voice: String, score: Double)] = []
            for (label, values) in scores {
                let ordered = values.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                guard let best = ordered.first else { continue }
                let total = values.values.reduce(0, +)
                let rival = ordered.dropFirst().first?.value ?? 0
                if best.value >= 0.3, best.value / total >= 0.65, (best.value - rival) / total >= 0.2 {
                    candidates.append((label, best.key, best.value))
                }
            }
            candidates.sort { $0.score == $1.score ? $0.label < $1.label : $0.score > $1.score }
            var used = Set<String>()
            for candidate in candidates where !used.contains(candidate.voice) {
                mappings[chunk, default: [:]][candidate.label] = candidate.voice
                used.insert(candidate.voice)
            }
        }
        return segments.map { piece in
            let mapped = piece.speaker.flatMap { mappings[piece.chunk]?[$0] }
            let temporal = OutputFormatter.assignSpeaker(start: piece.start, end: piece.end, in: timeline)
            let otherVoice = timeline.contains { $0.speaker != mapped && min(piece.end, $0.end) - max(piece.start, $0.start) > 0.15 }
            let review = piece.needsReview || mapped == nil || temporal.needsReview || otherVoice || (temporal.speaker != nil && mapped != temporal.speaker)
            return (piece, mapped ?? temporal.speaker, review)
        }.sorted { $0.segment.start == $1.segment.start ? $0.segment.end < $1.segment.end : $0.segment.start < $1.segment.start }
    }
}

enum JointTranscriptFormatter {
    static func format(_ transcript: JointTranscript, timeline: [DiarizationSegment], format: OutputFormat) -> String {
        OutputFormatter.formatJoint(transcript: transcript, timeline: timeline, format: format)
    }
}
