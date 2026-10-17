import Foundation

/// The on-disk schema and atomic replacement remain compatible with version 1.
struct JSONTranscriptRepository: TranscriptRepository {
    let directory: URL
    private var historyURL: URL { directory.appendingPathComponent("history.json") }

    func load() throws -> [Transcript] {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return [] }
        let data = try Data(contentsOf: historyURL)
        return try JSONDecoder().decode([Transcript].self, from: data).map {
            var transcript = $0
            transcript.normalizeGeneratedTitle()
            return transcript
        }
    }

    func save(_ transcripts: [Transcript]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(transcripts).write(to: historyURL, options: .atomic)
    }
}
