import CoreML
import FluidAudio
import Foundation

/// An ASR-guided second pass for speech omitted by segmentation. All comparisons
/// use raw WeSpeaker vectors from the same recording, never temporal guesswork.
final class SpeakerRecovery {
    let models: OfflineDiarizerModels
    let samples: [Float]
    init(models: OfflineDiarizerModels, samples: [Float]) {
        self.models = models; self.samples = samples
    }

    func recover(asr: ASRResult, timeline: [DiarizationSegment], log: (String) -> Void) throws -> [DiarizationSegment] {
        var references: [String: [[Float]]] = [:]
        for speaker in Set(timeline.map { $0.speaker }).sorted() {
            let candidates = timeline.filter { interval in
                interval.speaker == speaker && interval.end - interval.start >= 1.5 &&
                !timeline.contains { other in
                    other.speaker != speaker && min(interval.end, other.end) > max(interval.start, other.start)
                }
            }.sorted { $0.start < $1.start }
            guard !candidates.isEmpty else { continue }
            let count = min(20, candidates.count)
            for i in 0..<count {
                let interval = candidates[i * candidates.count / count]
                let lo = interval.start + 0.1, hi = min(interval.end - 0.1, lo + 5)
                references[speaker, default: []].append(try embedding(start: lo, end: hi))
            }
        }
        guard references.count >= 2 else { return timeline }
        let missing = OutputFormatter.missingSpeech(asrResult: asr, timeline: timeline)
        var recovered: [DiarizationSegment] = []
        for (start, end) in missing where end - start >= 0.5 {
            let query = try embedding(start: start, end: end)
            let scores = references.map { speaker, vectors -> (String, Float) in
                let best = vectors.map { Self.cosine(query, $0) }.sorted(by: >).prefix(3)
                return (speaker, best.reduce(0, +) / Float(best.count))
            }.sorted { $0.1 > $1.1 }
            guard let best = scores.first else { continue }
            let margin = best.1 - scores[1].1
            let short = end - start < 1.2
            if best.1 >= (short ? 0.65 : 0.5), margin >= (short ? 0.18 : 0.10) {
                recovered.append(.init(speaker: best.0, start: start, end: end))
                log(String(format: "Recovered voice: %@ %.2f-%.2f similarity=%.3f margin=%.3f", best.0, start, end, best.1, margin))
            }
        }
        log("Voice recovery: \(recovered.count) of \(missing.count) missing speech spans assigned acoustically")
        return (timeline + recovered).sorted { $0.start < $1.start }
    }

    /// Match the SDK's zero-padded embedSpan method. The weights cover exactly
    /// the requested speech; neighbouring voices cannot enter the pooled vector.
    func embedding(start: Double, end: Double) throws -> [Float] {
        let constraint = models.fbankModel.modelDescription.inputDescriptionsByName["audio"]!.multiArrayConstraint!
        let shape = constraint.shape
        let audio = try MLMultiArray(shape: shape, dataType: .float32)
        let ptr = audio.dataPointer.assumingMemoryBound(to: Float.self)
        ptr.initialize(repeating: 0, count: audio.count)
        let lo = max(0, Int(start * 16000)), hi = min(samples.count, Int(end * 16000))
        let length = min(audio.count, max(0, hi - lo))
        guard length > 0 else { return Array(repeating: 0, count: 256) }
        for i in 0..<length { ptr[i] = samples[lo + i] }
        let fbankInput = try MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: audio)])
        let features = try models.fbankModel.prediction(from: fbankInput).featureValue(for: "fbank_features")!
        let weightShape = models.embeddingModel.modelDescription.inputDescriptionsByName["weights"]!.multiArrayConstraint!.shape
        let weights = try MLMultiArray(shape: weightShape, dataType: .float32)
        let wptr = weights.dataPointer.assumingMemoryBound(to: Float.self)
        let active = min(weights.count, max(1, Int((Double(length) / Double(audio.count) * Double(weights.count)).rounded())))
        for i in 0..<weights.count { wptr[i] = i < active ? 1 : 0 }
        let input = try MLDictionaryFeatureProvider(dictionary: ["fbank_features": features, "weights": MLFeatureValue(multiArray: weights)])
        let vector = try models.embeddingModel.prediction(from: input).featureValue(for: "embedding")!.multiArrayValue!
        let raw = (0..<vector.count).map { vector[$0].floatValue }
        let norm = sqrt(raw.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? raw.map { $0 / norm } : raw
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
