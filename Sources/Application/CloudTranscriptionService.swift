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

    init(audioPreparer: any AudioPreparing, recognizer: any CloudRecognizing, credentials: any CredentialStoring) {
        self.audioPreparer = audioPreparer
        self.recognizer = recognizer
        self.credentials = credentials
    }

    func cancel() { audioPreparer.cancel() }

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
        let separate = prepared.tracks.count > 1
        let perTrackSpeaker = request.oneSpeakerPerSource
        progress.audioInfo = separate
            ? (perTrackSpeaker ? "Separate tracks · One speaker per track" : "Separate audio · \(prepared.tracks.count) sources · Voices detected within each")
            : "Mixed audio · All voices detected together"
        progress.modelInfo = "Deepgram Nova-3 · \(request.cloudLanguage.title) · Cloud"
        let options = DeepgramOptions(language: request.cloudLanguage, diarize: !perTrackSpeaker,
                                      keyterms: DeepgramOptions.keyterms(from: request.vocabulary))
        var transcript = Transcript(title: source.deletingPathExtension().lastPathComponent + "-transcribed",
            sourcePath: source.path, duration: prepared.duration, segments: [],
            audioLayout: progress.audioInfo, modelSummary: progress.modelInfo)
        for (index, track) in prepared.tracks.enumerated() {
            try Task.checkCancellation()
            progress.sourceProgress = separate ? "Source \(index + 1) of \(prepared.tracks.count)" : ""
            progress.stage = separate ? "Transcribing source \(index + 1) with Deepgram…" : "Transcribing with Deepgram…"
            let data = try await recognizer.recognize(audio: track, apiKey: apiKey, options: options)
            try Task.checkCancellation()
            let response: DeepgramResponse
            do { response = try JSONDecoder().decode(DeepgramResponse.self, from: data) }
            catch {
                throw NSError(domain: "VoiceScribe", code: 21, userInfo: [NSLocalizedDescriptionKey:
                    "Deepgram returned an unexpected response. \(error.localizedDescription)"])
            }
            let offset = index < prepared.offsets.count ? prepared.offsets[index] : 0
            let single = perTrackSpeaker ? "Source \(index + 1)" : nil
            var part = Transcript(title: transcript.title, sourcePath: source.path, duration: 0,
                segments: response.utterances(offset: offset, singleSpeaker: single))
            if separate && !perTrackSpeaker { part.namespaceSpeakers(sourceIndex: index) }
            transcript.segments += part.segments
            transcript.duration = max(transcript.duration, offset + (response.metadata?.duration ?? 0))
        }
        transcript.segments.sort { a, b in a.start == b.start ? a.speaker < b.speaker : a.start < b.start }
        if let previous {
            if perTrackSpeaker { transcript.copySourceSpeakerNames(from: previous) }
            else { transcript.copySpeakerNames(from: previous) }
        }
        transcript.processingDuration = ProcessInfo.processInfo.systemUptime - startedAt
        return transcript
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
