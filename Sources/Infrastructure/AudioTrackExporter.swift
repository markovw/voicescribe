import Foundation
import AVFoundation

@MainActor protocol AudioExporting {
    var progressFraction: Double? { get }
    /// Extension of the files this exporter writes, without a dot.
    var fileExtension: String { get }
    func export(_ asset: AVAsset, to url: URL) async throws
    func cancel()
}

/// Compressed M4A keeps cloud uploads small.
@MainActor final class AudioTrackExporter: AudioExporting {
    private var session: AVAssetExportSession?

    var fileExtension: String { "m4a" }

    var progressFraction: Double? {
        guard let session, session.status == .exporting else { return nil }
        return Double(session.progress)
    }

    func cancel() { session?.cancelExport() }

    func export(_ asset: AVAsset, to url: URL) async throws {
        try Task.checkCancellation()
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "VoiceScribe", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not open this audio format."])
        }
        session = exporter
        defer { session = nil }
        exporter.outputURL = url
        exporter.outputFileType = .m4a
        await exporter.export()
        try Task.checkCancellation()
        guard exporter.status == .completed else {
            throw exporter.error ?? NSError(domain: "VoiceScribe", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Could not extract an audio track."])
        }
    }
}

/// Local recognition decodes once to 16 kHz PCM WAV with the source channels.
/// Avoids a lossy AAC re-encode, its encoding time, and AAC end-of-stream
/// read errors (OSStatus -39) in the engine's audio decoder.
@MainActor final class PCMTrackExporter: AudioExporting {
    static let sampleRate = 16000.0
    private let state = ExportState()

    var fileExtension: String { "wav" }
    var progressFraction: Double? { state.fraction }
    func cancel() { state.cancel() }

    func export(_ asset: AVAsset, to url: URL) async throws {
        try Task.checkCancellation()
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NSError(domain: "VoiceScribe", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Could not extract an audio track."])
        }
        let duration = try await asset.load(.duration).seconds
        let description = try await track.load(.formatDescriptions).first
        let sourceChannels = description.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 1
        // Inspection separates at most ten channels per track.
        let channels = Int(min(10, max(1, sourceChannels)))
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono
            : channels == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        try? FileManager.default.removeItem(at: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        let writer = try AVAssetWriter(outputURL: url, fileType: .wav)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard reader.canAdd(output), writer.canAdd(input) else {
            throw NSError(domain: "VoiceScribe", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not open this audio format."])
        }
        reader.add(output)
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? NSError(domain: "VoiceScribe", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not open this audio format."])
        }
        writer.startSession(atSourceTime: .zero)
        state.begin(reader: reader)
        defer { state.end() }
        let transfer = SampleTransfer(output: output, input: input, state: state, duration: duration)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            transfer.start { continuation.resume() }
        }
        if state.isCancelled || Task.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        }
        guard reader.status == .completed, writer.status == .writing else {
            let failure = reader.error ?? writer.error
            reader.cancelReading()
            writer.cancelWriting()
            throw failure ?? NSError(domain: "VoiceScribe", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Could not extract an audio track."])
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "VoiceScribe", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Could not extract an audio track."])
        }
    }
}

/// Progress and cancellation shared with the background transfer queue.
private final class ExportState: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: Double?
    private var cancelled = false
    private var reader: AVAssetReader?

    var fraction: Double? { lock.withLock { progress } }
    var isCancelled: Bool { lock.withLock { cancelled } }

    func begin(reader: AVAssetReader) {
        lock.withLock { self.reader = reader; progress = 0 }
    }
    func update(_ value: Double) { lock.withLock { progress = min(1, max(0, value)) } }
    func end() { lock.withLock { reader = nil; progress = nil } }
    func cancel() {
        let active = lock.withLock { cancelled = true; return reader }
        active?.cancelReading()
    }
}

/// Moves decoded buffers from the reader to the writer on a private queue.
private final class SampleTransfer: @unchecked Sendable {
    private let output: AVAssetReaderTrackOutput
    private let input: AVAssetWriterInput
    private let state: ExportState
    private let duration: Double
    private let queue = DispatchQueue(label: "VoiceScribe.PCMTrackExporter")

    init(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput, state: ExportState, duration: Double) {
        self.output = output; self.input = input; self.state = state; self.duration = duration
    }

    func start(completion: @escaping @Sendable () -> Void) {
        var finished = false
        input.requestMediaDataWhenReady(on: queue) { [self] in
            guard !finished else { return }
            while input.isReadyForMoreMediaData {
                guard !state.isCancelled, let buffer = output.copyNextSampleBuffer() else {
                    finished = true
                    input.markAsFinished()
                    completion()
                    return
                }
                if duration > 0 {
                    let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(buffer), CMSampleBufferGetDuration(buffer))
                    if end.isNumeric { state.update(end.seconds / duration) }
                }
                if !input.append(buffer) {
                    finished = true
                    input.markAsFinished()
                    completion()
                    return
                }
            }
        }
    }
}
