import Foundation

struct TranscriptionRequest {
    let source: URL
    let speakerCount: Int
    let mode: TranscriptionMode
    let model: RecognitionModel
    let voiceModel: VoiceModel
    let vocabulary: String
    let audioLayout: String
    let oneSpeakerPerSource: Bool
}

struct TranscriptionProgress {
    var stage = "" {
        didSet {
            if stage != oldValue { fraction = nil; detail = "" }
        }
    }
    var fraction: Double?
    var detail = ""
    var audioInfo = ""
    var modelInfo = ""
    var sourceProgress = ""
}

@MainActor protocol TranscriptionServicing: AnyObject {
    var onProgress: ((TranscriptionProgress) -> Void)? { get set }
    func transcribe(_ request: TranscriptionRequest, previous: Transcript?) async throws -> Transcript
    func refreshProgress()
    func cancel()
}
