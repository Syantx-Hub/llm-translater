import Foundation

/// A translation engine. Implementations can be local sidecars, native models, or a
/// cloud "high quality" mode later — the pipeline only sees this protocol.
protocol Translator: Sendable {
    func start() async throws
    /// - Parameter context: the previous few source lines, for consistent names and pronouns.
    func translate(_ text: String, from source: String, to target: String, context: [String]) async throws -> String
    /// Like `translate`, but reports the translation so far as it is produced, for engines
    /// that generate it word by word. Cancelling the calling task stops it early.
    func translate(_ text: String, from source: String, to target: String, context: [String],
                   partial: @escaping @Sendable (String) -> Void) async throws -> String
    func stop() async
}

extension Translator {
    func translate(_ text: String, from source: String, to target: String, context: [String],
                   partial: @escaping @Sendable (String) -> Void) async throws -> String {
        try await translate(text, from: source, to: target, context: context)
    }
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

    var errorDescription: String? {
        switch self {
        case .notInstalled(let name): "\(name) is not downloaded yet. Open Models to download it."
        case .sidecarUnavailable: "The Python translation sidecar is not available in this build."
        }
    }
}

enum TranslatorFactory {
    /// - Parameter selection: a catalog model id, "sidecar:<engine>", or "off".
    static func make(selection: String) throws -> Translator {
        if selection == ModelStore.translationOff { return PassthroughTranslator() }
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
        return LlamaTranslator(modelPath: ModelFiles.localURL(for: model).path)
    }
}
