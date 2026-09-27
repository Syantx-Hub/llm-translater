import Foundation

/// A translation engine: a native model (MADLAD), a cloud or on-device LLM, or a developer
/// sidecar. The pipeline only sees this protocol.
protocol Translator: Sendable {
    func start() async throws
    /// - Parameter context: the previous few source lines, for consistent names and pronouns.
    /// Cancelling the calling task stops the translation early.
    func translate(_ text: String, from source: String, to target: String, context: [String]) async throws -> String
    func stop() async
}

/// Shows the recognised text as-is. Used when no translation engine is configured.
struct PassthroughTranslator: Translator {
    func start() async throws {}
    func translate(_ text: String, from source: String, to target: String, context: [String]) async throws -> String { text }
    func stop() async {}
}

/// Engines served by the Python sidecar (python/translate_server.py) in dev builds.
enum SidecarEngine: String, CaseIterable, Identifiable {
    case nllb, madlad, echo
    var id: String { rawValue }

    var label: String {
        switch self {
        case .nllb: "NLLB-200 via Python (non-commercial)"
        case .madlad: "MADLAD-400 via Python"
        case .echo: "Echo via Python (pipeline test)"
        }
    }
}

enum TranslatorSelectionError: LocalizedError {
    case notInstalled(String)
    case sidecarUnavailable
    case cloudNotSetUp(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let name): "\(name) is not downloaded yet. Open Models to download it."
        case .sidecarUnavailable: "The Python translation sidecar is not available in this build."
        case .cloudNotSetUp(let name): "\(name) isn't set up yet. Add it in Models › Cloud."
        }
    }
}

enum TranslatorFactory {
    /// - Parameter selection: a catalog model id, "cloud:<provider>", "sidecar:<engine>", or "off".
    static func make(selection: String, defaults: UserDefaults = .standard,
                     secrets: SecretStore = KeychainStore.app) throws -> Translator {
        if selection == ModelStore.translationOff { return PassthroughTranslator() }
        if selection.hasPrefix(ModelStore.cloudPrefix) {
            let id = String(selection.dropFirst(ModelStore.cloudPrefix.count))
            guard let provider = CloudProvider.provider(id) else { throw TranslatorSelectionError.cloudNotSetUp(id) }
            let config = CloudConfig(defaults: defaults)
            guard config.isConfigured(provider, secrets: secrets) else {
                throw TranslatorSelectionError.cloudNotSetUp(provider.name)
            }
            return try config.translator(for: provider, secrets: secrets, onEvent: { CloudActivity.post($0) })
        }
        if selection.hasPrefix(ModelStore.sidecarPrefix) {
            let name = String(selection.dropFirst(ModelStore.sidecarPrefix.count))
            guard let engine = SidecarEngine(rawValue: name), let location = SidecarLocation.resolve() else {
                throw TranslatorSelectionError.sidecarUnavailable
            }
            return SidecarTranslator(location: location, engine: engine)
        }
        guard let model = ModelCatalog.model(id: selection), model.kind == .translation else {
            throw TranslatorSelectionError.notInstalled(selection)
        }
        guard ModelFiles.isInstalled(model) else { throw TranslatorSelectionError.notInstalled(model.name) }
        let path = ModelFiles.localURL(for: model).path
        return model.isLLM ? LocalLLMTranslator(modelPath: path) : LlamaTranslator(modelPath: path)
    }
}
