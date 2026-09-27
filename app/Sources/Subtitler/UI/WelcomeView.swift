import CoreGraphics
import SwiftUI

/// First-run setup and tour: what Subtitler does, the three ways to use it, then the
/// models and the audio permission. It can be reopened any time from the panel's "?".
struct WelcomeView: View {
    @ObservedObject var store: ModelStore
    @ObservedObject var state: AppState
    @ObservedObject var style: CaptionStyle
    let onFinish: () -> Void

    // @StateObject rather than @State: the SwiftUI macro plugin behind @State ships only
    // with Xcode, and this app builds with the Command Line Tools.
    @StateObject private var flow: Flow
    @StateObject private var lookUpCast = Flag()

    private var step: Step { flow.step }
    private var hasPermission: Bool { flow.permission == .granted }

    final class Flow: ObservableObject {
        @Published var step: Step
        @Published var permission = AudioPermission.status()
        @Published var showsCloud = false

        init(step: Step) { self.step = step }
    }

    init(store: ModelStore, state: AppState, style: CaptionStyle, initialStep: Step = .welcome,
         onFinish: @escaping () -> Void) {
        self.store = store
        self.state = state
        self.style = style
        self.onFinish = onFinish
        _flow = StateObject(wrappedValue: Flow(step: initialStep))
    }

    /// Bumped when the tour changes enough that existing users should see it once.
    static let tourVersion = 2
    /// Off for `--snapshot`, which renders the tour without anyone seeing it.
    nonisolated(unsafe) static var recordsTour = true

    static var hasSeenTour: Bool {
        UserDefaults.standard.integer(forKey: "tourSeenVersion") >= tourVersion
    }

    enum Step: Int, CaseIterable {
        case welcome, mode, speech, translation, permission, done
    }

