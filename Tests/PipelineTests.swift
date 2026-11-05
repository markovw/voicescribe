import Foundation

private final class FixtureProcess: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var commands: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
    var separate = false
    var overlap = false
    var planPaths: [String]?

    func cancel() { }
    func run(executable: URL, arguments: [String], log: URL, environment: [String: String]) throws {
        lock.lock(); recorded.append(arguments); lock.unlock()
        func value(_ flag: String) -> String { arguments[arguments.firstIndex(of: flag)! + 1] }
        let output = URL(fileURLWithPath: value("--output"))
        let json: String
        switch arguments[0] {
        case "inspect-audio":
            json = """
            {"separate":\(separate),"paths":\(planPaths.map { "[" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "]" } ?? (separate ? "[\"a.wav\",\"b.wav\"]" : "[\"a.wav\"]")),"containerTracks":2,"channels":2,
             "quality":[{"dynamicRangeDB":30,"clippingFraction":0},{"dynamicRangeDB":30,"clippingFraction":0}]}
            """
        case "profile-audio":
            json = "{\"duration\":30,\"speakerCount\":2,\"speechSeconds\":20,\"overlapSeconds\":\(overlap ? 5 : 0)}"
        case "transcribe":
            json = """
            {"metadata":{"duration":30,"diarization":true,"coverageWarnings":["Review fixture"]},
             "segments":[{"start":0,"end":2,"text":"Hello, привет!","speaker":"Speaker 1","needsReview":true}]}
            """
        default: preconditionFailure("Unexpected command")
        }
        try Data(json.utf8).write(to: output)
        try Data().write(to: log)
    }
}

