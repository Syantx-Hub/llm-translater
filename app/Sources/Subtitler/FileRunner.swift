import AVFoundation
import Foundation

/// Headless mode: runs an audio file through the same segmenter → ASR → translation
/// pipeline as live capture and prints the subtitles. Needs no audio-capture permission.
///
///   Subtitler --file clip.m4a [--source en] [--target my] [--model SPEECH_ID] [--translator ID|sidecar:nllb|off]
///            [--responsiveness fast|balanced|accurate] [--realtime]
///
/// Missing catalog models are downloaded first, into the same place the app uses.
///
/// `--realtime` feeds audio at playback speed, so drafts and timings match live use.
enum FileRunner {
    static func run(arguments: [String]) async -> Int32 {
        func option(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        guard let path = option("--file") else {
            print("usage: Subtitler --file AUDIO [--source xx] [--target xx] [--model SPEECH_ID] [--translator ID|sidecar:nllb|off] [--responsiveness fast|balanced|accurate] [--realtime]")
            print("models: " + ModelCatalog.all.map(\.id).joined(separator: ", "))
            return 2
        }
        let source = option("--source")
        let target = option("--target") ?? "my"
        let speechID = option("--model") ?? ModelCatalog.recommendedSpeech
        let selection = option("--translator") ?? ModelCatalog.defaultTranslation
        let realtime = arguments.contains("--realtime")
        let responsiveness = option("--responsiveness").flatMap(Responsiveness.init) ?? .balanced

        do {
            let samples = try loadAudio(URL(fileURLWithPath: path))
            print("[audio] \(String(format: "%.1f", Double(samples.count) / SystemAudioCapture.sampleRate)) s")

            guard let speech = ModelCatalog.model(id: speechID), speech.kind == .speech else {
                print("error: unknown speech model \(speechID)")
                return 2
            }
            let transcriber = Transcriber()
            print("[asr] \(speech.name) — \(Hardware.chipName), \(Hardware.ramGB) GB")
            var t0 = Date()
            if speech.isBuiltIn {
                guard source != nil else {
                    print("error: Apple Speech needs --source")
                    return 2
                }
            } else {
                let speechFolder = try await ensureInstalled(speech)
                try await transcriber.load(model: speech.id, folder: speechFolder)
                await transcriber.warmUp()
                print("[asr] loaded in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
            }

            if let model = ModelCatalog.model(id: selection) { _ = try await ensureInstalled(model) }
            let translator = try TranslatorFactory.make(selection: selection)
            t0 = Date()
            try await translator.start()
            print("[mt] \(selection) ready in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")

            let start = Date()
            let elapsed = { String(format: "%6.2f", Date().timeIntervalSince(start)) }
            let pipeline = SubtitlePipeline(
                transcriber: transcriber, translator: translator, source: source, target: target
            ) { update in
                switch update {
                case .draft(let caption?) where !caption.text.isEmpty:
                    print("[\(elapsed())] draft\(caption.isTranslation ? "*" : " ") \(caption.text)")
                case .draft: break
                case .line(let original, let translation, let latency):
                    print("[\(elapsed())] line   \(original)\n                  -> \(translation)  (lag \(String(format: "%.2f", latency)) s)")
                case .detectedLanguage(let code): print("[\(elapsed())] detected language: \(code)")
                case .error(let message): print("[\(elapsed())] error  \(message)")
                }
            }

            if speech.isBuiltIn, let source {
                try await runAppleSpeech(samples, source: source, realtime: realtime, pipeline: pipeline)
                await pipeline.flush()
                await translator.stop()
                print("[done] \(elapsed()) s")
                return 0
            }

            let (events, sink) = AsyncStream<SpeechSegmenter.Event>.makeStream()
            let segmenter = SpeechSegmenter(tuning: responsiveness.tuning)
            segmenter.onEvent = { sink.yield($0) }
            let pump = Task { for await event in events { await pipeline.submit(event) } }

            // 100 ms chunks, like the capture callback; trailing silence flushes the last line.
            let chunk = Int(SystemAudioCapture.sampleRate) / 10
            let padded = samples + [Float](repeating: 0, count: Int(SystemAudioCapture.sampleRate))
            for offset in stride(from: 0, to: padded.count, by: chunk) {
                segmenter.append(Array(padded[offset..<min(offset + chunk, padded.count)]))
                if realtime { try await Task.sleep(for: .milliseconds(100)) }
            }
            sink.finish()
            await pump.value
            await pipeline.flush()
            await translator.stop()
            print("[done] \(elapsed()) s")
            return 0
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
    }

    /// Streams the file through Apple Speech in 100 ms chunks, like live capture.
    private static func runAppleSpeech(_ samples: [Float], source: String, realtime: Bool,
                                       pipeline: SubtitlePipeline) async throws {
        guard #available(macOS 26.0, *), let locale = await AppleSpeech.locale(for: source) else {
            throw SetupError.appleSpeechNeedsWhisper("Apple Speech can't recognise \(source).")
        }
        let recognizer = AppleSpeechRecognizer(locale: locale)
        let (events, sink) = AsyncStream<AppleSpeechRecognizer.Event>.makeStream()
        recognizer.onEvent = { sink.yield($0) }
        try await recognizer.start { print("[download] Apple Speech assets \(Int($0 * 100))%") }
        let pump = Task {
            for await event in events {
                switch event {
                case .volatile(let text): await pipeline.submitVolatile(text)
                case .final(let text, let ended): await pipeline.submitFinal(text, speechEndedAt: ended)
                }
            }
        }
        let chunk = Int(SystemAudioCapture.sampleRate) / 10
        let padded = samples + [Float](repeating: 0, count: Int(SystemAudioCapture.sampleRate))
        for offset in stride(from: 0, to: padded.count, by: chunk) {
            recognizer.append(Array(padded[offset..<min(offset + chunk, padded.count)]))
            if realtime { try await Task.sleep(for: .milliseconds(100)) }
        }
        await recognizer.stop()
        sink.finish()
        await pump.value
    }

    private static func ensureInstalled(_ model: ModelInfo) async throws -> URL {
        if ModelFiles.isInstalled(model) { return ModelFiles.localURL(for: model) }
        print("[download] \(model.name) (\(model.sizeLabel))…")
        let lastReported = Counter()
        return try await ModelFiles.download(model) { fraction in
            let percent = Int(fraction * 100)
            if lastReported.advance(to: percent / 10) { print("[download] \(percent)%") }
        }
    }

    /// Any file AVAudioFile reads (wav, aiff, m4a, mp3, caf) → 16 kHz mono Float32.
    static func loadAudio(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: SystemAudioCapture.sampleRate, channels: 1, interleaved: false)!
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: input)

        let ratio = SystemAudioCapture.sampleRate / file.processingFormat.sampleRate
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * ratio) + 1024)!
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

