import FluidAudio
import Foundation

struct TranscriptReviewRange: Decodable {
    let start: Double
    let end: Double
}

/// Formats transcription results into various output formats.
enum OutputFormatter {

    static func formatJoint(transcript: JointTranscript, timeline: [DiarizationSegment], format: OutputFormat, sourceSpeaker: String? = nil) -> String {
        let segments = sourceSpeaker.map { speaker in
            transcript.segments.map { Segment(start: $0.start, end: $0.end, text: cleanText($0.text), speaker: speaker, words: [], needsReview: $0.needsReview) }
        } ?? transcript.reconciled(timeline: timeline).map {
            Segment(start: $0.segment.start, end: $0.segment.end, text: cleanText($0.segment.text),
                speaker: $0.speaker, words: [], needsReview: $0.review)
        }
        switch format {
        case .json: return formatJSON(segments: segments, duration: transcript.duration, hasDiarization: true,
            coverageWarnings: recoveryWarnings(transcript.reviewRanges ?? []) + coverageWarnings(voices: timeline, text: segments.map { ($0.start, $0.end, $0.speaker) }))
        case .txt: return formatText(segments: segments)
        case .srt: return formatSRT(segments: segments)
        case .vtt: return formatVTT(segments: segments)
        }
    }

    static func format(
        asrResult: ASRResult,
        diarization: [DiarizationSegment]?,
        duration: Double,
        format: OutputFormat,
        reviewRanges: [TranscriptReviewRange] = [],
        sourceSpeaker: String? = nil
    ) -> String {
        // Build segments from token timings or fall back to full text
        var segments = buildSegments(asrResult: asrResult, diarization: diarization)
        if let sourceSpeaker {
            for index in segments.indices { segments[index].speaker = sourceSpeaker }
        }
        for index in segments.indices where reviewRanges.contains(where: {
            min($0.end, segments[index].end) > max($0.start, segments[index].start)
        }) {
            segments[index].needsReview = true
        }

        switch format {
        case .txt:
            return formatText(segments: segments)
        case .json:
            return formatJSON(segments: segments, duration: duration, hasDiarization: diarization != nil || sourceSpeaker != nil,
                coverageWarnings: recoveryWarnings(reviewRanges) + coverageWarnings(voices: diarization ?? [], text: segments.map { ($0.start, $0.end, $0.speaker) }))
        case .srt:
            return formatSRT(segments: segments)
        case .vtt:
            return formatVTT(segments: segments)
        }
    }

    // MARK: - Segment Building

    private static func recoveryWarnings(_ ranges: [TranscriptReviewRange]) -> [String] {
        ranges.map { "Recovered fragment · review text and timestamps · \(Int($0.start))–\(Int(ceil($0.end)))s" }
    }

    private struct Word {
        let start: Double
        let end: Double
        let text: String
    }

    private struct Segment {
        let start: Double
        let end: Double
        let text: String
        var speaker: String?
        let words: [Word]
        var needsReview: Bool = false
    }

    /// Merge BPE/SentencePiece tokens into whole words.
    /// Convention: a token starting with a space begins a new word; others continue the previous.
    private static func mergeTokensIntoWords(timings: [TokenTiming]) -> [Word] {
        var words: [Word] = []
        var currentText = ""
        var wordStart: Double = 0
        var wordEnd: Double = 0

        for timing in timings {
            let token = timing.token
            if token.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            let startsNewWord = token.hasPrefix(" ") || words.isEmpty && currentText.isEmpty

            if startsNewWord && !currentText.isEmpty {
                // Flush previous word
                let trimmed = currentText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    words.append(Word(start: wordStart, end: wordEnd, text: trimmed))
                }
                currentText = ""
            }

            if currentText.isEmpty {
                wordStart = timing.startTime
            }
            currentText += token
            wordEnd = timing.endTime
        }

