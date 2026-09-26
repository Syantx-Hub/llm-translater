import AppKit
import Foundation

enum SetupError: LocalizedError {
    case noSpeechModel
    case appleSpeechNeedsWhisper(String)
    case noSubtitleFile

    var errorDescription: String? {
        switch self {
        case .noSpeechModel: "Download a speech model in Models to start."
        case .appleSpeechNeedsWhisper(let reason): "\(reason) Download a Whisper model in Models for this."
        case .noSubtitleFile: "Choose a subtitle file to follow."
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
    private var sinks: [([Float]) -> Void] = []

    /// Every sink gets every sample (e.g. Apple Speech transcribing while Whisper watches
    /// for a change of language).
    func route(to sinks: [([Float]) -> Void]) {
        lock.lock()
        self.sinks = sinks
        lock.unlock()
    }

    func send(_ samples: [Float]) {
        lock.lock()
        let sinks = self.sinks
        lock.unlock()
        for sink in sinks { sink(samples) }
    }
}

enum CaptionMode: String, CaseIterable, Identifiable {
    case translate, transcribe
    /// Show a subtitle file's lines, translated, in sync with what's playing.
    case synced
    var id: String { rawValue }

    var label: String {
        switch self {
        case .translate: "Translate"
        case .transcribe: "Transcribe only"
        case .synced: "Subtitle file"
        }
    }

    /// Captions are in the subtitle language (translated) rather than the spoken one.
    var translates: Bool { self != .transcribe }
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
    var id = UUID()
    let original: String
    let translation: String
}

extension SubtitleLine {
    /// A subtitle-file line keeps the same identity while it's on screen, so the overlay
    /// doesn't redraw it every tick.
    init(stableID index: Int, original: String, translation: String) {
        self.init(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                  UInt8(index >> 24 & 0xFF), UInt8(index >> 16 & 0xFF), UInt8(index >> 8 & 0xFF), UInt8(index & 0xFF))),
                  original: original, translation: translation)
    }
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
    // Subtitle-file sync.
    /// The subtitle file to follow in "Subtitle file" mode, and its lines.
    @Published private(set) var syncFile: URL?
    @Published private(set) var syncCues: [SubtitleCue] = []
    /// The file's language (detected from its text; changeable).
    @Published var syncLanguage: String = "en"
    @Published private(set) var syncStatus: SubtitleSync.Status?
    private var sync: SubtitleSync?
    private var syncTranslations: SyncTranslations?
    private var syncSentences: SubtitleSentences?
    /// A cloud engine translating the whole file: progress, or why it stopped.
    @Published private(set) var syncCloudStatus: SyncTranslations.Status?
    /// Moves the file's clock, in seconds: positive shows subtitles earlier. Applies live.
    @Published var syncOffset: Double { didSet { save(syncOffset, "syncOffset"); updateSyncedCaptions() } }
    private var syncTimer: Task<Void, Never>?

    /// Hide lines the recognizer was unsure about rather than show misheard words.
    @Published var hidesUnclearLines: Bool { didSet { save(hidesUnclearLines, "hidesUnclearLines") } }
    private var unclearCount = 0
    private var usesAppleSpeech = false

    /// The language captions are written in: the target, or the spoken language when only transcribing.
    var captionLanguage: String {
        if isRunning {
            return sessionCaptionLanguage ?? spokenLanguage
        }
        return mode.translates ? targetLanguage : spokenLanguage
    }

    private var spokenLanguage: String {
        detectedLanguage ?? (sourceLanguage == Languages.auto ? "en" : sourceLanguage)
    }

    var isRunning: Bool { phase == .running }
    var isBusy: Bool { if case .loading = phase { true } else { false } }

    let models: ModelStore
    let style: CaptionStyle
    private let defaults: UserDefaults
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

    init(models: ModelStore, style: CaptionStyle, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.models = models
        self.style = style
        sourceLanguage = defaults.string(forKey: "sourceLanguage") ?? Languages.auto
        targetLanguage = defaults.string(forKey: "targetLanguage") ?? "my"
        // Older builds expressed transcribe-only as the "off" translation selection.
        mode = defaults.string(forKey: "mode").flatMap(CaptionMode.init)
            ?? (models.legacyTranscribeOnly ? .transcribe : .translate)
        responsiveness = defaults.string(forKey: "responsiveness").flatMap(Responsiveness.init) ?? .balanced
        appleAutoHandover = defaults.object(forKey: "appleAutoHandover") as? Bool ?? true
        hidesUnclearLines = defaults.object(forKey: "hidesUnclearLines") as? Bool ?? true
        syncOffset = defaults.double(forKey: "syncOffset")
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
        /// Whisper's segmenter input, kept in auto-detect sessions to notice language changes.
        var segmenterSink: (([Float]) -> Void)?
        /// Auto-detect with Apple Speech selected: follow the language with Apple Speech
        /// where it can hear it, and Whisper where it can't.
        var followsLanguage = false
        /// The language Apple Speech is transcribing, when it is.
        var appleLanguage: String?
    }

