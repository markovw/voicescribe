import Foundation

@main struct TranscriptionSmoke {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let resources = root.appendingPathComponent("dist/VoiceScribe.app/Contents/Resources")
        let store = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceScribe")
        // Reuse only the existing runtime/weights; never read or write history.
        for name in ["pyproject.toml", "uv.lock", "transcribe.py"] {
            let existing = try Data(contentsOf: store.appendingPathComponent("Accurate-v1/" + name))
            let bundled = try Data(contentsOf: resources.appendingPathComponent("Accurate/" + name))
            precondition(existing == bundled, "Smoke test requires identical existing runtime files")
        }
        for model in [RecognitionModel.parakeet, .qwen] {
            let pipeline = TranscriptionPipeline(runner: EngineRunner(),
                audioPreparer: AudioSourcePreparer(exporter: AudioTrackExporter()),
                localRuntime: LocalModelRuntime(store: store, resources: resources), resources: resources)
            let request = TranscriptionRequest(source: root.appendingPathComponent("examples/two-speakers-demo.mp4"),
                speakerCount: 0, mode: model == .parakeet ? .fast : .accurate, model: model,
                voiceModel: .automatic, vocabulary: "", audioLayout: "automatic", oneSpeakerPerSource: true)
            let transcript = try await pipeline.transcribe(request, previous: nil)
            precondition(!transcript.segments.isEmpty)
            precondition(transcript.segments.allSatisfy { $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start })
            precondition(transcript.segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            print("PASS: real \(model.rawValue) pipeline, \(transcript.segments.count) segments, \(transcript.duration)s; no library writes")
        }
    }
}
