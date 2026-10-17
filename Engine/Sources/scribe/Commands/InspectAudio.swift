import ArgumentParser
import AVFoundation
import FluidAudio
import Foundation

/// Conservative layout detection. Container tracks can include a redundant
/// full mix, and ordinary stereo is not evidence of two different speakers.
struct InspectAudio: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Detect independent audio tracks/channels.")
    @Argument var audioFiles: [String]
    @Option(name: .long) var directory: String
    @Option(name: .long) var output: String
    @Option(name: .long) var layout: String = "automatic"
    @Option(name: .long) var offsets: String?

    private struct Candidate {
        let path: String
        let source: Int
        let channel: Int
        let waveform: [Float]
        let energy: [Double]
        let active: [Bool]
        var activity: Int { active.filter { $0 }.count }
    }

    func run() async throws {
        guard ["automatic", "mixed", "separate", "tracks"].contains(layout) else { throw ValidationError("Unsupported audio layout.") }
        let starts = offsets?.split(separator: ",").compactMap { Double($0) } ?? Array(repeating: 0, count: audioFiles.count)
        guard starts.count == audioFiles.count, starts.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 86400 }) else {
            throw ValidationError("Invalid source track offsets.")
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var candidates: [Candidate] = []
        var monoPaths: [Int: String] = [:]
        for (index, path) in audioFiles.enumerated() {
            let padding = Int((starts[index] * 16000).rounded())
            let channels = try splitChannels(URL(fileURLWithPath: path), into: folder, index: index, padding: padding)
            let mono = folder.appendingPathComponent("track-\(index)-mono.wav")
            let samples = Array(repeating: Float(0), count: padding) + (try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path)))
            try write(samples, to: mono)
            monoPaths[index] = mono.path
            for (channel, url) in channels.enumerated() {
                let samples = try AudioConverter().resampleAudioFile(url)
                let energy = energies(samples)
                let peak = energy.max() ?? 0
                let sorted = energy.sorted()
                let noise = sorted.isEmpty ? 0 : sorted[sorted.count / 5]
                let threshold = max(1e-9, max(peak * 0.0004, min(noise * 6, peak * 0.08)))
                let active = energy.map { $0 > threshold }
                // Average to 1 kHz for correlation; retain a small proxy, not
                // several full-resolution copies of a long interview.
                var proxy: [Float] = []
                proxy.reserveCapacity(samples.count / 16)
                for start in stride(from: 0, to: samples.count - 15, by: 16) {
                    var sum: Float = 0
                    for i in start..<start + 16 { sum += samples[i] }
                    proxy.append(sum / 16)
                }
                if peak > 1e-9, active.filter({ $0 }).count >= 3 {
                    candidates.append(Candidate(path: url.path, source: index, channel: channel,
                        waveform: proxy, energy: energy, active: active))
                }
            }
        }
        // Collapse duplicate channels/tracks. Stereo panning can scale a voice;
        // a large waveform correlation still means one shared recording.
        var unique: [Candidate] = []
        for candidate in candidates {
            if let index = unique.firstIndex(where: { abs(correlation($0.waveform, candidate.waveform)) >= 0.85 && coverageMatches($0, candidate) }) {
                if candidate.activity > unique[index].activity { unique[index] = candidate }
            } else {
                unique.append(candidate)
            }
        }
        // OBS-style mix + microphone + remote audio: retain the two stems.
        // A positive linear combination can reconstruct the mix; a stem
        // cannot be reconstructed without subtracting another stem.
        if unique.count >= 3 {
            let original = unique
            unique = original.filter { target in
                let others = original.filter { $0.path != target.path }
                for i in others.indices {
                    for j in others.indices where j > i {
                        if covered(target, by: others[i], and: others[j]) && isMix(target.waveform, of: others[i].waveform, and: others[j].waveform) { return false }
                    }
                }
                return true
            }
        }
        var separate = unique.count >= 2 && unique.count <= 10
        if separate {
            // Each source needs some speech/activity of its own. Two copies
            // with noise or reverb, or a mix plus only one stem, fail this test.
            for (index, candidate) in unique.enumerated() {
                var own = 0
                for frame in candidate.active.indices where candidate.active[frame] {
                    let otherActive = unique.enumerated().contains { otherIndex, other in
                        otherIndex != index && frame < other.active.count && other.active[frame]
                    }
                    if !otherActive { own += 1 }
                }
                if own < max(3, candidate.activity / 20) { separate = false; break }
            }
        }
        if layout == "mixed" { separate = false }
        if layout == "separate" {
            guard unique.count >= 2 && unique.count <= 10 else {
                throw ValidationError("No separate audio sources found. Use Auto or Mixed audio.")
            }
            separate = true
        }
        let paths: [String]
        if layout == "tracks" {
            // Explicit source ownership uses container tracks, not channels or
            // acoustic activity. Preserve order, silent tracks and offsets.
            separate = true
            paths = audioFiles.indices.compactMap { monoPaths[$0] }
        }
        else if separate { paths = unique.map(\.path) }
        else if unique.count >= 2 {
            // Uncertain independence must not discard a participant. Build a
            // shared mono recording from all retained sources and diarize it.
            var combined: [Float] = []
            for candidate in unique {
                let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: candidate.path))
                if combined.count < samples.count { combined += repeatElement(0, count: samples.count - combined.count) }
                for i in samples.indices { combined[i] += samples[i] }
            }
            let peak = combined.reduce(Float(0)) { max($0, abs($1)) }
            if peak > 0.95 { for i in combined.indices { combined[i] *= 0.95 / peak } }
            let mix = folder.appendingPathComponent("combined-mono.wav")
            try write(combined, to: mix)
            paths = [mix.path]
        }
        else {
            // Prefer the track covering the most activity (typically the mix).
            let best = candidates.max { $0.activity < $1.activity }
            let source = best?.source ?? 0
            guard let mono = monoPaths[source] else { throw ValidationError("No readable audio found.") }
            paths = [mono]
        }
        let plan: [String: Any] = ["separate": separate, "paths": paths,
            "containerTracks": audioFiles.count, "channels": candidates.count,
            "quality": try paths.map { path -> [String: Double] in
                let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
                let sorted = energies(samples).filter { $0 > 1e-12 }.sorted()
                let contrast: Double
                if sorted.isEmpty { contrast = 60 }
                else { contrast = 10 * log10(max(sorted[sorted.count * 9 / 10], 1e-12) / max(sorted[sorted.count / 10], 1e-12)) }
                let clipping = Double(samples.filter { abs($0) >= 0.98 }.count) / Double(max(1, samples.count))
                return ["dynamicRangeDB": contrast, "clippingFraction": clipping]
            }]
        let data = try JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: output), options: .atomic)
    }

    private func splitChannels(_ source: URL, into folder: URL, index: Int, padding: Int) throws -> [URL] {
        let input = try AVAudioFile(forReading: source)
        let count = input.processingFormat.channelCount
        guard count > 0, count <= 10,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: count, interleaved: false),
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192),
              let channelBuffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 8192) else {
            throw ValidationError("Could not inspect the recording channels.")
        }
        let paths = (0..<Int(count)).map { folder.appendingPathComponent("track-\(index)-channel-\($0).wav") }
        let files = try paths.map { try AVAudioFile(forWriting: $0, settings: mono.settings) }
        // Exported M4A starts at zero. Add source time offsets explicitly in
        // PCM instead of relying on how a decoder interprets edit lists.
        var remaining = padding
        while remaining > 0 {
            let frames = min(remaining, Int(channelBuffer.frameCapacity))
            channelBuffer.frameLength = AVAudioFrameCount(frames)
            channelBuffer.floatChannelData![0].update(repeating: 0, count: frames)
            for file in files { try file.write(from: channelBuffer) }
            remaining -= frames
        }
        var readingError: Error?
        while true {
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { frames, inputStatus in
                // AAC may throw eofErr (-39) on a read after its last frame.
                // Signal EOF to the converter before asking the file to read.
                let remaining = input.length - input.framePosition
                guard remaining > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    let requested = min(Int64(min(frames, inputBuffer.frameCapacity)), remaining)
                    try input.read(into: inputBuffer, frameCount: AVAudioFrameCount(requested))
                    inputStatus.pointee = inputBuffer.frameLength == 0 ? .endOfStream : .haveData
                    return inputBuffer.frameLength == 0 ? nil : inputBuffer
                } catch {
                    readingError = error; inputStatus.pointee = .endOfStream; return nil
                }
            }
            if let readingError { throw readingError }
            if let conversionError { throw conversionError }
            if outputBuffer.frameLength > 0 {
                for channel in files.indices {
                    channelBuffer.frameLength = outputBuffer.frameLength
                    channelBuffer.floatChannelData![0].update(from: outputBuffer.floatChannelData![channel], count: Int(outputBuffer.frameLength))
                    try files[channel].write(from: channelBuffer)
                }
            }
            if status == .endOfStream { break }
            if status == .error { throw ValidationError("Could not read audio channels.") }
        }
        return paths
    }

    private func write(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count))) else {
            throw ValidationError("Could not prepare mono audio.")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { values in
            if let base = values.baseAddress { buffer.floatChannelData![0].update(from: base, count: values.count) }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func energies(_ samples: [Float]) -> [Double] {
        stride(from: 0, to: samples.count, by: 1600).map { start in
            let end = min(samples.count, start + 1600)
            var sum = 0.0
            for i in start..<end { let value = Double(samples[i]); sum += value * value }
            return sum / Double(end - start)
        }
    }

    private func correlation(_ a: [Float], _ b: [Float]) -> Double {
        var aa = 0.0, bb = 0.0, ab = 0.0
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? Double(a[i]) : 0, y = i < b.count ? Double(b[i]) : 0
            aa += x*x; bb += y*y; ab += x*y
        }
        return aa > 0 && bb > 0 ? ab / sqrt(aa*bb) : 0
    }

    private func coverageMatches(_ a: Candidate, _ b: Candidate) -> Bool {
        var different = 0
        for i in 0..<max(a.active.count, b.active.count) {
            if (i < a.active.count && a.active[i]) != (i < b.active.count && b.active[i]) { different += 1 }
        }
        return different <= 3
    }

    private func covered(_ target: Candidate, by a: Candidate, and b: Candidate) -> Bool {
        var missing = 0
        for i in target.active.indices where target.active[i] {
            if !(i < a.active.count && a.active[i]) && !(i < b.active.count && b.active[i]) { missing += 1 }
        }
        return missing <= 3
    }

    private func isMix(_ mix: [Float], of a: [Float], and b: [Float]) -> Bool {
        var aa = 0.0, bb = 0.0, ab = 0.0, am = 0.0, bm = 0.0, mm = 0.0
        for i in 0..<max(mix.count, max(a.count, b.count)) {
            let x = i < a.count ? Double(a[i]) : 0, y = i < b.count ? Double(b[i]) : 0, m = i < mix.count ? Double(mix[i]) : 0
            aa += x*x; bb += y*y; ab += x*y; am += x*m; bm += y*m; mm += m*m
        }
        let determinant = aa*bb - ab*ab
        guard determinant > aa*bb*0.01, mm > 0 else { return false }
        let x = (am*bb - bm*ab) / determinant, y = (bm*aa - am*ab) / determinant
        guard x > 0.05, y > 0.05 else { return false }
        let residual = max(0, mm - 2*x*am - 2*y*bm + x*x*aa + y*y*bb + 2*x*y*ab)
        return residual / mm < 0.01
    }
}
