import Foundation

private final class MemoryCredentials: CredentialStoring {
    var secret: String?
    var failSave = false
    func read() -> String? { secret }
    func save(_ secret: String) throws {
        if failSave { throw CocoaError(.fileWriteNoPermission) }
        self.secret = secret
    }
    func delete() throws { secret = nil }
}

private final class MemoryRepository: TranscriptRepository {
    func load() throws -> [Transcript] { [] }
    func save(_ transcripts: [Transcript]) throws { }
}

private final class MemoryPreferences: PreferencesStoring {
    var value = TranscriptionPreferences()
    func load() -> TranscriptionPreferences { value }
    func save(_ preferences: TranscriptionPreferences) { value = preferences }
}

@MainActor private final class FakePreparer: AudioPreparing {
    var tracks: [URL] = [URL(fileURLWithPath: "/tmp/input-0.m4a")]
    var offsets: [Double] = [0]
    var progressFraction: Double? { nil }
    func prepare(source: URL, folder: URL, onProgress: (TranscriptionProgress) -> Void) async throws -> PreparedAudio {
        PreparedAudio(duration: 10, tracks: tracks, offsets: offsets)
    }
    func cancel() { }
}

private final class FakeRecognizer: CloudRecognizing, @unchecked Sendable {
    var responses: [Data] = []
    var calls: [(URL, String, DeepgramOptions)] = []
    var failure: Error?
    func recognize(audio: URL, apiKey: String, options: DeepgramOptions) async throws -> Data {
        calls.append((audio, apiKey, options))
        if let failure { throw failure }
        return responses.isEmpty ? Data("{}".utf8) : responses.removeFirst()
    }
}

@MainActor private final class Marker: TranscriptionServicing {
    var onProgress: ((TranscriptionProgress) -> Void)?
    let name: String
    var calls = 0
    init(_ name: String) { self.name = name }
    func transcribe(_ request: TranscriptionRequest, previous: Transcript?) async throws -> Transcript {
        calls += 1
        onProgress?(TranscriptionProgress(stage: name))
        return Transcript(title: name, sourcePath: "/tmp/a.wav", duration: 0, segments: [])
    }
    func refreshProgress() { }
    func cancel() { }
}

private let twoSpeakers = Data("""
{"metadata":{"duration":4.5},"results":{"channels":[{"alternatives":[{"transcript":"привет как дела хорошо"}]}],
 "utterances":[{"start":0.1,"end":1.2,"transcript":" Привет, как дела? ","speaker":0,"confidence":0.98},
               {"start":1.5,"end":2.0,"transcript":"   ","speaker":1},
               {"start":2.4,"end":4.5,"transcript":"Хорошо.","speaker":1}]}}
""".utf8)

private func request(_ mode: TranscriptionMode, vocabulary: String = "", perTrack: Bool = false,
                     language: CloudLanguage = .russian) -> TranscriptionRequest {
    TranscriptionRequest(source: URL(fileURLWithPath: "/tmp/meeting.mp4"), speakerCount: 0, mode: mode,
        model: .automatic, voiceModel: .automatic, vocabulary: vocabulary, audioLayout: "automatic",
        oneSpeakerPerSource: perTrack, cloudLanguage: language)
}

