import AVFoundation
import Foundation

@main struct AudioEOFTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceScribe-audio-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("fixture.m4a")
        // A non-block-aligned AAC recording exercises both the final partial
        // read and the following EOF request from AVAudioConverter.
        let frames: AVAudioFrameCount = 48137
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let sample = Float(sin(Double(i) * 2 * .pi * 440 / 48000) * 0.2)
            buffer.floatChannelData![0][i] = sample
            buffer.floatChannelData![1][i] = sample
        }
        do {
            let file = try AVAudioFile(forWriting: audio, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000
            ])
            try file.write(from: buffer)
        }
        let output = folder.appendingPathComponent("plan.json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        process.arguments = ["inspect-audio", audio.path, "--directory", folder.appendingPathComponent("channels").path,
            "--output", output.path, "--layout", "automatic", "--offsets", "0"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "AudioEOFTests", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "AAC inspection must reach EOF without an error."])
        }
        let plan = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as! [String: Any]
        let paths = plan["paths"] as! [String]
        assert(paths.count == 1 && plan["separate"] as? Bool == false)
        let mono = try AVAudioFile(forReading: URL(fileURLWithPath: paths[0]))
        assert(mono.processingFormat.sampleRate == 16000 && mono.processingFormat.channelCount == 1)
        assert(mono.length > 15000 && mono.length < 18000)
        // Explicit track ownership must not collapse two correlated tracks or
        // split their stereo channels, and must preserve each source offset.
        let tracked = Process()
        tracked.executableURL = process.executableURL
        tracked.arguments = ["inspect-audio", audio.path, audio.path, "--directory", folder.appendingPathComponent("tracks").path,
            "--output", output.path, "--layout", "tracks", "--offsets", "0,0.25"]
        try tracked.run()
        tracked.waitUntilExit()
        assert(tracked.terminationStatus == 0)
        let trackPlan = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as! [String: Any]
        let trackPaths = trackPlan["paths"] as! [String]
        assert(trackPlan["separate"] as? Bool == true && trackPaths.count == 2)
        let first = try AVAudioFile(forReading: URL(fileURLWithPath: trackPaths[0]))
        let second = try AVAudioFile(forReading: URL(fileURLWithPath: trackPaths[1]))
        assert(second.length - first.length == 4000)
        print("PASS: AAC channel inspection reaches EOF and retains the full recording")
    }
}