        // Flush last word
        let trimmed = currentText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            words.append(Word(start: wordStart, end: wordEnd, text: trimmed))
        }

        return words
    }

    private static func buildSegments(asrResult: ASRResult, diarization: [DiarizationSegment]?) -> [Segment] {
        guard let timings = asrResult.tokenTimings, !timings.isEmpty else {
            return [Segment(
                start: 0,
                end: asrResult.duration,
                text: cleanText(asrResult.text),
                speaker: nil,
                words: [],
                needsReview: diarization != nil
            )]
        }

        let allWords = mergeTokensIntoWords(timings: timings)

        // Group words into sentence-like segments (split on sentence-ending punctuation)
        var segments: [Segment] = []
        var currentWords: [Word] = []
        var segStart: Double = 0
        var currentSpeaker: String? = nil
        var currentReview = false

        func flush() {
            guard let last = currentWords.last else { return }
            segments.append(Segment(start: segStart, end: last.end,
                text: cleanText(currentWords.map { $0.text }.joined(separator: " ")),
                speaker: currentSpeaker, words: currentWords, needsReview: currentReview))
            currentWords = []
            currentReview = false
        }

        for word in allWords {
            let assignment = assignSpeaker(start: word.start, end: word.end, in: diarization ?? [])
            let speaker = assignment.speaker
            if !currentWords.isEmpty && (speaker != currentSpeaker || word.start - (currentWords.last?.end ?? 0) > 1.2) {
                flush()
            }
            if currentWords.isEmpty {
                segStart = word.start
                currentSpeaker = speaker
            }
            currentWords.append(word)
            currentReview = currentReview || (diarization != nil && assignment.needsReview)

            let endsWithPunctuation = word.text.hasSuffix(".") || word.text.hasSuffix("?") || word.text.hasSuffix("!")
            if endsWithPunctuation || currentWords.count >= 30 {
                flush()
            }
        }

        // Flush remaining
        flush()

        return segments
    }

    /// ASR word boundaries and voice-activity boundaries can differ by a few
    /// frames. Use union overlap per speaker, then a bounded timing correction.
    /// Long missing turns stay unknown; silence must never invent an identity.
    static func assignSpeaker(start: Double, end: Double, in timeline: [DiarizationSegment])
        -> (speaker: String?, needsReview: Bool) {
        let end = max(end, start + 0.01)
        var spans: [String: [(Double, Double)]] = [:]
        for segment in timeline {
            let lo = max(start, segment.start), hi = min(end, segment.end)
            if hi > lo { spans[segment.speaker, default: []].append((lo, hi)) }
        }
        var scores: [(String, Double)] = []
        for (speaker, intervals) in spans {
            var total = 0.0, right = -Double.infinity
            for interval in intervals.sorted(by: { $0.0 < $1.0 }) {
                total += max(0, interval.1 - max(right, interval.0))
                right = max(right, interval.1)
            }
            scores.append((speaker, total))
        }
        scores.sort { a, b in a.1 == b.1 ? a.0 < b.0 : a.1 > b.1 }
        if let best = scores.first {
            let competing = scores.count > 1 && scores[1].1 > min(0.08, (end - start) * 0.3) && scores[1].1 / best.1 >= 0.65
            return (best.0, competing || best.1 / (end - start) < 0.5)
        }
        var nearby: [(String, Double)] = []
        for segment in timeline {
            let distance: Double = max(0.0, max(segment.start - end, start - segment.end))
            nearby.append((segment.speaker, distance))
        }
        nearby.sort { a, b in a.1 == b.1 ? a.0 < b.0 : a.1 < b.1 }
        guard let best = nearby.first, best.1 <= 0.5 else { return (nil, true) }
        let rival = nearby.first { $0.0 != best.0 }
        // A word near a speaker change requires a clear temporal winner.
        let uncertain = best.1 > 0.12 || (rival.map { $0.1 - best.1 < 0.15 } ?? false)
        return (best.0, uncertain)
    }

    static func missingSpeech(asrResult: ASRResult, timeline: [DiarizationSegment]) -> [(Double, Double)] {
        let words = mergeTokensIntoWords(timings: asrResult.tokenTimings ?? [])
        var ranges: [(Double, Double)] = []
        var consecutive = false
        for word in words {
            guard assignSpeaker(start: word.start, end: word.end, in: timeline).speaker == nil else {
                consecutive = false; continue
            }
            if consecutive, let last = ranges.last, word.start - last.1 <= 0.7, word.end - last.0 <= 5 {
                ranges[ranges.count - 1].1 = word.end
            } else { ranges.append((word.start, word.end)) }
            consecutive = true
        }
        return ranges
    }

    // MARK: - Plain Text

    private static func formatText(segments: [Segment]) -> String {
        var lines: [String] = []
        for seg in segments {
            let ts = formatTimestamp(seg.start)
            if let speaker = seg.speaker {
                lines.append("[\(ts)] \(speakerLabel(speaker)): \(seg.text)")
            } else {
                lines.append("[\(ts)] \(seg.text)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - JSON

    private static func formatJSON(segments: [Segment], duration: Double, hasDiarization: Bool, coverageWarnings: [String] = []) -> String {
        var jsonSegments: [[String: Any]] = []

        for seg in segments {
            var dict: [String: Any] = [
                "start": seg.start,
                "end": seg.end,
                "text": seg.text,
                "needsReview": seg.needsReview,
            ]
            if let speaker = seg.speaker {
                dict["speaker"] = speakerLabel(speaker)
            }
            if !seg.words.isEmpty {
                dict["words"] = seg.words.map { w in
                    [
                        "start": w.start,
                        "end": w.end,
                        "text": w.text,
                    ] as [String: Any]
                }
            }
            jsonSegments.append(dict)
        }

        let output: [String: Any] = [
            "metadata": [
                "duration": duration,
                "diarization": hasDiarization,
                "coverageWarnings": coverageWarnings,
            ],
            "segments": jsonSegments,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"error\": \"Failed to serialize JSON\"}"
        }

        return string + "\n"
    }

    /// A diarizer hearing a voice with no matching transcript is a warning,
    /// not proof of missing words. It also catches a lost overlapping turn.
    static func coverageWarnings(voices: [DiarizationSegment], text: [(Double, Double, String?)]) -> [String] {
        var gaps: [(Double, Double, String)] = []
        for voice in voices {
            var cursor = voice.start
            let spans = text.filter { $0.2 == voice.speaker && $0.1 > voice.start && $0.0 < voice.end }.sorted { $0.0 < $1.0 }
            for span in spans {
                if span.0 - cursor >= 0.75 { gaps.append((cursor, min(span.0, voice.end), voice.speaker)) }
                cursor = max(cursor, min(voice.end, span.1))
            }
            if voice.end - cursor >= 0.75 { gaps.append((cursor, voice.end, voice.speaker)) }
        }
        // Avoid repeating the same diagnostic for duplicate intervals.
        var seen = Set<String>()
        return gaps.sorted { $0.0 < $1.0 }.compactMap { start, end, speaker in
            let note = String(format: "Possible missing speech · %.1f–%.1fs · %@", start, end, speakerLabel(speaker))
            return seen.insert(note).inserted ? note : nil
        }
    }

    // MARK: - SRT

    private static func formatSRT(segments: [Segment]) -> String {
        var lines: [String] = []
        for (i, seg) in segments.enumerated() {
            let start = formatSRTTimestamp(seg.start)
            let end = formatSRTTimestamp(seg.end)
            let prefix = seg.speaker.map { "[\(speakerLabel($0))] " } ?? ""
            lines.append("\(i + 1)")
            lines.append("\(start) --> \(end)")
            lines.append("\(prefix)\(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - VTT

    private static func formatVTT(segments: [Segment]) -> String {
        var lines: [String] = ["WEBVTT", ""]
        for seg in segments {
            let start = formatVTTTimestamp(seg.start)
            let end = formatVTTTimestamp(seg.end)
            lines.append("\(start) --> \(end)")
            if let speaker = seg.speaker {
                lines.append("<v \(speakerLabel(speaker))>\(seg.text)")
            } else {
                lines.append(seg.text)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func cleanText(_ text: String) -> String {
        let pattern = "<\\|[^|]*\\|>"
        let cleaned = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    private static func speakerLabel(_ id: String) -> String {
        if id.hasPrefix("S"), let n = Int(id.dropFirst()) { return "Speaker \(n)" }
        // FluidAudio returns IDs like "0", "1", "2" — map to "Speaker 1", etc.
        if let num = Int(id) {
            return "Speaker \(num + 1)"
        }
        return id
    }

    private static func findSpeaker(at time: Double, in diarization: [DiarizationSegment]) -> String? {
        return diarization.first(where: { time >= $0.start && time < $0.end })?.speaker
    }

    private static func formatTimestamp(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    private static func formatSRTTimestamp(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        let millis = Int((seconds - Double(totalSeconds)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }

    private static func formatVTTTimestamp(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        let millis = Int((seconds - Double(totalSeconds)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
    }
}
