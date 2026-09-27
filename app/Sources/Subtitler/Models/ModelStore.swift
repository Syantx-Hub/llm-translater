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

    /// Legacy translation selection from builds before transcribe-only was a mode.
    nonisolated static let translationOff = "off"
    nonisolated static let sidecarPrefix = "sidecar:"
    /// "cloud:<provider id>": translate with a cloud (or local OpenAI-compatible) LLM.
    nonisolated static let cloudPrefix = "cloud:"

    @Published private(set) var status: [String: Status] = [:]
    @Published var selectedSpeech: String? { didSet { defaults.set(selectedSpeech, forKey: "selectedSpeech") } }
    @Published var selectedTranslation: String { didSet { defaults.set(selectedTranslation, forKey: "selectedTranslation") } }
    /// Models a live (or starting) session has loaded. They can't be deleted or swapped.
    @Published var inUse: Set<String> = []
    /// Disk space used by installed models, recomputed on refresh rather than per render.
    @Published private(set) var installedBytes: Int64 = 0

    /// True when an older build stored "don't translate" as the translation selection.
    let legacyTranscribeOnly: Bool

    private let defaults: UserDefaults
    /// API keys; the Keychain in the app, in memory in tests and snapshots.
    let secrets: SecretStore
    var cloudConfig: CloudConfig { CloudConfig(defaults: defaults) }
    /// Cloud providers ready to use (key saved), and the masked keys ("••••1234").
    @Published private(set) var configuredCloud: [CloudProvider] = []
    @Published private(set) var keyHints: [String: String] = [:]
    private var downloads: [String: (attempt: UUID, task: Task<Void, Never>)] = [:]

    init(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainStore.app) {
        self.defaults = defaults
        self.secrets = secrets
        let stored = defaults.string(forKey: "selectedTranslation")
        legacyTranscribeOnly = stored == Self.translationOff
        selectedSpeech = defaults.string(forKey: "selectedSpeech")
        selectedTranslation = stored ?? ModelCatalog.defaultTranslation
        // Transcribe-only is a mode now; a sidecar selection only makes sense in dev builds.
        if legacyTranscribeOnly || (selectedTranslation.hasPrefix(Self.sidecarPrefix) && !sidecarAvailable) {
            selectedTranslation = ModelCatalog.defaultTranslation
        }
        ModelFiles.removeAbandonedDownloads()
        refresh()
        refreshCloud()
    }

    // MARK: Cloud

    /// The selected cloud provider, if translation is set to one.
    var cloudProvider: CloudProvider? {
        guard selectedTranslation.hasPrefix(Self.cloudPrefix) else { return nil }
        return CloudProvider.provider(String(selectedTranslation.dropFirst(Self.cloudPrefix.count)))
    }

    /// Something can translate: a downloaded model, a configured cloud engine, or the sidecar.
    var translationReady: Bool {
        if let cloudProvider { return configuredCloud.contains(cloudProvider) }
        return translationModel != nil || selectedTranslation.hasPrefix(Self.sidecarPrefix)
    }

    /// Translating with an LLM (cloud or Gemma), which reads the viewer's character notes.
    var translatesWithLLM: Bool {
        cloudProvider != nil || translationModel?.isLLM == true
    }

    var translationName: String {
        if let cloudProvider {
            let model = cloudConfig.model(for: cloudProvider)
            let label = cloudProvider.model(model)?.label ?? model
            return configuredCloud.contains(cloudProvider) ? "\(cloudProvider.name) · \(label)" : "\(cloudProvider.name) (not set up)"
        }
        if selectedTranslation.hasPrefix(Self.sidecarPrefix) {
            return SidecarEngine(rawValue: String(selectedTranslation.dropFirst(Self.sidecarPrefix.count)))?.label
                ?? selectedTranslation
        }
        return translationModel?.name ?? "Translation model not downloaded"
    }

    /// Re-reads which providers have keys. Only masked hints are kept, never the keys.
    func refreshCloud() {
        let config = cloudConfig
        configuredCloud = CloudProvider.all.filter { config.isConfigured($0, secrets: secrets) }
        keyHints = Dictionary(uniqueKeysWithValues: CloudProvider.all.compactMap { provider in
            secrets.hint(provider.id).map { (provider.id, $0) }
        })
    }

    func saveKey(_ key: String, for provider: CloudProvider) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        try secrets.save(key, for: provider.id)
        refreshCloud()
    }

    func removeKey(for provider: CloudProvider) throws {
        try secrets.delete(provider.id)
        if cloudProvider == provider, inUse.isEmpty { selectedTranslation = ModelCatalog.defaultTranslation }
        refreshCloud()
    }

    func selectCloud(_ provider: CloudProvider) {
        guard inUse.isEmpty else { return }
        selectedTranslation = Self.cloudPrefix + provider.id
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

    func isDownloading(_ model: ModelInfo) -> Bool { downloads[model.id] != nil }

    func isSelected(_ model: ModelInfo) -> Bool {
        model.kind == .speech ? selectedSpeech == model.id : selectedTranslation == model.id
    }

    func refresh() {
        for model in ModelCatalog.all where downloads[model.id] == nil {
            status[model.id] = ModelFiles.isInstalled(model) ? .installed : .notInstalled
        }
        installedBytes = ModelCatalog.all.filter { isInstalled($0) && !$0.isBuiltIn }.reduce(0) { total, model in
            total + Self.size(of: ModelFiles.localURL(for: model))
        }
        reselectIfNeeded()
    }

    /// Keeps a usable selection when the chosen model is missing but another is installed.
    /// A selection that is being (re)downloaded is left alone.
    private func reselectIfNeeded() {
        let speechPending = selectedSpeech.flatMap(ModelCatalog.model(id:)).map(isDownloading) ?? false
        if speechModel == nil, !speechPending {
            selectedSpeech = preferredInstalled(ModelCatalog.speech, recommended: ModelCatalog.recommendedSpeech)?.id
        }
        let translationPending = ModelCatalog.model(id: selectedTranslation).map(isDownloading) ?? false
        if translationModel == nil, !translationPending, ModelCatalog.model(id: selectedTranslation) != nil,
           let installed = preferredInstalled(ModelCatalog.translation, recommended: ModelCatalog.recommendedTranslation) {
            selectedTranslation = installed.id
        }
    }

    private func preferredInstalled(_ models: [ModelInfo], recommended: String) -> ModelInfo? {
        let installed = models.filter(isInstalled)
        return installed.first { $0.id == recommended } ?? installed.first
    }

    func download(_ model: ModelInfo) {
        guard downloads[model.id] == nil, !inUse.contains(model.id) else { return }
        let attempt = UUID()
        status[model.id] = .downloading(0)
        let task = Task { [weak self] in
            do {
                _ = try await ModelFiles.download(model) { fraction in
                    Task { @MainActor in self?.updateProgress(model, attempt: attempt, fraction: fraction) }
                }
                self?.finishDownload(model, attempt: attempt, .installed)
            } catch is CancellationError {
                self?.finishDownload(model, attempt: attempt, .notInstalled)
            } catch let error as URLError where error.code == .cancelled {
                self?.finishDownload(model, attempt: attempt, .notInstalled)
            } catch {
                self?.finishDownload(model, attempt: attempt, .failed(error.localizedDescription))
            }
        }
        downloads[model.id] = (attempt, task)
    }

    /// Ignores progress from a cancelled attempt that arrives after a retry started.
    private func updateProgress(_ model: ModelInfo, attempt: UUID, fraction: Double) {
        guard downloads[model.id]?.attempt == attempt else { return }
        status[model.id] = .downloading(fraction)
    }

    private func finishDownload(_ model: ModelInfo, attempt: UUID, _ result: Status) {
        guard downloads[model.id]?.attempt == attempt else { return }
        downloads[model.id] = nil
        status[model.id] = result
        guard result == .installed else { return }
        // The first model of a kind becomes the one in use.
        if model.kind == .speech, speechModel == nil || selectedSpeech == nil { selectedSpeech = model.id }
        if model.kind == .translation, translationModel == nil, !selectedTranslation.hasPrefix(Self.sidecarPrefix) {
            selectedTranslation = model.id
        }
        refresh()
    }

    func cancelDownload(_ model: ModelInfo) {
        downloads[model.id]?.task.cancel()
    }

    func select(_ model: ModelInfo) {
        guard isInstalled(model), inUse.isEmpty else { return }
        if model.kind == .speech { selectedSpeech = model.id } else { selectedTranslation = model.id }
    }

    func delete(_ model: ModelInfo) {
        guard !model.isBuiltIn, !inUse.contains(model.id), !isDownloading(model) else { return }
        do {
            try ModelFiles.delete(model)
            status[model.id] = .notInstalled
            if selectedSpeech == model.id { selectedSpeech = nil }
            refresh()
        } catch {
            status[model.id] = .failed(error.localizedDescription)
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