    private func run(_ id: Int) async {
        previewOnScreen = false
        lastError = nil
        notice = nil
        unclearCount = 0
        detectedLanguage = nil
        latency = nil
        // Snapshot the settings this session runs with; the pickers are disabled meanwhile.
        let sessionMode = mode
        let sessionTarget = targetLanguage
        var owned = Resources()
        do {
            if sessionMode == .synced, syncCues.isEmpty { throw SetupError.noSubtitleFile }
            // Sync listens for the file's language; the other modes for the chosen one.
            let spoken = sessionMode == .synced ? syncLanguage : sourceLanguage
            let engine = try await chooseSpeechEngine(spoken: spoken)
            if case .whisper(let model, _) = engine { try await loadSpeechModel(model) }
            try checkSession(id)
            // The selected model, plus the Whisper fallback if Apple Speech handed over.
            var loaded: Set<String> = [models.speechModel?.id].compactMap { $0 }.reduce(into: []) { $0.insert($1) }
            if case .whisper(let model, _) = engine { loaded.insert(model.id) }
            models.inUse = loaded

            let translator: Translator
            if sessionMode.translates, !(sessionMode == .synced && syncLanguage == sessionTarget) {
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
                source: spoken == Languages.auto ? nil : spoken,
                // Sync only needs what was said; the file's lines are translated separately.
                target: sessionMode == .translate ? sessionTarget : nil,
                // Finished sentences are translated in the background while someone speaks.
                translateDrafts: sessionMode == .translate,
                // For syncing, even a shaky transcript can still match a line.
                hidesUnclearLines: hidesUnclearLines && sessionMode != .synced,
                emit: { [weak self] update in
                    DispatchQueue.main.async { self?.apply(update, session: id) }
                })
            owned.pipeline = pipeline

            let capture = AudioCaptureFactory.make()
            let router = owned.router
            if sessionMode == .synced {
                let silence = startSync(translator: translator, target: sessionTarget, session: id)
                capture.onSamples = { router.send($0); silence.append($0) }
            } else {
                capture.onSamples = { router.send($0) }
            }
            // A segmenter always runs: it feeds Whisper, or, while Apple Speech transcribes,
            // tells the pipeline when the speaker pauses and which language is spoken.
            let (events, sink) = AsyncStream<SpeechSegmenter.Event>.makeStream()
            let segmenter = SpeechSegmenter(tuning: responsiveness.tuning, detector: SileroVAD())
            segmenter.onEvent = { sink.yield($0) }
            owned.eventPump = Task {
                for await event in events { await pipeline.submit(event) }
            }
            let segmenterSink: ([Float]) -> Void = { segmenter.append($0) }
            owned.segmenterSink = segmenterSink
            switch engine {
            case .whisper(_, let handOver):
                owned.followsLanguage = handOver
                router.route(to: [segmenterSink])
            case .apple(let locale):
                phase = .loading("Preparing Apple Speech for \(Self.name(of: locale))…")
                let appleSink = try await startAppleSpeech(locale, pipeline: pipeline, session: id, into: &owned, showProgress: true)
                await pipeline.setWhisperTranscribes(false)
                router.route(to: [segmenterSink, appleSink])
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
            sessionCaptionLanguage = sessionMode.translates ? sessionTarget : nil
            usesAppleSpeech = { if case .apple = engine { true } else { false } }()
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

    /// Starts Apple Speech and returns where to send audio. Used at session start and when
    /// the session follows a change of language.
    private func startAppleSpeech(_ locale: Locale, pipeline: SubtitlePipeline, session id: Int,
                                  into owned: inout Resources, showProgress: Bool) async throws -> ([Float]) -> Void {
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
                case .final(let text, let ended, let confidence): await pipeline.submitFinal(text, speechEndedAt: ended, confidence: confidence)
                }
            }
        }
        return { recognizer.append($0) }
    }

    /// Language switches run one at a time, in order.
    private var languageSwitch: Task<Void, Never>?

    /// Auto-detect found a (new) language: transcribe it with Apple Speech if it can hear
    /// it, otherwise with Whisper, without stopping the session.
    private func followLanguage(_ code: String, session id: Int) {
        guard resources.followsLanguage else { return }
        let previous = languageSwitch
        languageSwitch = Task {
            await previous?.value
            await switchRecognizer(to: code, session: id)
        }
    }

