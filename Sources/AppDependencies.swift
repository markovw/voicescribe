import Foundation

/// The composition root is the only place that selects concrete adapters.
@MainActor enum AppDependencies {
    static func makeStudio(paths: ApplicationPaths = .live) -> Studio {
        var credentials = KeychainCredentialStore()
        if paths.preferencesSuite != nil { credentials.service = "local.voicescribe.validation.deepgram" }
        return Studio(repository: JSONTranscriptRepository(directory: paths.library),
               preferences: UserDefaultsPreferences(defaults: paths.preferencesSuite.flatMap(UserDefaults.init(suiteName:))),
               credentials: credentials) {
            TranscriptionRouter(local: {
                TranscriptionPipeline(runner: EngineRunner(), audioPreparer: AudioSourcePreparer(exporter: AudioTrackExporter()),
                    localRuntime: LocalModelRuntime(store: paths.library), resources: Bundle.main.resourceURL)
            }, cloud: {
                CloudTranscriptionService(audioPreparer: AudioSourcePreparer(exporter: AudioTrackExporter()),
                    recognizer: DeepgramClient(), credentials: credentials)
            })
        }
    }
}
