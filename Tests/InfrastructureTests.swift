import AVFoundation
import Foundation

private final class RecordingProcess: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(URL, [String], [String: String])] = []
    var calls: [(URL, [String], [String: String])] {
        lock.lock(); defer { lock.unlock() }; return records
    }
    func cancel() { }
    func run(executable: URL, arguments: [String], log: URL, environment: [String: String]) throws {
        lock.lock(); records.append((executable, arguments, environment)); lock.unlock()
        try Data().write(to: log)
    }
}

/// Writes a fixed audio plan, as `inspect-audio` would.
private final class PlanProcess: ProcessRunning, @unchecked Sendable {
    var plan: String?
    var failure: Error?
    func cancel() { }
    func run(executable: URL, arguments: [String], log: URL, environment: [String: String]) throws {
        if let failure { throw failure }
        guard let index = arguments.firstIndex(of: "--output"), let plan else { return }
        try Data(plan.utf8).write(to: URL(fileURLWithPath: arguments[index + 1]))
    }
}

private func writeTone(_ url: URL, seconds: Int, bursts: [(Double, Double, Double)], channels: AVAudioChannelCount = 1) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: channels, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 16000))!
    buffer.frameLength = buffer.frameCapacity
    for i in 0..<Int(buffer.frameLength) {
        let t = Double(i) / 16000
        var value = 0.0
        for (start, end, frequency) in bursts where t >= start && t < end { value += sin(t * 2 * .pi * frequency) * 0.2 }
        // Meeting apps often store one voice as identical left and right channels.
        for channel in 0..<Int(channels) { buffer.floatChannelData![channel][i] = Float(value) }
    }
    try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
}

