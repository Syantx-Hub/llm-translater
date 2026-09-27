import Foundation
import WhisperKit

struct Transcript: Equatable, Sendable {
    let text: String
    let language: String
    /// How sure the recognizer is, 0–1 (nil when it doesn't say). For Whisper this is the
    /// average token probability, exp(mean log-probability).
    var confidence: Double? = nil
    /// True for output that looks like a hallucination: the same few words repeated.
    var looksRepetitive = false
}

/// Speech-to-text as the pipeline sees it; tests substitute a fake.
protocol SpeechTranscribing: Sendable {
    /// - Parameter language: Whisper code, or nil to auto-detect. Returns nil for no speech.
    func transcribe(_ samples: [Float], language: String?) async throws -> Transcript?
    /// The spoken language of `samples` (Whisper code), without transcribing them.
    func detectLanguage(_ samples: [Float]) async throws -> String?
}

/// On-device speech recognition with WhisperKit (CoreML on the Neural Engine / GPU).
actor Transcriber: SpeechTranscribing {
    typealias Result = Transcript

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
        loads += 1
        whisper = nil
        let config = WhisperKitConfig(
            // tokenizerFolder: only a fallback (the tokenizer ships in the model folder),
            // but it keeps WhisperKit from downloading into ~/Documents.
            model: model, modelFolder: folder.path, tokenizerFolder: ModelFiles.speechBase, verbose: false, logLevel: .error,
            prewarm: true, load: true, download: false)
        whisper = try await WhisperKit(config)
    }

    var isLoaded: Bool { whisper != nil }

    /// Frees the model's memory (up to 3 GB) once any decode in flight has finished. The next
    /// session loads it again, which takes a few seconds.
    func unload() async {
        let generation = loads
        await tail?.value
        // A load that started while waiting is the next session's: keep it.
        if loads == generation { whisper = nil }
    }

    /// Counts loads, so an unload never frees a model loaded after it was asked for.
    private var loads = 0

    /// Runs one throwaway decode so the first real line doesn't pay for GPU/ANE setup.
    func warmUp() async {
        let noise = (0..<16_000).map { _ in Float.random(in: -0.001...0.001) }
        _ = try? await transcribe(noise, language: "en")
    }

    /// The previous decode; the next one waits for it, so WhisperKit never runs two at once
    /// (a cancelled decode can still be unwinding when the next request arrives).
    private var tail: Task<Void, Never>?

    /// - Parameter language: Whisper code, or nil to auto-detect.
    /// Cancelling the calling task stops the decode early.
    func transcribe(_ samples: [Float], language: String?) async throws -> Result? {
        let previous = tail
        let work = Task { () async throws -> Result? in
            await previous?.value
            try Task.checkCancellation()
            return try await self.decode(samples, language: language)
        }
        tail = Task { _ = try? await work.value }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func detectLanguage(_ samples: [Float]) async throws -> String? {
        let previous = tail
        let work = Task { () async throws -> String? in
            await previous?.value
            try Task.checkCancellation()
            return try await self.whisper?.detectLangauge(audioArray: samples).language
        }
        tail = Task { _ = try? await work.value }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func decode(_ samples: [Float], language: String?) async throws -> Result? {
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
        let segments = results.flatMap(\.segments)
        let tokenCount = segments.reduce(0) { $0 + max($1.tokens.count, 1) }
        let meanLogProb = segments.reduce(0.0) { $0 + Double($1.avgLogprob) * Double(max($1.tokens.count, 1)) }
            / Double(max(tokenCount, 1))
        return Transcript(
            text: text, language: results.first?.language ?? language ?? "",
            confidence: segments.isEmpty ? nil : exp(meanLogProb),
            looksRepetitive: segments.contains { $0.compressionRatio > 2.4 })
    }
}
