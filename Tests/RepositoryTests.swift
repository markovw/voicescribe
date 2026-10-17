import Foundation

@main struct RepositoryTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = JSONTranscriptRepository(directory: folder)
        let empty = try repository.load()
        assert(empty.isEmpty)
        var transcript = Transcript(title: "meeting", sourcePath: "/tmp/meeting.wav", duration: 4,
            segments: [Utterance(start: 0, end: 4, text: "Hello, привет!", speaker: "Speaker 1", needsReview: true)])
        transcript.names = ["Speaker 1": "First voice"]
        try repository.save([transcript])
        let loaded = try repository.load()
        assert(loaded.count == 1 && loaded[0].id == transcript.id)
        assert(loaded[0].title == "meeting-transcribed")
        assert(loaded[0].segments[0].text == transcript.segments[0].text)
        assert(loaded[0].names == transcript.names && loaded[0].reviewCount == 1)
        let historyURL = folder.appendingPathComponent("history.json")
        let before = try Data(contentsOf: historyURL)
        // A failed directory creation must not replace the existing history.
        let invalidRepository = JSONTranscriptRepository(directory: historyURL)
        do {
            try invalidRepository.save([])
            assertionFailure("Saving through a file as directory must fail")
        } catch { }
        let after = try Data(contentsOf: historyURL)
        assert(after == before)
        try repository.save([])
        let cleared = try repository.load()
        assert(cleared.isEmpty)
        try Data("invalid json".utf8).write(to: historyURL)
        do {
            _ = try repository.load()
            assertionFailure("Corrupt history must not silently become an empty library")
        } catch { }

        let suite = "local.voicescribe.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserDefaultsPreferences(defaults: defaults)
        let initial = preferences.load()
        assert(initial.mode == .accurate && initial.accurateModel == .qwen && initial.speakerCount == 0)
        defaults.set("unknown-future-model", forKey: "accurateRecognitionModel")
        defaults.set(100, forKey: "speakerCount")
        assert(preferences.load().accurateModel == .qwen && preferences.load().speakerCount == 10)
        let settings = TranscriptionPreferences(speakerCount: 3, mode: .fast, fastModel: .parakeet,
            accurateModel: .qwenSmall, voiceModel: .community, oneSpeakerPerSource: true, vocabulary: "AsyncSequence")
        preferences.save(settings)
        let restored = preferences.load()
        assert(restored.speakerCount == 3 && restored.mode == .fast && restored.fastModel == .parakeet)
        assert(restored.accurateModel == .qwenSmall && restored.voiceModel == .community)
        assert(restored.oneSpeakerPerSource && restored.vocabulary == "AsyncSequence")
        print("PASS: legacy library, atomic persistence, read failures, preference compatibility and isolation")
    }
}
