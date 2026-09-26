import Foundation
import WhisperKit

enum ModelFilesError: LocalizedError, Equatable {
    case incomplete(String)
    case busy(String)
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .incomplete(let name): "\(name) did not download completely. Try again."
        case .busy(let name): "\(name) is being downloaded or removed by another Subtitler window or process."
        case .badResponse(let code): "The download server answered with HTTP \(code)."
        }
    }
}

/// Where downloaded models live on disk, and how to fetch and remove them.
/// Not tied to the UI, so the headless `--file` mode and tests use it too.
///
/// Each download goes to its own staging folder and is moved into place only once it
/// is complete, so an interrupted, cancelled or concurrent download never leaves a
/// half-written model where the app loads from.
enum ModelFiles {
    /// Tests point this at a temporary directory.
    static var rootOverride: URL?

    static var root: URL {
        if let rootOverride { return rootOverride }
        // Development: benchmark models without touching the real library.
        if let custom = ProcessInfo.processInfo.environment["SUBTITLER_MODELS_DIR"] {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Subtitler/Models", isDirectory: true)
    }

    static let completeMarker = ".complete"

    /// Files every WhisperKit variant must have, non-empty, to count as installed.
    static let requiredSpeechFiles = [
        "AudioEncoder.mlmodelc/coremldata.bin", "AudioEncoder.mlmodelc/model.mil", "AudioEncoder.mlmodelc/weights/weight.bin",
        "TextDecoder.mlmodelc/coremldata.bin", "TextDecoder.mlmodelc/model.mil", "TextDecoder.mlmodelc/weights/weight.bin",
        "MelSpectrogram.mlmodelc/coremldata.bin", "MelSpectrogram.mlmodelc/model.mil", "MelSpectrogram.mlmodelc/weights/weight.bin",
        "config.json",
    ]

    /// Where WhisperKit falls back to fetching a tokenizer that isn't in the model folder.
    static var speechBase: URL { root.appendingPathComponent("speech", isDirectory: true) }
    private static var speechRepo: URL { speechBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true) }
    static var staging: URL { root.appendingPathComponent(".staging", isDirectory: true) }

    /// The folder (WhisperKit) or file (GGUF) the runtime loads.
    static func localURL(for model: ModelInfo) -> URL {
        switch model.source {
        case .whisperKit(let variant, _):
            speechRepo.appendingPathComponent(variant, isDirectory: true)
        case .gguf(_, let fileName):
            root.appendingPathComponent("translation/\(fileName)")
        case .system:
            root
        }
    }

    /// Everything on disk that belongs to `model`, including the download cache older
    /// builds left next to the model.
    static func allFiles(for model: ModelInfo) -> [URL] {
        switch model.source {
        case .whisperKit(let variant, _):
            [localURL(for: model), speechRepo.appendingPathComponent(".cache/huggingface/download/\(variant)", isDirectory: true)]
        case .gguf:
            [localURL(for: model)]
        case .system:
            []
        }
    }

