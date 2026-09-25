import Foundation

/// A translation engine. Implementations can be local sidecars, native models, or a
/// cloud "high quality" mode later — the pipeline only sees this protocol.
protocol Translator: Sendable {
    func start() async throws
    /// - Parameter context: the previous few source lines, for consistent names and pronouns.
    func translate(_ text: String, from source: String, to target: String, context: [String]) async throws -> String
    func stop() async
}

/// Shows the recognised text as-is. Used when no translation engine is configured.
struct PassthroughTranslator: Translator {
    func start() async throws {}
    func translate(_ text: String, from source: String, to target: String, context: [String]) async throws -> String { text }
    func stop() async {}
}

enum TranslationEngine: String, CaseIterable, Identifiable {
    case nllb, madlad, echo, off
    var id: String { rawValue }

    var label: String {
        switch self {
        case .nllb: "NLLB-200 (non-commercial)"
        case .madlad: "MADLAD-400"
        case .echo: "Echo (sidecar test)"
        case .off: "Off (show original)"
        }
    }
}
