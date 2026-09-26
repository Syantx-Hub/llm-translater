import Foundation
import NaturalLanguage

/// Translations of a subtitle file's sentences, made just ahead of where the video is.
/// Cues that split one sentence are translated together (`SubtitleSentences`), so the
/// work and the results are per sentence group, not per cue.
actor SyncTranslations {
    /// Progress of a whole-file run (batch engines), for the panel.
    enum Status: Equatable, Sendable {
        case translating(done: Int, total: Int, requests: Int)
        case finished(total: Int)
        case stopped(String)
    }

    private let cues: [SubtitleCue]
    let sentences: SubtitleSentences
    private let translator: Translator
    private let source: String
    private let target: String
    private var done: [Int: String]
    private var queue: [Int] = []
    private var working = false
    /// Batch engines translate the whole file, starting here (the latest position asked for).
    private var cursor = 0
    private var requests = 0
    private var stopped = false
    /// Where a whole-file run saves what it has, so later runs send nothing.
    private let cacheURL: URL?
    private let onStatus: @Sendable (Status) -> Void

    /// - Parameters:
    ///   - existing: translations already on disk (from Save Translated Copy), by group.
    ///   - cacheURL: for batch (cloud) engines, the file to keep translations in.
    init(cues: [SubtitleCue], sentences: SubtitleSentences, translator: Translator, source: String, target: String,
         existing: [Int: String] = [:], cacheURL: URL? = nil, onStatus: @escaping @Sendable (Status) -> Void = { _ in }) {
        self.cues = cues
        self.sentences = sentences
        self.translator = translator
        self.source = source
        self.target = target
        self.cacheURL = cacheURL
        self.onStatus = onStatus
        done = existing
    }

    func translation(ofGroup group: Int) -> String? { done[group] }

    /// Translates the sentences these cues belong to (in order) unless already done or queued.
    /// A batch engine instead translates the whole file, from these cues onwards.
    func prefetch(cues indices: [Int]) {
        let wanted = sentences.groups(of: indices)
        if translator is BatchTranslating {
            guard let first = wanted.first(where: { done[$0] == nil }) else { return }
            cursor = first
        } else {
            let new = wanted.filter { done[$0] == nil && !queue.contains($0) }
            // Newest request first: after a jump, the lines near the new position matter most.
            queue = new + queue.filter { !new.contains($0) }
        }
        guard !working, !stopped else { return }
        working = true
        Task { translator is BatchTranslating ? await workWholeFile() : await work() }
    }

    private func work() async {
        while !queue.isEmpty {
            let group = queue.removeFirst()
            guard done[group] == nil else { continue }
            let text = sentences.text(of: group, in: cues)
            let translation = try? await SubtitlePipeline.translate(text, from: source, to: target, context: [], with: translator)
            done[group] = translation ?? text
        }
        working = false
    }

    /// Batches of consecutive untranslated sentences from the cursor on (wrapping round to
    /// the start), so a seek moves the work to the new position.
    private func workWholeFile() async {
        guard let batcher = translator as? BatchTranslating else { return }
        let names = NameGlossary.names(in: cues.map { SubtitleFile.plainText($0.text) })
        let total = sentences.groups.count
        while let batch = nextBatch(size: batcher.batchSize) {
            onStatus(.translating(done: done.count, total: total, requests: requests))
            let lines = batch.map { sentences.text(of: $0, in: cues) }
            let context = (max(0, batch[0] - SentenceTranslation.contextLines)..<batch[0]).map { sentences.text(of: $0, in: cues) }
            do {
                let translations = try await batcher.translateBatch(lines, from: source, to: target, context: context, names: names)
                for (group, translation) in zip(batch, translations) { done[group] = translation }
                requests += 1
                cursor = batch.last! + 1
                saveCache()
            } catch {
                stopped = true
                working = false
                let progress = "Translated \(done.count) of \(total) lines; the rest will continue next time"
                if case CloudError.quotaExhausted = error {
                    onStatus(.stopped("Daily limit reached. \(progress) (or switch to offline MADLAD)."))
                } else if !(error is CancellationError) {
                    onStatus(.stopped("\(error.localizedDescription) \(progress)."))
                }
                return
            }
        }
        onStatus(.finished(total: total))
        working = false
    }

    private func nextBatch(size: Int) -> [Int]? {
        let total = sentences.groups.count
        guard done.count < total else { return nil }
        let start = (cursor..<total).first { done[$0] == nil } ?? (0..<total).first { done[$0] == nil }!
        var batch = [start]
        while batch.count < size, batch.last! + 1 < total, done[batch.last! + 1] == nil { batch.append(batch.last! + 1) }
        return batch
    }

    private func saveCache() {
        guard let cacheURL else { return }
        let translated = SentenceTranslation.cues(done, sentences: sentences, cues: cues)
        try? SubtitleFile.srt(translated).write(to: cacheURL, atomically: true, encoding: .utf8)
    }

    /// Where a whole-file run may keep its translations: "Movie.my.srt" next to the file,
    /// unless a different file (other timings) already has that name.
    static func cacheURL(for input: URL, cues: [SubtitleCue], sentences: SubtitleSentences, target: String) -> URL? {
        let url = SubtitleFile.translationURL(for: input, target: target)
        guard url.standardizedFileURL != input.standardizedFileURL else { return nil }
        if !FileManager.default.fileExists(atPath: url.path) { return url }
        return existingTranslations(for: input, cues: cues, sentences: sentences, target: target).isEmpty ? nil : url
    }

    /// Reuses a translated file made earlier ("Movie.my.srt" next to "Movie.en.srt"), by
    /// sentence group, so nothing has to be translated again. Works with copies whose cues
    /// match one to one, copies that joined split sentences, and partial copies (a run that
    /// hit a daily limit): groups missing from the copy are simply not returned. A file
    /// whose timings don't line up with this one is ignored.
    static func existingTranslations(for input: URL, cues: [SubtitleCue], sentences: SubtitleSentences,
                                     target: String) -> [Int: String] {
        let candidate = SubtitleFile.translationURL(for: input, target: target)
        guard candidate.standardizedFileURL != input.standardizedFileURL,
              let translated = try? SubtitleFile.read(candidate) else { return [:] }
        let spans = sentences.groups.map { (start: cues[$0.first!].start, end: cues[$0.last!].end) }
        var parts: [Int: [String]] = [:]
        var group = 0
        for cue in translated {
            // The group this cue starts in: its start must be within the group's span.
            while group < spans.count, cue.start >= spans[group].end - 0.01 { group += 1 }
            guard group < spans.count, cue.start > spans[group].start - 0.01 else { return [:] }
            // A group's translation starts with a cue at the group's start.
            if parts[group] == nil, abs(cue.start - spans[group].start) > 0.01 { return [:] }
            parts[group, default: []].append(cue.text)
        }
        return parts.mapValues { $0.joined(separator: " ") }
    }
}

enum SubtitleLanguage {
    /// Detects a subtitle file's language from its text (on device, NaturalLanguage).
    static func detect(_ cues: [SubtitleCue]) -> String? {
        let sample = cues.prefix(200).map { SubtitleFile.plainText($0.text) }.joined(separator: " ")
        guard let language = NLLanguageRecognizer.dominantLanguage(for: sample) else { return nil }
        let code = String(language.rawValue.prefix(2)) // "zh-Hans" → "zh"
        return Languages.isSupported(code) ? code : nil
    }
}
