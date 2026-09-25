import Foundation
import WhisperKit

/// Where downloaded models live on disk, and how to fetch and remove them.
/// Not tied to the UI, so the headless `--file` mode uses it too.
enum ModelFiles {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Subtitler/Models", isDirectory: true)
    }

    private static let completeMarker = ".complete"

    /// The folder (WhisperKit) or file (GGUF) the runtime loads.
    static func localURL(for model: ModelInfo) -> URL {
        switch model.source {
        case .whisperKit(let variant):
            // Layout WhisperKit's Hub downloader uses under its download base.
            root.appendingPathComponent("speech/models/argmaxinc/whisperkit-coreml/\(variant)", isDirectory: true)
        case .gguf(_, let fileName):
            root.appendingPathComponent("translation/\(fileName)")
        }
    }

    static func isInstalled(_ model: ModelInfo) -> Bool {
        let url = localURL(for: model)
        switch model.source {
        case .whisperKit:
            return FileManager.default.fileExists(atPath: url.appendingPathComponent(completeMarker).path)
        case .gguf:
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// Downloads the model and returns `localURL(for:)`. Cancelling the calling task
    /// cancels the download.
    static func download(_ model: ModelInfo, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let destination = localURL(for: model)
        switch model.source {
        case .whisperKit(let variant):
            let folder = try await WhisperKit.download(
                variant: variant, downloadBase: root.appendingPathComponent("speech", isDirectory: true),
                progressCallback: { progress($0.fractionCompleted) })
            try Task.checkCancellation()
            FileManager.default.createFile(atPath: folder.appendingPathComponent(completeMarker).path, contents: nil)
            return folder
        case .gguf(let url, _):
            let observer = DownloadProgressObserver(onProgress: progress)
            let (temporary, response) = try await URLSession.shared.download(from: url, delegate: observer)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        }
    }

    static func delete(_ model: ModelInfo) throws {
        let url = localURL(for: model)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
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
