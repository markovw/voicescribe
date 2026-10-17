import Foundation

protocol ProcessRunning: AnyObject, Sendable {
    func cancel()
    func run(executable: URL, arguments: [String], log: URL, environment: [String: String]) throws
}

extension ProcessRunning {
    func run(executable: URL, arguments: [String], log: URL) throws {
        try run(executable: executable, arguments: arguments, log: log, environment: [:])
    }
}

@MainActor protocol LocalBatchRunning {
    func run(runner: any ProcessRunning, jobs: [[String: String]], terms: String,
             folder: URL, onStage: (String, URL) -> Void) async throws
}

