import Foundation
import AVFoundation

/// Runs the engine's `inspect-audio`, so cloud recognition sees the same
/// sources as local recognition: duplicate tracks and an OBS-style full mix
/// are dropped, and tracks of uncertain independence are combined into one.
@MainActor final class EngineSourceInspector: SourceInspecting {
    private let runner: any ProcessRunning
    private let engine: URL?
    private let encoder: any AudioExporting

    init(runner: any ProcessRunning, engine: URL?, encoder: any AudioExporting) {
        self.runner = runner
        self.engine = engine
        self.encoder = encoder
    }

    func cancel() {
        runner.cancel()
        encoder.cancel()
    }

    func inspect(_ audio: PreparedAudio, folder: URL) async throws -> InspectedAudio {
        let all = InspectedAudio(tracks: audio.tracks, offsets: audio.offsets)
        guard audio.tracks.count > 1, let engine, FileManager.default.isExecutableFile(atPath: engine.path) else { return all }
        let planURL = folder.appendingPathComponent("audio-plan.json")
        let log = folder.appendingPathComponent("inspection.log")
        let arguments = ["inspect-audio"] + audio.tracks.map(\.path) +
            ["--directory", folder.appendingPathComponent("audio").path, "--output", planURL.path,
             "--layout", "automatic", "--offsets", audio.offsets.map { String($0) }.joined(separator: ",")]
        let runner = self.runner
        let plan: AudioPlan
        do {
            try await Task.detached { try runner.run(executable: engine, arguments: arguments, log: log) }.value
            plan = try JSONDecoder().decode(AudioPlan.self, from: Data(contentsOf: planURL))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Inspection only removes redundancy; it never blocks an upload.
            try Task.checkCancellation()
            return all
        }
        try Task.checkCancellation()
        guard !plan.paths.isEmpty else { return all }
        var tracks: [URL] = []
        var offsets: [Double] = []
        var origins: [Int?] = []
        for (index, path) in plan.paths.enumerated() {
            let origin = AudioPlan.origin(of: path).flatMap { $0 < audio.tracks.count ? $0 : nil }
            origins.append(origin)
            if let source = Self.wholeTrack(path, plan: plan), source < audio.tracks.count {
                // A retained mono track is uploaded as exported, without a re-encode.
                tracks.append(audio.tracks[source])
                offsets.append(source < audio.offsets.count ? audio.offsets[source] : 0)
            } else {
                // Engine output is padded to the media timeline: offset zero.
                let url = folder.appendingPathComponent("source-\(index).\(encoder.fileExtension)")
                try await encoder.export(AVURLAsset(url: URL(fileURLWithPath: path)), to: url)
                tracks.append(url)
                offsets.append(0)
            }
        }
        return InspectedAudio(tracks: tracks, offsets: offsets, origins: origins)
    }

    /// The container track behind an engine channel file, when every track is mono.
    /// A channel of a stereo track is uploaded alone: the other channel may
    /// repeat another track, so the whole stereo track is not safe to send.
    static func wholeTrack(_ path: String, plan: AudioPlan) -> Int? {
        guard plan.channels == plan.containerTracks else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard name.hasPrefix("track-"), name.hasSuffix("-channel-0.wav") else { return nil }
        return Int(name.dropFirst("track-".count).dropLast("-channel-0.wav".count))
    }
}
