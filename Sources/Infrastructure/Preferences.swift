import Foundation

struct UserDefaultsPreferences: PreferencesStoring {
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? ApplicationPaths.live.preferencesSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func load() -> TranscriptionPreferences {
        TranscriptionPreferences(
            speakerCount: min(10, max(0, defaults.integer(forKey: "speakerCount"))),
            mode: defaults.string(forKey: "transcriptionMode").flatMap(TranscriptionMode.init(rawValue:)) ?? .accurate,
            fastModel: defaults.string(forKey: "fastRecognitionModel").flatMap(RecognitionModel.init(rawValue:)) ?? .automatic,
            accurateModel: defaults.string(forKey: "accurateRecognitionModel").flatMap(RecognitionModel.init(rawValue:)) ?? .qwen,
            voiceModel: defaults.string(forKey: "voiceModel").flatMap(VoiceModel.init(rawValue:)) ?? .automatic,
            oneSpeakerPerSource: defaults.bool(forKey: "oneSpeakerPerSource"),
            vocabulary: defaults.string(forKey: "transcriptionVocabulary") ?? "",
            cloudLanguage: defaults.string(forKey: "cloudLanguage").flatMap(CloudLanguage.init(rawValue:)) ?? .russian)
    }

    func save(_ preferences: TranscriptionPreferences) {
        defaults.set(preferences.speakerCount, forKey: "speakerCount")
        defaults.set(preferences.mode.rawValue, forKey: "transcriptionMode")
        defaults.set(preferences.fastModel.rawValue, forKey: "fastRecognitionModel")
        defaults.set(preferences.accurateModel.rawValue, forKey: "accurateRecognitionModel")
        defaults.set(preferences.voiceModel.rawValue, forKey: "voiceModel")
        defaults.set(preferences.oneSpeakerPerSource, forKey: "oneSpeakerPerSource")
        defaults.set(preferences.vocabulary, forKey: "transcriptionVocabulary")
        defaults.set(preferences.cloudLanguage.rawValue, forKey: "cloudLanguage")
    }
}
