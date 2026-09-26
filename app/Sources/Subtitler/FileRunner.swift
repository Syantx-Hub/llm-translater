import AVFoundation
import Foundation

/// Headless mode: runs an audio file through the same segmenter → ASR → translation
/// pipeline as live capture and prints the subtitles. Needs no audio-capture permission.
///
///   Subtitler --file clip.m4a [--source en] [--target my] [--model SPEECH_ID] [--translator ID|sidecar:nllb|off]
///            [--responsiveness fast|balanced|accurate] [--realtime] [--sync SUBTITLES]
///
/// Missing catalog models are downloaded first, into the same place the app uses.
///
/// `--realtime` feeds audio at playback speed, so drafts and timings match live use.
///
/// `--sync SUBTITLES` runs Subtitle file mode instead: heard lines only position the file,
/// and since the file starts playing when the run starts, it prints how far the sync clock
/// is from the truth (positive: subtitles would show late). Use with `--realtime`.
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
        let syncPath = option("--sync")

        do {
            let sync = try syncPath.map { SubtitleSync(cues: try SubtitleFile.read(URL(fileURLWithPath: $0))) }
            let samples = try loadAudio(URL(fileURLWithPath: path))
            print("[audio] \(String(format: "%.1f", Double(samples.count) / SystemAudioCapture.sampleRate)) s")

            // Any WhisperKit variant can be benchmarked, not just the catalog's.
            let adHoc = speechID.hasPrefix("openai_whisper") || speechID.hasPrefix("distil-whisper")
                ? ModelInfo(id: speechID, kind: .speech, name: speechID, summary: "", strengths: [],
                            source: .whisperKit(variant: speechID, tokenizer: speechID.contains("small") ? .small : .largev3),
                            sizeMB: 0, speed: 0, quality: 0, license: "MIT", commercialUse: true, minRAMGB: 8, englishOnly: false)
                : nil
            guard let speech = ModelCatalog.model(id: speechID) ?? adHoc, speech.kind == .speech else {
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

            let start = playbackStart.value // the audio "starts playing" now
            let observations = ObservationLog()
            let elapsed = { String(format: "%6.2f", Date().timeIntervalSince(start)) }
            let pipeline = SubtitlePipeline(
                transcriber: transcriber, translator: translator, source: source,
                // As in the app: sync only needs what was said, with exact timing.
                target: sync == nil ? target : nil, commitsEarly: sync == nil
            ) { update in
                if let sync, case .line(let original, _, _, let spoken) = update {
                    guard let span = spoken else {
                        print("[\(elapsed())] heard  \(original)  (no timing; not used for sync)")
                        return
                    }
                    let cue = sync.observe(original, spoken: span)
                    let error = sync.anchor.map { String(format: "%+.2f s", $0.timeIntervalSince(start)) } ?? "not synced"
                    // Each end's own verdict on this line: + means subtitles would show late.
                    var ends = ""
                    if let seen = sync.lastObservation, seen.last == cue ?? seen.last {
                        let startError = seen.startAnchor.map { String(format: "%+.2f", $0.timeIntervalSince(start)) } ?? "  -  "
                        ends = String(format: " [start %@, end %+.2f, cues %d-%d]", startError,
                                      seen.endAnchor.timeIntervalSince(start), seen.first + 1, seen.last + 1)
                        observations.append(seen)
                    }
                    print("[\(elapsed())] heard  \(original)  → cue \(cue.map { String($0 + 1) } ?? "-"), clock \(error)\(ends)")
                    return
                }
                switch update {
                case .draft(let caption?) where !caption.text.isEmpty:
                    print("[\(elapsed())] draft\(caption.isTranslation ? "*" : " ") \(caption.text)")
                case .draft: break
                case .line(let original, let translation, let latency, _):
                    Trace.log("line shown: \(original)")
                    print("[\(elapsed())] line   \(original)\n                  -> \(translation)  (lag \(String(format: "%.2f", latency)) s)")
                case .detectedLanguage(let code): print("[\(elapsed())] detected language: \(code)")
                case .unclear(let text): print("[\(elapsed())] hidden (unclear) \(text)")
                case .error(let message): print("[\(elapsed())] error  \(message)")
                }
            }

            if speech.isBuiltIn, let source {
                try await runAppleSpeech(samples, source: source, realtime: realtime, pipeline: pipeline)
                await pipeline.flush()
                await translator.stop()
                if let sync {
                    print("[sync] clock " + (sync.anchor.map { String(format: "%+.2f s (positive: subtitles late)", $0.timeIntervalSince(start)) } ?? "never synced"))
                    observations.summary(start: start)
                }
                print("[done] \(elapsed()) s")
                return 0
            }

            let (events, sink) = AsyncStream<SpeechSegmenter.Event>.makeStream()
            let segmenter = SpeechSegmenter(tuning: responsiveness.tuning, detector: SileroVAD())
            segmenter.onEvent = { sink.yield($0) }
            let pump = Task { for await event in events { await pipeline.submit(event) } }

            // 100 ms chunks, like the capture callback; trailing silence flushes the last line.
            let chunk = Int(SystemAudioCapture.sampleRate) / 10
            let padded = samples + [Float](repeating: 0, count: Int(SystemAudioCapture.sampleRate))
            Trace.log("audio playback starts")
            for offset in stride(from: 0, to: padded.count, by: chunk) {
                segmenter.append(Array(padded[offset..<min(offset + chunk, padded.count)]))
                if realtime { try await playbackPace(offset + chunk) }
            }
            sink.finish()
            await pump.value
            await pipeline.flush()
            await translator.stop()
            if let sync {
                print("[sync] clock " + (sync.anchor.map { String(format: "%+.2f s (positive: subtitles late)", $0.timeIntervalSince(start)) } ?? "never synced"))
                observations.summary(start: start)
            }
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
                case .final(let text, let ended, let started, let confidence):
                    await pipeline.submitFinal(text, speechEndedAt: ended, speechStartedAt: started, confidence: confidence)
                }
            }
        }
        // As in the app: our VAD tells the pipeline when the speaker pauses.
        await pipeline.setWhisperTranscribes(false)
        let (segments, segmentSink) = AsyncStream<SpeechSegmenter.Event>.makeStream()
        let segmenter = SpeechSegmenter(detector: SileroVAD())
        segmenter.onEvent = { segmentSink.yield($0) }
        let segmentPump = Task { for await event in segments { await pipeline.submit(event) } }
        defer { segmentSink.finish(); segmentPump.cancel() }

        let chunk = Int(SystemAudioCapture.sampleRate) / 10
        let padded = samples + [Float](repeating: 0, count: Int(SystemAudioCapture.sampleRate))
        Trace.log("audio playback starts")
        for offset in stride(from: 0, to: padded.count, by: chunk) {
            let piece = Array(padded[offset..<min(offset + chunk, padded.count)])
            segmenter.append(piece)
            recognizer.append(piece)
            if realtime { try await playbackPace(offset + chunk) }
        }
        await recognizer.stop()
        sink.finish()
        await pump.value
    }

    /// Sleeps until `samples` of audio would have played since the first call, on an
    /// absolute schedule: sleeping 100 ms per chunk drifts behind real time, and the sync
    /// measurement would then blame the clock for it.
    private static let playbackStart = LockedDate()
    private static func playbackPace(_ samples: Int) async throws {
        let due = playbackStart.value.addingTimeInterval(Double(samples) / SystemAudioCapture.sampleRate)
        let wait = due.timeIntervalSinceNow
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
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

/// The first time it's read, remembers that moment.
private final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date?

    var value: Date {
        lock.lock()
        defer { lock.unlock() }
        if date == nil { date = Date() }
        return date!
    }
}

/// Every matched line's start- and end-based clock error, for the `--sync` summary.
private final class ObservationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SubtitleSync.Observation] = []

    func append(_ item: SubtitleSync.Observation) { lock.withLock { items.append(item) } }

    func summary(start: Date) {
        let items = lock.withLock { self.items }
        func median(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "-" }
            let sorted = values.sorted()
            return String(format: "%+.2f s", sorted[sorted.count / 2])
        }
        let starts = items.compactMap { $0.startAnchor?.timeIntervalSince(start) }
        let ends = items.map { $0.endAnchor.timeIntervalSince(start) }
        print("[sync] \(items.count) matched lines; median error from speech start \(median(starts)) (\(starts.count) lines), from speech end \(median(ends))")
    }
}
