import Foundation

/// One pipeline instance owns exactly one cancellable transcription operation.
@MainActor final class TranscriptionPipeline: TranscriptionServicing {
    var onProgress: ((TranscriptionProgress) -> Void)?
    private var progress = TranscriptionProgress() {
        didSet { onProgress?(progress) }
    }
    private let runner: any ProcessRunning
    private let audioPreparer: any AudioPreparing
    private let localRuntime: any LocalBatchRunning
    private let resources: URL?
    private var logURL: URL?

    init(runner: any ProcessRunning,
         audioPreparer: any AudioPreparing,
         localRuntime: any LocalBatchRunning,
         resources: URL?) {
        self.runner = runner
        self.audioPreparer = audioPreparer
        self.localRuntime = localRuntime
        self.resources = resources
    }

    func cancel() {
        runner.cancel()
        audioPreparer.cancel()
    }

    func refreshProgress() {
        if let fraction = audioPreparer.progressFraction {
            progress.fraction = fraction
            return
        }
        guard let logURL, let log = try? String(contentsOf: logURL, encoding: .utf8),
              let status = ProcessingStatus.fromLog(log) else { return }
        progress.stage = status.label
        progress.fraction = status.fraction
        progress.detail = status.detail ?? ""
    }

    func transcribe(_ request: TranscriptionRequest, previous: Transcript?) async throws -> Transcript {
        let runner = self.runner
        let source = request.source
        let speakerCount = request.speakerCount
        let selectedMode = request.mode
        let requestedModel = request.model
        let requestedVoiceModel = request.voiceModel
        let selectedVocabulary = request.vocabulary
        let selectedLayout = request.audioLayout
        let sourceSpeakers = request.oneSpeakerPerSource
        let startedAt = ProcessInfo.processInfo.systemUptime
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceScribe-\(UUID())")
        defer {
            logURL = nil
            try? FileManager.default.removeItem(at: folder)
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let engine = resources?.appendingPathComponent("scribe"), FileManager.default.isExecutableFile(atPath: engine.path) else {
            throw NSError(domain: "VoiceScribe", code: 4, userInfo: [NSLocalizedDescriptionKey: "The transcription engine is missing. Reinstall VoiceScribe."])
        }
        let prepared = try await audioPreparer.prepare(source: source, folder: folder) { [self] update in
            progress = update
        }
        let duration = prepared.duration
        let exportedTracks = prepared.tracks
        let trackOffsets = prepared.offsets
        let planURL = folder.appendingPathComponent("audio-plan.json")
        let inspectionLog = folder.appendingPathComponent("inspection.log")
        logURL = inspectionLog; progress.stage = "Checking audio channels…"
        let inspectionArgs = ["inspect-audio"] + exportedTracks.map(\.path) +
            ["--directory", folder.appendingPathComponent("audio").path, "--output", planURL.path, "--layout", SpeakerProcessing.layout(requested: selectedLayout, totalSpeakers: speakerCount, oneSpeakerPerSource: sourceSpeakers),
             "--offsets", trackOffsets.map { String($0) }.joined(separator: ",")]
        try await Task.detached { try runner.run(executable: engine, arguments: inspectionArgs, log: inspectionLog) }.value
        try Task.checkCancellation()
        let plan = try JSONDecoder().decode(AudioPlan.self, from: Data(contentsOf: planURL))
        guard !plan.paths.isEmpty else { throw NSError(domain: "VoiceScribe", code: 7, userInfo: [NSLocalizedDescriptionKey: "No audio sources found."]) }
        progress.audioInfo = sourceSpeakers ? "Separate tracks · One speaker per track" : plan.description
        // A known total constrains mixed audio only. Source ownership
        // is explicit and never inferred from participant count.
        let sourceSpeakerCount = plan.separate ? 0 : speakerCount
        let selectedVoice = SpeakerProcessing.voiceModel(requested: requestedVoiceModel, totalSpeakers: sourceSpeakerCount)
        if selectedVoice == .nemotron && sourceSpeakerCount > 8 {
            throw NSError(domain: "VoiceScribe", code: 8, userInfo: [NSLocalizedDescriptionKey: "Nemotron supports up to 8 voices per source. Choose Community or Auto."])
        }
        var choices: [RecognitionChoice] = []
        var timelines: [URL?] = []
        for (index, path) in plan.paths.enumerated() {
            try Task.checkCancellation()
            var profile: VoiceProfile?
            var timeline: URL?
            if !sourceSpeakers && selectedMode == .fast && requestedModel == .automatic {
                let profileURL = folder.appendingPathComponent("voices-\(index).json")
                let log = folder.appendingPathComponent("profile-\(index).log")
                progress.stage = "Analyzing voices and overlap · Source \(index + 1)…"; logURL = log
                var args = ["profile-audio", path, "--output", profileURL.path, "--speaker-model", selectedVoice.rawValue]
                if selectedVoice == .community && sourceSpeakerCount > 0 { args += ["--speakers", String(sourceSpeakerCount)] }
                let profileArgs = args
                try await Task.detached { try runner.run(executable: engine, arguments: profileArgs, log: log) }.value
                profile = try JSONDecoder().decode(VoiceProfile.self, from: Data(contentsOf: profileURL))
                timeline = profileURL
            }
            let quality = plan.quality.flatMap { index < $0.count ? $0[index] : nil }
            choices.append(RecognitionChoice.choose(mode: selectedMode, requested: requestedModel, quality: quality, voices: profile))
            timelines.append(timeline)
        }
        func describeModels() -> String {
            choices.enumerated().map { index, choice in
                let prefix = plan.paths.count > 1 ? "Source \(index + 1): " : ""
                return "\(prefix)\(choice.model.title) · \(choice.reason) · Voices: \(sourceSpeakers ? "By audio track" : selectedVoice.title)"
            }.joined(separator: "\n")
        }
        progress.modelInfo = describeModels()
        var jobs = choices.enumerated().compactMap { index, choice -> [String: String]? in
            guard choice.model != .parakeet else { return nil }
            return ["audio": plan.paths[index], "output": folder.appendingPathComponent("words-\(index).json").path, "model": choice.model.rawValue,
                "sourceIndex": String(index + 1), "sourceCount": String(plan.paths.count)]
        }
        if !jobs.isEmpty {
            do {
                try await localRuntime.run(runner: runner, jobs: jobs, terms: selectedVocabulary, folder: folder) { [self] stage, log in
                    progress.stage = stage
                    logURL = log
                }
            } catch {
                try Task.checkCancellation()
                // Only Auto may change a model after failure. A manual
                // selection fails visibly instead of being substituted.
                guard requestedModel == .automatic, choices.contains(where: { $0.model == .moss }) else { throw error }
                for index in choices.indices where choices[index].model == .moss {
                    choices[index] = .init(model: .qwenSmall, reason: "Auto fallback · MOSS could not run; overlapping speech needs review")
                }
                progress.modelInfo = describeModels()
                jobs = jobs.map { job in var job = job; if job["model"] == "moss" { job["model"] = "qwenSmall" }; return job }
                try await localRuntime.run(runner: runner, jobs: jobs, terms: selectedVocabulary, folder: folder) { [self] stage, log in
                    progress.stage = stage
                    logURL = log
                }
            }
        }
        var refined = Transcript(title: source.deletingPathExtension().lastPathComponent + "-transcribed",
            sourcePath: source.path, duration: duration, segments: [], audioLayout: progress.audioInfo, modelSummary: progress.modelInfo)
        for (index, path) in plan.paths.enumerated() {
            progress.sourceProgress = plan.separate ? "Source \(index + 1) of \(plan.paths.count)" : ""
            try Task.checkCancellation()
            let resultURL = folder.appendingPathComponent("transcript-\(index).json")
            let log = folder.appendingPathComponent("engine-\(index).log")
            var args = ["transcribe", path, "--format", "json", "--output", resultURL.path, "--verbose"]
            if sourceSpeakers {
                args += ["--single-speaker"]
            } else {
                args += ["--diarize", "--speaker-model", selectedVoice.rawValue]
                if selectedVoice == .community, sourceSpeakerCount > 0 { args += ["--speakers", String(sourceSpeakerCount)] }
            }
            if let timeline = timelines[index] { args += ["--speaker-timeline", timeline.path] }
            if choices[index].model != .parakeet {
                let words = folder.appendingPathComponent("words-\(index).json")
                args += [choices[index].model == .moss ? "--joint-transcript" : "--aligned-words", words.path]
            }
            logURL = log
            progress.stage = plan.separate ? "Transcribing source \(index + 1) of \(plan.paths.count)…" : "Preparing local models…"
            try await Task.detached { try runner.run(executable: engine, arguments: args, log: log) }.value
            try Task.checkCancellation()
            let result = try JSONDecoder().decode(EngineOutput.self, from: Data(contentsOf: resultURL))
            var part = result.transcript(source: source)
            if plan.separate {
                part.namespaceSpeakers(sourceIndex: index)
            }
            refined.segments += part.segments
            let warnings = part.coverageWarnings ?? []
            if !warnings.isEmpty {
                refined.coverageWarnings = (refined.coverageWarnings ?? []) + warnings.map { plan.separate ? "Source \(index + 1): \($0)" : $0 }
            }
            refined.duration = max(refined.duration, part.duration)
        }
        refined.segments.sort { a, b in a.start == b.start ? a.speaker < b.speaker : a.start < b.start }
        if let previous {
            if sourceSpeakers { refined.copySourceSpeakerNames(from: previous) }
            else { refined.copySpeakerNames(from: previous) }
        }
        refined.processingDuration = ProcessInfo.processInfo.systemUptime - startedAt
        return refined
    }
}
