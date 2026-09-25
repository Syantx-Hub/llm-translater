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
    @Published private(set) var draft = ""
    @Published private(set) var detectedLanguage: String?
    @Published private(set) var lastError: String?

    // Settings, persisted in UserDefaults. Changes apply on the next start.
    @Published var sourceLanguage: String { didSet { save(sourceLanguage, "sourceLanguage") } }
    @Published var targetLanguage: String { didSet { save(targetLanguage, "targetLanguage") } }
    @Published var fontSize: Double { didSet { save(fontSize, "fontSize") } }
    @Published var showOriginal: Bool { didSet { save(showOriginal, "showOriginal") } }

    var isRunning: Bool { phase == .running }
    var isBusy: Bool { if case .loading = phase { true } else { false } }

    let models: ModelStore
    private let defaults = UserDefaults.standard
    private let transcriber = Transcriber()
    private var loadedModel: String?
    private var capture: SystemAudioCapture?
    private var translator: Translator?
    private var eventPump: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private lazy var overlay = OverlayController(state: self)

    init(models: ModelStore) {
        self.models = models
        sourceLanguage = defaults.string(forKey: "sourceLanguage") ?? Languages.auto
        targetLanguage = defaults.string(forKey: "targetLanguage") ?? "my"
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 34
        showOriginal = defaults.object(forKey: "showOriginal") as? Bool ?? true
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
        lastError = nil
        detectedLanguage = nil
        do {
            try await loadSpeechModel()

            phase = .loading("Starting translator (loading the model can take a minute)…")
            let translator = await startTranslator()
            self.translator = translator

            phase = .loading("Starting audio capture…")
            let pipeline = SubtitlePipeline(
                transcriber: transcriber, translator: translator,
                source: sourceLanguage == Languages.auto ? nil : sourceLanguage,
                target: targetLanguage,
                emit: { [weak self] update in DispatchQueue.main.async { self?.apply(update) } })

            // One ordered stream from the capture queue to the pipeline actor.
            let (events, sink) = AsyncStream<SpeechSegmenter.Event>.makeStream()
            let segmenter = SpeechSegmenter()
            segmenter.onEvent = { sink.yield($0) }
            eventPump = Task {
                for await event in events { await pipeline.submit(event) }
            }

            let capture = SystemAudioCapture()
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
        draft = ""
        overlay.hide()
    }

    private func fail(_ message: String) {
        guard phase != .idle else { return }
        Task { await teardown() }
        phase = .failed(message)
    }

    private func apply(_ update: SubtitlePipeline.Update) {
        guard isRunning else { return }
        switch update {
        case .draft(let text):
            draft = text
        case .line(let original, let translation):
            draft = ""
            lines.append(SubtitleLine(original: original, translation: translation))
            if lines.count > 2 { lines.removeFirst(lines.count - 2) }
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
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.lines = []
        }
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}

extension AppState {
    /// Sample subtitles for `--snapshot`.
    func previewLines() {
        lines = [SubtitleLine(original: "I was waiting for you at the station.", translation: "ဘူတာမှာ မင်းကို စောင့်နေခဲ့တာ။")]
        draft = "Don't worry, my brother will drive us home."
    }
}