/// Thread-safe "report each step once" counter for download progress lines.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1

    func advance(to next: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard next > value else { return false }
        value = next
        return true
    }
}

/// Dev check for audio capture: `Subtitler --audio-probe` prints the permission status and,
/// if granted, the loudness of 3 s of system audio. Never triggers a permission prompt.
enum AudioProbe {
    static func run() async -> Int32 {
        let status = AudioPermission.status()
        print("[probe] \(AudioPermission.name): \(status)")
        guard status == .granted else { return 1 }
        let capture = AudioCaptureFactory.make()
        let meter = LoudnessMeter()
        capture.onSamples = { meter.add($0) }
        do {
            try await capture.start()
            try await Task.sleep(for: .seconds(3))
            await capture.stop()
        } catch {
            print("[probe] error: \(error.localizedDescription)")
            return 1
        }
        print(String(format: "[probe] %.1f s captured, RMS %.4f", Double(meter.count) / SystemAudioCapture.sampleRate, meter.rms))
        return 0
    }
}

private final class LoudnessMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var sum: Double = 0
    private(set) var count = 0

    func add(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        sum += samples.reduce(0) { $0 + Double($1 * $1) }
        count += samples.count
    }

    var rms: Double { count == 0 ? 0 : (sum / Double(count)).squareRoot() }
}
