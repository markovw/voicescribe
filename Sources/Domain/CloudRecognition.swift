import Foundation

enum CloudLanguage: String, CaseIterable, Identifiable {
    case russian = "ru", english = "en", multilingual = "multi"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .russian: return "Russian"
        case .english: return "English"
        case .multilingual: return "Mixed languages"
        }
    }
}

/// Request options are value types so the query can be verified without a network.
struct DeepgramOptions: Equatable {
    var language: CloudLanguage
    var diarize: Bool
    var keyterms: [String]

    static func keyterms(from vocabulary: String) -> [String] {
        var seen = Set<String>()
        return vocabulary.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "model", value: "nova-3"),
                     URLQueryItem(name: "language", value: language.rawValue),
                     URLQueryItem(name: "smart_format", value: "true"),
                     URLQueryItem(name: "punctuate", value: "true"),
                     URLQueryItem(name: "utterances", value: "true"),
                     URLQueryItem(name: "diarize", value: diarize ? "true" : "false")]
        items += keyterms.map { URLQueryItem(name: "keyterm", value: $0) }
        return items
    }
}

struct DeepgramResponse: Decodable {
    struct Metadata: Decodable { var duration: Double? }
    struct Alternative: Decodable { var transcript: String? }
    struct Channel: Decodable { var alternatives: [Alternative]? }
    struct Part: Decodable {
        var start: Double; var end: Double; var transcript: String
        var speaker: Int?; var confidence: Double?
    }
    struct Results: Decodable { var channels: [Channel]?; var utterances: [Part]? }
    var metadata: Metadata?
    var results: Results?

    /// Deepgram returns times relative to the uploaded track; `offset`
    /// restores the source timeline. Speakers are numbered from 1.
    func utterances(offset: Double, singleSpeaker: String?) -> [Utterance] {
        let parts = results?.utterances ?? []
        if parts.isEmpty {
            let text = (results?.channels?.first?.alternatives?.first?.transcript ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [.init(start: offset, end: offset + (metadata?.duration ?? 0), text: text,
                          speaker: singleSpeaker ?? "Unknown", needsReview: singleSpeaker == nil)]
        }
        return parts.compactMap { (part: Part) -> Utterance? in
            let text = part.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let speaker = singleSpeaker ?? part.speaker.map { "Speaker \($0 + 1)" } ?? "Unknown"
            return .init(start: max(0, part.start) + offset, end: max(part.start, part.end) + offset,
                         text: text, speaker: speaker, needsReview: speaker == "Unknown")
        }
    }

    static func errorMessage(status: Int, body: Data) -> String {
        struct Failure: Decodable { var err_msg: String?; var message: String?; var details: String? }
        let failure = try? JSONDecoder().decode(Failure.self, from: body)
        let detail = failure?.err_msg ?? failure?.message ?? String(decoding: body.prefix(400), as: UTF8.self)
        switch status {
        case 401, 403: return "Deepgram rejected the API key. Check it in Deepgram settings. \(detail)"
        case 402: return "Deepgram balance is exhausted. Add credit in the Deepgram console."
        case 413: return "The audio is too large for Deepgram. Split the recording and try again."
        case 429: return "Deepgram rate limit reached. Wait a moment and try again."
        default: return "Deepgram error \(status). \(detail)"
        }
    }
}