    static func isInstalled(_ model: ModelInfo) -> Bool {
        let url = localURL(for: model)
        switch model.source {
        case .whisperKit:
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent(completeMarker).path) else { return false }
            return requiredSpeechFiles.allSatisfy { size(of: url.appendingPathComponent($0)) > 0 }
        case .gguf:
            return isGGUF(url)
        case .system:
            return AppleSpeech.isAvailable
        }
    }

    /// Downloads the model and returns `localURL(for:)`. Cancelling the calling task
    /// cancels the download; nothing of a failed or cancelled attempt is left behind.
    static func download(_ model: ModelInfo, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard !model.isBuiltIn else { return localURL(for: model) }
        let lock = try DownloadLock(root: root, id: model.id, name: model.name)
        defer { lock.release() }
        let attempt = staging.appendingPathComponent("\(model.id)-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: attempt) }
        try FileManager.default.createDirectory(at: attempt, withIntermediateDirectories: true)

        let staged: URL
        switch model.source {
        case .whisperKit(let variant, let tokenizer):
            staged = try await WhisperKit.download(
                variant: variant, downloadBase: attempt, progressCallback: { progress($0.fractionCompleted) })
            try Task.checkCancellation()
            // The tokenizer lives in the model folder, so the model works offline and is
            // deleted with it.
            _ = try await ModelUtilities.loadTokenizer(for: tokenizer, tokenizerFolder: attempt)
            try copyTokenizer(from: attempt, to: staged)
            try Task.checkCancellation()
            try markComplete(staged, name: model.name)
        case .gguf(let url, _):
            let observer = DownloadProgressObserver(onProgress: progress)
            let (temporary, response) = try await URLSession.shared.download(from: url, delegate: observer)
            staged = attempt.appendingPathComponent("model.gguf")
            try FileManager.default.moveItem(at: temporary, to: staged)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw ModelFilesError.badResponse(status) }
            guard isGGUF(staged) else { throw ModelFilesError.incomplete(model.name) }
        case .system:
            return localURL(for: model)
        }

        try install(staged, as: model)
        return localURL(for: model)
    }

    /// Validates a downloaded WhisperKit folder and writes the marker `isInstalled` checks.
    static func markComplete(_ folder: URL, name: String) throws {
        guard requiredSpeechFiles.allSatisfy({ size(of: folder.appendingPathComponent($0)) > 0 }) else {
            throw ModelFilesError.incomplete(name)
        }
        guard FileManager.default.createFile(atPath: folder.appendingPathComponent(completeMarker).path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Moves a finished download into place, replacing any previous copy.
    static func install(_ staged: URL, as model: ModelInfo) throws {
        let destination = localURL(for: model)
        try removeFiles(model)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staged, to: destination)
    }

    /// Removes the model and its caches from disk. Fails with `.busy` while the model is
    /// downloading anywhere, rather than deleting files out from under the download.
    static func delete(_ model: ModelInfo) throws {
        let lock = try DownloadLock(root: root, id: model.id, name: model.name)
        defer { lock.release() }
        try removeFiles(model)
    }

    /// Removes staging folders of downloads that were interrupted (crash, force quit).
    /// Folders whose download is still running elsewhere are kept.
    static func removeAbandonedDownloads() {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            guard let model = ModelCatalog.all.first(where: { folder.lastPathComponent.hasPrefix($0.id + "-") }),
                  let lock = try? DownloadLock(root: root, id: model.id, name: model.name)
            else { continue }
            try? FileManager.default.removeItem(at: folder)
            lock.release()
        }
    }

    private static func removeFiles(_ model: ModelInfo) throws {
        for url in allFiles(for: model) where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Copies the tokenizer files the Hub downloaded under `base` into the model folder.
    private static func copyTokenizer(from base: URL, to modelFolder: URL) throws {
        let files = FileManager.default.enumerator(at: base.appendingPathComponent("models/openai"), includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            let name = file.lastPathComponent
            guard name.hasPrefix("tokenizer") || ["vocab.json", "merges.txt", "special_tokens_map.json", "added_tokens.json"].contains(name)
            else { continue }
            let target = modelFolder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: file, to: target)
        }
        guard FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent("tokenizer.json").path) else {
            throw ModelFilesError.incomplete("The tokenizer")
        }
    }

    private static func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// GGUF files start with the ASCII magic "GGUF".
    static func isGGUF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("GGUF".utf8)
    }
}

/// An exclusive, cross-process lock per model, held while downloading or deleting it.
final class DownloadLock {
    private let descriptor: Int32

    init(root: URL, id: String, name: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(".\(id).lock").path
        descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw ModelFilesError.busy(name)
        }
    }

    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

private final class DownloadProgressObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [onProgress] progress, _ in
            onProgress(progress.fractionCompleted)
        }
    }
}