@MainActor private final class FixtureRuntime: LocalBatchRunning {
    var calls: [[[String: String]]] = []
    var failMoss = false
    func run(runner: any ProcessRunning, jobs: [[String: String]], terms: String,
             folder: URL, onStage: (String, URL) -> Void) async throws {
        calls.append(jobs)
        if failMoss && jobs.contains(where: { $0["model"] == "moss" }) {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}

/// Track ownership needs several container tracks; reuse the real extraction twice.
@MainActor private final class TwoTrackPreparer: AudioPreparing {
    let base = AudioSourcePreparer(exporter: PCMTrackExporter())
    var progressFraction: Double? { base.progressFraction }
    func cancel() { base.cancel() }
    func prepare(source: URL, folder: URL, onProgress: (TranscriptionProgress) -> Void) async throws -> PreparedAudio {
        let audio = try await base.prepare(source: source, folder: folder, onProgress: onProgress)
        return PreparedAudio(duration: audio.duration, tracks: audio.tracks + audio.tracks, offsets: audio.offsets + audio.offsets)
    }
}

@main struct PipelineTests {
    @MainActor static func main() async throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let engine = URL(fileURLWithPath: CommandLine.arguments[2])
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        try FileManager.default.createSymbolicLink(at: resources.appendingPathComponent("scribe"), withDestinationURL: engine)
        let process = FixtureProcess()
        process.separate = true
        let runtime = FixtureRuntime()
        let owned = TranscriptionPipeline(runner: process, audioPreparer: TwoTrackPreparer(),
            localRuntime: runtime, resources: resources)
        var updates: [TranscriptionProgress] = []
        owned.onProgress = { updates.append($0) }
        let request = TranscriptionRequest(source: source, speakerCount: 2, mode: .accurate,
            model: .qwen, voiceModel: .automatic, vocabulary: "SwiftUI", audioLayout: "separate", oneSpeakerPerSource: true)
        let result = try await owned.transcribe(request, previous: nil)
        assert(result.segments.count == 2)
        assert(Set(result.segments.map(\.speaker)) == ["Source 1 · Speaker 1", "Source 2 · Speaker 1"])
        assert(result.segments.allSatisfy(\.needsReview))
        assert(result.coverageWarnings == ["Source 1: Review fixture", "Source 2: Review fixture"])
        assert(result.processingDuration != nil && result.audioLayout == "Separate tracks · One speaker per track")
        let commands = process.commands
        assert(commands.count == 3 && !commands.contains(where: { $0[0] == "profile-audio" }))
        assert(commands.filter { $0[0] == "transcribe" }.allSatisfy { $0.contains("--single-speaker") && !$0.contains("--diarize") })
        assert(runtime.calls.count == 1 && runtime.calls[0].count == 2)
        assert(updates.contains { $0.sourceProgress == "Source 2 of 2" })
        let outputIndex = commands[0].firstIndex(of: "--output")!
        let workspace = URL(fileURLWithPath: commands[0][outputIndex + 1]).deletingLastPathComponent()
        assert(!FileManager.default.fileExists(atPath: workspace.path))

        // Track ownership keeps the inspected stems (stereo channel files) and
        // never sends a dropped mix track to recognition.
        let stems = FixtureProcess()
        stems.separate = true
        stems.planPaths = ["/x/track-1-channel-0.wav"]
        let stemPipeline = TranscriptionPipeline(runner: stems, audioPreparer: TwoTrackPreparer(),
            localRuntime: FixtureRuntime(), resources: resources)
        let fallback = try await stemPipeline.transcribe(request, previous: nil)
        let fallbackInputs = stems.commands.filter { $0[0] == "transcribe" }.map { URL(fileURLWithPath: $0[1]).lastPathComponent }
        assert(fallbackInputs == ["track-0-mono.wav", "track-1-mono.wav"], "One stem cannot own tracks: \(fallbackInputs)")
        assert(fallback.audioLayout == "Separate tracks · One speaker per track")
        let owners = FixtureProcess()
        owners.separate = true
        owners.planPaths = ["/x/track-0-channel-0.wav", "/x/track-1-channel-1.wav"]
        let ownerPipeline = TranscriptionPipeline(runner: owners, audioPreparer: TwoTrackPreparer(),
            localRuntime: FixtureRuntime(), resources: resources)
        let ownedResult = try await ownerPipeline.transcribe(request, previous: nil)
        let ownedInputs = owners.commands.filter { $0[0] == "transcribe" }.map { $0[1] }
        assert(ownedInputs == ["/x/track-0-channel-0.wav", "/x/track-1-channel-1.wav"])
        assert(owners.commands.first { $0[0] == "inspect-audio" }.map { $0[$0.firstIndex(of: "--layout")! + 1] } == "automatic")
        assert(Set(ownedResult.speakers) == ["Source 1 · Speaker 1", "Source 2 · Speaker 1"])

        // One container track has no track ownership: voices are still detected.
        let lone = FixtureProcess()
        let lonePipeline = TranscriptionPipeline(runner: lone, audioPreparer: AudioSourcePreparer(exporter: PCMTrackExporter()),
            localRuntime: FixtureRuntime(), resources: resources)
        let loneResult = try await lonePipeline.transcribe(request, previous: nil)
        let loneInspect = lone.commands.first { $0[0] == "inspect-audio" }!
        assert(loneInspect[loneInspect.firstIndex(of: "--layout")! + 1] != "tracks")
        assert(loneResult.audioLayout?.hasPrefix("Mixed audio") == true)

        // Auto may recover from MOSS failures; a manual MOSS choice must fail visibly.
        let autoProcess = FixtureProcess()
        autoProcess.overlap = true
        let autoRuntime = FixtureRuntime()
        autoRuntime.failMoss = true
        let autoPipeline = TranscriptionPipeline(runner: autoProcess, audioPreparer: AudioSourcePreparer(exporter: PCMTrackExporter()),
            localRuntime: autoRuntime, resources: resources)
        let autoRequest = TranscriptionRequest(source: source, speakerCount: 0, mode: .fast,
            model: .automatic, voiceModel: .automatic, vocabulary: "", audioLayout: "automatic", oneSpeakerPerSource: false)
        let recovered = try await autoPipeline.transcribe(autoRequest, previous: nil)
        assert(autoRuntime.calls.count == 2)
        assert(autoRuntime.calls[0][0]["model"] == "moss" && autoRuntime.calls[1][0]["model"] == "qwenSmall")
        assert(recovered.modelSummary?.contains("Auto fallback") == true)

        let manualRuntime = FixtureRuntime()
        manualRuntime.failMoss = true
        let manualPipeline = TranscriptionPipeline(runner: FixtureProcess(), audioPreparer: AudioSourcePreparer(exporter: PCMTrackExporter()),
            localRuntime: manualRuntime, resources: resources)
        let manualRequest = TranscriptionRequest(source: source, speakerCount: 0, mode: .accurate,
            model: .moss, voiceModel: .automatic, vocabulary: "", audioLayout: "mixed", oneSpeakerPerSource: false)
        do {
            _ = try await manualPipeline.transcribe(manualRequest, previous: nil)
            assertionFailure("A manually selected model must not be substituted")
        } catch { assert(manualRuntime.calls.count == 1) }
        print("PASS: real AVFoundation extraction, source identity, warnings, cleanup and Auto-only fallback")
    }
}
