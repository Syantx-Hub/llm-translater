import AppKit
import Foundation

enum SetupError: LocalizedError {
    case noSpeechModel
    case appleSpeechNeedsWhisper(String)

    var errorDescription: String? {
        switch self {
        case .noSpeechModel: "Download a speech model in Models to start."
        case .appleSpeechNeedsWhisper(let reason): "\(reason) Download a Whisper model in Models for this."
        }
    }
}

/// Which recognizer a session uses.
private enum SpeechEngine {
    /// `handOver`: auto-detect with Whisper, then switch to Apple Speech.
    case whisper(ModelInfo, handOver: Bool)
    case apple(Locale)
}

/// Where captured audio goes. The capture callback reads it on the audio queue while the
/// session can switch recognizers on the main thread, so it is guarded by a lock.
final class SampleRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (([Float]) -> Void)?

    func route(to sink: @escaping ([Float]) -> Void) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    func send(_ samples: [Float]) {
        lock.lock()
        let sink = self.sink
        lock.unlock()
        sink?(samples)
    }
}

enum CaptionMode: String, CaseIterable, Identifiable {
    case translate, transcribe
    var id: String { rawValue }
    var label: String { self == .translate ? "Translate" : "Transcribe only" }
}

enum Responsiveness: String, CaseIterable, Identifiable {
    case fast, balanced, accurate
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var detail: String {
        switch self {
        case .fast: "Lines appear soonest; sentences may be split more often."
        case .balanced: "A good default for films and videos."
        case .accurate: "Waits for longer pauses, so Whisper hears whole sentences."
        }
    }

    var tuning: SpeechSegmenter.Tuning {
        switch self {
        case .fast: .fast
        case .balanced: .balanced
        case .accurate: .accurate
        }
    }
}

struct SubtitleLine: Identifiable, Equatable {
    let id = UUID()
    let original: String
    let translation: String
}

