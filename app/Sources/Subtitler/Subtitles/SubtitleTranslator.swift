import Foundation

/// Translates a subtitle file ahead of time. Unlike live captions there's no rush, so
/// the translation can appear exactly when the actor speaks — the file keeps its timing.
enum SubtitleTranslator {
    struct Progress: Sendable, Equatable {
        /// Sentences translated (including ones cached from an earlier run).
        let done: Int
        let total: Int
        /// Requests sent so far this run.
        let requests: Int
        /// Estimated seconds left, once a few requests have been timed.
        let secondsLeft: TimeInterval?
    }

    /// Stopped early (quota, network, cancel); `cues` holds what was translated, to save.
    struct Stopped: Error {
        let cues: [SubtitleCue]
        let translated: Int
        let total: Int
        let underlying: Error
    }

    /// Translates the file sentence by sentence: cues that split one sentence are joined
    /// (`SubtitleSentences`) and become one cue spanning them, so the translation reads as
    /// a whole sentence. Other cues keep their timing. `existing` translations (by sentence
    /// group, from an earlier partial run) are kept, so only the rest is translated.
    static func translate(_ cues: [SubtitleCue], from source: String, to target: String, with translator: Translator,
                          existing: [Int: String] = [:], title: String? = nil, notes: String = "",
                          progress: @escaping @Sendable (Progress) -> Void) async throws -> [SubtitleCue] {
        let sentences = SubtitleSentences(cues: cues)
        let total = sentences.groups.count
        let started = Date()
        let remainingAtStart = total - existing.count
        do {
            let done = try await SentenceTranslation.run(
                order: Array(sentences.groups.indices), cues: cues, sentences: sentences,
                from: source, to: target, with: translator, done: existing, title: title, notes: notes
            ) { step in
                let newlyDone = step.done.count - existing.count
                let elapsed = Date().timeIntervalSince(started)
                let secondsLeft = newlyDone >= 5 && step.requestsDone >= 2
                    ? elapsed / Double(newlyDone) * Double(remainingAtStart - newlyDone) : nil
                progress(Progress(done: step.done.count, total: total, requests: step.requestsDone, secondsLeft: secondsLeft))
            }
            return SentenceTranslation.cues(done, sentences: sentences, cues: cues)
        } catch let partial as SentenceTranslation.Partial {
            throw Stopped(cues: SentenceTranslation.cues(partial.done, sentences: sentences, cues: cues),
                          translated: partial.done.count, total: total, underlying: partial.underlying)
        }
    }
}

/// UI state for the "Save Translated Copy" window.
@MainActor
final class SubtitleJob: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loaded(cues: Int, duration: TimeInterval)
        case preparing
        case translating(done: Int, total: Int, requests: Int, secondsLeft: TimeInterval?)
        case finished(URL)
        /// Stopped early with part of the file saved; the next run continues from there.
        case partial(URL, message: String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var input: URL?
    /// Highlights the drop zone while a file is dragged over it.
    @Published var isDropTargeted = false

    private(set) var cues: [SubtitleCue] = []
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

    /// Sentences already translated into `target` next to the file, from an earlier run.
    func cached(target: String) -> [Int: String] {
        guard let input else { return [:] }
        return SyncTranslations.existingTranslations(for: input, cues: cues, sentences: SubtitleSentences(cues: cues),
                                                     target: target)
    }

    /// What a run would send, for the estimate shown before starting.
    func estimate(target: String, batchSize: Int, limits: RateLimits?) -> CloudEstimate {
        let groups = SubtitleSentences(cues: cues).groups.count
        return CloudEstimate(cues: cues.count, groups: groups, remaining: groups - cached(target: target).count,
                             batchSize: batchSize, limits: limits)
    }

    /// - Parameter source: the subtitles' language, or `auto` (MADLAD detects it itself).
    func start(source: String, target: String, translatorSelection: String) {
        guard let input, !cues.isEmpty, !isWorking else { return }
        let cues = cues
        let existing = cached(target: target)
        // Continue into our own earlier (partial) copy; never overwrite someone else's file.
        let output = existing.isEmpty ? SubtitleFile.outputURL(for: input, target: target)
                                      : SubtitleFile.translationURL(for: input, target: target)
        phase = .preparing
        task = Task { [weak self] in
            do {
                let translator = try TranslatorFactory.make(selection: translatorSelection)
                try await translator.start()
                defer { Task { await translator.stop() } }
                let result = try await SubtitleTranslator.translate(
                    cues, from: source == Languages.auto ? "en" : source, to: target, with: translator, existing: existing,
                    title: FilmTitle.from(input), notes: CharacterNotes.get(for: input)
                ) { progress in
                    Task { @MainActor in
                        guard let self, self.isWorking else { return }
                        self.phase = .translating(done: progress.done, total: progress.total,
                                                  requests: progress.requests, secondsLeft: progress.secondsLeft)
                    }
                }
                try SubtitleFile.srt(result).write(to: output, atomically: true, encoding: .utf8)
                self?.phase = .finished(output)
            } catch let stopped as SubtitleTranslator.Stopped {
                self?.saveStopped(stopped, to: output)
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func saveStopped(_ stopped: SubtitleTranslator.Stopped, to output: URL) {
        let cancelled = stopped.underlying is CancellationError
        guard stopped.translated > 0, (try? SubtitleFile.srt(stopped.cues).write(to: output, atomically: true, encoding: .utf8)) != nil
        else {
            phase = cancelled ? .loaded(cues: cues.count, duration: cues.last?.end ?? 0) : .failed(stopped.underlying.localizedDescription)
            return
        }
        let progress = "Translated \(stopped.translated) of \(stopped.total) lines; the rest will continue next time"
        if case CloudError.quotaExhausted = stopped.underlying {
            phase = .partial(output, message: "Daily limit reached. \(progress) (or switch to offline MADLAD).")
        } else if cancelled {
            phase = .partial(output, message: "Stopped. \(progress).")
        } else {
            phase = .partial(output, message: "\(stopped.underlying.localizedDescription) \(progress).")
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
                    print("[subtitles] \(progress.done)/\(progress.total) (\(progress.requests) requests)")
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

/// Headless: `Subtitler --search-subtitles "breaking bad s01e01" [--language en]`, using the
/// key from .env. Prints results only, never the key.
enum SubtitleSearchRunner {
    static func run(arguments: [String]) async -> Int32 {
        func option(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        guard let text = option("--search-subtitles") else { return 2 }
        guard let client = OpenSubtitlesClient.fromSecrets() else {
            print("error: \(OpenSubtitlesError.missingAPIKey.localizedDescription)")
            return 1
        }
        let query = SubtitleQuery.parse(text)
        do {
            let results = try await client.search(query, languages: [option("--language") ?? "en"])
            print("[search] \(query.title)\(query.isEpisode ? " S\(query.season!)E\(query.episode!)" : ""): \(results.count) results")
            for result in results.prefix(5) {
                print("  \(result.savedFileName) · \(result.release) · \(result.downloads) downloads")
            }
            return 0
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
    }
}
