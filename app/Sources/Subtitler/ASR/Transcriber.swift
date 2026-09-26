import Foundation
import WhisperKit

/// On-device speech recognition with WhisperKit (CoreML on the Neural Engine / GPU).
actor Transcriber {
    struct Result {
        let text: String
        let language: String
    }

    private var whisper: WhisperKit?

    /// Whisper's stock outputs for music, silence and credits that VAD lets through.
    private static let hallucinations: Set<String> = [
        "thank you.", "thank you for watching.", "thanks for watching!", "thanks for watching.",
        "you", "bye.", "subtitles by the amara.org community", "[music]", "(music)", "♪",
    ]

    /// The model WhisperKit recommends for this chip (M1 through M4, any RAM size).
    static var recommendedModel: String { WhisperKit.recommendedModels().default }

    /// Loads and prewarms the model. The first load on a new Mac compiles it for the
    /// Neural Engine, which can take a few minutes; later loads are fast.
    func load(model: String, folder: URL) async throws {
        whisper = nil
        let config = WhisperKitConfig(
            model: model, modelFolder: folder.path, verbose: false, logLevel: .error,
            prewarm: true, load: true, download: false)
        whisper = try await WhisperKit(config)
    }

    var isLoaded: Bool { whisper != nil }

    /// Runs one throwaway decode so the first real line doesn't pay for GPU/ANE setup.
    func warmUp() async {
        let noise = (0..<16_000).map { _ in Float.random(in: -0.001...0.001) }
        _ = try? await transcribe(noise, language: "en")
    }

    /// - Parameter language: Whisper code, or nil to auto-detect.
    func transcribe(_ samples: [Float], language: String?) async throws -> Result? {
        guard let whisper else { return nil }
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = language
        options.detectLanguage = language == nil
        options.usePrefillPrompt = language != nil
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        options.suppressBlank = true
        options.noSpeechThreshold = 0.6

        let results: [TranscriptionResult] = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !Self.hallucinations.contains(text.lowercased()) else { return nil }
        return Result(text: text, language: results.first?.language ?? language ?? "")
    }
}
