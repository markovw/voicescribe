import Foundation

struct ProcessingStatus: Decodable {
    let label: String
    var current: Int? = nil
    var total: Int? = nil
    var detail: String? = nil
    var fraction: Double? {
        guard let current, let total, total > 0, current >= 0, current <= total else { return nil }
        return Double(current) / Double(total)
    }

    static func fromLog(_ log: String) -> ProcessingStatus? {
        for line in log.components(separatedBy: .newlines).reversed() {
            if line.hasPrefix("[progress] "),
               let status = try? JSONDecoder().decode(Self.self, from: Data(line.dropFirst("[progress] ".count).utf8)) {
                return status
            }
            if line.hasPrefix("[accurate] ") { return .init(label: String(line.dropFirst("[accurate] ".count))) }
            if line.contains("Recovering missing speakers") { return .init(label: "Matching segments to speakers…") }
            if line.contains("Diarizing speakers") { return .init(label: "Identifying speakers…") }
            if line.contains("Loading diarization") { return .init(label: "Preparing speaker detection…") }
            if line.contains("Transcribing '") { return .init(label: "Transcribing audio…") }
            if line.contains("Loading ASR") { return .init(label: "Loading transcription model…") }
            if line.hasPrefix("[scribe] Written to") { return .init(label: "Finishing transcript…") }
        }
        return nil
    }
}

