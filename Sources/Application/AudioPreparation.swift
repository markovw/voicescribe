import Foundation

struct PreparedAudio {
    let duration: Double
    let tracks: [URL]
    let offsets: [Double]
}

@MainActor protocol AudioPreparing {
    var progressFraction: Double? { get }
    func prepare(source: URL, folder: URL,
                 onProgress: (TranscriptionProgress) -> Void) async throws -> PreparedAudio
    func cancel()
}

/// Recognition sources left after redundant container tracks are removed.
struct InspectedAudio {
    let tracks: [URL]
    let offsets: [Double]
    /// Container track behind each source; nil for a combined recording.
    var origins: [Int?]

    init(tracks: [URL], offsets: [Double], origins: [Int?]? = nil) {
        self.tracks = tracks
        self.offsets = offsets
        self.origins = origins ?? tracks.indices.map { $0 }
    }

    /// One source per distinct container track, as track ownership requires.
    var ownsTracks: Bool {
        tracks.count > 1 && origins.allSatisfy { $0 != nil } && Set(origins.compactMap { $0 }).count == origins.count
    }
}

/// Reduces exported container tracks to independent sources. A duplicate
/// track or a full mix of the other tracks would repeat every voice under
/// a second source label, so it must not reach a recognizer.
@MainActor protocol SourceInspecting {
    func inspect(_ audio: PreparedAudio, folder: URL) async throws -> InspectedAudio
    func cancel()
}
