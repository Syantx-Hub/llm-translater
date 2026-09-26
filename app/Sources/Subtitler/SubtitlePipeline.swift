import Foundation

/// Turns speech segments into subtitle updates: ASR one segment at a time, then
/// translation in a separate ordered chain so the next segment's ASR can run meanwhile.
///
/// Latency tricks, in order of impact:
/// - The segmenter drafts the moment the speaker pauses. If the pause becomes the end of
///   the utterance, that draft already heard every word, so the final reuses its text and
///   its (possibly in-flight) translation instead of decoding again.
/// - Drafts are translated while someone is still talking.
/// - Only the newest draft is kept, so a slow Mac shows fewer drafts rather than lagging.
actor SubtitlePipeline {
    enum Update: Equatable {
        /// In-progress text for the current utterance (nil clears it).
        case draft(DraftCaption?)
        /// `latency`: seconds from the end of speech to the translated line.
        case line(original: String, translation: String, latency: TimeInterval)
        case detectedLanguage(String)
        case error(String)
    }

    private struct Final {
        let samples: [Float]
        let trailingSilence: Int
        let endedAt: Date
    }

    private let transcriber: Transcriber
    private let translator: Translator
    private let target: String
    private let translateDrafts: Bool
    private let emit: @Sendable (Update) -> Void

    /// nil until auto-detection settles on the language of the first line.
    private var source: String?
    private var finals: [Final] = []
    private var latestDraft: [Float]?
    private var draining = false
    private var context: [String] = []
    private var translationChain: Task<Void, Never>?

    /// Bumped per final; draft results from an older utterance are dropped.
    private var utterance = 0
    /// The newest draft of the current utterance: how many samples it covered and its text.
    private var lastDraft: (count: Int, text: String)?
    private var pendingDraftText: String?
    private var draftTranslation: (text: String, task: Task<String?, Never>)?

    init(transcriber: Transcriber, translator: Translator, source: String?, target: String,
         translateDrafts: Bool = true, emit: @escaping @Sendable (Update) -> Void) {
        self.transcriber = transcriber
        self.translator = translator
        self.source = source
        self.target = target
        self.translateDrafts = translateDrafts
        self.emit = emit
    }

    func submit(_ event: SpeechSegmenter.Event) {
        switch event {
        case .final(let samples, let trailingSilence):
            finals.append(Final(samples: samples, trailingSilence: trailingSilence, endedAt: Date()))
            latestDraft = nil
        case .partial(let samples):
            latestDraft = samples
        }
        guard !draining else { return }
        draining = true
        Task { await drain() }
    }

    /// Waits until every submitted segment has been transcribed and translated.
    func flush() async {
        while draining {
            try? await Task.sleep(for: .milliseconds(50))
        }
        _ = await draftTranslation?.task.value
        await translationChain?.value
    }

    private func drain() async {
        while true {
            if !finals.isEmpty {
                await finalize(finals.removeFirst())
            } else if let samples = latestDraft {
                latestDraft = nil
                await draft(samples)
            } else {
                draining = false
                return
            }
        }
    }

    private var sourceNeedsTranslation: Bool {
        guard let from = source else { return false }
        return from != target && Languages.isSupported(from)
    }

    private func detect(_ language: String) {
        guard source == nil, Languages.isSupported(language) else { return }
        source = language
        emit(.detectedLanguage(language))
    }

    // MARK: Drafts

    private func draft(_ samples: [Float]) async {
        let generation = utterance
        guard let result = try? await transcriber.transcribe(samples, language: source) else { return }
        // A final that arrived while decoding supersedes this draft.
        guard finals.isEmpty, generation == utterance else { return }
        detect(result.language)
        lastDraft = (samples.count, result.text)
        guard translateDrafts, sourceNeedsTranslation else {
            emit(.draft(DraftCaption(text: result.text, isTranslation: false)))
            return
        }
        // Until the first translated draft lands, show the source text.
        if draftTranslation == nil { emit(.draft(DraftCaption(text: result.text, isTranslation: false))) }
        pendingDraftText = result.text
        startDraftTranslation()
    }

    /// At most one draft translation runs; a newer draft replaces the queued one.
    private func startDraftTranslation() {
        guard draftTranslation == nil, let text = pendingDraftText, let from = source else { return }
        pendingDraftText = nil
        let generation = utterance
        let task = Task { [translator, target, context] in
            try? await Self.translate(text, from: from, to: target, context: context, with: translator)
        }
        draftTranslation = (text, task)
        Task {
            let translation = await task.value
            finishDraftTranslation(translation, generation: generation)
        }
    }

    private func finishDraftTranslation(_ translation: String?, generation: Int) {
        guard generation == utterance else { return }
        draftTranslation = nil
        if let translation, finals.isEmpty {
            emit(.draft(DraftCaption(text: translation, isTranslation: true)))
        }
        startDraftTranslation()
    }

    // MARK: Finals

    private func finalize(_ final: Final) async {
        // Claim this utterance's draft work before moving to the next utterance.
        let reusableText = lastDraft.flatMap { draft -> String? in
            let unheard = final.samples.count - draft.count
            return unheard >= 0 && unheard <= final.trailingSilence ? draft.text : nil
        }
        let inFlight = draftTranslation
        utterance += 1
        lastDraft = nil
        pendingDraftText = nil
        draftTranslation = nil

        let text: String
        if let reusableText {
            text = reusableText
        } else {
            do {
                guard let result = try await transcriber.transcribe(final.samples, language: source) else {
                    emit(.draft(nil))
                    return
                }
                detect(result.language)
                text = result.text
            } catch {
                emit(.error(error.localizedDescription))
                return
            }
        }

        let from = source ?? ""
        let lineContext = context
        context.append(text)
        if context.count > 4 { context.removeFirst() }
        let translate = sourceNeedsTranslation
        let draftTask = inFlight?.text == text ? inFlight?.task : nil

        let previous = translationChain
        translationChain = Task { [translator, target, emit] in
            await previous?.value
            let latency = { Date().timeIntervalSince(final.endedAt) }
            guard translate else {
                emit(.line(original: text, translation: text, latency: latency()))
                return
            }
            if let draftTask, let translation = await draftTask.value {
                emit(.line(original: text, translation: translation, latency: latency()))
                return
            }
            do {
                let translation = try await Self.translate(text, from: from, to: target, context: lineContext, with: translator)
                emit(.line(original: text, translation: translation, latency: latency()))
            } catch {
                emit(.error(error.localizedDescription))
                emit(.line(original: text, translation: text, latency: latency()))
            }
        }
    }

    // MARK: Translation

    /// Translates sentence by sentence: short inputs are faster and keep MT models from
    /// looping or dropping clauses on long run-on transcripts.
    static func translate(_ text: String, from source: String, to target: String, context: [String],
                          with translator: Translator) async throws -> String {
        var parts: [String] = []
        for sentence in sentences(in: text) {
            parts.append(try await translator.translate(sentence, from: source, to: target, context: context))
        }
        return parts.joined(separator: " ")
    }

    /// Splits after sentence-ending punctuation followed by a space (so "3.5" and "Mr. X"
    /// stay mostly intact); CJK and Burmese enders split even without a space.
    static func sentences(in text: String) -> [String] {
        let spaced: Set<Character> = [".", "!", "?"]
        let unspaced: Set<Character> = ["。", "！", "？", "။"]
        let characters = Array(text)
        var sentences: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            current.append(character)
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            if unspaced.contains(character) || (spaced.contains(character) && next.isWhitespace) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                // Very short pieces ("Mr.", "Dr.") join the following sentence.
                if trimmed.count >= 4 {
                    sentences.append(trimmed)
                    current = ""
                }
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { sentences.append(rest) }
        return sentences.isEmpty ? [text] : sentences
    }
}