    var body: some View {
        VStack(spacing: 0) {
            // The steps scroll on short screens; the footer's buttons always stay in view.
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
            }
            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(width: 640, height: ScreenFit.height(680))
        .onAppear {
            store.refresh()
            // Seen once: later launches open the panel instead (the "?" reopens the tour).
            if WelcomeView.recordsTour { UserDefaults.standard.set(WelcomeView.tourVersion, forKey: "tourSeenVersion") }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .mode: modeStep
        case .speech: speech
        case .translation: translation
        case .permission: permission
        case .done: done
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text("Subtitles for anything you watch").font(.largeTitle.weight(.semibold))
                Text("Subtitler listens to what your Mac plays and shows subtitles on top of any app, even full-screen video: translated into your language, or as spoken.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 480)
            }
            CaptionPreview(style: style, mode: .translate, language: state.targetLanguage, height: 170)
                .frame(width: 302)
            VStack(alignment: .leading, spacing: 10) {
                Text("What it can do").font(.headline)
                Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 12) {
                    GridRow {
                        capability("character.bubble", "Translate live", "Any video, stream or call, in your language as it's said.")
                        capability("doc.text.magnifyingglass", "Follow a subtitle file", "Finds its place in the film's subtitles and shows them translated, exactly on time.")
                    }
                    GridRow {
                        capability("text.bubble", "Transcribe", "The original words, as they're spoken.")
                        capability("magnifyingglass", "Find subtitles online", "Search OpenSubtitles for films and TV episodes.")
                    }
                    GridRow {
                        capability("textformat.size", "Your style", "Font, size, colours and position, with a live preview.")
                        capability("square.and.arrow.down", "Save a translated copy", "Translate an .srt once and watch it in any video player.")
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            HStack(spacing: 18) {
                Label("Private: runs on this Mac; audio is never sent or stored", systemImage: "lock.shield")
                Label("Burmese first, plus 44 languages", systemImage: "globe.asia.australia")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .symbolRenderingMode(.hierarchical)
        }
    }

    private func capability(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 270, alignment: .leading)
    }

    private var modeStep: some View {
        stepLayout(
            title: "How will you use Subtitler?",
            subtitle: "There are three ways. Pick the one for what you watch most; you can switch any time in the panel."
        ) {
            HStack(alignment: .top, spacing: 18) {
                ModeChooser(mode: $state.mode, showsBestFor: true)
                    .frame(width: 300)
                VStack(alignment: .leading, spacing: 10) {
                    CaptionPreview(style: style, mode: state.mode, language: previewLanguage, height: 150)
                    StepList(steps: state.mode.steps)
                        .font(.callout)
                    if state.mode == .synced {
                        LearnMore(title: "Why a subtitle file?") {
                            ForEach(CaptionMode.whySubtitleFile, id: \.self) { Text($0) }
                        }
                    }
                }
                .frame(width: 250)
            }
        }
    }

    private var previewLanguage: String {
        state.mode.translates ? state.targetLanguage : "en"
    }

    private var speech: some View {
        stepLayout(
            title: "Choose a speech model",
            subtitle: "The speech model turns what you hear into text, on this Mac. Recommended is the best fit for your \(Hardware.chipName) with \(Hardware.ramGB) GB; bigger models cope better with accents and background music."
        ) {
            ForEach(ModelCatalog.speech) { ModelCard(model: $0, store: store, compact: true) }
        }
    }

    private var translation: some View {
        stepLayout(
            title: "Choose your language and a translator",
            subtitle: "The translator turns the words into your subtitle language, on this Mac. Gemma is recommended for movies: it reads the scene for natural dialogue. MADLAD is recommended for live Translate: it's quickest, but translates each sentence on its own. Or use a cloud AI with your own key."
        ) {
            Picker("Subtitles in", selection: $state.targetLanguage) {
                ForEach(Languages.all) { Text($0.name).tag($0.code) }
            }
            .frame(maxWidth: 280, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
            ForEach([ModelCatalog.gemma[0], ModelCatalog.madlad[0]]) { ModelCard(model: $0, store: store, compact: true) }
            cloudChoice
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Toggle(FilmBackgroundSettings.toggleLabel, isOn: Binding(
                    get: { lookUpCast.value },
                    set: { lookUpCast.value = $0; FilmBackgroundSettings().lookupEnabled = $0 }))
                HelpNote("Helps AI translators get pronouns and politeness right between characters. Off unless you turn it on.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .onAppear { lookUpCast.value = FilmBackgroundSettings().lookupEnabled }
        }
    }

    /// The optional cloud translator, set up right here rather than later in Models.
    @ViewBuilder
    private var cloudChoice: some View {
        if flow.showsCloud || store.cloudProvider != nil {
            CloudSection(store: store)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { flow.showsCloud = true }
                } label: {
                    Label("Use a cloud AI instead (your own key)", systemImage: "icloud")
                }
                HelpNote("More natural wording: it reads the whole script, keeps names and picks casual or polite speech. Needs an API key from a provider such as OpenRouter or Groq (both have free tiers). Offline stays the default; you can also set this up later in Models.")
            }
        }
    }

    private var permission: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 20)
            Image(systemName: hasPermission ? "checkmark.seal.fill" : "speaker.wave.2.circle")
                .font(.system(size: 52))
                .foregroundStyle(hasPermission ? Color.green : Color.accentColor)
            Text("Let Subtitler hear your Mac").font(.title2.weight(.semibold))
            Text(AudioCaptureFactory.usesScreenRecording
                 ? "On this version of macOS, apps hear system audio through the Screen Recording permission. Subtitler only uses the audio; it never looks at your screen."
                 : "Subtitler needs the System Audio Recording permission. It only hears what your Mac plays; it never sees your screen, and audio is never stored or sent anywhere.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            switch flow.permission {
            case .granted:
                Label("Permission granted", systemImage: "checkmark").foregroundStyle(.green)
            case .denied:
                Text("\(AudioPermission.name) is turned off for Subtitler. Turn it on in System Settings.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Button("Open System Settings") { NSWorkspace.shared.open(AudioPermission.settingsURL) }
                    .buttonStyle(.borderedProminent)
            case .unknown:
                HStack {
                    Button("Allow…") {
                        Task { flow.permission = await AudioPermission.request() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Open System Settings") { NSWorkspace.shared.open(AudioPermission.settingsURL) }
                }
                Text("You can also skip this; macOS will ask the first time you press Start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        // Pick up a change made in System Settings without reopening the app.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            flow.permission = AudioPermission.status()
        }
    }

    private var done: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 50))
                .foregroundStyle(.green)
            Text("You're set up for \(state.mode.label)").font(.title.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                StepList(steps: state.mode.steps)
                Divider()
                Label {
                    Text("Subtitler lives in the menu bar: click \(Image(systemName: "captions.bubble")) to open it, press Start, and change the mode there any time.")
                } icon: {
                    Image(systemName: "menubar.arrow.up.rectangle")
                }
                Label("Change the look of subtitles in Captions…; models and cloud translation in Models…",
                      systemImage: "slider.horizontal.3")
                if isDownloading {
                    Label("Your models are still downloading; you can start once they finish.", systemImage: "arrow.down.circle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .frame(maxWidth: 460, alignment: .leading)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            Text("You can take this tour again from \(Image(systemName: "questionmark.circle")) in the panel.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }

    private var footer: some View {
        HStack {
            if step != .welcome, step != .done {
                Button("Back") { move(-1) }
            }
            Spacer()
            stepDots
            Spacer()
            switch step {
            case .welcome:
                Button("Get Started") { move(1) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .mode:
                Button("Continue with \(state.mode.label)") { move(1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .speech:
                Button("Continue") { move(1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasSpeechChoice)
            case .translation:
                if hasTranslationChoice {
                    Button("Continue") { move(1) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Skip for Now") { move(1) }
                        .help("You can download a translator later in Models.")
                }
            case .permission:
                // While asking, the page's own Allow button is the prominent one.
                if hasPermission {
                    Button("Continue") { move(1) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Later") { move(1) }
                }
            case .done:
                Button("Done") { onFinish() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { item in
                Circle()
                    .fill(item == step ? Color.accentColor : Color.primary.opacity(0.2))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    private func stepLayout<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 10, content: content)
                .padding(.bottom, 12)
        }
    }

    private func move(_ delta: Int) {
        guard var next = Step(rawValue: step.rawValue + delta) else { return }
        // Transcribing needs no translator.
        if next == .translation, state.mode == .transcribe {
            guard let skipped = Step(rawValue: next.rawValue + delta) else { return }
            next = skipped
        }
        // Nothing to ask for when the permission is already granted.
        if next == .permission, AudioPermission.status() == .granted {
            flow.permission = .granted
            guard let skipped = Step(rawValue: next.rawValue + delta) else { return }
            next = skipped
        }
        withAnimation(.easeOut(duration: 0.2)) { flow.step = next }
    }

    private func hasChoice(in models: [ModelInfo]) -> Bool {
        models.contains { store.isInstalled($0) || isDownloading($0) }
    }

    private var hasSpeechChoice: Bool { hasChoice(in: ModelCatalog.speech) }
    /// A downloaded (or downloading) offline model, or a cloud translator that's set up and chosen.
    private var hasTranslationChoice: Bool {
        hasChoice(in: ModelCatalog.translation)
            || store.cloudProvider.map { store.configuredCloud.contains($0) } == true
    }
    private var isDownloading: Bool { ModelCatalog.all.contains(where: isDownloading) }

    private func isDownloading(_ model: ModelInfo) -> Bool {
        if case .downloading = store.status(of: model) { true } else { false }
    }
}
