import Foundation
import WhisperKit

enum ModelFilesError: LocalizedError, Equatable {
    case incomplete(String)
    case busy(String)

    var errorDescription: String? {
        switch self {
        case .incomplete(let name): "\(name) did not download completely. Try again."
        case .busy(let name): "\(name) is already being downloaded by another Subtitler window or process."
        }
    }
}

/// Where downloaded models live on disk, and how to fetch and remove them.
/// Not tied to the UI, so the headless `--file` mode and tests use it too.
enum ModelFiles {
    /// Tests point this at a temporary directory.
    static var rootOverride: URL?

    static var root: URL {
        rootOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Subtitler/Models", isDirectory: true)
    }

    static let completeMarker = ".complete"

    /// The WhisperKit models every speech variant must contain, with their weights.
    static let requiredSpeechFiles = [
        "AudioEncoder.mlmodelc/coremldata.bin", "AudioEncoder.mlmodelc/weights/weight.bin",
        "TextDecoder.mlmodelc/coremldata.bin", "TextDecoder.mlmodelc/weights/weight.bin",
        "MelSpectrogram.mlmodelc/coremldata.bin", "MelSpectrogram.mlmodelc/weights/weight.bin",
    ]

    private static var speechBase: URL { root.appendingPathComponent("speech", isDirectory: true) }
    private static var speechRepo: URL { speechBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true) }

    /// The folder (WhisperKit) or file (GGUF) the runtime loads.
    static func localURL(for model: ModelInfo) -> URL {
        switch model.source {
        case .whisperKit(let variant):
            // Layout WhisperKit's Hub downloader uses under its download base.
            speechRepo.appendingPathComponent(variant, isDirectory: true)
        case .gguf(_, let fileName):
            root.appendingPathComponent("translation/\(fileName)")
        }
    }

    /// Everything on disk that belongs to `model`, including download caches.
    static func allFiles(for model: ModelInfo) -> [URL] {
        switch model.source {
        case .whisperKit(let variant):
            [localURL(for: model), speechRepo.appendingPathComponent(".cache/huggingface/download/\(variant)", isDirectory: true)]
        case .gguf:
            [localURL(for: model)]
        }
    }

    static func isInstalled(_ model: ModelInfo) -> Bool {
        let url = localURL(for: model)
        let files = FileManager.default
        switch model.source {
        case .whisperKit:
            guard files.fileExists(atPath: url.appendingPathComponent(completeMarker).path) else { return false }
            return requiredSpeechFiles.allSatisfy { files.fileExists(atPath: url.appendingPathComponent($0).path) }
        case .gguf:
            return isGGUF(url)
        }
    }

    /// Downloads the model and returns `localURL(for:)`. Cancelling the calling task
    /// cancels the download. Leftovers of an earlier, interrupted download are removed first.
    static func download(_ model: ModelInfo, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let lock = try DownloadLock(root: root, id: model.id, name: model.name)
        defer { lock.release() }
        if !isInstalled(model) { try delete(model) }

        let destination = localURL(for: model)
        switch model.source {
        case .whisperKit(let variant):
            let folder = try await WhisperKit.download(
                variant: variant, downloadBase: speechBase, progressCallback: { progress($0.fractionCompleted) })
            try Task.checkCancellation()
            let missing = requiredSpeechFiles.filter {
                !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
            guard missing.isEmpty else {
                try? delete(model)
                throw ModelFilesError.incomplete(model.name)
            }
            FileManager.default.createFile(atPath: folder.appendingPathComponent(completeMarker).path, contents: nil)
            return folder
        case .gguf(let url, _):
            let observer = DownloadProgressObserver(onProgress: progress)
            let (temporary, response) = try await URLSession.shared.download(from: url, delegate: observer)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            guard isGGUF(temporary) else {
                try? FileManager.default.removeItem(at: temporary)
                throw ModelFilesError.incomplete(model.name)
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        }
    }

    /// Removes the model and its download cache from disk.
    static func delete(_ model: ModelInfo) throws {
        for url in allFiles(for: model) where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// GGUF files start with the ASCII magic "GGUF".
    static func isGGUF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("GGUF".utf8)
    }
}

/// An exclusive, cross-process lock per model, so two downloads never write the same files.
private final class DownloadLock {
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
