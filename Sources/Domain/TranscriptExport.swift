import Foundation

extension Transcript {
    func exported(_ format: String) throws -> String {
        if format == "json" {
            return String(decoding: try JSONEncoder.pretty.encode(self), as: UTF8.self)
        }
        if format == "md" {
            func escaped(_ text: String) -> String {
                var result = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                for character in ["\\", "`", "*", "_", "{", "}", "[", "]", "<", ">", "#", "|", "!"] {
                    result = result.replacingOccurrences(of: character, with: "\\" + character)
                }
                return result
            }
            func inline(_ text: String) -> String { escaped(text).replacingOccurrences(of: "\n", with: " ") }
            let participants = speakers.map { "- \(inline($0)): \(inline(name($0)))" }.joined(separator: "\n")
            let turns = segments.map { s in
                let review = s.needsReview ? " · speaker needs review" : ""
                let body = escaped(s.text).components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
                return "### \(stamp(s.start, subtitle: true, vtt: true))–\(stamp(s.end, subtitle: true, vtt: true)) · \(inline(name(s.speaker))) [\(inline(s.speaker))]\(review)\n\n\(body)"
            }.joined(separator: "\n\n")
            return "# \(inline(title))\n\nDuration: \(stamp(duration))\n\n## Speakers\n\n\(participants)\n\n## Transcript\n\n\(turns)\n"
        }
        if format == "srt" || format == "vtt" {
            let cues = segments.enumerated().map { i, s in
                let text = s.text.replacingOccurrences(of: "\n", with: " ")
                return "\(i + 1)\n\(stamp(s.start, subtitle: true, vtt: format == "vtt")) --> \(stamp(s.end, subtitle: true, vtt: format == "vtt"))\n[\(name(s.speaker))] \(text)\n"
            }.joined(separator: "\n")
            return (format == "vtt" ? "WEBVTT\n\n" : "") + cues
        }
        return segments.map { "[\(stamp($0.start))] \(name($0.speaker)): \($0.text)" }.joined(separator: "\n\n")
    }
    func writeNextToSource(format: String) throws -> URL {
        let source = URL(fileURLWithPath: sourcePath)
        let base = source.deletingPathExtension().lastPathComponent + "-transcribed"
        let folder = source.deletingLastPathComponent()
        let data = Data(try exported(format).utf8)
        var version = 1
        while true {
            let suffix = version == 1 ? "" : "-\(version)"
            let target = folder.appendingPathComponent("\(base)\(suffix).\(format)")
            do {
                try data.write(to: target, options: .withoutOverwriting)
                return target
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                version += 1
            }
        }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }
}

func stamp(_ seconds: Double, subtitle: Bool = false, vtt: Bool = false) -> String {
    let ms = Int((max(0, seconds) * 1000).rounded())
    let h = ms / 3_600_000, m = ms / 60_000 % 60, s = ms / 1000 % 60
    if subtitle { return String(format: "%02d:%02d:%02d%@%03d", h, m, s, vtt ? "." : ",", ms % 1000) }
    return h > 0 ? String(format: "%02d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

