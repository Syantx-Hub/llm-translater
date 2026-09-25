import AVFoundation
import Foundation

/// Headless mode: runs an audio file through the same segmenter → ASR → translation
/// pipeline as live capture and prints the subtitles. Needs no Screen Recording permission.
///
///   Subtitler --file clip.m4a [--source en] [--target my] [--engine nllb] [--model NAME] [--realtime]
///
/// `--realtime` feeds audio at playback speed, so drafts and timings match live use.
enum FileRunner {
    static func run(arguments: [String]) async -> Int32 {
        func option(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        guard let path = option("--file") else {
            print("usage: Subtitler --file AUDIO [--source xx] [--target xx] [--engine nllb|madlad|echo|off] [--model NAME] [--realtime]")
            return 2
        }
        let source = option("--source")
        let target = option("--target") ?? "my"
        let engine = option("--engine").flatMap(TranslationEngine.init) ?? .nllb
        let model = option("--model") ?? Transcriber.recommendedModel
        let realtime = arguments.contains("--realtime")

        do {
            let samples = try loadAudio(URL(fileURLWithPath: path))
            print("[audio] \(String(format: "%.1f", Double(samples.count) / SystemAudioCapture.sampleRate)) s")

            let transcriber = Transcriber()
            print("[asr] \(model) (recommended for this Mac: \(Transcriber.recommendedModel))")
            let folder = try await transcriber.download(model: model) { _ in }
            var t0 = Date()
            try await transcriber.load(model: model, folder: folder)
            print("[asr] loaded in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")

            let translator: Translator
            if engine == .off {
                translator = PassthroughTranslator()
            } else {
                guard let location = SidecarLocation.resolve() else {
                    print("error: translation sidecar not found; run from the repo or set SUBTITLER_REPO")
                    return 1
                }
                translator = SidecarTranslator(location: location, engine: engine)
                t0 = Date()
                try await translator.start()
                print("[mt] \(engine.rawValue) ready in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
            }

            let start = Date()
            let elapsed = { String(format: "%6.2f", Date().timeIntervalSince(start)) }
            let pipeline = SubtitlePipeline(
                transcriber: transcriber, translator: translator, source: source, target: target
            ) { update in
                switch update {
                case .draft(let text) where !text.isEmpty: print("[\(elapsed())] draft  \(text)")
                case .draft: break
                case .line(let original, let translation):
                    print("[\(elapsed())] line   \(original)\n                  -> \(translation)")
                case .detectedLanguage(let code): print("[\(elapsed())] detected language: \(code)")
                case .error(let message): print("[\(elapsed())] error  \(message)")
                }
            }

            let (events, sink) = AsyncStream<SpeechSegmenter.Event>.makeStream()
            let segmenter = SpeechSegmenter()
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