    private func switchRecognizer(to code: String, session id: Int) async {
        guard session == id, let pipeline = resources.pipeline, let segmenterSink = resources.segmenterSink,
              resources.appleLanguage != code else { return }
        let name = Languages.all.first { $0.code == code }?.name ?? code
        let oldStop = resources.stopRecognizer
        let oldPump = resources.recognizerPump

        if let locale = await AppleSpeech.locale(for: code) {
            notice = "Detected \(name) — switching to Apple Speech…"
            var updated = Resources()
            do {
                let appleSink = try await startAppleSpeech(locale, pipeline: pipeline, session: id, into: &updated, showProgress: false)
                guard session == id else {
                    await updated.stopRecognizer?()
                    return
                }
                await pipeline.setWhisperTranscribes(false)
                // Whisper keeps listening, but only to notice the next change of language.
                resources.router.route(to: [segmenterSink, appleSink])
                resources.stopRecognizer = updated.stopRecognizer
                resources.recognizerPump = updated.recognizerPump
                resources.appleLanguage = code
                notice = "Detected \(name) — using Apple Speech."
            } catch {
                await updated.stopRecognizer?()
                await useWhisper(pipeline, segmenterSink)
                notice = "Detected \(name); Apple Speech couldn't start (\(error.localizedDescription)) — using Whisper."
            }
        } else {
            await useWhisper(pipeline, segmenterSink)
            notice = "Detected \(name) — using Whisper (Apple Speech can't recognise \(name))."
        }
        // Stop feeding the old recognizer's last words (the wrong language) into the pipeline.
        oldPump?.cancel()
        await oldStop?()
    }

    private func useWhisper(_ pipeline: SubtitlePipeline, _ segmenterSink: @escaping ([Float]) -> Void) async {
        resources.router.route(to: [segmenterSink])
        await pipeline.setWhisperTranscribes(true)
        resources.stopRecognizer = nil
        resources.recognizerPump = nil
        resources.appleLanguage = nil
    }

