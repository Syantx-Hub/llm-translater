import Foundation

/// Translates a subtitle file ahead of time. Unlike live captions there's no rush, so
/// the translation can appear exactly when the actor speaks — the file keeps its timing.
enum SubtitleTranslator {
    struct Progress: Sendable {
        let done: Int
        let total: Int
        /// Estimated seconds left, once a few cues have been timed.
        let secondsLeft: TimeInterval?
    }

    /// Translates every cue's text; timing is kept as is. Identical lines ("Yes.", "What?")
    /// are translated once. Cancelling the calling task stops early with CancellationError.
    static func translate(_ cues: [SubtitleCue], from source: String, to target: String, with translator: Translator,
                          progress: @Sendable (Progress) -> Void) async throws -> [SubtitleCue] {
        var translated: [SubtitleCue] = []
        var cache: [String: String] = [:]
        let started = Date()
        for (index, cue) in cues.enumerated() {
            try Task.checkCancellation()
            let text = SubtitleFile.plainText(cue.text)
            var output = cue
            if !text.isEmpty {
                if let cached = cache[text] {
                    output.text = cached
                } else {
                    output.text = try await SubtitlePipeline.translate(text, from: source, to: target, context: [], with: translator)
                    cache[text] = output.text
                }
            }
            translated.append(output)
            let done = index + 1
            let elapsed = Date().timeIntervalSince(started)
            progress(Progress(done: done, total: cues.count,
                              secondsLeft: done >= 5 ? elapsed / Double(done) * Double(cues.count - done) : nil))
        }
        return translated
    }
}

/// UI state for the "Translate Subtitles" window.
@MainActor
final class SubtitleJob: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loaded(cues: Int, duration: TimeInterval)
        case preparing
        case translating(done: Int, total: Int, secondsLeft: TimeInterval?)
        case finished(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var input: URL?
    /// Highlights the drop zone while a file is dragged over it.
    @Published var isDropTargeted = false

    private var cues: [SubtitleCue] = []
    private var task: Task<Void, Never>?

    var isWorking: Bool {
        switch phase {
        case .preparing, .translating: true
        default: false
        }
    }

    func load(_ url: URL) {
        guard !isWorking else { return }
        input = url
        do {
            cues = try SubtitleFile.read(url)
            phase = .loaded(cues: cues.count, duration: cues.last?.end ?? 0)
        } catch {
            cues = []
            phase = .failed(error.localizedDescription)
        }
    }

    /// - Parameter source: the subtitles' language, or `auto` (MADLAD detects it itself).
    func start(source: String, target: String, translatorSelection: String) {
        guard let input, !cues.isEmpty, !isWorking else { return }
        let cues = cues
        phase = .preparing
        task = Task { [weak self] in
            do {
                let translator = try TranslatorFactory.make(selection: translatorSelection)
                try await translator.start()
                defer { Task { await translator.stop() } }
                let result = try await SubtitleTranslator.translate(
                    cues, from: source == Languages.auto ? "en" : source, to: target, with: translator
                ) { progress in
                    Task { @MainActor in
                        guard let self, self.isWorking else { return }
                        self.phase = .translating(done: progress.done, total: progress.total, secondsLeft: progress.secondsLeft)
                    }
                }
                let output = SubtitleFile.outputURL(for: input, target: target)
                try SubtitleFile.srt(result).write(to: output, atomically: true, encoding: .utf8)
                self?.phase = .finished(output)
            } catch is CancellationError {
                self?.phase = .loaded(cues: cues.count, duration: cues.last?.end ?? 0)
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func reset() {
        guard !isWorking else { return }
        input = nil
        cues = []
        phase = .idle
    }
}

/// Headless: `Subtitler --translate-subtitles Movie.en.srt [--target my] [--source en] [--translator ID]`
enum SubtitleRunner {
    static func run(arguments: [String]) async -> Int32 {
        func option(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        guard let path = option("--translate-subtitles") else { return 2 }
        let target = option("--target") ?? "my"
        let source = option("--source") ?? "en"
        let selection = option("--translator") ?? ModelCatalog.defaultTranslation
        do {
            let input = URL(fileURLWithPath: path)
            let cues = try SubtitleFile.read(input)
            print("[subtitles] \(cues.count) lines")
            let translator = try TranslatorFactory.make(selection: selection)
            try await translator.start()
            let started = Date()
            let result = try await SubtitleTranslator.translate(cues, from: source, to: target, with: translator) { progress in
                if progress.done % 10 == 0 || progress.done == progress.total {
                    print("[subtitles] \(progress.done)/\(progress.total)")
                }
            }
            await translator.stop()
            let output = SubtitleFile.outputURL(for: input, target: target)
            try SubtitleFile.srt(result).write(to: output, atomically: true, encoding: .utf8)
            print(String(format: "[subtitles] saved %@ in %.1f s", output.path, Date().timeIntervalSince(started)))
            return 0
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
    }
}
