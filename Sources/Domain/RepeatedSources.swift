import Foundation

/// Finds sources whose recognized words repeat other sources at the same time:
/// a full mix or duplicate track that audio inspection could not rule out.
/// Independent tracks share few words at the same moment (single digits in
/// percent, mostly echo and backchannel); a mix repeats nearly everything.
enum RepeatedSources {
    static let threshold = 0.5
    static let minimumWords = 30
    static let window = 1.5

    /// Indices of sources to drop. The largest repeated source goes first,
    /// since a mix contains each stem; coverage is then measured again.
    static func redundant(_ sources: [[Utterance]]) -> Set<Int> {
        let words = sources.map { $0.map { tokens($0.text) } }
        var dropped = Set<Int>()
        while sources.count - dropped.count > 1 {
            let kept = sources.indices.filter { !dropped.contains($0) }
            var worst: (index: Int, words: Int)?
            for index in kept {
                let others = kept.filter { $0 != index }.flatMap { other in
                    sources[other].indices.map { (sources[other][$0], words[other][$0]) }
                }.sorted { $0.0.start < $1.0.start }
                let (covered, total) = coverage(of: sources[index], words: words[index], by: others)
                guard total >= minimumWords, Double(covered) / Double(total) >= threshold else { continue }
                if worst == nil || total > worst!.words { worst = (index, total) }
            }
            guard let worst else { break }
            dropped.insert(worst.index)
        }
        return dropped
    }

    private static func coverage(of segments: [Utterance], words: [[String]],
                                 by others: [(Utterance, [String])]) -> (Int, Int) {
        let latestEnd = others.reduce(into: [Double]()) { ends, item in ends.append(max(ends.last ?? -.infinity, item.0.end)) }
        var covered = 0, total = 0
        for (segment, tokens) in zip(segments, words) where !tokens.isEmpty {
            total += tokens.count
            // First neighbour that may still overlap the window (running max of ends).
            var low = 0, high = others.count
            while low < high {
                let middle = (low + high) / 2
                if latestEnd[middle] < segment.start - window { low = middle + 1 } else { high = middle }
            }
            var pool = Set<String>()
            var index = low
            while index < others.count, others[index].0.start <= segment.end + window {
                if others[index].0.end >= segment.start - window { pool.formUnion(others[index].1) }
                index += 1
            }
            covered += tokens.filter(pool.contains).count
        }
        return (covered, total)
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
