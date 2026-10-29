import Foundation

enum TranscriptionMode: String, CaseIterable, Identifiable {
    case fast, accurate, cloud
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fast: return "Fast"
        case .accurate: return "Accurate"
        case .cloud: return "Deepgram"
        }
    }
    var detail: String {
        switch self {
        case .fast: return "Auto balances speed and difficult speech using local audio analysis."
        case .accurate: return "Choose a local model for careful transcription. Quality depends on the recording."
        case .cloud: return "Sends extracted audio to Deepgram Nova-3 with your API key. Usage is billed to your Deepgram account."
        }
    }
    var isLocal: Bool { self != .cloud }
}

enum RecognitionModel: String, CaseIterable, Identifiable {
    case automatic, parakeet, qwenSmall, qwen, moss
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Auto · Analyze audio"
        case .parakeet: return "Parakeet v3"
        case .qwenSmall: return "Qwen3 · 0.6B"
        case .qwen: return "Qwen3 · 1.7B"
        case .moss: return "MOSS · 0.9B (experimental)"
        }
    }
    var detail: String {
        switch self {
        case .automatic: return "Fast analyzes voices, overlapping speech and signal quality before choosing. Accurate uses Qwen 1.7B."
        case .parakeet: return "Fast word-timed transcription for clear Russian and English. Voices are detected separately."
        case .qwenSmall: return "Compact multilingual model for a balance of speed and difficult audio. Separate word alignment and voice detection."
        case .qwen: return "Larger multilingual model for accents and mixed languages. More processing and memory; separate alignment and voice detection."
        case .moss: return "Joint text, voices and segment timestamps. Useful to test interruptions; slower and experimental. Voice labels are checked across the whole recording."
        }
    }
    var menuSummary: String {
        switch self {
        case .automatic: return "Fast analyzes voices, overlap and audio quality. Accurate uses Qwen3 1.7B."
        case .parakeet: return "Quick transcription of clear Russian and English, with word timestamps."
        case .qwenSmall: return "Compact multilingual option balancing speed and difficult speech."
        case .qwen: return "For accents and mixed languages; uses more time and memory."
        case .moss: return "Text and voices together, with segment timestamps. Slower; experimental on interruptions."
        }
    }
    var shortTitle: String {
        switch self {
        case .automatic: return "Auto · Analyze audio"
        case .parakeet: return "Parakeet v3"
        case .qwenSmall: return "Qwen3 0.6B"
        case .qwen: return "Qwen3 1.7B"
        case .moss: return "MOSS 0.9B"
        }
    }
}

enum VoiceModel: String, CaseIterable, Identifiable {
    case automatic, nemotron, community
    var id: String { rawValue }
    var title: String { self == .automatic ? "Auto" : (self == .nemotron ? "Nemotron 3" : "Community") }
    var detail: String {
        self == .community ? "Voice clustering; supports a known speaker count." : "Nemotron detects up to 8 voices per source. Auto uses Community when you specify a count for mixed audio."
    }
    func resolved(speakerCount: Int) -> VoiceModel {
        self == .automatic ? (speakerCount > 0 ? .community : .nemotron) : self
    }
}

enum SpeakerProcessing {
    static func layout(requested: String, totalSpeakers: Int, oneSpeakerPerSource: Bool = false) -> String {
        oneSpeakerPerSource ? "tracks" : requested
    }

    static func voiceModel(requested: VoiceModel, totalSpeakers: Int) -> VoiceModel {
        totalSpeakers > 0 ? .community : requested.resolved(speakerCount: 0)
    }
}

struct AudioQuality: Decodable {
    var dynamicRangeDB: Double
    var clippingFraction: Double
}

struct VoiceProfile: Decodable {
    var duration: Double
    var speakerCount: Int
    var speechSeconds: Double
    var overlapSeconds: Double
}

struct RecognitionChoice {
    var model: RecognitionModel
    var reason: String
    static func choose(mode: TranscriptionMode, requested: RecognitionModel, quality: AudioQuality?, voices: VoiceProfile?) -> RecognitionChoice {
        if requested != .automatic { return .init(model: requested, reason: "Selected manually") }
        if mode == .accurate { return .init(model: .qwen, reason: "Accurate default · larger multilingual model") }
        if let voices, voices.speakerCount >= 2, voices.speechSeconds > 0,
           voices.overlapSeconds / voices.speechSeconds >= 0.05 {
            return .init(model: .moss, reason: "Overlapping voices detected · joint transcription (experimental)")
        }
        if let quality, quality.dynamicRangeDB < 12 || quality.clippingFraction > 0.005 {
            return .init(model: .qwenSmall, reason: "Limited signal contrast or clipping · compact multilingual model")
        }
        return .init(model: .parakeet, reason: "No strong overlap or signal-quality warning · fast word-timed model")
    }
}

