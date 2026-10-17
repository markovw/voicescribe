import Foundation

struct ApplicationPaths {
    let library: URL
    let preferencesSuite: String?

    /// Isolated UI validation never opens the user's normal library or settings.
    static var live: ApplicationPaths {
        if let directory = ProcessInfo.processInfo.environment["VOICESCRIBE_LIBRARY_DIR"], !directory.isEmpty {
            return ApplicationPaths(library: URL(fileURLWithPath: directory, isDirectory: true),
                                    preferencesSuite: "local.voicescribe.validation")
        }
        return ApplicationPaths(library: FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("VoiceScribe", isDirectory: true),
            preferencesSuite: nil)
    }
}
