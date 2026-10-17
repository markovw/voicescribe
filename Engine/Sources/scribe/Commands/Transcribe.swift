import ArgumentParser
import FluidAudio
import Foundation

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe an audio file."
    )

    @Argument(help: "Path to the audio file to transcribe.")
    var audioFile: String

    @Flag(name: .long, help: "Enable speaker diarization.")
    var diarize: Bool = false
    @Flag(name: .long, help: "Assign all recognized speech to one known source speaker; skips voice clustering.")
    var singleSpeaker: Bool = false

    @Option(name: .long, help: "Number of speakers (helps diarization accuracy).")
    var speakers: Int?

    @Option(name: .long, help: "Minimum speaker turn duration in seconds (default: 0.15).")
    var minTurnDuration: Double = 0.15

    @Option(name: .long, help: "Speaker model: nemotron (up to 8 voices) or community.")
    var speakerModel: SpeakerModel = .nemotron

    @Option(name: .long, help: "Output format: txt, json, srt, vtt.")
    var format: OutputFormat = .txt

    @Option(name: .long, help: "Language code (auto-detect if not specified).")
    var language: String?

    @Option(name: .long, help: "JSON containing externally recognized text and aligned words (skips Parakeet).")
    var alignedWords: String?

    @Option(name: .long, help: "Reusable local voice profile JSON (avoids detecting voices twice).")
    var speakerTimeline: String?

    @Option(name: .long, help: "Native MOSS segment transcript JSON; reconciles chunk voice labels acoustically.")
    var jointTranscript: String?

    @Option(name: .shortAndLong, help: "Output file path (default: stdout).")
    var output: String?

    @Flag(name: .long, help: "Show progress and timing information.")
    var verbose: Bool = false

    func run() async throws {
        let fileURL = URL(fileURLWithPath: audioFile)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ValidationError("File not found: \(audioFile)")
        }
        guard minTurnDuration >= 0 && minTurnDuration <= 5 else {
            throw ValidationError("min-turn-duration must be between 0 and 5")
        }
        guard alignedWords == nil || jointTranscript == nil else { throw ValidationError("Choose aligned words or a joint transcript, not both.") }
        guard !singleSpeaker || (!diarize && speakerTimeline == nil) else { throw ValidationError("Single-speaker source assignment cannot use voice clustering or a cached voice timeline.") }
        guard jointTranscript == nil || diarize || singleSpeaker else { throw ValidationError("Joint transcription requires voice detection or single-speaker source assignment.") }

        // Load audio
        if verbose { log("Loading audio...") }
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(fileURL)
        let duration = Double(samples.count) / 16000.0

        if verbose { log(String(format: "Audio loaded: %.0fs (%.1f min)", duration, duration / 60)) }

        let startTime = Date()
        let asrResult: ASRResult
        var reviewRanges: [TranscriptReviewRange] = []
        var asrManager: AsrManager?
        let joint = try jointTranscript.map { try JSONDecoder().decode(JointTranscript.self, from: Data(contentsOf: URL(fileURLWithPath: $0))) }
        if let joint {
            try joint.validate(duration: duration)
            asrResult = ASRResult(text: joint.segments.map(\.text).joined(separator: " "), confidence: 0, duration: duration, processingTime: 0, tokenTimings: [])
        } else if let alignedWords {
            let input = try JSONDecoder().decode(AlignedTranscript.self, from: Data(contentsOf: URL(fileURLWithPath: alignedWords)))
            reviewRanges = input.reviewRanges ?? []
            guard abs(input.duration - duration) < 0.2,
                  reviewRanges.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= duration + 0.1 }),
                  input.words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= duration + 0.1 }),
                  input.text.isEmpty || !input.words.isEmpty else {
                throw ValidationError("Invalid word alignment. Please retry Accurate transcription.")
            }
            asrResult = ASRResult(text: input.text, confidence: 0, duration: duration, processingTime: 0,
                tokenTimings: input.words.enumerated().map { i, word in
                    TokenTiming(token: " " + word.text, tokenId: i, startTime: word.start, endTime: word.end, confidence: 0)
                })
        } else {
        // Fast mode: Parakeet TDT v3.
        if verbose { log("Loading ASR model (Parakeet TDT v3)...") }
        let asrModels = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager()
        asrManager = manager
        try await manager.loadModels(asrModels)

        if verbose { log("Transcribing '\(audioFile)'...") }
        var decoderState = try TdtDecoderState(decoderLayers: 2)
        let selectedLanguage = language.flatMap { Language(rawValue: $0) }
        if language != nil && selectedLanguage == nil { throw ValidationError("Unsupported language code") }
        asrResult = try await manager.transcribe(samples, decoderState: &decoderState, language: selectedLanguage)
        let transcribeElapsed = Date().timeIntervalSince(startTime)

        if verbose {
            log(String(format: "Transcription completed in %.1fs (%.1fx real-time)",
                       transcribeElapsed, duration / transcribeElapsed))
        }
        }

        // Diarize if requested
        var diarizationSegments: [DiarizationSegment]? = nil
        if diarize {
            if verbose { log("Loading diarization model...") }
            let diarizeStart = Date()

            var recoveryModels: OfflineDiarizerModels?
            if let speakerTimeline {
                let profile = try JSONDecoder().decode(VoiceTimeline.self, from: Data(contentsOf: URL(fileURLWithPath: speakerTimeline)))
                guard abs(profile.duration - duration) < 0.2,
                      profile.segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= duration + 0.2 }) else {
                    throw ValidationError("Invalid cached voice timeline.")
                }
                diarizationSegments = profile.segments
            } else {
                if verbose { log("Diarizing speakers...") }
                let detected = try await LocalVoiceAnalysis.detect(samples: samples, model: speakerModel, speakers: speakers, minTurn: minTurnDuration)
                diarizationSegments = detected.0
                recoveryModels = detected.1
            }
            let timeline = diarizationSegments ?? []
            // Avoid loading embedding models when there is nothing to recover.
            if joint == nil, Set(timeline.map(\.speaker)).count >= 2,
               OutputFormatter.missingSpeech(asrResult: asrResult, timeline: timeline).contains(where: { $0.1 - $0.0 >= 0.5 }) {
                if verbose { log("Recovering missing speakers...") }
                let models: OfflineDiarizerModels
                if let recoveryModels { models = recoveryModels }
                else { models = try await OfflineDiarizerModels.load() }
                diarizationSegments = try SpeakerRecovery(models: models, samples: samples)
                    .recover(asr: asrResult, timeline: timeline, log: { message in if verbose { log(message) } })
            }
            if verbose { log(String(format: "Diarization completed in %.1fs", Date().timeIntervalSince(diarizeStart))) }
        }

        // Format output
        let formatted: String
        if let joint {
            formatted = OutputFormatter.formatJoint(transcript: joint, timeline: diarizationSegments ?? [], format: format, sourceSpeaker: singleSpeaker ? "S1" : nil)
        } else {
            formatted = OutputFormatter.format(asrResult: asrResult, diarization: diarizationSegments, duration: duration, format: format, reviewRanges: reviewRanges, sourceSpeaker: singleSpeaker ? "S1" : nil)
        }

        // Write output
        if let outputPath = output {
            try formatted.write(toFile: outputPath, atomically: true, encoding: String.Encoding.utf8)
            if verbose { log("Written to \(outputPath)") }
        } else {
            print(formatted, terminator: "")
            fflush(stdout)
        }

        if verbose {
            let totalElapsed = Date().timeIntervalSince(startTime)
            log(String(format: "Total time: %.1fs", totalElapsed))
        }

        await asrManager?.cleanup()
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[scribe] \(message)\n".utf8))
    }
}

// MARK: - Output Format

enum OutputFormat: String, ExpressibleByArgument, CaseIterable, Sendable {
    case txt, json, srt, vtt
}

enum SpeakerModel: String, ExpressibleByArgument, Sendable { case nemotron, community }

private struct AlignedTranscript: Decodable {
    struct Word: Decodable { let start: Double; let end: Double; let text: String }
    let text: String
    let duration: Double
    let words: [Word]
    let reviewRanges: [TranscriptReviewRange]?
}

// MARK: - Diarization Segment (internal)

struct DiarizationSegment: Codable, Sendable {
    let speaker: String
    let start: Double
    let end: Double
}