@main struct CloudTests {
    @MainActor static func main() async throws {
        // Query: model, language, diarization, deduplicated keyterms, encoded plus.
        assert(DeepgramOptions.keyterms(from: " VoiceScribe, Deepgram,,voicescribe\nC++ ") == ["VoiceScribe", "Deepgram", "C++"])
        let options = DeepgramOptions(language: .russian, diarize: true, keyterms: ["C++", "Михаил"])
        let urlRequest = DeepgramClient.makeRequest(apiKey: "secret", options: options)
        let query = urlRequest.url!.query!
        assert(query.contains("model=nova-3") && query.contains("language=ru") && query.contains("diarize=true"))
        assert(query.contains("utterances=true") && query.contains("smart_format=true"))
        assert(query.contains("keyterm=C%2B%2B"), query)
        assert(!query.contains("secret"))
        assert(urlRequest.httpMethod == "POST" && urlRequest.value(forHTTPHeaderField: "Authorization") == "Token secret")
        assert(urlRequest.value(forHTTPHeaderField: "Content-Type") == "audio/mp4")
        assert(!DeepgramOptions(language: .multilingual, diarize: false, keyterms: []).queryItems.contains { $0.name == "keyterm" })

        // Response: trimmed text, empty utterances dropped, offsets, speakers from 1.
        let parsed = try JSONDecoder().decode(DeepgramResponse.self, from: twoSpeakers)
        let segments = parsed.utterances(offset: 3, singleSpeaker: nil)
        assert(segments.count == 2)
        assert(segments[0].text == "Привет, как дела?" && segments[0].speaker == "Speaker 1" && !segments[0].needsReview)
        assert(abs(segments[0].start - 3.1) < 0.0001 && abs(segments[1].end - 7.5) < 0.0001)
        assert(segments[1].speaker == "Speaker 2")
        assert(parsed.utterances(offset: 0, singleSpeaker: "Source 1").allSatisfy { $0.speaker == "Source 1" })
        // Fallback to the channel transcript without utterances; nothing for silence.
        let flat = try JSONDecoder().decode(DeepgramResponse.self, from: Data("""
            {"metadata":{"duration":2},"results":{"channels":[{"alternatives":[{"transcript":"Hello"}]}]}}
            """.utf8)).utterances(offset: 0, singleSpeaker: nil)
        assert(flat.count == 1 && flat[0].speaker == "Unknown" && flat[0].needsReview && flat[0].end == 2)
        let empty = try JSONDecoder().decode(DeepgramResponse.self, from: Data("{}".utf8))
        assert(empty.utterances(offset: 0, singleSpeaker: nil).isEmpty)

        // Errors are actionable and never echo the key.
        assert(DeepgramResponse.errorMessage(status: 401, body: Data(#"{"err_msg":"Invalid credentials."}"#.utf8)).contains("API key"))
        assert(DeepgramResponse.errorMessage(status: 402, body: Data()).contains("balance"))
        assert(DeepgramResponse.errorMessage(status: 400, body: Data(#"{"err_msg":"bad language"}"#.utf8)).contains("bad language"))

        // Service: missing key fails before any upload.
        let credentials = MemoryCredentials()
        let preparer = FakePreparer()
        let recognizer = FakeRecognizer()
        let service = CloudTranscriptionService(audioPreparer: preparer, recognizer: recognizer, credentials: credentials)
        do {
            _ = try await service.transcribe(request(.cloud), previous: nil)
            preconditionFailure("Missing key must fail")
        } catch {
            assert(error.localizedDescription.contains("API key") && recognizer.calls.isEmpty)
        }

        // Single track: key trimmed, vocabulary as keyterms, transcript assembled.
        credentials.secret = "  key-123\n"
        recognizer.responses = [twoSpeakers]
        var progressStages: [String] = []
        service.onProgress = { progressStages.append($0.stage) }
        let single = try await service.transcribe(request(.cloud, vocabulary: "Nova, Swift", language: .english), previous: nil)
        assert(recognizer.calls.count == 1 && recognizer.calls[0].1 == "key-123")
        assert(recognizer.calls[0].2 == DeepgramOptions(language: .english, diarize: true, keyterms: ["Nova", "Swift"]))
        assert(single.segments.count == 2 && single.speakers == ["Speaker 1", "Speaker 2"])
        assert(single.title == "meeting-transcribed" && single.duration == 10 && single.processingDuration != nil)
        assert(single.modelSummary?.contains("Deepgram") == true && progressStages.contains("Transcribing with Deepgram…"))

        // Separate tracks: offsets applied, speakers namespaced per source, ordered by time.
        preparer.tracks = [URL(fileURLWithPath: "/tmp/input-0.m4a"), URL(fileURLWithPath: "/tmp/input-1.m4a")]
        preparer.offsets = [0, 1]
        recognizer.calls = []
        recognizer.responses = [twoSpeakers, twoSpeakers]
        let separate = try await service.transcribe(request(.cloud), previous: nil)
        assert(recognizer.calls.map { $0.0.lastPathComponent } == ["input-0.m4a", "input-1.m4a"])
        assert(separate.segments.count == 4 && separate.speakers.contains("Source 2 · Speaker 1"))
        assert(zip(separate.segments, separate.segments.dropFirst()).allSatisfy { $0.start <= $1.start })
        assert(separate.duration == 10)

        // One speaker per track: diarization off, labels follow tracks, names carried over.
        recognizer.calls = []
        recognizer.responses = [twoSpeakers, twoSpeakers]
        let perTrack = try await service.transcribe(request(.cloud, perTrack: true), previous: nil)
        assert(recognizer.calls.allSatisfy { !$0.2.diarize })
        assert(Set(perTrack.speakers) == ["Source 1", "Source 2"])
        var named = perTrack; named.names = ["Source 1": "Anna"]
        recognizer.responses = [twoSpeakers, twoSpeakers]
        let renamed = try await service.transcribe(request(.cloud, perTrack: true), previous: named)
        assert(renamed.names["Source 1"] == "Anna")

        // Upload failure propagates unchanged.
        recognizer.failure = NSError(domain: "VoiceScribe", code: 402, userInfo: [NSLocalizedDescriptionKey: "balance"])
        do { _ = try await service.transcribe(request(.cloud), previous: nil); preconditionFailure("Failure must propagate") }
        catch { assert(error.localizedDescription == "balance") }

        // Router: local modes never reach the cloud service and vice versa.
        let local = Marker("local"), cloud = Marker("cloud")
        let router = TranscriptionRouter(local: { local }, cloud: { cloud })
        var routed: [String] = []
        router.onProgress = { routed.append($0.stage) }
        _ = try await router.transcribe(request(.fast), previous: nil)
        _ = try await router.transcribe(request(.accurate), previous: nil)
        let viaCloud = try await router.transcribe(request(.cloud), previous: nil)
        assert(local.calls == 2 && cloud.calls == 1 && viaCloud.title == "cloud" && routed == ["local", "local", "cloud"])

        // Studio: key lives in the credential store, language in preferences.
        let preferences = MemoryPreferences()
        preferences.value.cloudLanguage = .multilingual
        let keys = MemoryCredentials()
        let studio = Studio(repository: MemoryRepository(), preferences: preferences, credentials: keys, startTicker: false) { local }
        assert(!studio.hasCloudKey && studio.cloudLanguage == .multilingual)
        let blank = studio.saveCloudKey("   ")
        assert(!blank)
        let saved = studio.saveCloudKey(" dg-key ")
        assert(saved && keys.secret == "dg-key" && studio.hasCloudKey)
        studio.cloudLanguage = .english
        assert(preferences.value.cloudLanguage == .english)
        studio.mode = .cloud
        let accurateBefore = studio.accurateModel
        studio.recognitionModel = .moss
        assert(studio.accurateModel == accurateBefore && studio.fastModel != .moss)
        keys.failSave = true
        let failed = studio.saveCloudKey("other")
        assert(!failed && studio.error?.contains("Deepgram key") == true && keys.secret == "dg-key")
        studio.removeCloudKey()
        assert(!studio.hasCloudKey && keys.secret == nil)

        // Persisted preferences round-trip the cloud language and mode.
        let suite = "local.voicescribe.cloud-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let stored = UserDefaultsPreferences(defaults: defaults)
        assert(stored.load().cloudLanguage == .russian)
        var settings = TranscriptionPreferences(); settings.mode = .cloud; settings.cloudLanguage = .english
        stored.save(settings)
        assert(stored.load().mode == .cloud && stored.load().cloudLanguage == .english)
        print("Cloud tests passed")
    }
}
