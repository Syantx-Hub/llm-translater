import Foundation

/// Turns speech segments into subtitle updates: ASR one segment at a time, then
/// translation in a separate ordered chain so the next segment's ASR can run meanwhile.
///
/// Finals always run; drafts only run when nothing else is queued, and only the newest
/// draft is kept, so a slow Mac shows fewer drafts rather than falling behind.
actor SubtitlePipeline {
    enum Update {
        /// Grey in-progress text in the source language ("" clears it).
        case draft(String)
        case line(original: String, translation: String)
        case detectedLanguage(String)
        case error(String)
    }

    private let transcriber: Transcriber
    private let translator: Translator
    private let target: String
    private let emit: @Sendable (Update) -> Void

    /// nil until auto-detection settles on the language of the first line.
    private var source: String?
    private var finals: [[Float]] = []
    private var latestDraft: [Float]?
    private var draining = false
    private var context: [String] = []
    private var translationChain: Task<Void, Never>?

    init(transcriber: Transcriber, translator: Translator, source: String?, target: String,
         emit: @escaping @Sendable (Update) -> Void) {
        self.transcriber = transcriber
        self.translator = translator
        self.source = source
        self.target = target
        self.emit = emit
    }

    func submit(_ event: SpeechSegmenter.Event) {
        switch event {
        case .final(let samples):
            finals.append(samples)
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

    private func draft(_ samples: [Float]) async {
        guard let result = try? await transcriber.transcribe(samples, language: source) else { return }
        // A final that arrived while decoding supersedes this draft.
        guard finals.isEmpty else { return }
        emit(.draft(result.text))
    }

    private func finalize(_ samples: [Float]) async {
        let result: Transcriber.Result?
        do {
            result = try await transcriber.transcribe(samples, language: source)
        } catch {
            emit(.error(error.localizedDescription))
            return
        }
        guard let result else {
            emit(.draft(""))
            return
        }
        if source == nil, Languages.isSupported(result.language) {
            source = result.language
            emit(.detectedLanguage(result.language))
        }
        emit(.draft(result.text))

        let from = source ?? result.language
        let lineContext = context
        context.append(result.text)
        if context.count > 4 { context.removeFirst() }

        let previous = translationChain
        translationChain = Task { [translator, target, emit] in
            await previous?.value
            guard from != target, Languages.isSupported(from) else {
                emit(.line(original: result.text, translation: result.text))
                return
            }
            do {
                let translation = try await translator.translate(result.text, from: from, to: target, context: lineContext)
                emit(.line(original: result.text, translation: translation))
            } catch {
                emit(.error(error.localizedDescription))
                emit(.line(original: result.text, translation: result.text))
            }
        }
    }
}
