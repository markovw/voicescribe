import Foundation

/// The composition root is the only place that selects concrete adapters.
@MainActor enum AppDependencies {
    static func makeStudio(paths: ApplicationPaths = .live) -> Studio {
        Studio(repository: JSONTranscriptRepository(directory: paths.library),
               preferences: UserDefaultsPreferences(defaults: paths.preferencesSuite.flatMap(UserDefaults.init(suiteName:)))) {
            TranscriptionPipeline(runner: EngineRunner(), audioPreparer: AudioSourcePreparer(exporter: AudioTrackExporter()),
                localRuntime: LocalModelRuntime(store: paths.library), resources: Bundle.main.resourceURL)
        }
    }
}
