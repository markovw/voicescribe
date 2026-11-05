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

@MainActor private final class FakeInspector: SourceInspecting {
    var keep: [Int] = []
    var combined = false
    /// Stereo tracks come back as encoded channel files, not the exported tracks.
    var encoded = false
    var calls = 0
    func inspect(_ audio: PreparedAudio, folder: URL) async throws -> InspectedAudio {
        calls += 1
        let tracks = keep.map { encoded ? URL(fileURLWithPath: "/tmp/source-\($0).m4a") : audio.tracks[$0] }
        return InspectedAudio(tracks: tracks, offsets: keep.map { encoded ? 0 : audio.offsets[$0] },
                              origins: combined ? keep.map { _ in nil } : keep)
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

        // One track has no track ownership: voices are still diarized.
        recognizer.calls = []
        recognizer.responses = [twoSpeakers]
        let lone = try await service.transcribe(request(.cloud, perTrack: true), previous: nil)
        assert(recognizer.calls.count == 1 && recognizer.calls[0].2.diarize)
        assert(lone.speakers == ["Speaker 1", "Speaker 2"] && lone.audioLayout?.hasPrefix("Mixed audio") == true)

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

        // Redundant tracks: a full mix is never uploaded, so voices are not repeated.
        let inspector = FakeInspector()
        let inspected = CloudTranscriptionService(audioPreparer: preparer, recognizer: recognizer,
                                                  credentials: credentials, inspector: inspector)
        preparer.tracks.append(URL(fileURLWithPath: "/tmp/input-2.m4a"))
        preparer.offsets.append(0)
        inspector.keep = [0, 1]
        recognizer.calls = []
        recognizer.responses = [twoSpeakers, twoSpeakers]
        let stems = try await inspected.transcribe(request(.cloud), previous: nil)
        assert(inspector.calls == 1 && recognizer.calls.map { $0.0.lastPathComponent } == ["input-0.m4a", "input-1.m4a"])
        assert(!stems.speakers.contains { $0.hasPrefix("Source 3") })
        assert(stems.audioLayout?.contains("2 sources") == true && stems.audioLayout?.contains("1 redundant track skipped") == true)
        // Combined into one source: speakers are numbered once for the whole recording.
        inspector.keep = [2]
        inspector.combined = true
        recognizer.calls = []
        recognizer.responses = [twoSpeakers]
        let mixed = try await inspected.transcribe(request(.cloud), previous: nil)
        assert(recognizer.calls.count == 1 && mixed.speakers == ["Speaker 1", "Speaker 2"])
        assert(mixed.audioLayout?.hasPrefix("Mixed audio") == true)
        // Track ownership also drops a full mix, then labels the remaining tracks.
        inspector.keep = [0, 1]
        inspector.combined = false
        recognizer.calls = []
        recognizer.responses = [twoSpeakers, twoSpeakers]
        let owned = try await inspected.transcribe(request(.cloud, perTrack: true), previous: nil)
        assert(inspector.calls == 3 && recognizer.calls.map { $0.0.lastPathComponent } == ["input-0.m4a", "input-1.m4a"])
        assert(Set(owned.speakers) == ["Source 1", "Source 2"] && owned.audioLayout?.contains("1 redundant track skipped") == true)
        // A combined recording has no track owner: every track is kept.
        inspector.keep = [2]
        inspector.combined = true
        recognizer.calls = []
        recognizer.responses = [twoSpeakers, twoSpeakers, twoSpeakers]
        _ = try await inspected.transcribe(request(.cloud, perTrack: true), previous: nil)
        assert(inspector.calls == 4 && recognizer.calls.count == 3)
        inspector.combined = false
        // Stereo tracks: channel files still map to their tracks, so ownership holds.
        inspector.keep = [1, 2]
        inspector.encoded = true
        recognizer.calls = []
        recognizer.responses = [twoSpeakers, twoSpeakers]
        let stereo = try await inspected.transcribe(request(.cloud, perTrack: true), previous: nil)
        assert(recognizer.calls.map { $0.0.lastPathComponent } == ["source-1.m4a", "source-2.m4a"])
        assert(Set(stereo.speakers) == ["Source 1", "Source 2"] && stereo.audioLayout?.contains("1 redundant track skipped") == true)
        inspector.encoded = false

        // Safety net: a mix that inspection missed repeats both stems and is dropped after recognition.
        inspector.keep = [0, 1, 2]
        func response(_ turns: [(Double, String)]) -> Data {
            let items = turns.map { #"{"start":\#($0.0),"end":\#($0.0 + 2),"transcript":"\#($0.1)","speaker":0}"# }
            return Data(#"{"metadata":{"duration":100},"results":{"utterances":[\#(items.joined(separator: ","))]}}"#.utf8)
        }
        let micTurns = (0..<10).map { t in (Double(t) * 10, (0..<6).map { w in "mic\(t)x\(w)" }.joined(separator: " ")) }
        let remoteTurns = (0..<10).map { t in (Double(t) * 10 + 5, (0..<6).map { w in "remote\(t)x\(w)" }.joined(separator: " ")) }
        for perTrack in [false, true] {
            recognizer.calls = []
            recognizer.responses = [response(micTurns + remoteTurns), response(micTurns), response(remoteTurns)]
            let safe = try await inspected.transcribe(request(.cloud, perTrack: perTrack), previous: nil)
            assert(recognizer.calls.count == 3 && safe.segments.count == 20, "\(safe.segments.count)")
            assert(Set(safe.speakers) == (perTrack ? ["Source 1", "Source 2"] : ["Source 1 · Speaker 1", "Source 2 · Speaker 1"]))
            assert(safe.segments.first { $0.text.hasPrefix("mic0") }?.speaker.hasPrefix("Source 1") == true)
            assert(safe.audioLayout?.contains("1 redundant track skipped") == true)
        }
        preparer.tracks.removeLast(); preparer.offsets.removeLast()

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
        // One speaker per track is on for a fresh install; an explicit choice persists.
        assert(stored.load().oneSpeakerPerSource)
        var off = TranscriptionPreferences(); off.oneSpeakerPerSource = false
        stored.save(off)
        assert(!stored.load().oneSpeakerPerSource)
        var settings = TranscriptionPreferences(); settings.mode = .cloud; settings.cloudLanguage = .english
        stored.save(settings)
        assert(stored.load().mode == .cloud && stored.load().cloudLanguage == .english)
        print("Cloud tests passed")
    }
}
