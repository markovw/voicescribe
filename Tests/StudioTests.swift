import Foundation

private final class MemoryRepository: TranscriptRepository {
    var records: [Transcript] = []
    var failWrites = false
    func load() throws -> [Transcript] { records }
    func save(_ transcripts: [Transcript]) throws {
        if failWrites { throw CocoaError(.fileWriteNoPermission) }
        records = transcripts
    }
}

private final class MemoryPreferences: PreferencesStoring {
    var value = TranscriptionPreferences()
    var saveCount = 0
    func load() -> TranscriptionPreferences { value }
    func save(_ preferences: TranscriptionPreferences) { saveCount += 1; value = preferences }
}

@MainActor private final class ControlledTranscription: TranscriptionServicing {
    var onProgress: ((TranscriptionProgress) -> Void)?
    var request: TranscriptionRequest?
    var previous: Transcript?
    var cancelled = false
    var waitForCancellation = false
    var failure: Error?
    var result = Transcript(title: "Synthetic", sourcePath: "/tmp/synthetic.wav", duration: 2,
        segments: [Utterance(start: 0, end: 2, text: "Test", speaker: "Speaker 1", needsReview: false)])

    func transcribe(_ request: TranscriptionRequest, previous: Transcript?) async throws -> Transcript {
        self.request = request
        self.previous = previous
        onProgress?(TranscriptionProgress(stage: "Working", fraction: 0.5, detail: "Synthetic"))
        if waitForCancellation { try await Task.sleep(nanoseconds: 30_000_000_000) }
        if let failure { throw failure }
        return result
    }
    func refreshProgress() { }
    func cancel() { cancelled = true }
}

@main struct StudioTests {
    @MainActor static func waitUntilIdle(_ studio: Studio) async throws {
        for _ in 0..<500 {
            if !studio.busy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("View model did not finish")
    }

    @MainActor static func main() async throws {
        let repository = MemoryRepository()
        let preferences = MemoryPreferences()
        preferences.value = TranscriptionPreferences(speakerCount: 3, mode: .fast, fastModel: .parakeet,
            accurateModel: .qwenSmall, voiceModel: .community, oneSpeakerPerSource: true, vocabulary: "Swift")
        let service = ControlledTranscription()
        let studio = Studio(repository: repository, preferences: preferences, startTicker: false) { service }
        assert(studio.count == 3 && studio.mode == .fast && studio.accurateModel == .qwenSmall)
        assert(studio.voiceModel == .community && studio.oneSpeakerPerSource && studio.vocabulary == "Swift")
        assert(preferences.saveCount == 0)
        studio.source = URL(fileURLWithPath: "/tmp/synthetic.wav")
        studio.count = 2
        studio.mode = .fast
        studio.fastModel = .parakeet
        studio.oneSpeakerPerSource = true
        studio.vocabulary = "SwiftUI"
        assert(preferences.value.oneSpeakerPerSource && preferences.value.vocabulary == "SwiftUI")
        studio.transcribe()
        assert(studio.busy)
        // Changes after Start must not mutate the request already submitted.
        studio.count = 4
        try await waitUntilIdle(studio)
        assert(service.request?.speakerCount == 2 && service.request?.oneSpeakerPerSource == true)
        assert(service.request?.model == .parakeet)
        assert(studio.document?.id == service.result.id && repository.records.count == 1)
        assert(studio.stage == "Transcript ready" && service.onProgress == nil)
        assert(studio.processingFraction == nil && studio.processingDetail.isEmpty)
        studio.rename("Speaker 1", "Voice")
        studio.removeSpeaker("Speaker 1")
        assert(studio.document?.segments[0].speaker == "Unknown")
        studio.undoSpeakerRemoval()
        assert(studio.document?.names["Speaker 1"] == "Voice")
        assert(repository.records[0].segments[0].speaker == "Speaker 1")

        repository.failWrites = true
        let currentID = studio.document?.id
        assert(!studio.clearLibrary())
        assert(studio.document?.id == currentID && studio.history.count == 1)
        assert(repository.records.count == 1 && studio.error != nil)
        repository.failWrites = false

        service.waitForCancellation = true
        studio.transcribe()
        await Task.yield()
        studio.cancel()
        assert(studio.stage == "Stopping…")
        try await waitUntilIdle(studio)
        assert(service.cancelled && studio.stage == "Processing stopped")
        assert(studio.document?.id == currentID && repository.records.count == 1)
        service.waitForCancellation = false
        service.failure = CocoaError(.fileReadCorruptFile)
        studio.transcribe()
        try await waitUntilIdle(studio)
        assert(studio.stage == "Could not process this file" && studio.error != nil)
        assert(studio.document?.id == currentID && repository.records.count == 1)
        assert(studio.clearLibrary())
        assert(repository.records.isEmpty && studio.document == nil && studio.history.isEmpty)
        print("PASS: request snapshots, editing/undo, failed clear, cancellation, errors and service cleanup")
    }
}
