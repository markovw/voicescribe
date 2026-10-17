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