    /// Apple Speech when it's selected and can hear the spoken language; otherwise Whisper.
    /// Apple Speech can't auto-detect the language, so auto-detect also uses Whisper.
    private func chooseSpeechEngine(spoken language: String) async throws -> SpeechEngine {
        guard let selected = models.speechModel else { throw SetupError.noSpeechModel }
        guard selected.isBuiltIn else { return .whisper(selected, handOver: false) }
        let spoken = Languages.all.first { $0.code == language }?.name
        if language != Languages.auto, let locale = await AppleSpeech.locale(for: language) {
            return .apple(locale)
        }
        let reason = spoken.map { "Apple Speech can't recognise \($0)." }
            ?? "Apple Speech can't auto-detect the spoken language — choose it to use Apple Speech."
        let whisper = ModelCatalog.whisper.filter(models.isInstalled)
        guard let fallback = whisper.first(where: { $0.id == ModelCatalog.recommendedWhisper }) ?? whisper.first else {
            throw SetupError.appleSpeechNeedsWhisper(reason)
        }
        if language == Languages.auto, appleAutoHandover {
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
        syncTimer?.cancel()
        syncTimer = nil
        sync = nil
        syncTranslations = nil
        syncSentences = nil
        syncCloudStatus = nil
        syncStatus = nil
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
        case .draft where sync != nil:
            break // sync mode shows the file's lines, never live words
        case .draft(let caption):
            draft = caption
        case .line(let original, _, let seconds) where sync != nil:
            // Sync mode: what was heard only positions the file; its own lines are shown.
            let speechEnded = SubtitleSync.speechEnd(
                lineShownAt: Date(), latency: seconds,
                endSilence: usesAppleSpeech ? 0 : Double(responsiveness.tuning.endSilenceMS) / 1000)
            sync?.observe(original, speechEndedAt: speechEnded)
            updateSyncedCaptions()
        case .line(let original, let translation, let seconds):
            draft = nil
            lines.append(SubtitleLine(original: original, translation: translation))
            if lines.count > 3 { lines.removeFirst(lines.count - 3) }
            latency = latency.map { $0 * 0.7 + seconds * 0.3 } ?? seconds
            scheduleHide()
        case .detectedLanguage(let code):
            detectedLanguage = code
            followLanguage(code, session: id)
        case .unclear:
            unclearCount += 1
            notice = "Hid \(unclearCount) line\(unclearCount == 1 ? "" : "s") that were hard to hear."
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

// MARK: - Subtitle-file sync

extension AppState {
    /// Loads a subtitle file to follow and detects its language.
    func loadSyncFile(_ url: URL) {
        do {
            let cues = try SubtitleFile.read(url)
            syncFile = url
            syncCues = cues
            syncLanguage = SubtitleLanguage.detect(cues) ?? syncLanguage
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// What a cloud engine would send for the loaded file, shown before Start; nil when
    /// no cloud engine is selected.
    func syncEstimate(models: ModelStore) -> CloudEstimate? {
        guard let provider = models.cloudProvider, let file = syncFile, !syncCues.isEmpty,
              syncLanguage != targetLanguage else { return nil }
        let sentences = SubtitleSentences(cues: syncCues)
        let cached = SyncTranslations.existingTranslations(for: file, cues: syncCues, sentences: sentences, target: targetLanguage)
        return CloudEstimate(cues: syncCues.count, groups: sentences.groups.count,
                             remaining: sentences.groups.count - cached.count, batchSize: CloudTranslator.defaultBatchSize,
                             limits: models.cloudConfig.limits(for: provider))
    }

    /// Loads subtitle text downloaded from OpenSubtitles, saved under Application Support.
    func loadDownloadedSubtitles(_ text: String, named name: String) throws -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Subtitler/Subtitles", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name.hasSuffix(".srt") || name.hasSuffix(".vtt") ? name : name + ".srt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        loadSyncFile(url)
        return url
    }

    /// Starts following the file: a clock driven by what's heard, lines translated just
    /// ahead of it, and pause detection from digital silence.
    fileprivate func startSync(translator: Translator, target: String, session id: Int) -> PlaybackSilenceDetector {
        let sync = SubtitleSync(cues: syncCues)
        self.sync = sync
        let sentences = SubtitleSentences(cues: syncCues)
        syncSentences = sentences
        let existing = syncFile.map {
            SyncTranslations.existingTranslations(for: $0, cues: syncCues, sentences: sentences, target: target)
        } ?? [:]
        // A cloud engine translates the whole file and keeps it next to the subtitles, so
        // watching again sends nothing.
        let cacheURL = translator is BatchTranslating
            ? syncFile.flatMap { SyncTranslations.cacheURL(for: $0, cues: syncCues, sentences: sentences, target: target) }
            : nil
        syncTranslations = syncLanguage == target
            ? nil
            : SyncTranslations(cues: syncCues, sentences: sentences, translator: translator,
                               source: syncLanguage, target: target, existing: existing, cacheURL: cacheURL,
                               title: FilmTitle.from(syncFile), notes: CharacterNotes.get(for: syncFile)) { status in
                Task { @MainActor [weak self] in
                    guard let self, self.session == id else { return }
                    self.syncCloudStatus = status
                }
            }
        let silence = PlaybackSilenceDetector()
        silence.onChange = { [weak self] silent, since in
            DispatchQueue.main.async {
                guard let self, self.session == id else { return }
                if silent { self.sync?.pause(at: since) } else { self.sync?.resume(at: since) }
                self.updateSyncedCaptions()
            }
        }
        syncTimer = Task { [weak self] in
            while !Task.isCancelled {
                // 50 ms: a line shows at most that late after its time.
                try? await Task.sleep(for: .milliseconds(50))
                await MainActor.run { self?.updateSyncedCaptions() }
            }
        }
        return silence
    }

    /// Shows the file's current sentences (translated when ready) and translates the next
    /// ones. A sentence split over several cues is shown as one line for all of them.
    fileprivate func updateSyncedCaptions() {
        guard let sync, let sentences = syncSentences, isRunning else { return }
        // The offset moves the file's clock: positive shows subtitles earlier.
        let now = Date().addingTimeInterval(syncOffset)
        syncStatus = sync.status(at: now)
        let groups = sentences.groups(of: sync.activeCues(at: now))
        Task { [syncTranslations, syncCues] in
            await syncTranslations?.prefetch(cues: sync.upcomingCues(at: now, count: 12))
            var shown: [SubtitleLine] = []
            for group in groups {
                let original = sentences.text(of: group, in: syncCues)
                if let syncTranslations {
                    // Not translated yet: show nothing rather than the other language.
                    guard let translation = await syncTranslations.translation(ofGroup: group) else { continue }
                    shown.append(SubtitleLine(stableID: group, original: original, translation: translation))
                } else {
                    shown.append(SubtitleLine(stableID: group, original: original, translation: original))
                }
            }
            await MainActor.run { [weak self] in
                guard let self, self.sync === sync, self.lines != shown else { return }
                self.lines = shown
            }
        }
    }
}

extension AppState {
    /// Sample captions in the caption language, for previews and `--snapshot`: three
    /// finished lines (so "Lines on screen" is visible) and a fourth as the draft.
    var sampleLines: [SubtitleLine] {
        Array(SampleCaptions.lines(language: captionLanguage, translating: mode.translates).dropLast())
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
