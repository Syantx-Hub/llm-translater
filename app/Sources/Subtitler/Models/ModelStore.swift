import Foundation

/// UI state for the model library: what is installed, what is downloading, and which
/// speech and translation models are selected.
@MainActor
final class ModelStore: ObservableObject {
    enum Status: Equatable {
        case notInstalled
        case downloading(Double)
        case installed
        case failed(String)
    }

    /// Translation choices that are not downloadable models.
    nonisolated static let translationOff = "off"
    nonisolated static let sidecarPrefix = "sidecar:"

    @Published private(set) var status: [String: Status] = [:]
    @Published var selectedSpeech: String? { didSet { defaults.set(selectedSpeech, forKey: "selectedSpeech") } }
    @Published var selectedTranslation: String { didSet { defaults.set(selectedTranslation, forKey: "selectedTranslation") } }

    private let defaults = UserDefaults.standard
    private var downloads: [String: Task<Void, Never>] = [:]

    init() {
        selectedSpeech = defaults.string(forKey: "selectedSpeech")
        selectedTranslation = defaults.string(forKey: "selectedTranslation") ?? ModelCatalog.defaultTranslation
        refresh()
    }

    var speechModel: ModelInfo? {
        selectedSpeech.flatMap(ModelCatalog.model(id:)).flatMap { isInstalled($0) ? $0 : nil }
    }

    var translationModel: ModelInfo? {
        ModelCatalog.model(id: selectedTranslation).flatMap { isInstalled($0) ? $0 : nil }
    }

    /// True until the person has at least a speech model: drives the welcome flow.
    var needsSetup: Bool { speechModel == nil }

    /// Dev builds that can reach python/translate_server.py also offer the NLLB sidecar.
    var sidecarAvailable: Bool { SidecarLocation.resolve() != nil }

    func status(of model: ModelInfo) -> Status { status[model.id] ?? .notInstalled }

    func isInstalled(_ model: ModelInfo) -> Bool { status(of: model) == .installed }

    func isSelected(_ model: ModelInfo) -> Bool {
        model.kind == .speech ? selectedSpeech == model.id : selectedTranslation == model.id
    }

    func refresh() {
        for model in ModelCatalog.all where downloads[model.id] == nil {
            status[model.id] = ModelFiles.isInstalled(model) ? .installed : .notInstalled
        }
        // Keep a usable selection when the chosen model is missing but another is installed.
        if speechModel == nil {
            selectedSpeech = preferredInstalled(ModelCatalog.speech, recommended: ModelCatalog.recommendedSpeech)?.id
        }
        if translationModel == nil, ModelCatalog.model(id: selectedTranslation) != nil,
           let installed = preferredInstalled(ModelCatalog.translation, recommended: ModelCatalog.recommendedTranslation) {
            selectedTranslation = installed.id
        }
    }

    private func preferredInstalled(_ models: [ModelInfo], recommended: String) -> ModelInfo? {
        let installed = models.filter(isInstalled)
        return installed.first { $0.id == recommended } ?? installed.first
    }

    func download(_ model: ModelInfo) {
        guard downloads[model.id] == nil else { return }
        status[model.id] = .downloading(0)
        downloads[model.id] = Task { [weak self] in
            do {
                _ = try await ModelFiles.download(model) { fraction in
                    Task { @MainActor in
                        guard case .downloading = self?.status[model.id] else { return }
                        self?.status[model.id] = .downloading(fraction)
                    }
                }
                self?.finishDownload(model, .installed)
            } catch is CancellationError {
                self?.finishDownload(model, .notInstalled)
            } catch let error as URLError where error.code == .cancelled {
                self?.finishDownload(model, .notInstalled)
            } catch {
                self?.finishDownload(model, .failed(error.localizedDescription))
            }
        }
    }

    private func finishDownload(_ model: ModelInfo, _ result: Status) {
        downloads[model.id] = nil
        status[model.id] = result
        guard result == .installed else { return }
        // The first model of a kind becomes the one in use.
        if model.kind == .speech, speechModel == nil || selectedSpeech == nil { selectedSpeech = model.id }
        if model.kind == .translation, translationModel == nil, selectedTranslation != Self.translationOff,
           !selectedTranslation.hasPrefix(Self.sidecarPrefix) {
            selectedTranslation = model.id
        }
    }

    func cancelDownload(_ model: ModelInfo) {
        downloads[model.id]?.cancel()
    }

    func select(_ model: ModelInfo) {
        guard isInstalled(model) else { return }
        if model.kind == .speech { selectedSpeech = model.id } else { selectedTranslation = model.id }
    }

    func delete(_ model: ModelInfo) {
        do {
            try ModelFiles.delete(model)
            status[model.id] = .notInstalled
            if selectedSpeech == model.id { selectedSpeech = nil }
        } catch {
            status[model.id] = .failed(error.localizedDescription)
        }
    }

    var installedBytes: Int64 {
        ModelCatalog.all.filter(isInstalled).reduce(0) { total, model in
            total + Self.size(of: ModelFiles.localURL(for: model))
        }
    }

    private static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        var total: Int64 = 0
        while let file = files?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
