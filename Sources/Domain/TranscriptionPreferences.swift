import Foundation

struct TranscriptionPreferences {
    var speakerCount = 0
    var mode: TranscriptionMode = .accurate
    var fastModel: RecognitionModel = .automatic
    var accurateModel: RecognitionModel = .qwen
    var voiceModel: VoiceModel = .automatic
    var oneSpeakerPerSource = false
    var vocabulary = ""
}