/// Cloud source inspection: duplicates and full mixes never reach a recognizer.
@MainActor private func verifySourceInspection(root: URL) async throws {
    let folder = root.appendingPathComponent("inspection")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let mic = folder.appendingPathComponent("input-0.wav"), remote = folder.appendingPathComponent("input-1.wav")
    let mix = folder.appendingPathComponent("input-2.wav")
    let micBursts = [(1.0, 4.0, 220.0), (9.0, 12.0, 220.0), (15.0, 17.0, 220.0)]
    let remoteBursts = [(5.0, 8.0, 330.0), (11.0, 14.0, 330.0), (18.0, 19.5, 330.0)]
    try writeTone(mic, seconds: 20, bursts: micBursts)
    try writeTone(remote, seconds: 20, bursts: remoteBursts)
    try writeTone(mix, seconds: 20, bursts: micBursts + remoteBursts)
    let audio = PreparedAudio(duration: 20, tracks: [mic, remote, mix], offsets: [0, 0.5, 0])
    let shell = URL(fileURLWithPath: "/bin/sh")

    // Retained mono tracks are reused as exported, with their offsets.
    let fake = PlanProcess()
    fake.plan = #"{"separate":true,"paths":["/x/track-0-channel-0.wav","/x/track-1-channel-0.wav"],"containerTracks":3,"channels":3}"#
    let reused = try await EngineSourceInspector(runner: fake, engine: shell, encoder: PCMTrackExporter()).inspect(audio, folder: folder)
    assert(reused.tracks == [mic, remote] && reused.offsets == [0, 0.5])
    // Engine-built audio (a combined mix or a split channel) is encoded, already on the timeline.
    fake.plan = #"{"separate":false,"paths":["\#(mix.path)"],"containerTracks":3,"channels":4}"#
    let combined = try await EngineSourceInspector(runner: fake, engine: shell, encoder: AudioTrackExporter()).inspect(audio, folder: folder)
    assert(combined.tracks.map(\.lastPathComponent) == ["source-0.m4a"] && combined.offsets == [0])
    assert(FileManager.default.fileExists(atPath: combined.tracks[0].path))
    // Inspection is best effort: a failure or missing engine keeps every track; cancellation stops.
    fake.failure = NSError(domain: "test", code: 1)
    let failed = try await EngineSourceInspector(runner: fake, engine: shell, encoder: PCMTrackExporter()).inspect(audio, folder: folder)
    assert(failed.tracks == audio.tracks && failed.offsets == audio.offsets)
    let missing = try await EngineSourceInspector(runner: fake, engine: nil, encoder: PCMTrackExporter()).inspect(audio, folder: folder)
    assert(missing.tracks == audio.tracks)
    fake.failure = CancellationError()
    do {
        _ = try await EngineSourceInspector(runner: fake, engine: shell, encoder: PCMTrackExporter()).inspect(audio, folder: folder)
        assertionFailure("Cancelled inspection must not fall back to uploading")
    } catch is CancellationError { }

    // Real engine: microphone + remote + their full mix keeps only the two stems.
    let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Engine/.build/release/scribe")
    guard FileManager.default.isExecutableFile(atPath: engine.path) else { preconditionFailure("Build the engine first") }
    let real = try await EngineSourceInspector(runner: EngineRunner(), engine: engine, encoder: AudioTrackExporter())
        .inspect(PreparedAudio(duration: 20, tracks: [mic, remote, mix], offsets: [0, 0, 0]), folder: folder)
    assert(real.tracks == [mic, remote], "A full mix must be dropped: \(real.tracks.map(\.lastPathComponent))")
    let duplicate = try await EngineSourceInspector(runner: EngineRunner(), engine: engine, encoder: AudioTrackExporter())
        .inspect(PreparedAudio(duration: 20, tracks: [mic, remote, mic], offsets: [0, 0, 0]), folder: folder)
    assert(duplicate.tracks == [mic, remote], "A duplicate track must be dropped: \(duplicate.tracks.map(\.lastPathComponent))")

    // Real engine, stereo (dual-mono) tracks as in meeting recordings: the mix is
    // dropped and each kept channel file still names its own container track.
    let stereo = ["mix", "mic", "remote"].map { folder.appendingPathComponent("stereo-\($0).wav") }
    try writeTone(stereo[0], seconds: 20, bursts: micBursts + remoteBursts, channels: 2)
    try writeTone(stereo[1], seconds: 20, bursts: micBursts, channels: 2)
    try writeTone(stereo[2], seconds: 20, bursts: remoteBursts, channels: 2)
    let stereoFolder = folder.appendingPathComponent("stereo")
    try FileManager.default.createDirectory(at: stereoFolder, withIntermediateDirectories: true)
    let channels = try await EngineSourceInspector(runner: EngineRunner(), engine: engine, encoder: AudioTrackExporter())
        .inspect(PreparedAudio(duration: 20, tracks: stereo, offsets: [0, 0, 0]), folder: stereoFolder)
    assert(channels.origins == [1, 2] && channels.ownsTracks, "Stereo stems must keep track ownership: \(channels.origins)")
    assert(channels.tracks.allSatisfy { $0.pathExtension == "m4a" && FileManager.default.fileExists(atPath: $0.path) })
}

