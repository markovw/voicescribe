import Foundation

private final class FixtureProcess: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var commands: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
    var separate = false
    var overlap = false

    func cancel() { }
    func run(executable: URL, arguments: [String], log: URL, environment: [String: String]) throws {
        lock.lock(); recorded.append(arguments); lock.unlock()
        func value(_ flag: String) -> String { arguments[arguments.firstIndex(of: flag)! + 1] }
        let output = URL(fileURLWithPath: value("--output"))
        let json: String
        switch arguments[0] {
        case "inspect-audio":
            json = """
            {"separate":\(separate),"paths":\(separate ? "[\"a.wav\",\"b.wav\"]" : "[\"a.wav\"]"),"containerTracks":2,"channels":2,
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
        let pipeline = TranscriptionPipeline(runner: process, audioPreparer: AudioSourcePreparer(exporter: AudioTrackExporter()),
            localRuntime: runtime, resources: resources)
        var updates: [TranscriptionProgress] = []
        pipeline.onProgress = { updates.append($0) }
        let request = TranscriptionRequest(source: source, speakerCount: 2, mode: .accurate,
            model: .qwen, voiceModel: .automatic, vocabulary: "SwiftUI", audioLayout: "separate", oneSpeakerPerSource: true)
        let result = try await pipeline.transcribe(request, previous: nil)
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

        // Auto may recover from MOSS failures; a manual MOSS choice must fail visibly.
        let autoProcess = FixtureProcess()
        autoProcess.overlap = true
        let autoRuntime = FixtureRuntime()
        autoRuntime.failMoss = true
        let autoPipeline = TranscriptionPipeline(runner: autoProcess, audioPreparer: AudioSourcePreparer(exporter: AudioTrackExporter()),
            localRuntime: autoRuntime, resources: resources)
        let autoRequest = TranscriptionRequest(source: source, speakerCount: 0, mode: .fast,
            model: .automatic, voiceModel: .automatic, vocabulary: "", audioLayout: "automatic", oneSpeakerPerSource: false)
        let recovered = try await autoPipeline.transcribe(autoRequest, previous: nil)
        assert(autoRuntime.calls.count == 2)
        assert(autoRuntime.calls[0][0]["model"] == "moss" && autoRuntime.calls[1][0]["model"] == "qwenSmall")
        assert(recovered.modelSummary?.contains("Auto fallback") == true)

        let manualRuntime = FixtureRuntime()
        manualRuntime.failMoss = true
        let manualPipeline = TranscriptionPipeline(runner: FixtureProcess(), audioPreparer: AudioSourcePreparer(exporter: AudioTrackExporter()),
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
