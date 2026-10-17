import Foundation

final class EngineRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var active: Process?
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true; let process = active; lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }
    func run(executable: URL, arguments: [String], log: URL, environment: [String: String] = [:]) throws {
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.standardError = handle; process.standardOutput = handle
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run(); active = process; lock.unlock() }
        catch { lock.unlock(); throw error }
        process.waitUntilExit()
        lock.lock(); active = nil; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw NSError(domain: "VoiceScribe", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Transcription failed. \(detail.suffix(1600))"])
        }
    }
}
