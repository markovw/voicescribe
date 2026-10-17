import ArgumentParser
import FluidAudio
import Foundation

/// Local acoustic analysis doubles as the voice timeline for transcription.
struct ProfileAudio: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Analyze voices and overlap locally, saving a reusable timeline.")
    @Argument var audioFile: String
    @Option(name: .long) var output: String
    @Option(name: .long) var speakerModel: SpeakerModel = .nemotron
    @Option(name: .long) var speakers: Int?

    func run() async throws {
        let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: audioFile))
        let (segments, _) = try await LocalVoiceAnalysis.detect(samples: samples, model: speakerModel, speakers: speakers, minTurn: 0.15)
        let profile = VoiceTimeline(duration: Double(samples.count) / 16000, segments: segments)
        try JSONEncoder().encode(profile).write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}

struct VoiceTimeline: Codable {
    let duration: Double
    let segments: [DiarizationSegment]
    let speakerCount: Int
    let speechSeconds: Double
    let overlapSeconds: Double

    init(duration: Double, segments: [DiarizationSegment]) {
        self.duration = duration
        self.segments = segments
        speakerCount = Set(segments.map(\.speaker)).count
        // Union active voices, not a sum of duplicate same-speaker intervals.
        var events: [(time: Double, speaker: String, delta: Int)] = []
        for segment in segments {
            let start = max(0, segment.start), end = min(duration, segment.end)
            if end > start {
                events.append((start, segment.speaker, 1))
                events.append((end, segment.speaker, -1))
            }
        }
        var speech = 0.0, overlap = 0.0, previous = 0.0
        var counts: [String: Int] = [:]
        var voices = 0
        for event in events.sorted(by: { $0.time < $1.time }) {
            if voices > 0 { speech += event.time - previous }
            if voices > 1 { overlap += event.time - previous }
            let before = counts[event.speaker, default: 0]
            let after = before + event.delta
            counts[event.speaker] = after
            if before == 0 && after > 0 { voices += 1 }
            if before > 0 && after == 0 { voices -= 1 }
            previous = event.time
        }
        speechSeconds = speech
        overlapSeconds = overlap
    }
}

enum LocalVoiceAnalysis {
    static func detect(samples: [Float], model: SpeakerModel, speakers: Int?, minTurn: Double)
        async throws -> ([DiarizationSegment], OfflineDiarizerModels?) {
        guard speakers == nil || (1...10).contains(speakers!) else { throw ValidationError("Speaker count must be 1–10 or Auto.") }
        if model == .nemotron {
            guard speakers == nil || speakers! <= 8 else { throw ValidationError("Nemotron supports up to 8 voices per source. Choose Community or Auto.") }
            let config = Nemotron3Config.offline
            let models = try await Nemotron3Models.loadFromHuggingFace(config: config)
            let result = try Nemotron3Diarizer(config: config, models: models).processComplete(samples)
            let intervals = Nemotron3Diarizer.segments(probabilities: result.probabilities,
                frameCount: result.frameCount, minDurationSeconds: Float(minTurn))
            return (intervals.map { .init(speaker: "S\($0.speakerIndex + 1)", start: Double($0.startSeconds), end: Double($0.endSeconds)) }, nil)
        }
        var config = OfflineDiarizerConfig(clusteringThreshold: 0.6, segmentationStepRatio: 0.1, minSegmentDuration: minTurn)
        config.postProcessing.exclusiveSegments = false
        config.zeroVoteReembed.enabled = true
        if let speakers { config.clustering.numSpeakers = speakers }
        let manager = OfflineDiarizerManager(config: config)
        let models = try await OfflineDiarizerModels.load()
        manager.initialize(models: models)
        let result = try await manager.process(audio: samples)
        return (result.segments.map { .init(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }, models)
    }
}
