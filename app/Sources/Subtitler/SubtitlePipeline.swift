import Foundation

/// `SUBTITLER_TRACE=1` prints pipeline timings to stderr, for latency work.
enum Trace {
    static let enabled = ProcessInfo.processInfo.environment["SUBTITLER_TRACE"] == "1"
    private static let start = Date()

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        fputs(String(format: "[trace %6.2f] ", Date().timeIntervalSince(start)) + message() + "\n", stderr)
    }

    static func seconds(_ samples: Int) -> String { String(format: "%.1fs", Double(samples) / 16_000) }
}

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

    private let transcriber: any SpeechTranscribing
    private let translator: Translator
    /// nil when only transcribing.
    private let target: String?
    private let translateDrafts: Bool
    private let emitUpdate: @Sendable (Update) -> Void
    private var cancelled = false

    /// nil until auto-detection settles on the language of the first line.
    private var source: String?
    /// Auto-detect keeps listening for a change of language (a new video), not just the first.
    private let autoDetect: Bool
    /// A different language heard in a row; two agreeing results switch to it.
    private var languageCandidate: (code: String, count: Int)?
    /// False while a streaming recognizer (Apple Speech) transcribes: Whisper then only
    /// checks which language is spoken.
    private var whisperTranscribes = true
    private var checkingLanguage = false
    private var lastLanguageCheck = Date.distantPast
    /// Shorter audio is too little to trust a language guess.
    private let minSamplesForLanguage = 24_000
    private var finals: [Final] = []
    private var latestDraft: (samples: [Float], isPause: Bool)?
    /// The draft being decoded. A regular draft is cancelled when the speaker pauses or the
    /// utterance ends, so the pause draft (whose result a final can reuse) runs right away.
    private var decodingDraft: (isPause: Bool, task: Task<Transcript?, Never>)?
    private var draining = false
    private var context: [String] = []
    private var translationChain: Task<Void, Never>?

    /// Bumped per final; draft results from an older utterance are dropped.
    private var utterance = 0
    /// The newest draft of the current utterance: how many samples it covered and its text.
    private var lastDraft: (count: Int, text: String)?
    private var pendingDraftText: String?
    private var draftTranslation: (text: String, task: Task<String?, Never>)?
    /// The latest finished draft translation of the current utterance.
    private var translatedDraft: (text: String, translation: String)?
    /// Recent sentence translations. Drafts translate sentences as soon as they're complete,
    /// so a final usually finds all but its last sentence here.
    private var sentenceCache: [String: String] = [:]
    private var sentenceCacheOrder: [String] = []
    /// The newest source text of the line being spoken.
    private var liveSource: String?

    /// Sentences of the current streaming phrase already shown as finished lines.
    private var committedSentences = 0

    init(transcriber: any SpeechTranscribing, translator: Translator, source: String?, target: String?,
         translateDrafts: Bool = true, emit: @escaping @Sendable (Update) -> Void) {
        self.transcriber = transcriber
        self.translator = translator
        self.source = source
        self.autoDetect = source == nil
        self.target = target
        self.translateDrafts = translateDrafts
        self.emitUpdate = emit
    }

    /// Stops all work: queued segments are dropped, in-flight translations cancelled, and
    /// nothing more is emitted. Call when the session ends.
    func cancel() {
        cancelled = true
        finals.removeAll()
        latestDraft = nil
        decodingDraft?.task.cancel()
        pendingDraftText = nil
        draftTranslation?.task.cancel()
        draftTranslation = nil
        translationChain?.cancel()
    }

    private func emit(_ update: Update) {
        guard !cancelled else { return }
        // When translating, only finished lines are shown: a sentence can't be translated
        // well before it ends, and the original words would be the wrong language.
        if target != nil, case .draft(let caption?) = update, !caption.text.isEmpty { return }
        emitUpdate(update)
    }

    /// Hands transcription to a streaming recognizer (or back). Whisper then only watches
    /// for a change of language.
    func setWhisperTranscribes(_ on: Bool) {
        whisperTranscribes = on
        if !on {
            finals.removeAll()
            latestDraft = nil
        }
    }

    func submit(_ event: SpeechSegmenter.Event) {
        guard !cancelled else { return }
        guard whisperTranscribes else {
            checkLanguage(of: event)
            return
        }
        switch event {
        case .final(let samples, let trailingSilence):
            finals.append(Final(samples: samples, trailingSilence: trailingSilence, endedAt: Date()))
            latestDraft = nil
            cancelRegularDraft()
        case .partial(let samples, let isPause):
            latestDraft = (samples, isPause)
            // A new pause means speech resumed since any draft now decoding, so that draft
            // is stale; free Whisper for this one.
            if isPause { decodingDraft?.task.cancel() }
        }
        guard !draining else { return }
        draining = true
        Task { await drain() }
    }

    /// Waits until every submitted segment has been transcribed and translated.
    func flush() async {
        // A draft translation clears `draftTranslation` once its result has been shown.
        while draining || draftTranslation != nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await translationChain?.value
    }

    private func drain() async {
        while !cancelled {
            if !finals.isEmpty {
                await finalize(finals.removeFirst())
            } else if let next = latestDraft {
                latestDraft = nil
                await draft(next.samples, isPause: next.isPause)
            } else {
                break
            }
        }
        draining = false
    }

    private var sourceNeedsTranslation: Bool {
        guard let from = source, let target else { return false }
        return from != target && Languages.isSupported(from)
    }

    private func detect(_ language: String) {
        guard source == nil, Languages.isSupported(language) else { return }
        source = language
        emit(.detectedLanguage(language))
    }

    /// Auto-detect: switch language when two results in a row agree on a new one, so one
    /// misheard line (a foreign word, a song) doesn't flip it.
    private func observeLanguage(_ language: String, samples: Int) {
        guard autoDetect, let current = source, samples >= minSamplesForLanguage, Languages.isSupported(language) else { return }
        guard language != current else {
            languageCandidate = nil
            return
        }
        let count = languageCandidate?.code == language ? languageCandidate!.count + 1 : 1
        languageCandidate = (language, count)
        guard count >= 2 else { return }
        Trace.log("language changed \(current) -> \(language)")
        languageCandidate = nil
        source = language
        context.removeAll()
        pendingDraftText = nil
        translatedDraft = nil
        emit(.detectedLanguage(language))
    }

    /// While Apple Speech transcribes, Whisper samples the language every few seconds.
    private func checkLanguage(of event: SpeechSegmenter.Event) {
        let samples: [Float]
        switch event {
        case .final(let audio, _): samples = audio
        case .partial(let audio, true): samples = audio
        case .partial: return
        }
        guard autoDetect, !checkingLanguage, samples.count >= minSamplesForLanguage,
              Date().timeIntervalSince(lastLanguageCheck) >= 3 else { return }
        checkingLanguage = true
        lastLanguageCheck = Date()
        Task {
            let language = try? await transcriber.detectLanguage(samples)
            checkingLanguage = false
            if let language, !cancelled { observeLanguage(language, samples: samples.count) }
        }
    }

    /// Auto-detect decodes without a language hint so a change of language is noticed.
    private var decodeLanguage: String? { autoDetect ? nil : source }

    // MARK: Drafts

    private func cancelRegularDraft() {
        if let decoding = decodingDraft, !decoding.isPause { decoding.task.cancel() }
    }

    private func draft(_ samples: [Float], isPause: Bool) async {
        let generation = utterance
        let t0 = Date()
        let task = Task { [transcriber, decodeLanguage] in try? await transcriber.transcribe(samples, language: decodeLanguage) }
        decodingDraft = (isPause, task)
        let result = await task.value
        decodingDraft = nil
        Trace.log("\(isPause ? "pause" : "draft") asr \(Trace.seconds(samples.count)) audio in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s\(task.isCancelled ? " (cancelled)" : "")")
        guard let result, !task.isCancelled, generation == utterance, !cancelled else { return }
        observeLanguage(result.language, samples: samples.count)
        // Remember it even if the final already arrived: when the final adds nothing but
        // silence, it reuses this text instead of decoding again.
        lastDraft = (samples.count, result.text)
        // A waiting final supersedes this draft on screen.
        guard finals.isEmpty else { return }
        // Language is only locked from finals: a half-second draft is too short to trust.
        showDraft(result.text)
    }

    /// Shows the words being spoken (transcribe-only), and when translating, starts
    /// translating finished sentences and clauses in the background so the line's
    /// translation is ready, or nearly, by the time the line ends. Half sentences are never
    /// translated: word order differs between languages (Burmese puts the verb last).
    private func showDraft(_ text: String) {
        liveSource = text
        emit(.draft(DraftCaption(text: text, isTranslation: false)))
        guard translateDrafts, sourceNeedsTranslation else { return }
        let (complete, _) = Self.stableSplit(text)
        if !complete.isEmpty, translatedDraft?.text != complete, draftTranslation?.text != complete {
            pendingDraftText = complete
            startDraftTranslation()
        }
    }

    /// At most one draft translation runs; a newer draft replaces the queued one.
    private func startDraftTranslation() {
        guard draftTranslation == nil, let text = pendingDraftText, let from = source, let target else { return }
        pendingDraftText = nil
        let generation = utterance
        let task = Task { [context] in
            let t0 = Date()
            let result = try? await self.translateCached(text, from: from, to: target, context: context)
            Trace.log("draft mt \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
            return result
        }
        draftTranslation = (text, task)
        Task {
            let translation = await task.value
            finishDraftTranslation(translation, generation: generation)
        }
    }

    private func finishDraftTranslation(_ translation: String?, generation: Int) {
        guard generation == utterance else { return }
        let text = draftTranslation?.text
        draftTranslation = nil
        if let translation, let text { translatedDraft = (text, translation) }
        startDraftTranslation()
    }

    // MARK: Text from streaming recognizers

    /// In-progress words from a streaming recognizer (Apple Speech), which does its own
    /// speech detection, so no segmenter or Whisper is involved.
    func submitVolatile(_ text: String) {
        guard !cancelled, !text.isEmpty else { return }
        var sentences = Self.sentences(in: text)
        sentences.removeFirst(min(committedSentences, sentences.count))
        // Apple Speech can keep a whole paragraph in one phrase. Once the speaker has moved
        // on to another sentence, the ones before it are finished: show them as lines now
        // rather than letting the live line grow until the phrase ends.
        if sentences.count > 1 {
            let finished = sentences.dropLast()
            committedSentences += finished.count
            sentences.removeFirst(finished.count)
            commitEarly(finished.joined(separator: " "))
        }
        showDraft(sentences.joined(separator: " "))
    }

    private func commitEarly(_ text: String) {
        let inFlight = draftTranslation
        utterance += 1
        pendingDraftText = nil
        draftTranslation = nil
        translatedDraft = nil
        liveSource = nil
        Trace.log("early commit of \(Self.sentences(in: text).count) sentence(s)")
        commit(text, endedAt: Date(), inFlight: inFlight, finished: nil)
    }

    /// A finished phrase from a streaming recognizer.
    func submitFinal(_ text: String, speechEndedAt: Date) {
        guard !cancelled, !text.isEmpty else { return }
        var sentences = Self.sentences(in: text)
        sentences.removeFirst(min(committedSentences, sentences.count))
        committedSentences = 0
        let text = sentences.joined(separator: " ")
        guard !text.isEmpty else {
            emit(.draft(nil))
            return
        }
        let inFlight = draftTranslation
        let finished = translatedDraft
        utterance += 1
        lastDraft = nil
        pendingDraftText = nil
        draftTranslation = nil
        translatedDraft = nil
        liveSource = nil
        Trace.log("stream final; mt \(finished?.text == text ? "reused" : inFlight?.text == text ? "in flight" : "needed")")
        commit(text, endedAt: speechEndedAt, inFlight: inFlight, finished: finished)
    }

    // MARK: Finals

    private func finalize(_ final: Final) async {
        // Claim this utterance's draft work before moving to the next utterance.
        let reusableText = lastDraft.flatMap { draft -> String? in
            let unheard = final.samples.count - draft.count
            return unheard >= 0 && unheard <= final.trailingSilence ? draft.text : nil
        }
        let inFlight = draftTranslation
        let finished = translatedDraft
        let lastDraftCount = lastDraft?.count
        utterance += 1
        lastDraft = nil
        pendingDraftText = nil
        draftTranslation = nil
        translatedDraft = nil
        liveSource = nil

        Trace.log("final \(Trace.seconds(final.samples.count)) waited \(String(format: "%.2f", Date().timeIntervalSince(final.endedAt)))s in queue; reuse \(reusableText != nil && source != nil ? "hit" : "miss") (draft covers \(lastDraftCount.map(Trace.seconds) ?? "-"), mt \(finished != nil ? "done" : inFlight != nil ? "running" : "none"))")
        let text: String
        if let reusableText, source != nil {
            text = reusableText
        } else {
            do {
                guard let result = try await transcriber.transcribe(final.samples, language: decodeLanguage) else {
                    emit(.draft(nil))
                    return
                }
                detect(result.language)
                observeLanguage(result.language, samples: final.samples.count)
                text = result.text
            } catch {
                emit(.error(error.localizedDescription))
                return
            }
        }

        commit(text, endedAt: final.endedAt, inFlight: inFlight, finished: finished)
    }

    /// Emits a finished line, reusing the draft's translation when it matches.
    private func commit(_ text: String, endedAt: Date,
                        inFlight: (text: String, task: Task<String?, Never>)?,
                        finished: (text: String, translation: String)?) {
        let from = source ?? ""
        let lineContext = context
        context.append(text)
        if context.count > 4 { context.removeFirst() }
        let translate = sourceNeedsTranslation
        let draftTask = inFlight?.text == text ? inFlight?.task : nil
        let finishedTranslation = finished?.text == text ? finished?.translation : nil
        // A draft translation of text the final doesn't start with only delays the final
        // (the translator does one thing at a time). One that does will fill the sentence
        // cache, so let it finish.
        if let inFlight, draftTask == nil, !text.hasPrefix(inFlight.text) { inFlight.task.cancel() }

        let previous = translationChain
        translationChain = Task { [target] in
            await previous?.value
            guard !Task.isCancelled else { return }
            let latency = { Date().timeIntervalSince(endedAt) }
            // `translate` is false when only transcribing (no target) or the pair is unsupported.
            guard translate, let target else {
                self.emit(.line(original: text, translation: text, latency: latency()))
                return
            }
            if let finishedTranslation {
                self.emit(.line(original: text, translation: finishedTranslation, latency: latency()))
                return
            }
            if let draftTask, let translation = await draftTask.value {
                self.emit(.line(original: text, translation: translation, latency: latency()))
                return
            }
            do {
                let translation = try await self.translateCached(text, from: from, to: target, context: lineContext)
                self.emit(.line(original: text, translation: translation, latency: latency()))
            } catch {
                guard !Task.isCancelled else { return }
                self.emit(.error(error.localizedDescription))
                self.emit(.line(original: text, translation: text, latency: latency()))
            }
        }
    }

    // MARK: Translation

    /// `translate(...)` with a per-sentence cache shared by drafts and finals.
    private func translateCached(_ text: String, from source: String, to target: String, context: [String]) async throws -> String {
        var parts: [String] = []
        for sentence in Self.sentences(in: text) {
            let key = "\(source)>\(target)|\(sentence)"
            if let cached = sentenceCache[key] {
                parts.append(cached)
                continue
            }
            let translation = try await translator.translate(sentence, from: source, to: target, context: context)
            sentenceCache[key] = translation
            sentenceCacheOrder.append(key)
            if sentenceCacheOrder.count > 64 { sentenceCache[sentenceCacheOrder.removeFirst()] = nil }
            parts.append(translation)
        }
        return parts.joined(separator: " ")
    }

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

    /// Splits text into the part made of finished sentences and clauses, safe to translate
    /// on its own, and the unfinished rest. A clause ends at a comma or semicolon once it has
    /// a few words (or characters, for CJK and Burmese).
    static func stableSplit(_ text: String) -> (complete: String, tail: String) {
        let enders: Set<Character> = [".", "!", "?", "。", "！", "？", "။"]
        let clauseMarks: Set<Character> = [",", ";", "，", "；", "、", "၊"]
        let unspaced: Set<Character> = ["。", "！", "？", "။", "，", "；", "、", "၊"]
        let characters = Array(text)
        var cut = 0
        var pieceStart = 0
        for (index, character) in characters.enumerated() {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            // End of text counts: "Where have you been?" is a finished sentence.
            let followedBySpace = next?.isWhitespace ?? true
            guard enders.contains(character) || clauseMarks.contains(character),
                  unspaced.contains(character) || followedBySpace else { continue }
            let piece = String(characters[pieceStart...index])
            let words = piece.split(whereSeparator: \.isWhitespace).count
            let longEnough = enders.contains(character) || words >= 3 || (unspaced.contains(character) && piece.count >= 6)
            if longEnough {
                cut = index + 1
                pieceStart = index + 1
            }
        }
        let complete = String(characters[..<cut]).trimmingCharacters(in: .whitespaces)
        let tail = String(characters[cut...]).trimmingCharacters(in: .whitespaces)
        return (complete, tail)
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
                // Very short Latin pieces ("Mr.", "Dr.") join the following sentence;
                // CJK and Burmese sentences can be that short on their own.
                if unspaced.contains(character) || trimmed.count >= 4 {
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
