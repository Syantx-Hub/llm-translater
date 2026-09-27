import Foundation

enum SidecarError: LocalizedError {
    case notFound(String)
    case exited(Int32)
    case remote(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notFound(let path): "Translation sidecar not found at \(path). See README: set up python/.venv."
        case .exited(let code): "Translation sidecar exited (code \(code)). Check the Console log for details."
        case .remote(let message): "Translation failed: \(message)"
        case .timedOut: "The translation sidecar did not start in time."
        }
    }
}

/// Where the Python sidecar lives. For development builds this is the repo checkout,
/// baked into Info.plist by `scripts/build-app.sh --dev` or overridden with SUBTITLER_REPO.
struct SidecarLocation {
    let python: URL
    let script: URL
    let repoRoot: URL

    static func resolve() -> SidecarLocation? {
        let configured = ProcessInfo.processInfo.environment["SUBTITLER_REPO"]
            ?? Bundle.main.object(forInfoDictionaryKey: "SubtitlerRepoRoot") as? String
        guard let rootURL = configured.map({ URL(fileURLWithPath: $0, isDirectory: true) }) ?? findRepoRoot()
        else { return nil }
        return SidecarLocation(
            python: rootURL.appendingPathComponent("python/.venv/bin/python"),
            script: rootURL.appendingPathComponent("python/translate_server.py"),
            repoRoot: rootURL)
    }

    /// For `swift run` / `--file` mode: walk up from the working directory.
    private static func findRepoRoot() -> URL? {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("python/translate_server.py").path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    func arguments(for engine: SidecarEngine) -> [String] {
        var args = [script.path, "--engine", engine.rawValue]
        let ct2 = repoRoot.appendingPathComponent("models/madlad400-3b-ct2")
        if engine == .madlad, FileManager.default.fileExists(atPath: ct2.path) {
            args += ["--madlad-ct2", ct2.path]
        }
        return args
    }
}

/// Talks to python/translate_server.py over stdin/stdout, one JSON object per line.
actor SidecarTranslator: Translator {
    private let location: SidecarLocation
    private let engine: SidecarEngine

    private var process: Process?
    private var input: FileHandle?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]
    private var ready = false
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var readerTask: Task<Void, Never>?

    init(location: SidecarLocation, engine: SidecarEngine) {
        self.location = location
        self.engine = engine
    }

    func start() async throws {
        guard FileManager.default.isExecutableFile(atPath: location.python.path) else {
            throw SidecarError.notFound(location.python.path)
        }
        let process = Process()
        process.executableURL = location.python
        process.arguments = location.arguments(for: engine)
        process.currentDirectoryURL = location.script.deletingLastPathComponent()
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError

        // A single ordered stream of stdout chunks; per-chunk Tasks could reorder them.
        let (chunks, sink) = AsyncStream<Data>.makeStream()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                sink.finish()
            } else {
                sink.yield(data)
            }
        }
        process.terminationHandler = { [weak self] proc in
            Task { await self?.failAll(SidecarError.exited(proc.terminationStatus)) }
        }
        readerTask = Task { [weak self] in
            var buffer = Data()
            for await chunk in chunks {
                buffer += chunk
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer = buffer[(newline + 1)...]
                    await self?.handle(line: Data(line))
                }
            }
        }

        try process.run()
        self.process = process
        self.input = stdin.fileHandleForWriting
        if !ready {
            // Loading can involve a model download, but a sidecar that never answers must
            // not leave the app stuck in "Starting translator…".
            let timeout = Task { [weak self] in
                try await Task.sleep(for: .seconds(300))
                await self?.failAll(SidecarError.timedOut)
            }
            defer { timeout.cancel() }
            try await withCheckedThrowingContinuation { readyWaiter = $0 }
        }
    }

    func translate(_ text: String, from source: String, to target: String, context: [String]) async throws -> String {
        guard let input, ready else { throw SidecarError.exited(-1) }
        let id = nextID
        nextID += 1
        let request: [String: Any] = ["id": id, "text": text, "source": source, "target": target, "context": context]
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(0x0A)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try input.write(contentsOf: line)
            } catch {
                pending[id] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    func stop() async {
        process?.terminationHandler = nil
        try? input?.close()
        process?.terminate()
        process = nil
        input = nil
        readerTask?.cancel()
        failAll(CancellationError())
    }

    private func handle(line: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if message["ready"] as? Bool == true {
            ready = true
            readyWaiter?.resume()
            readyWaiter = nil
            return
        }
        guard let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { return }
        if let translation = message["translation"] as? String {
            continuation.resume(returning: translation)
        } else {
            continuation.resume(throwing: SidecarError.remote(message["error"] as? String ?? "unknown error"))
        }
    }

    private func failAll(_ error: Error) {
        ready = false
        readyWaiter?.resume(throwing: error)
        readyWaiter = nil
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: error) }
    }
}
