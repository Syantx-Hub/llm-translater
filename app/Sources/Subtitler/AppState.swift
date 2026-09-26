import AppKit
import Foundation

enum SetupError: LocalizedError {
    case noSpeechModel

    var errorDescription: String? {
        switch self {
        case .noSpeechModel: "Download a speech model in Models to start."
        }
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
    @Published var translateDrafts: Bool { didSet { save(translateDrafts, "translateDrafts") } }

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
        translateDrafts = defaults.object(forKey: "translateDrafts") as? Bool ?? true
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
    }

    private func run(_ id: Int) async {
        previewOnScreen = false
        lastError = nil
        detectedLanguage = nil
        latency = nil
        // Snapshot the settings this session runs with; the pickers are disabled meanwhile.
        let sessionMode = mode
        let sessionTarget = targetLanguage
        var owned = Resources()
        do {
            let speech = try await loadSpeechModel()
            try checkSession(id)
            models.inUse = [speech.id]

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
                translateDrafts: sessionMode == .translate && translateDrafts,
                emit: { [weak self] update in
                    DispatchQueue.main.async { self?.apply(update, session: id) }
                })
            owned.pipeline = pipeline

            // One ordered stream from the capture queue to the pipeline actor.
            let (events, sink) = AsyncStream<SpeechSegmenter.Event>.makeStream()
            let segmenter = SpeechSegmenter(tuning: responsiveness.tuning)
            segmenter.onEvent = { sink.yield($0) }
            owned.eventPump = Task {
                for await event in events { await pipeline.submit(event) }
            }

            let capture = AudioCaptureFactory.make()
            capture.onSamples = { segmenter.append($0) }
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

    private func loadSpeechModel() async throws -> ModelInfo {
        guard let model = models.speechModel else { throw SetupError.noSpeechModel }
        if loadedModel == model.id, await transcriber.isLoaded { return model }
        loadedModel = nil // a failed load must not look like the old model is still loaded
        phase = .loading("Loading \(model.name) (the first run on this Mac can take a few minutes)…")
        try await transcriber.load(model: model.id, folder: ModelFiles.localURL(for: model))
        await transcriber.warmUp()
        loadedModel = model.id
        return model
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

    var sampleDraft: DraftCaption {
        let last = SampleCaptions.lines(language: captionLanguage, translating: mode == .translate).last!
        return mode == .translate && translateDrafts
            ? DraftCaption(text: last.translation, isTranslation: true)
            : DraftCaption(text: last.original, isTranslation: false)
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
