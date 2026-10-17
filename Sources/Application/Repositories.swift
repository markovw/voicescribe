import Foundation

protocol TranscriptRepository {
    func load() throws -> [Transcript]
    func save(_ transcripts: [Transcript]) throws
}

protocol PreferencesStoring {
    func load() -> TranscriptionPreferences
    func save(_ preferences: TranscriptionPreferences)
}

