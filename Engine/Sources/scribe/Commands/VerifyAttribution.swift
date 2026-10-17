import ArgumentParser
import FluidAudio
import Foundation

/// Runs regression checks against the real formatter without downloading models.
struct VerifyAttribution: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "verify-attribution",
        abstract: "Verify word attribution, speaker changes and review flags.")

    func run() throws {
        func word(_ text: String, _ start: Double, _ end: Double) -> TokenTiming {
            TokenTiming(token: text, tokenId: 1, startTime: start, endTime: end, confidence: 1)
        }
        func segments(_ intervals: [DiarizationSegment], _ timings: [TokenTiming]) throws -> [[String: Any]] {
            let result = ASRResult(text: "Hello yes please", confidence: 1, duration: 3,
                processingTime: 0.1, tokenTimings: timings)
            let json = OutputFormatter.format(asrResult: result, diarization: intervals, duration: 3, format: .json)
            let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            return object["segments"] as! [[String: Any]]
        }
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw ValidationError(message) }
        }
        let turns = [DiarizationSegment(speaker: "S1", start: 0, end: 1),
            DiarizationSegment(speaker: "S2", start: 1, end: 3)]
        let recoveredResult = ASRResult(text: "Recovered sentence. Clear.", confidence: 0, duration: 3,
            processingTime: 0, tokenTimings: [word("Recovered sentence.", 0, 1), word(" Clear.", 2, 3)])
        let recoveredJSON = OutputFormatter.format(asrResult: recoveredResult, diarization: nil, duration: 3,
            format: .json, reviewRanges: [.init(start: 0, end: 1)])
        let recoveredObject = try JSONSerialization.jsonObject(with: Data(recoveredJSON.utf8)) as! [String: Any]
        let recoveredSegments = recoveredObject["segments"] as! [[String: Any]]
        try check(recoveredSegments[0]["needsReview"] as? Bool == true, "Recovered timing must require review")
        try check(recoveredSegments.last?["needsReview"] as? Bool == false, "Normal aligned segments must stay unaffected")
        try check(((recoveredObject["metadata"] as? [String: Any])?["coverageWarnings"] as? [String])?.first?.contains("Recovered fragment") == true,
            "Alignment recovery must remain visible in saved transcripts")
        let pinnedJSON = OutputFormatter.format(asrResult: recoveredResult, diarization: nil, duration: 3,
            format: .json, reviewRanges: [.init(start: 0, end: 1)], sourceSpeaker: "S1")
        let pinnedObject = try JSONSerialization.jsonObject(with: Data(pinnedJSON.utf8)) as! [String: Any]
        let pinnedSegments = pinnedObject["segments"] as! [[String: Any]]
        try check(pinnedSegments.allSatisfy { $0["speaker"] as? String == "Speaker 1" }, "Source assignment must keep every aligned fragment on its own source")
        try check(pinnedSegments[0]["needsReview"] as? Bool == true, "Source assignment must retain timing recovery warnings")
        let switched = try segments(turns, [word("Hello", 0, 0.5), word(" yes", 1.1, 1.5), word(" please", 1.6, 2)])
        try check(switched.count == 2, "Speaker change without punctuation must split a sentence")
        try check(switched[0]["text"] as? String == "Hello", "First speaker must retain only their words")
        try check(switched[1]["text"] as? String == "yes please", "Second speaker must retain both words")
        try check(switched[1]["speaker"] as? String == "Speaker 2", "Speaker labels must be normalized")
        let boundary = try segments(turns, [word("Hello", 0.7, 1.4)])
        try check(boundary[0]["speaker"] as? String == "Speaker 2", "Largest overlap must determine attribution")
        try check(boundary[0]["needsReview"] as? Bool == true, "Ambiguous boundary must require review")
        let unknown = try segments([.init(speaker: "S1", start: 2, end: 3)], [word("Hello", 0, 0.5)])
        try check(unknown[0]["speaker"] == nil && unknown[0]["needsReview"] as? Bool == true,
            "Words outside voice intervals must be unknown and require review")
        let near = OutputFormatter.assignSpeaker(start: 3.1, end: 3.3, in: turns)
        try check(near.speaker == "S2" && !near.needsReview, "Small ASR timing gaps should recover automatically")
        let distant = OutputFormatter.assignSpeaker(start: 5, end: 6, in: turns)
        try check(distant.speaker == nil && distant.needsReview, "Long gaps must not invent a speaker")
        let minor = OutputFormatter.assignSpeaker(start: 0.95, end: 1.8, in: turns)
        try check(minor.speaker == "S2" && !minor.needsReview, "Tiny boundary overlap must not flag a whole sentence")
        let overlap = OutputFormatter.assignSpeaker(start: 1, end: 2, in: [
            .init(speaker: "S1", start: 0, end: 3), .init(speaker: "S2", start: 1, end: 2)])
        try check(overlap.needsReview, "Balanced simultaneous speech must remain reviewable")
        let duplicate = OutputFormatter.assignSpeaker(start: 0, end: 1, in: [
            .init(speaker: "S1", start: 0, end: 0.4), .init(speaker: "S1", start: 0, end: 0.4),
            .init(speaker: "S2", start: 0.4, end: 1)])
        try check(duplicate.speaker == "S2", "Repeated intervals must not inflate evidence")
        let shortOverlap = OutputFormatter.assignSpeaker(start: 1, end: 1.08, in: [
            .init(speaker: "S1", start: 0, end: 3), .init(speaker: "S2", start: 1, end: 1.1)])
        try check(shortOverlap.needsReview, "Short overlapping backchannels must not appear certain")
        let voiceProfile = VoiceTimeline(duration: 4, segments: [
            .init(speaker: "S1", start: 0, end: 3), .init(speaker: "S1", start: 0, end: 3),
            .init(speaker: "S2", start: 1, end: 2)])
        try check(voiceProfile.speechSeconds == 3 && voiceProfile.overlapSeconds == 1 && voiceProfile.speakerCount == 2,
            "Voice profiling must union duplicate intervals")
        let jointJSON = """
        {"duration":8,"segments":[
        {"start":0,"end":1,"text":"Первый","speaker":"S01","chunk":0,"needsReview":false},
        {"start":2,"end":3,"text":"Second","speaker":"S02","chunk":0,"needsReview":false},
        {"start":4,"end":5,"text":"Первый снова","speaker":"S02","chunk":1,"needsReview":false},
        {"start":6,"end":7,"text":"Second again","speaker":"S01","chunk":1,"needsReview":false}]}
        """
        let joint = try JSONDecoder().decode(JointTranscript.self, from: Data(jointJSON.utf8))
        try joint.validate(duration: 8)
        let pinnedJointJSON = OutputFormatter.formatJoint(transcript: joint, timeline: [], format: .json, sourceSpeaker: "S1")
        let pinnedJoint = try JSONSerialization.jsonObject(with: Data(pinnedJointJSON.utf8)) as! [String: Any]
        try check((pinnedJoint["segments"] as! [[String: Any]]).allSatisfy { $0["speaker"] as? String == "Speaker 1" && $0["needsReview"] as? Bool == false },
            "Changing MOSS labels must not create voices inside a known single-speaker track")
        let stableVoices = [DiarizationSegment(speaker: "S1", start: 0, end: 1),
            .init(speaker: "S2", start: 2, end: 3), .init(speaker: "S1", start: 4, end: 5), .init(speaker: "S2", start: 6, end: 7)]
        let reconciled = joint.reconciled(timeline: stableVoices)
        try check(reconciled.map { $0.speaker } == ["S1", "S2", "S1", "S2"], "MOSS labels may restart or swap between chunks")
        try check(reconciled.allSatisfy { !$0.review }, "Clear acoustic mappings should remain unflagged")
        let unresolved = joint.reconciled(timeline: [])
        try check(unresolved.allSatisfy { $0.speaker == nil && $0.review }, "Native labels without stable voice evidence must remain reviewable")
        let uncovered = OutputFormatter.coverageWarnings(voices: [
            .init(speaker: "S1", start: 0, end: 3), .init(speaker: "S2", start: 1, end: 2)], text: [(0, 3, "S1")])
        try check(uncovered.count == 1 && uncovered[0].contains("Speaker 2"), "Lost overlapping voice must produce a coverage warning")
        let covered = OutputFormatter.coverageWarnings(voices: stableVoices, text: reconciled.map { ($0.segment.start, $0.segment.end, $0.speaker) })
        try check(covered.isEmpty, "Fully covered voice intervals must not warn")
        print("PASS: speaker turns, overlap union, bounded timing recovery, real ambiguity, unknown preservation")
    }
}
