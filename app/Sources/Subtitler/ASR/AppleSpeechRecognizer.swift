import AVFoundation
import Speech

enum AppleSpeech {
    /// Apple's streaming recognizer (SpeechAnalyzer) ships with macOS 26.
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }

    /// Region used when asking Speech for a language; any supported variant works.
    private static let preferredRegions: [String: String] = [
        "en": "en-US", "ko": "ko-KR", "ja": "ja-JP", "zh": "zh-CN",
        "fr": "fr-FR", "de": "de-DE", "es": "es-ES", "pt": "pt-BR", "it": "it-IT",
    ]

    /// Our language codes Apple Speech may support; `locale(for:)` gives the final answer.
    static let candidateLanguages = Set(preferredRegions.keys)

    /// The Speech locale for a spoken-language code, or nil if Apple Speech can't hear it.
    static func locale(for code: String) async -> Locale? {
        guard #available(macOS 26.0, *), let identifier = preferredRegions[code] else { return nil }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
    }
}

enum AppleSpeechError: LocalizedError {
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "Apple Speech could not accept the captured audio."
        }
    }
}

/// Streams captured audio into Apple's SpeechAnalyzer. Unlike Whisper it needs no VAD
/// or chunking: it reports the words so far as they are heard (volatile results) and a
/// final result per phrase.
@available(macOS 26.0, *)
final class AppleSpeechRecognizer: @unchecked Sendable {
    enum Event: Sendable {
        case volatile(String)
        /// `speechEndedAt`: wall-clock estimate of when the phrase ended, for lag.
        /// `confidence`: Apple's average word confidence, 0–1.
        /// `speechStartedAt`: when the phrase began, from the result's audio range.
        case final(String, speechEndedAt: Date, speechStartedAt: Date?, confidence: Double?)
    }

    /// Called on an arbitrary thread, in order.
    var onEvent: (@Sendable (Event) -> Void)?

    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var format: AVAudioFormat?
    private let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: SystemAudioCapture.sampleRate, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var fedSeconds: Double = 0

    init(locale: Locale) {
        self.locale = locale
    }

    /// Installs the language's on-device assets if needed (a one-time download managed by
    /// macOS), then starts listening. `progress` reports the asset download.
    func start(progress: @escaping @Sendable (Double) -> Void) async throws {
        // Progressive results plus per-word confidence, to hide lines Apple barely heard.
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
            attributeOptions: [.transcriptionConfidence])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let observation = request.progress.observe(\.fractionCompleted) { value, _ in progress(value.fractionCompleted) }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let converter = AVAudioConverter(from: sourceFormat, to: format)
        else { throw AppleSpeechError.unsupportedFormat }
        self.format = format
        self.converter = converter

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber])
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    if result.isFinal {
                        // Audio fed so far minus where the phrase ended = how long ago it ended.
                        let now = Date()
                        let behind = max(0, self.audioFed - result.range.end.seconds)
                        let startBehind = max(0, self.audioFed - result.range.start.seconds)
                        self.onEvent?(.final(text, speechEndedAt: now.addingTimeInterval(-behind),
                                             speechStartedAt: now.addingTimeInterval(-startBehind),
                                             confidence: Self.confidence(of: result.text)))
                    } else {
                        self.onEvent?(.volatile(text))
                    }
                }
            } catch {
                // Cancelled on stop; nothing to report.
            }
        }
    }

    /// Feeds 16 kHz mono Float32 samples. Call from one thread at a time.
    func append(_ samples: [Float]) {
        guard let converter, let format, let input, !samples.isEmpty,
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / sourceFormat.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        guard error == nil, output.frameLength > 0 else { return }
        lock.lock()
        fedSeconds += Double(samples.count) / sourceFormat.sampleRate
        lock.unlock()
        input.yield(AnalyzerInput(buffer: output))
    }

    /// Finishes the current phrase (its final result is still delivered) and stops.
    func stop() async {
        input?.finish()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        analyzer = nil
    }

    /// Character-weighted average of the words' confidence.
    private static func confidence(of text: AttributedString) -> Double? {
        var total = 0.0
        var weight = 0
        for run in text.runs {
            guard let value = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] else { continue }
            let length = text[run.range].characters.count
            total += value * Double(length)
            weight += length
        }
        return weight > 0 ? total / Double(weight) : nil
    }

    private var audioFed: Double {
        lock.lock()
        defer { lock.unlock() }
        return fedSeconds
    }
}
