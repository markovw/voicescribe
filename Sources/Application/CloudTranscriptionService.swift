import Foundation

/// Sends one prepared audio file to a hosted recognizer and returns its raw response.
protocol CloudRecognizing: Sendable {
    func recognize(audio: URL, apiKey: String, options: DeepgramOptions) async throws -> Data
}

/// Cloud counterpart of `TranscriptionPipeline`: local track extraction,
/// remote recognition, the same `Transcript` model and library.
@MainActor final class CloudTranscriptionService: TranscriptionServicing {
    var onProgress: ((TranscriptionProgress) -> Void)?
    private var progress = TranscriptionProgress() {
        didSet { onProgress?(progress) }
    }
    private let audioPreparer: any AudioPreparing
    private let recognizer: any CloudRecognizing
    private let credentials: any CredentialStoring
    private let inspector: (any SourceInspecting)?

    init(audioPreparer: any AudioPreparing, recognizer: any CloudRecognizing, credentials: any CredentialStoring,
         inspector: (any SourceInspecting)? = nil) {
        self.audioPreparer = audioPreparer
        self.recognizer = recognizer
        self.credentials = credentials
        self.inspector = inspector
    }

    func cancel() {
        audioPreparer.cancel()
        inspector?.cancel()
    }

    func refreshProgress() {
        if let fraction = audioPreparer.progressFraction { progress.fraction = fraction }
    }

    func transcribe(_ request: TranscriptionRequest, previous: Transcript?) async throws -> Transcript {
        guard let apiKey = credentials.read()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw NSError(domain: "VoiceScribe", code: 20, userInfo: [NSLocalizedDescriptionKey:
                "Add your Deepgram API key in Deepgram settings before transcribing."])
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let source = request.source
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceScribe-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prepared = try await audioPreparer.prepare(source: source, folder: folder) { [self] update in
            progress = update
        }
        // A single track has no track ownership: its voices are always diarized.
        let perTrackSpeaker = request.oneSpeakerPerSource && prepared.tracks.count > 1
        var sources = InspectedAudio(tracks: prepared.tracks, offsets: prepared.offsets)
        // Drop duplicates and full mixes so no voice is recognized twice.
        if prepared.tracks.count > 1, let inspector {
            progress.stage = "Checking audio tracks…"
            progress.fraction = nil; progress.detail = ""
            let inspected = try await inspector.inspect(prepared, folder: folder)
            try Task.checkCancellation()
            // Track ownership needs one source per container track. A
            // combined recording has no owner: keep every track then.
            if !perTrackSpeaker || inspected.ownsTracks { sources = inspected }
        }
        progress.modelInfo = "Deepgram Nova-3 · \(request.cloudLanguage.title) · Cloud"
        progress.audioInfo = Self.layout(sources: sources.tracks.count, skipped: prepared.tracks.count - sources.tracks.count,
                                          perTrack: perTrackSpeaker)
        let options = DeepgramOptions(language: request.cloudLanguage, diarize: !perTrackSpeaker,
                                      keyterms: DeepgramOptions.keyterms(from: request.vocabulary))
        var transcript = Transcript(title: source.deletingPathExtension().lastPathComponent + "-transcribed",
            sourcePath: source.path, duration: prepared.duration, segments: [])
        let uploads = sources.tracks.count
        var parts: [[Utterance]] = []
        for (index, track) in sources.tracks.enumerated() {
            try Task.checkCancellation()
            progress.sourceProgress = uploads > 1 ? "Source \(index + 1) of \(uploads)" : ""
            progress.stage = uploads > 1 ? "Transcribing source \(index + 1) with Deepgram…" : "Transcribing with Deepgram…"
            let data = try await recognizer.recognize(audio: track, apiKey: apiKey, options: options)
            try Task.checkCancellation()
            let response: DeepgramResponse
            do { response = try JSONDecoder().decode(DeepgramResponse.self, from: data) }
            catch {
                throw NSError(domain: "VoiceScribe", code: 21, userInfo: [NSLocalizedDescriptionKey:
                    "Deepgram returned an unexpected response. \(error.localizedDescription)"])
            }
            let offset = index < sources.offsets.count ? sources.offsets[index] : 0
            parts.append(response.utterances(offset: offset, singleSpeaker: perTrackSpeaker ? "Source" : nil))
            transcript.duration = max(transcript.duration, offset + (response.metadata?.duration ?? 0))
        }
        // Safety net: a source whose words repeat the others is a mix or a
        // duplicate that inspection missed. Sources are then numbered again.
        let repeated = RepeatedSources.redundant(parts)
        let kept = parts.indices.filter { !repeated.contains($0) }
        for (number, index) in kept.enumerated() {
            var part = Transcript(title: transcript.title, sourcePath: source.path, duration: 0, segments: parts[index])
            if perTrackSpeaker { for i in part.segments.indices { part.segments[i].speaker = "Source \(number + 1)" } }
            else if kept.count > 1 { part.namespaceSpeakers(sourceIndex: number) }
            transcript.segments += part.segments
        }
        transcript.audioLayout = Self.layout(sources: kept.count, skipped: prepared.tracks.count - kept.count, perTrack: perTrackSpeaker)
        transcript.modelSummary = progress.modelInfo
        transcript.segments.sort { a, b in a.start == b.start ? a.speaker < b.speaker : a.start < b.start }
        if let previous {
            if perTrackSpeaker { transcript.copySourceSpeakerNames(from: previous) }
            else { transcript.copySpeakerNames(from: previous) }
        }
        transcript.processingDuration = ProcessInfo.processInfo.systemUptime - startedAt
        return transcript
    }
}

extension CloudTranscriptionService {
    static func layout(sources: Int, skipped: Int, perTrack: Bool) -> String {
        let skippedInfo = skipped > 0 ? " · \(skipped) redundant track\(skipped == 1 ? "" : "s") skipped" : ""
        guard sources > 1 else { return "Mixed audio · All voices detected together" + skippedInfo }
        return (perTrack ? "Separate tracks · One speaker per track"
            : "Separate audio · \(sources) sources · Voices detected within each") + skippedInfo
    }
}

/// Chooses the local or cloud service per request; one operation at a time.
@MainActor final class TranscriptionRouter: TranscriptionServicing {
    var onProgress: ((TranscriptionProgress) -> Void)?
    private let makeLocal: @MainActor () -> any TranscriptionServicing
    private let makeCloud: @MainActor () -> any TranscriptionServicing
    private var active: (any TranscriptionServicing)?

    init(local: @escaping @MainActor () -> any TranscriptionServicing,
         cloud: @escaping @MainActor () -> any TranscriptionServicing) {
        makeLocal = local
        makeCloud = cloud
    }

    func transcribe(_ request: TranscriptionRequest, previous: Transcript?) async throws -> Transcript {
        let service = request.mode.isLocal ? makeLocal() : makeCloud()
        service.onProgress = { [weak self] in self?.onProgress?($0) }
        active = service
        defer { service.onProgress = nil; active = nil }
        return try await service.transcribe(request, previous: previous)
    }
    func refreshProgress() { active?.refreshProgress() }
    func cancel() { active?.cancel() }
}
