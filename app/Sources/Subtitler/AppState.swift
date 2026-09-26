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
        mode == .translate ? targetLanguage : (detectedLanguage ?? (sourceLanguage == Languages.auto ? "en" : sourceLanguage))
    }

    var isRunning: Bool { phase == .running }
    var isBusy: Bool { if case .loading = phase { true } else { false } }

    let models: ModelStore
    let style: CaptionStyle
    private let defaults = UserDefaults.standard
    private let transcriber = Transcriber()
    private var loadedModel: String?
    private var capture: AudioCapture?
    private var translator: Translator?
    private var eventPump: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private lazy var overlay = OverlayController(state: self, style: style)

    init(models: ModelStore, style: CaptionStyle) {
        self.models = models
        self.style = style
        sourceLanguage = defaults.string(forKey: "sourceLanguage") ?? Languages.auto
        targetLanguage = defaults.string(forKey: "targetLanguage") ?? "my"
        // Older builds expressed transcribe-only as the "off" translation selection.
        mode = defaults.string(forKey: "mode").flatMap(CaptionMode.init)
            ?? (models.selectedTranslation == ModelStore.translationOff ? .transcribe : .translate)
        responsiveness = defaults.string(forKey: "responsiveness").flatMap(Responsiveness.init) ?? .balanced
        translateDrafts = defaults.object(forKey: "translateDrafts") as? Bool ?? true
    }

    func start() {
        guard phase == .idle || isFailed else { return }
        Task { await run() }
    }

    func stop() {
        Task { await teardown() }
        phase = .idle
    }

    private var isFailed: Bool { if case .failed = phase { true } else { false } }

    private func run() async {
        previewOnScreen = false
        lastError = nil
        detectedLanguage = nil
        latency = nil
        do {
            try await loadSpeechModel()

            let translator: Translator
            if mode == .translate {
                phase = .loading("Starting translator (loading the model can take a minute)…")
                translator = await startTranslator()
            } else {
                translator = PassthroughTranslator()
            }
            self.translator = translator

            phase = .loading("Starting audio capture…")
            let pipeline = SubtitlePipeline(
                transcriber: transcriber, translator: translator,
                source: sourceLanguage == Languages.auto ? nil : sourceLanguage,
                // Transcribe-only uses the passthrough translator, so the target is unused.
                target: mode == .translate ? targetLanguage : "",
                translateDrafts: mode == .translate && translateDrafts,
                emit: { [weak self] update in DispatchQueue.main.async { self?.apply(update) } })

            // One ordered stream from the capture queue to the pipeline actor.
            let (events, sink) = AsyncStream<SpeechSegmenter.Event>.makeStream()
            let segmenter = SpeechSegmenter(tuning: responsiveness.tuning)
            segmenter.onEvent = { sink.yield($0) }
            eventPump = Task {
                for await event in events { await pipeline.submit(event) }
            }

            let capture = AudioCaptureFactory.make()
            capture.onSamples = { segmenter.append($0) }
            capture.onStop = { [weak self] error in
                DispatchQueue.main.async {
                    self?.fail(error?.localizedDescription ?? "Audio capture stopped.")
                }
            }
            try await capture.start()
            self.capture = capture

            phase = .running
            overlay.show()
        } catch {
            await teardown()
            fail(error.localizedDescription)
        }
    }

    private func loadSpeechModel() async throws {
        guard let model = models.speechModel else { throw SetupError.noSpeechModel }
        guard loadedModel != model.id else { return }
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

    private func teardown() async {
        eventPump?.cancel()
        eventPump = nil
        await capture?.stop()
        capture = nil
        await translator?.stop()
        translator = nil
        hideTask?.cancel()
        lines = []
        draft = nil
        if !previewOnScreen { overlay.hide() }
    }

    private func fail(_ message: String) {
        guard phase != .idle else { return }
        Task { await teardown() }
        phase = .failed(message)
    }

    private func apply(_ update: SubtitlePipeline.Update) {
        guard isRunning else { return }
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
    /// Sample captions in the caption language, for previews and `--snapshot`.
    var sampleLines: [SubtitleLine] {
        let original = "I was waiting for you at the station."
        let translations = [
            "my": "ဘူတာမှာ မင်းကို စောင့်နေခဲ့တာ။",
            "ko": "역에서 너를 기다리고 있었어.",
            "ja": "駅で君を待っていたんだ。",
            "zh": "我一直在车站等你。",
            "th": "ฉันรอเธออยู่ที่สถานี",
        ]
        let translation = mode == .translate ? translations[targetLanguage] ?? original : original
        return [SubtitleLine(original: original, translation: translation)]
    }

    var sampleDraft: DraftCaption {
        mode == .translate && targetLanguage == "my"
            ? DraftCaption(text: "စိတ်မပူပါနဲ့၊ အစ်ကိုက အိမ်ကို လိုက်ပို့ပေးမယ်။", isTranslation: true)
            : DraftCaption(text: "Don't worry, my brother will drive us home.", isTranslation: false)
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
