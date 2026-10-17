import Foundation
import AVFoundation

/// AVFoundation types remain behind this boundary; the use case receives URLs and offsets.
@MainActor final class AudioSourcePreparer: AudioPreparing {
    private let exporter: any AudioExporting

    init(exporter: any AudioExporting) { self.exporter = exporter }

    var progressFraction: Double? { exporter.progressFraction }
    func cancel() { exporter.cancel() }

    func prepare(source: URL, folder: URL,
                 onProgress: (TranscriptionProgress) -> Void) async throws -> PreparedAudio {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw NSError(domain: "VoiceScribe", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "This file has no readable audio track. Try MP4, MOV, M4A, MP3 or WAV."])
        }
        let mediaDuration = try await asset.load(.duration)
        let duration = mediaDuration.seconds.isFinite ? mediaDuration.seconds : 0
        var tracks: [URL] = []
        var offsets: [Double] = []
        onProgress(TranscriptionProgress(stage: "Checking audio tracks…"))
        for (index, track) in audioTracks.enumerated() {
            try Task.checkCancellation()
            onProgress(TranscriptionProgress(stage: "Extracting audio…", fraction: 0,
                detail: "Track \(index + 1) of \(audioTracks.count)"))
            let composition = AVMutableComposition()
            guard let destination = composition.addMutableTrack(withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw NSError(domain: "VoiceScribe", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Could not read an audio track."])
            }
            let range = try await track.load(.timeRange)
            try destination.insertTimeRange(range, of: track, at: .zero)
            // The worker pads PCM explicitly, preserving the video timeline
            // even when a decoder ignores empty M4A edit-list intervals.
            offsets.append(max(0, range.start.seconds))
            let trackURL = folder.appendingPathComponent("input-\(index).m4a")
            try await exporter.export(composition, to: trackURL)
            tracks.append(trackURL)
        }
        return PreparedAudio(duration: duration, tracks: tracks, offsets: offsets)
    }
}