/// Owns the live session (capture → segmenter → pipeline) and everything the UI shows.
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading(String)
        case running
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lines: [SubtitleLine] = []
    @Published private(set) var draft: DraftCaption?
    @Published private(set) var detectedLanguage: String?
    @Published private(set) var lastError: String?
    /// Seconds from the end of speech to the line on screen, smoothed.
    @Published private(set) var latency: TimeInterval?
    /// Shows sample captions on screen while the Captions window is open.
    @Published var previewOnScreen = false { didSet { updatePreview() } }

    // Settings, persisted in UserDefaults. Changes apply on the next start.
    @Published var sourceLanguage: String { didSet { save(sourceLanguage, "sourceLanguage") } }
    @Published var targetLanguage: String { didSet { save(targetLanguage, "targetLanguage"); updatePreview() } }
    @Published var mode: CaptionMode { didSet { save(mode.rawValue, "mode"); updatePreview() } }
    @Published var responsiveness: Responsiveness { didSet { save(responsiveness.rawValue, "responsiveness") } }
    /// With Apple Speech and Auto-detect: detect the language with Whisper on the first
    /// line, then switch to Apple Speech for the rest of the session.
    @Published var appleAutoHandover: Bool { didSet { save(appleAutoHandover, "appleAutoHandover") } }
    /// Informational status (e.g. which engine is in use), shown less loudly than errors.
    @Published private(set) var notice: String?

    /// The language captions are written in: the target, or the spoken language when only transcribing.
    var captionLanguage: String {
        if isRunning {
            return sessionCaptionLanguage ?? spokenLanguage
        }
        return mode == .translate ? targetLanguage : spokenLanguage
    }

    private var spokenLanguage: String {
        detectedLanguage ?? (sourceLanguage == Languages.auto ? "en" : sourceLanguage)
    }

    var isRunning: Bool { phase == .running }
    var isBusy: Bool { if case .loading = phase { true } else { false } }

    let models: ModelStore
    let style: CaptionStyle
    private let defaults = UserDefaults.standard
    private let transcriber = Transcriber()
    private var loadedModel: String?
    /// Bumped on every start, stop and failure; work from an older session is ignored.
    private var session = 0
    private var runTask: Task<Void, Never>?
    private var resources = Resources()
    /// The caption language the running session was started with.
    private var sessionCaptionLanguage: String?
    private var hideTask: Task<Void, Never>?
    private lazy var overlay = OverlayController(state: self, style: style)

    init(models: ModelStore, style: CaptionStyle) {
        self.models = models
        self.style = style
        sourceLanguage = defaults.string(forKey: "sourceLanguage") ?? Languages.auto
        targetLanguage = defaults.string(forKey: "targetLanguage") ?? "my"
        // Older builds expressed transcribe-only as the "off" translation selection.
        mode = defaults.string(forKey: "mode").flatMap(CaptionMode.init)
            ?? (models.legacyTranscribeOnly ? .transcribe : .translate)
        responsiveness = defaults.string(forKey: "responsiveness").flatMap(Responsiveness.init) ?? .balanced
        appleAutoHandover = defaults.object(forKey: "appleAutoHandover") as? Bool ?? true
    }

    /// Starts a session. The phase flips to loading immediately, so a double click can't
    /// start two sessions.
    func start() {
        guard phase == .idle || isFailed else { return }
        session += 1
        let id = session
        phase = .loading("Preparing…")
        runTask = Task { await run(id) }
    }

    /// Stops the running session, or cancels one that is still loading.
    func stop() {
        session += 1
        runTask?.cancel()
        runTask = nil
        phase = .idle
        endSession()
    }

    private var isFailed: Bool { if case .failed = phase { true } else { false } }

    /// Everything a live session owns, released together.
    private struct Resources {
        var pipeline: SubtitlePipeline?
        var capture: AudioCapture?
        var translator: Translator?
        var eventPump: Task<Void, Never>?
        /// Stops the streaming recognizer (Apple Speech), if the session uses one.
        var stopRecognizer: (@Sendable () async -> Void)?
        var recognizerPump: Task<Void, Never>?
        var router = SampleRouter()
        /// Set while a Whisper session waits to hand over to Apple Speech.
        var handOverPending = false
    }

    private func run(_ id: Int) async {
        previewOnScreen = false
        lastError = nil
        notice = nil
        detectedLanguage = nil
        latency = nil
        // Snapshot the settings this session runs with; the pickers are disabled meanwhile.
        let sessionMode = mode
        let sessionTarget = targetLanguage
        var owned = Resources()
        do {
            let engine = try await chooseSpeechEngine()
            if case .whisper(let model, _) = engine { try await loadSpeechModel(model) }
            try checkSession(id)
            // The selected model, plus the Whisper fallback if Apple Speech handed over.
            var loaded: Set<String> = [models.speechModel?.id].compactMap { $0 }.reduce(into: []) { $0.insert($1) }
            if case .whisper(let model, _) = engine { loaded.insert(model.id) }
            models.inUse = loaded

            let translator: Translator
            if sessionMode == .translate {
                phase = .loading("Starting translator (loading the model can take a minute)…")
                translator = await startTranslator()
                if let selection = ModelCatalog.model(id: models.selectedTranslation), !(translator is PassthroughTranslator) {
                    models.inUse.insert(selection.id)
                }
            } else {
                translator = PassthroughTranslator()
            }
            owned.translator = translator
            try checkSession(id)

            phase = .loading("Starting audio capture…")
            let pipeline = SubtitlePipeline(
                transcriber: transcriber, translator: translator,
                source: sourceLanguage == Languages.auto ? nil : sourceLanguage,
                target: sessionMode == .translate ? sessionTarget : nil,
                // Finished sentences are translated in the background while someone speaks.
                translateDrafts: sessionMode == .translate,
                emit: { [weak self] update in
                    DispatchQueue.main.async { self?.apply(update, session: id) }
                })
            owned.pipeline = pipeline

            let capture = AudioCaptureFactory.make()
            let router = owned.router
            capture.onSamples = { router.send($0) }
            switch engine {
            case .whisper(_, let handOver):
                owned.handOverPending = handOver
                // One ordered stream from the capture queue to the pipeline actor.
                let (events, sink) = AsyncStream<SpeechSegmenter.Event>.makeStream()
                let segmenter = SpeechSegmenter(tuning: responsiveness.tuning)
                segmenter.onEvent = { sink.yield($0) }
                owned.eventPump = Task {
                    for await event in events { await pipeline.submit(event) }
                }
                router.route { segmenter.append($0) }
            case .apple(let locale):
                phase = .loading("Preparing Apple Speech for \(Self.name(of: locale))…")
                try await startAppleSpeech(locale, pipeline: pipeline, session: id, into: &owned, showProgress: true)
                try checkSession(id)
            }
            capture.onStop = { [weak self] error in
                DispatchQueue.main.async {
                    guard self?.session == id else { return }
                    self?.fail(error?.localizedDescription ?? "Audio capture stopped.")
                }
            }
            owned.capture = capture
            try await capture.start()
            try checkSession(id)

            resources = owned
            sessionCaptionLanguage = sessionMode == .translate ? sessionTarget : nil
            phase = .running
            overlay.show()
        } catch {
            await release(owned)
            guard session == id else { return } // stopped or superseded: nothing to report
            models.inUse = []
            phase = .failed(error.localizedDescription)
        }
    }

    private func checkSession(_ id: Int) throws {
        if session != id || Task.isCancelled { throw CancellationError() }
    }

    private static func name(of locale: Locale) -> String {
        Locale.current.localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "") ?? "the language"
    }

    /// Starts Apple Speech and routes captured audio to it. Used at session start and when
    /// a Whisper session hands over after detecting the language.
    private func startAppleSpeech(_ locale: Locale, pipeline: SubtitlePipeline, session id: Int,
                                  into owned: inout Resources, showProgress: Bool) async throws {
        guard #available(macOS 26.0, *) else { throw SetupError.noSpeechModel }
        let language = Self.name(of: locale)
        let recognizer = AppleSpeechRecognizer(locale: locale)
        let (events, sink) = AsyncStream<AppleSpeechRecognizer.Event>.makeStream()
        recognizer.onEvent = { sink.yield($0) }
        owned.stopRecognizer = { await recognizer.stop() }
        try await recognizer.start { [weak self] fraction in
            DispatchQueue.main.async {
                guard let self, self.session == id else { return }
                let message = "Downloading Apple Speech for \(language)… \(Int(fraction * 100))%"
                if showProgress { self.phase = .loading(message) } else { self.notice = message }
            }
        }
        owned.recognizerPump = Task {
            for await event in events {
                switch event {
                case .volatile(let text): await pipeline.submitVolatile(text)
                case .final(let text, let ended): await pipeline.submitFinal(text, speechEndedAt: ended)
                }
            }
        }
        owned.router.route { recognizer.append($0) }
    }

    /// The first final line revealed the language: switch to Apple Speech if it can hear it.
    private func handOverToAppleSpeech(_ code: String, session id: Int) async {
        guard resources.handOverPending, let pipeline = resources.pipeline else { return }
        resources.handOverPending = false
        let name = Languages.all.first { $0.code == code }?.name ?? code
        guard let locale = await AppleSpeech.locale(for: code) else {
            notice = "Detected \(name), which Apple Speech can't recognise — staying on Whisper."
            return
        }
        notice = "Detected \(name) — switching to Apple Speech…"
        var updated = resources
        do {
            try await startAppleSpeech(locale, pipeline: pipeline, session: id, into: &updated, showProgress: false)
        } catch {
            await updated.stopRecognizer?()
            notice = "Couldn't start Apple Speech (\(error.localizedDescription)) — staying on Whisper."
            return
        }
        guard session == id else {
            await release(updated)
            return
        }
        // Whisper's segmenter no longer gets audio; its queued work still finishes.
        resources.stopRecognizer = updated.stopRecognizer
        resources.recognizerPump = updated.recognizerPump
        notice = "Detected \(name) — using Apple Speech."
    }

    /// Apple Speech when it's selected and can hear the spoken language; otherwise Whisper.
    /// Apple Speech can't auto-detect the language, so auto-detect also uses Whisper.
    private func chooseSpeechEngine() async throws -> SpeechEngine {
        guard let selected = models.speechModel else { throw SetupError.noSpeechModel }
        guard selected.isBuiltIn else { return .whisper(selected, handOver: false) }
        let spoken = Languages.all.first { $0.code == sourceLanguage }?.name
        if sourceLanguage != Languages.auto, let locale = await AppleSpeech.locale(for: sourceLanguage) {
            return .apple(locale)
        }
        let reason = spoken.map { "Apple Speech can't recognise \($0)." }
            ?? "Apple Speech can't auto-detect the spoken language — choose it to use Apple Speech."
        let whisper = ModelCatalog.whisper.filter(models.isInstalled)
        guard let fallback = whisper.first(where: { $0.id == ModelCatalog.recommendedWhisper }) ?? whisper.first else {
            throw SetupError.appleSpeechNeedsWhisper(reason)
        }
        if sourceLanguage == Languages.auto, appleAutoHandover {
            notice = "Detecting the language with \(fallback.name), then switching to Apple Speech."
            return .whisper(fallback, handOver: true)
        }
        notice = "\(reason) Using \(fallback.name)."
        return .whisper(fallback, handOver: false)
    }

    private func loadSpeechModel(_ model: ModelInfo) async throws {
        if loadedModel == model.id, await transcriber.isLoaded { return }
        loadedModel = nil // a failed load must not look like the old model is still loaded
        phase = .loading("Loading \(model.name) (the first run on this Mac can take a few minutes)…")
        try await transcriber.load(model: model.id, folder: ModelFiles.localURL(for: model))
        await transcriber.warmUp()
        loadedModel = model.id
    }

    /// Falls back to showing the original text, so subtitles still work without a translator.
    private func startTranslator() async -> Translator {
        do {
            let translator = try TranslatorFactory.make(selection: models.selectedTranslation)
            do {
                try await translator.start()
                return translator
            } catch {
                await translator.stop()
                throw error
            }
        } catch {
            lastError = "\(error.localizedDescription) Showing original text."
            return PassthroughTranslator()
        }
    }

    /// Ends the current session's UI state and releases its resources in the background.
    /// Fields are cleared before any await, so a new session started meanwhile is untouched.
    private func endSession() {
        let owned = resources
        resources = Resources()
        sessionCaptionLanguage = nil
        models.inUse = []
        hideTask?.cancel()
        lines = []
        draft = nil
        if !previewOnScreen { overlay.hide() }
        Task { await release(owned) }
    }

    private func release(_ owned: Resources) async {
        await owned.pipeline?.cancel()
        await owned.stopRecognizer?()
        owned.recognizerPump?.cancel()
        owned.eventPump?.cancel()
        await owned.capture?.stop()
        await owned.translator?.stop()
    }

    private func fail(_ message: String) {
        guard phase != .idle else { return }
        session += 1
        runTask?.cancel()
        runTask = nil
        phase = .failed(message)
        endSession()
    }

    private func apply(_ update: SubtitlePipeline.Update, session id: Int) {
        guard isRunning, id == session else { return }
        switch update {
        case .draft(let caption):
            draft = caption
        case .line(let original, let translation, let seconds):
            draft = nil
            lines.append(SubtitleLine(original: original, translation: translation))
            if lines.count > 3 { lines.removeFirst(lines.count - 3) }
            latency = latency.map { $0 * 0.7 + seconds * 0.3 } ?? seconds
            scheduleHide()
        case .detectedLanguage(let code):
            detectedLanguage = code
            if resources.handOverPending { Task { await handOverToAppleSpeech(code, session: id) } }
        case .error(let message):
            lastError = message
        }
    }

    /// Clear subtitles after a quiet spell so stale lines don't sit on screen.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.style.hideAfter ?? 6))
            guard !Task.isCancelled else { return }
            self?.lines = []
        }
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}

extension AppState {
    /// Sample captions in the caption language, for previews and `--snapshot`: three
    /// finished lines (so "Lines on screen" is visible) and a fourth as the draft.
    var sampleLines: [SubtitleLine] {
        Array(SampleCaptions.lines(language: captionLanguage, translating: mode == .translate).dropLast())
    }

    /// Transcribe-only shows words as they're spoken; translating shows finished lines only.
    var sampleDraft: DraftCaption? {
        guard mode == .transcribe else { return nil }
        let last = SampleCaptions.lines(language: captionLanguage, translating: false).last!
        return DraftCaption(text: last.original, isTranslation: false)
    }

    func previewLines() {
        lines = sampleLines
        draft = sampleDraft
    }

    fileprivate func updatePreview() {
        guard !isRunning, !isBusy else { return }
        if previewOnScreen {
            previewLines()
            overlay.show()
        } else {
            lines = []
            draft = nil
            overlay.hide()
        }
    }
}