@main struct InfrastructureTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("resources")
        let bundled = resources.appendingPathComponent("Accurate")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        for name in ["pyproject.toml", "uv.lock", "transcribe.py"] {
            try Data("fixture-\(name)".utf8).write(to: bundled.appendingPathComponent(name))
        }
        let store = root.appendingPathComponent("library")
        let runtime = LocalModelRuntime(store: store, resources: resources)
        let process = RecordingProcess()
        let jobs = [["audio": "synthetic.wav", "output": "words.json", "model": "qwen"]]
        try await runtime.run(runner: process, jobs: jobs, terms: "SwiftUI", folder: root) { _, _ in }
        let calls = process.calls
        assert(calls.count == 2 && calls[0].1.contains("--frozen"))
        assert(calls[0].0 == resources.appendingPathComponent("uv"))
        assert(calls[1].1.suffix(2) == ["--terms", "SwiftUI"])
        assert(calls[0].2["PYTHONNOUSERSITE"] == "1")
        assert(calls[0].2["HF_HUB_DISABLE_TELEMETRY"] == "1")
        assert(calls[0].2["HF_HOME"] == store.appendingPathComponent("Models/huggingface").path)
        let manifest = try JSONDecoder().decode([[String: String]].self,
            from: Data(contentsOf: root.appendingPathComponent("recognition-jobs.json")))
        assert(manifest == jobs)
        let installed = store.appendingPathComponent("Accurate-v1/transcribe.py")
        try Data("stale".utf8).write(to: installed)
        try await runtime.run(runner: process, jobs: jobs, terms: "", folder: root) { _, _ in }
        let refreshed = try Data(contentsOf: installed)
        assert(refreshed == Data("fixture-transcribe.py".utf8))

        let log = root.appendingPathComponent("process.log")
        let runner = EngineRunner()
        try runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf success"], log: log)
        let contents = try String(contentsOf: log, encoding: .utf8)
        assert(contents == "success")
        do {
            try runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 7"], log: log)
            assertionFailure("Non-zero child status must be reported")
        } catch { assert((error as NSError).code == 7) }

        let cancelled = EngineRunner()
        cancelled.cancel()
        do {
            try cancelled.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"], log: log)
            assertionFailure("A cancelled runner must not start a process")
        } catch is CancellationError { }

        let active = EngineRunner()
        let activeLog = root.appendingPathComponent("active.log")
        let task = Task.detached {
            try active.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo ready; exec /bin/sleep 30"], log: activeLog)
        }
        var ready = false
        for _ in 0..<500 {
            if (try? String(contentsOf: activeLog, encoding: .utf8))?.contains("ready") == true {
                ready = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        active.cancel()
        do {
            try await task.value
            assertionFailure("Cancellation must terminate the child and report cancellation")
        } catch is CancellationError { }
        assert(ready)

        // Local recognition receives decoded 16 kHz PCM with every source
        // channel and the full duration, never a re-encoded AAC file.
        let aac = root.appendingPathComponent("stereo.m4a")
        let seconds = 120.0
        do {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
            let file = try AVAudioFile(forWriting: aac, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000])
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
            buffer.frameLength = 44100
            for second in 0..<Int(seconds) {
                for i in 0..<44100 {
                    let t = Double(second * 44100 + i) / 44100
                    buffer.floatChannelData![0][i] = Float(sin(t * 2 * .pi * 220) * 0.2)
                    buffer.floatChannelData![1][i] = Float(sin(t * 2 * .pi * 330) * 0.2)
                }
                try file.write(from: buffer)
            }
        }
        let extraction = root.appendingPathComponent("extraction")
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
        let prepared = try await AudioSourcePreparer(exporter: PCMTrackExporter()).prepare(source: aac, folder: extraction) { _ in }
        assert(prepared.tracks.map(\.lastPathComponent) == ["input-0.wav"])
        let pcm = try AVAudioFile(forReading: prepared.tracks[0])
        assert(pcm.fileFormat.sampleRate == 16000 && pcm.fileFormat.channelCount == 2)
        assert(abs(Double(pcm.length) / 16000 - seconds) < 0.1, "PCM export must keep the whole recording")
        let stopped = PCMTrackExporter()
        // A pipeline stops its exporter without cancelling the Swift task.
        stopped.cancel()
        let export = Task { try await stopped.export(AVURLAsset(url: aac), to: root.appendingPathComponent("stopped.wav")) }
        do {
            try await export.value
            assertionFailure("A cancelled PCM export must not report success")
        } catch is CancellationError { }
        try await verifySourceInspection(root: root)
        print("PASS: cloud source inspection drops duplicate and full-mix tracks, falls back safely")
        print("PASS: frozen runtime setup, isolated caches, refreshed scripts, process errors and active cancellation")
        print("PASS: PCM track export keeps channels and duration, and stops on cancellation")
    }
}
