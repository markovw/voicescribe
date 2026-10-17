import Foundation

private final class RecordingProcess: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(URL, [String], [String: String])] = []
    var calls: [(URL, [String], [String: String])] {
        lock.lock(); defer { lock.unlock() }; return records
    }
    func cancel() { }
    func run(executable: URL, arguments: [String], log: URL, environment: [String: String]) throws {
        lock.lock(); records.append((executable, arguments, environment)); lock.unlock()
        try Data().write(to: log)
    }
}

@main struct InfrastructureTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("resources")
        let bundled = resources.appendingPathComponent("Accurate")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        for name in ["pyproject.toml", "uv.lock", "transcribe.py"] {
            try Data("fixture-\(name)".utf8).write(to: bundled.appendingPathComponent(name))
        }
        let store = root.appendingPathComponent("library")
        let runtime = LocalModelRuntime(store: store, resources: resources)
        let process = RecordingProcess()
        let jobs = [["audio": "synthetic.wav", "output": "words.json", "model": "qwen"]]
        try await runtime.run(runner: process, jobs: jobs, terms: "SwiftUI", folder: root) { _, _ in }
        let calls = process.calls
        assert(calls.count == 2 && calls[0].1.contains("--frozen"))
        assert(calls[0].0 == resources.appendingPathComponent("uv"))
        assert(calls[1].1.suffix(2) == ["--terms", "SwiftUI"])
        assert(calls[0].2["PYTHONNOUSERSITE"] == "1")
        assert(calls[0].2["HF_HUB_DISABLE_TELEMETRY"] == "1")
        assert(calls[0].2["HF_HOME"] == store.appendingPathComponent("Models/huggingface").path)
        let manifest = try JSONDecoder().decode([[String: String]].self,
            from: Data(contentsOf: root.appendingPathComponent("recognition-jobs.json")))
        assert(manifest == jobs)
        let installed = store.appendingPathComponent("Accurate-v1/transcribe.py")
        try Data("stale".utf8).write(to: installed)
        try await runtime.run(runner: process, jobs: jobs, terms: "", folder: root) { _, _ in }
        let refreshed = try Data(contentsOf: installed)
        assert(refreshed == Data("fixture-transcribe.py".utf8))

        let log = root.appendingPathComponent("process.log")
        let runner = EngineRunner()
        try runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf success"], log: log)
        let contents = try String(contentsOf: log, encoding: .utf8)
        assert(contents == "success")
        do {
            try runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 7"], log: log)
            assertionFailure("Non-zero child status must be reported")
        } catch { assert((error as NSError).code == 7) }

        let cancelled = EngineRunner()
        cancelled.cancel()
        do {
            try cancelled.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"], log: log)
            assertionFailure("A cancelled runner must not start a process")
        } catch is CancellationError { }

        let active = EngineRunner()
        let activeLog = root.appendingPathComponent("active.log")
        let task = Task.detached {
            try active.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo ready; exec /bin/sleep 30"], log: activeLog)
        }
        var ready = false
        for _ in 0..<500 {
            if (try? String(contentsOf: activeLog, encoding: .utf8))?.contains("ready") == true {
                ready = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        active.cancel()
        do {
            try await task.value
            assertionFailure("Cancellation must terminate the child and report cancellation")
        } catch is CancellationError { }
        assert(ready)
        print("PASS: frozen runtime setup, isolated caches, refreshed scripts, process errors and active cancellation")
    }
}
