import Foundation

@main struct CoreTests {
    static func main() throws {
        assert(SpeakerProcessing.layout(requested: "automatic", totalSpeakers: 2) == "automatic")
        assert(SpeakerProcessing.layout(requested: "separate", totalSpeakers: 2) == "separate")
        assert(SpeakerProcessing.layout(requested: "mixed", totalSpeakers: 2, oneSpeakerPerSource: true) == "tracks")
        assert(SpeakerProcessing.layout(requested: "separate", totalSpeakers: 0) == "separate")
        assert(SpeakerProcessing.voiceModel(requested: .nemotron, totalSpeakers: 2) == .community)
        assert(SpeakerProcessing.voiceModel(requested: .automatic, totalSpeakers: 0) == .nemotron)
        let fixture = """
        {"metadata":{"duration":8,"diarization":true},"segments":[
        {"start":0,"end":2,"text":"Привет!","speaker":"Speaker 1","needsReview":false},
        {"start":3,"end":6,"text":"Hello!","speaker":"Speaker 2","needsReview":true},
        {"start":6,"end":8,"text":"Да."}]}
        """
        var doc = try JSONDecoder().decode(EngineOutput.self, from: Data(fixture.utf8))
            .transcript(source: URL(fileURLWithPath: "/tmp/meeting.mp4"))
        assert(doc.segments.count == 3 && doc.segments[2].needsReview)
        assert(doc.processingDuration == nil && doc.processingTimeLabel == nil)
        doc.processingDuration = 42
        assert(doc.processingTimeLabel == "Transcribed in 42s")
        doc.processingDuration = 135
        assert(doc.processingTimeLabel == "Transcribed in 2m 15s")
        assert(doc.segments[2].speaker == "Unknown")
        doc.names["Speaker 1"] = "Анна"
        doc.segments[1].speaker = "Speaker 1"
        doc.segments[1].text = "Исправленный текст\nс новой строкой"
        let restored = try JSONDecoder().decode(Transcript.self, from: JSONEncoder.pretty.encode(doc))
        assert(restored.id == doc.id && restored.name("Speaker 1") == "Анна")
        assert(restored.processingDuration == 135 && restored.processingTimeLabel == "Transcribed in 2m 15s")
        let txt = try restored.exported("txt")
        assert(txt.contains("Анна: Исправленный текст") && !txt.contains("Speaker 2"))
        let srt = try restored.exported("srt")
        assert(srt.contains("00:00:03,000 --> 00:00:06,000\n[Анна] Исправленный текст с новой строкой"))
        let vtt = try restored.exported("vtt")
        assert(vtt.hasPrefix("WEBVTT\n\n") && vtt.contains("00:00:03.000 --> 00:00:06.000"))
        assert(stamp(59.9996, subtitle: true) == "00:01:00,000")
        assert(stamp(3661) == "01:01:01")
        let md = try restored.exported("md")
        assert(md.hasPrefix("# meeting-transcribed\n") && md.contains("## Speakers"))
        assert(md.contains("Анна [Speaker 1] · speaker needs review"))
        assert(md.contains("> Исправленный текст\n> с новой строкой"))
        assert(md.contains("00:00:03.000–00:00:06.000"))
        var markdownFixture = restored
        markdownFixture.title = "Meeting #1"
        markdownFixture.segments[0].text = "# Heading\n[link](https://example.com)"
        let safeMD = try markdownFixture.exported("md")
        assert(safeMD.contains("Meeting \\#1") && safeMD.contains("> \\# Heading\n> \\[link\\]"))
        assert(restored.title == "meeting-transcribed")
        var reviewed = restored
        reviewed.updateSegment(reviewed.segments[1].id, speaker: "Speaker 2")
        assert(!reviewed.segments[1].needsReview && reviewed.reviewCount == 1)
        reviewed.updateSegment(reviewed.segments[2].id, text: "Edited")
        assert(reviewed.segments[2].needsReview)
        reviewed.confirmAllReviews()
        assert(reviewed.reviewCount == 0 && reviewed.segments[2].text == "Edited")
        let reviewRoundTrip = try JSONDecoder().decode(Transcript.self, from: JSONEncoder.pretty.encode(reviewed))
        assert(reviewRoundTrip.reviewCount == 0)
        var legacy = restored
        legacy.title = "meeting · улучшено · улучшено"
        legacy.normalizeGeneratedTitle()
        assert(legacy.title == "meeting-transcribed")
        legacy.title = "My custom title"
        legacy.normalizeGeneratedTitle()
        assert(legacy.title == "My custom title")
        assert(legacy.name("Не определён") == "Unknown speaker")
        var removed = restored
        removed.names["Speaker 2"] = "Unused speaker"
        let originalText = removed.segments.map(\.text)
        let originalIDs = removed.segments.map(\.id)
        let originalTimes = removed.segments.map { [$0.start, $0.end] }
        removed.removeSpeaker("Speaker 1")
        assert(removed.names["Speaker 1"] == nil && !removed.speakers.contains("Speaker 1"))
        assert(removed.segments[0].speaker == "Unknown" && removed.segments[0].needsReview)
        assert(removed.segments[1].speaker == "Unknown" && removed.segments[1].needsReview)
        assert(removed.segments.map(\.text) == originalText && removed.segments.map(\.id) == originalIDs)
        assert(removed.segments.map { [$0.start, $0.end] } == originalTimes)
        removed.removeSpeaker("Speaker 2")
        assert(removed.names["Speaker 2"] == nil)
        removed.updateSegment(removed.segments[0].id, speaker: "Speaker 3")
        assert(!removed.segments[0].needsReview)
        let afterDeletion = try JSONDecoder().decode(Transcript.self, from: JSONEncoder.pretty.encode(removed))
        assert(afterDeletion.segments[1].speaker == "Unknown" && afterDeletion.segments[1].needsReview)
        let afterDeletionMD = try afterDeletion.exported("md")
        assert(!afterDeletionMD.contains("Анна"))
        var swapped = restored
        swapped.names = [:]
        for i in swapped.segments.indices where swapped.segments[i].speaker == "Speaker 1" {
            swapped.segments[i].speaker = "Speaker 2"
        }
        swapped.copySpeakerNames(from: restored)
        assert(swapped.names["Speaker 2"] == "Анна")
        assert(swapped.names["Не определён"] == nil)
        var separated = doc
        let reviewFlags = separated.segments.map(\.needsReview)
        separated.namespaceSpeakers(sourceIndex: 1)
        assert(separated.segments[0].speaker == "Source 2 · Speaker 1")
        assert(separated.segments[2].speaker == "Unknown")
        assert(separated.segments.map(\.needsReview) == reviewFlags)
        assert(separated.speakerCount == doc.speakerCount)
        var pinned = separated
        pinned.audioLayout = "Separate tracks · One speaker per track"
        pinned.names = ["Source 2 · Speaker 1": "Microphone"]
        var delayed = pinned
        delayed.names = [:]
        for index in delayed.segments.indices { delayed.segments[index].start += 0.25; delayed.segments[index].end += 0.25 }
        delayed.copySourceSpeakerNames(from: pinned)
        assert(delayed.names["Source 2 · Speaker 1"] == "Microphone")
        delayed.names = [:]
        delayed.copySourceSpeakerNames(from: separated)
        assert(delayed.names.isEmpty) // changing assignment must not import guessed names
        separated.modelSummary = "Source 2: MOSS · overlapping speech"
        separated.coverageWarnings = ["Possible missing speech · 5–7s"]
        let modelRoundTrip = try JSONDecoder().decode(Transcript.self, from: JSONEncoder.pretty.encode(separated))
        assert(modelRoundTrip.modelSummary == separated.modelSummary)
        assert(modelRoundTrip.coverageWarnings == separated.coverageWarnings)
        let clean = AudioQuality(dynamicRangeDB: 30, clippingFraction: 0)
        let noisy = AudioQuality(dynamicRangeDB: 6, clippingFraction: 0)
        let overlapProfile = VoiceProfile(duration: 100, speakerCount: 3, speechSeconds: 60, overlapSeconds: 12)
        assert(RecognitionChoice.choose(mode: .fast, requested: .automatic, quality: clean, voices: nil).model == .parakeet)
        assert(RecognitionChoice.choose(mode: .fast, requested: .automatic, quality: noisy, voices: nil).model == .qwenSmall)
        assert(RecognitionChoice.choose(mode: .fast, requested: .automatic, quality: clean, voices: overlapProfile).model == .moss)
        assert(RecognitionChoice.choose(mode: .fast, requested: .parakeet, quality: noisy, voices: overlapProfile).model == .parakeet)
        assert(RecognitionChoice.choose(mode: .accurate, requested: .automatic, quality: clean, voices: overlapProfile).model == .qwen)
        assert(VoiceModel.automatic.resolved(speakerCount: 0) == .nemotron)
        assert(VoiceModel.automatic.resolved(speakerCount: 3) == .community)
        let oldPlan = try JSONDecoder().decode(AudioPlan.self, from: Data("{\"separate\":true,\"paths\":[\"a\",\"b\"],\"channels\":2,\"containerTracks\":2}".utf8))
        assert(oldPlan.quality == nil && oldPlan.description.contains("within each"))
        let progressLog = """
        [accurate] Loading Qwen3 1.7B…
        [progress] {"label":"Transcribing audio…","current":2,"total":8,"detail":"Source 1 of 2"}
        """
        let progress = ProcessingStatus.fromLog(progressLog)
        assert(progress?.fraction == 0.25 && progress?.detail == "Source 1 of 2")
        assert(ProcessingStatus.fromLog(progressLog + "\n[accurate] Loading word alignment model…")?.fraction == nil)
        assert(ProcessingStatus.fromLog("[progress] {\"label\":\"Waiting\",\"current\":1,\"total\":0}")?.fraction == nil)
        assert(ProcessingStatus.fromLog("[progress] {\"label\":\"Waiting\",\"current\":9,\"total\":8}")?.fraction == nil)
        assert(ProcessingStatus.fromLog("[scribe] Diarizing speakers...")?.label == "Identifying speakers…")
        print("PASS: decoding, review flags, correction persistence, speaker names, TXT/SRT/VTT, timestamp rollover")
    }
}
