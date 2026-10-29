import Foundation

protocol TranscriptRepository {
    func load() throws -> [Transcript]
    func save(_ transcripts: [Transcript]) throws
}

protocol PreferencesStoring {
    func load() -> TranscriptionPreferences
    func save(_ preferences: TranscriptionPreferences)
}


/// Secrets stay outside UserDefaults and the transcript library.
protocol CredentialStoring {
    /// Presence check that must not reveal or decrypt the secret.
    var hasSecret: Bool { get }
    func read() -> String?
    func save(_ secret: String) throws
    func delete() throws
}

extension CredentialStoring {
    var hasSecret: Bool { !(read() ?? "").isEmpty }
}
