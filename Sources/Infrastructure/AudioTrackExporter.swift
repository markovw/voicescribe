import Foundation
import AVFoundation

@MainActor protocol AudioExporting {
    var progressFraction: Double? { get }
    func export(_ asset: AVAsset, to url: URL) async throws
    func cancel()
}

@MainActor final class AudioTrackExporter: AudioExporting {
    private var session: AVAssetExportSession?

    var progressFraction: Double? {
        guard let session, session.status == .exporting else { return nil }
        return Double(session.progress)
    }

    func cancel() { session?.cancelExport() }

    func export(_ asset: AVAsset, to url: URL) async throws {
        try Task.checkCancellation()
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "VoiceScribe", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not open this audio format."])
        }
        session = exporter
        defer { session = nil }
        exporter.outputURL = url
        exporter.outputFileType = .m4a
        await exporter.export()
        try Task.checkCancellation()
        guard exporter.status == .completed else {
            throw exporter.error ?? NSError(domain: "VoiceScribe", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Could not extract an audio track."])
        }
    }
}
