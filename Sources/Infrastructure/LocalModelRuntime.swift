import Foundation

@MainActor struct LocalModelRuntime: LocalBatchRunning {
    let store: URL
    let resources: URL?

    init(store: URL = ApplicationPaths.live.library, resources: URL? = Bundle.main.resourceURL) {
        self.store = store
        self.resources = resources
    }

    func run(runner: any ProcessRunning, jobs: [[String: String]], terms: String, folder: URL, onStage: (String, URL) -> Void) async throws {
        guard let resources else {
            throw NSError(domain: "VoiceScribe", code: 6, userInfo: [NSLocalizedDescriptionKey: "Accurate resources are missing. Reinstall VoiceScribe."])
        }
        let uv = resources.appendingPathComponent("uv")
        let bundled = resources.appendingPathComponent("Accurate")
        let runtime = store.appendingPathComponent("Accurate-v1")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        // Keep runtime/dependency caches outside the signed app bundle.
        for name in ["pyproject.toml", "uv.lock", "transcribe.py"] {
            let data = try Data(contentsOf: bundled.appendingPathComponent(name))
            let destination = runtime.appendingPathComponent(name)
            if (try? Data(contentsOf: destination)) != data { try data.write(to: destination, options: .atomic) }
        }
        let environment = [
            "UV_CACHE_DIR": store.appendingPathComponent("Runtime/cache").path,
            "UV_PYTHON_INSTALL_DIR": store.appendingPathComponent("Runtime/python").path,
            "UV_NO_PROGRESS": "1", "PYTHONUNBUFFERED": "1", "PYTHONNOUSERSITE": "1",
            "HF_HOME": store.appendingPathComponent("Models/huggingface").path,
            "HF_HUB_DISABLE_TELEMETRY": "1", "HF_HUB_DISABLE_PROGRESS_BARS": "1"
        ]
        let setupLog = folder.appendingPathComponent("runtime.log")
        onStage("Preparing local models. First use downloads runtime and weights…", setupLog)
        try await Task.detached {
            try runner.run(executable: uv, arguments: ["sync", "--frozen", "--no-dev", "--managed-python",
                "--python", "3.12", "--project", runtime.path], log: setupLog, environment: environment)
        }.value
        try Task.checkCancellation()
        let python = runtime.appendingPathComponent(".venv/bin/python")
        let recognitionLog = folder.appendingPathComponent("accurate.log")
        let manifest = folder.appendingPathComponent("recognition-jobs.json")
        try JSONEncoder().encode(jobs).write(to: manifest, options: .atomic)
        onStage("Loading local transcription models…", recognitionLog)
        try await Task.detached {
            try runner.run(executable: python, arguments: [runtime.appendingPathComponent("transcribe.py").path,
                "--jobs", manifest.path, "--terms", terms], log: recognitionLog, environment: environment)
        }.value
    }
}
