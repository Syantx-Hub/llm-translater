import SwiftUI
import UniformTypeIdentifiers

/// The menu bar panel (and main window): what's happening, the three ways to use
/// Subtitler, and the chosen mode's settings, each explained where it sits.
struct ControlPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var models: ModelStore
    /// Saving a translated copy of the chosen subtitle file.
    @ObservedObject var subtitleJob: SubtitleJob
    @ObservedObject var style: CaptionStyle
    @Environment(\.openWindow) private var openWindow

    private var locked: Bool { state.isRunning || state.isBusy }

    /// The scrolling middle's natural height, measured, so the panel is only as tall as
    /// its content until that no longer fits on screen.
    @StateObject private var contentHeight = Measured()
    @StateObject private var panelHeight = Measured()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding([.horizontal, .top], 14)
            ScrollView {
                middle
                    .padding(.horizontal, 14)
                    .padding(.vertical, 2)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: HeightKey.self, value: geometry.size.height)
                    })
            }
            .frame(height: min(contentHeight.value, maxScrollHeight))
            .onPreferenceChange(HeightKey.self) { contentHeight.value = $0 }
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                footer
            }
            .padding([.horizontal, .bottom], 14)
        }
        .frame(width: 360)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: PanelHeightKey.self, value: geometry.size.height)
        })
        .onPreferenceChange(PanelHeightKey.self) { panelHeight.value = $0 }
        .background(FitWindowHeight(height: panelHeight.value))
        .onAppear { models.refreshCloud() }
    }

    /// Everything between the header and the footer; scrolls when the screen is short.
    private var middle: some View {
        VStack(alignment: .leading, spacing: 12) {
            if models.needsSetup && !locked {
                setupPrompt
            } else {
                modeTabs
                settings
            }
            messages
        }
    }

    /// The three ways to use Subtitler, as tabs, with one line on what the chosen one does.
    private var modeTabs: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Mode", selection: $state.mode) {
                ForEach(CaptionMode.allCases) { mode in
                    Text(mode == .transcribe ? "Transcribe" : mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(locked)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(state.mode.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                InfoButton(label: "How \(state.mode.label) works") {
                    Text("How it works").font(.headline)
                    StepList(steps: state.mode.steps)
                    Text(state.mode.bestFor).foregroundStyle(.secondary)
                    if state.mode == .synced {
                        Divider()
                        Text("Why a subtitle file?").font(.headline)
                        ForEach(CaptionMode.whySubtitleFile, id: \.self) { Text($0).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    /// Room left on screen for the scrolling part, below the menu bar and above the Dock,
    /// after the header and footer.
    private var maxScrollHeight: CGFloat {
        max(240, ScreenFit.visibleHeight - 150)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Subtitler").font(.headline)
                Label(status, systemImage: statusIcon)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
            }
            Spacer()
            if state.isRunning, let latency = state.latency, state.mode != .synced {
                // How far behind the speaker the captions are, as a readout.
                VStack(alignment: .trailing, spacing: 0) {
                    Text(String(format: "%.1f s", latency)).font(.title3.monospacedDigit().weight(.semibold))
                    Text("behind").font(.caption2).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Button(primaryActionTitle) {
                locked ? state.stop() : state.start()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            // Stopping and cancelling must always work, even if a model was just removed.
            .disabled(!locked && (models.needsSetup || !canStart))
        }
    }

    private var primaryActionTitle: String {
        state.isRunning ? "Stop" : state.isBusy ? "Cancel" : "Start"
    }

    private var canStart: Bool {
        state.mode != .synced || !state.syncCues.isEmpty
    }

    private var setupPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subtitler needs a speech model before it can listen.")
            HelpNote("The setup takes a couple of minutes: choose how you'll use it, download a model, allow audio.")
            Button("Set Up Subtitler…") { show("welcome") }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Settings per mode

    @ViewBuilder
    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch state.mode {
            case .translate:
                spokenLanguage
                subtitleLanguage(label: "Subtitles in")
                TranslationEnginePicker(models: models, mode: .translate, compact: true) { ModelsView.request(.translation); show("models") }
                options
            case .transcribe:
                spokenLanguage
                options
            case .synced:
                syncSettings
            }
        }
        .disabled(locked && state.mode != .synced)
        .help(locked ? "Stop to change these. Caption style changes apply right away." : "")
    }

    private var spokenLanguage: some View {
        FieldRow("Spoken language") {
            Picker("Spoken language", selection: $state.sourceLanguage) {
                Text(autoLabel).tag(Languages.auto)
                ForEach(Languages.all) { Text($0.name).tag($0.code) }
            }
        }
        .help("Auto-detect follows the video, even if the language changes.")
    }

    private func subtitleLanguage(label: String) -> some View {
        FieldRow(label) {
            Picker(label, selection: $state.targetLanguage) {
                ForEach(Languages.all) { Text($0.name).tag($0.code) }
            }
        }
    }

    /// Settings most people never change, folded away.
    private var options: some View {
        LearnMore(title: "Options") {
            VStack(alignment: .leading, spacing: 8) {
                FieldRow("Speed") {
                    Picker("Speed", selection: $state.responsiveness) {
                        ForEach(Responsiveness.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .help(state.responsiveness.detail)
                Toggle("Hide lines that were hard to hear", isOn: $state.hidesUnclearLines)
                    .help("Skips lines the speech model wasn't sure about, instead of showing misheard words.")
                if models.speechModel?.isBuiltIn == true, state.sourceLanguage == Languages.auto {
                    Toggle("Switch to Apple Speech once the language is known", isOn: $state.appleAutoHandover)
                }
            }
            .foregroundStyle(.primary)
            .font(.body)
        }
    }

    // MARK: Subtitle file

    private var syncSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: state.syncFile == nil ? "doc.badge.plus" : "doc.text")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.syncFile?.lastPathComponent ?? "No subtitle file yet")
                        .lineLimit(1).truncationMode(.middle)
                    Text(state.syncCues.isEmpty ? "In the language being spoken" : "\(state.syncCues.count) lines")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                Button("Choose File…") { chooseSyncFile() }
                Button("Find Online…") { show("find-subtitles") }
            }
            .disabled(locked)
            if !state.syncCues.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    FieldRow("File is in") {
                        Picker("File is in", selection: $state.syncLanguage) {
                            ForEach(Languages.all) { Text($0.name).tag($0.code) }
                        }
                    }
                    subtitleLanguage(label: "Translate to")
                    TranslationEnginePicker(models: models, mode: .synced, compact: true) { ModelsView.request(.translation); show("models") }
                    if let provider = models.cloudProvider, let estimate = state.syncEstimate(models: models) {
                        CloudEstimateView(estimate: estimate, provider: provider,
                                          freeTier: models.cloudConfig.usesFreeTier(provider),
                                          model: models.cloudConfig.model(for: provider),
                                          notesFile: state.syncFile, compact: true)
                    }
                }
                .disabled(locked)
                timing
                Button("Save Translated Copy…") {
                    if let file = state.syncFile { subtitleJob.load(file) }
                    show("subtitles")
                }
                .buttonStyle(.link)
                .font(.callout)
                .disabled(locked)
                .help("Writes the translation next to the file, so any video player can show it.")
            }
            syncStatusRow
        }
    }

    private var timing: some View {
        VStack(alignment: .leading, spacing: 2) {
            FieldRow("Timing") {
                HStack {
                    Text(syncOffsetLabel).monospacedDigit().foregroundStyle(.secondary)
                    Stepper("Timing", value: $state.syncOffset, in: -2...2, step: 0.1)
                    Spacer()
                    Button("Reset") { state.syncOffset = 0 }
                        .disabled(state.syncOffset == 0)
                }
            }
            .help("If lines show a little early or late, nudge them. Applies immediately.")
        }
    }

    private var syncOffsetLabel: String {
        let tenths = (state.syncOffset * 10).rounded() / 10
        if tenths == 0 { return "On time" }
        return String(format: "%.1f s %@", abs(tenths), tenths > 0 ? "earlier" : "later")
    }

    @ViewBuilder
    private var syncStatusRow: some View {
        switch state.syncStatus {
        case .searching?:
            NoticeRow(symbol: "ear", text: "Listening for dialogue to find your place in the video…")
        case .synced(let time)?:
            NoticeRow(symbol: "link", text: "In sync at \(Self.clock(time))", tone: .done)
        case .paused(let time)?:
            NoticeRow(symbol: "pause.circle", text: "Paused at \(Self.clock(time))")
        case nil:
            EmptyView()
        }
        if let provider = models.cloudProvider, state.isRunning {
            RateLimitCountdown(provider: provider.name)
            switch state.syncCloudStatus {
            case .translating(let done, let total, _)?:
                ProgressView(value: Double(done), total: Double(max(total, 1))) {
                    Text("Translating ahead: \(done) of \(total)").font(.caption)
                }
            case .finished?:
                NoticeRow(symbol: "checkmark.circle", text: "Whole file translated and saved; watching again sends nothing.", tone: .done)
            case .stopped(let message)?:
                NoticeRow(symbol: "pause.circle", text: message, tone: .caution)
            case nil:
                EmptyView()
            }
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    private func chooseSyncFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SubtitleFile.readableExtensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.loadSyncFile(url)
    }

    // MARK: Messages and footer

    @ViewBuilder
    private var messages: some View {
        if let notice = state.notice {
            NoticeRow(symbol: "info.circle", text: notice)
        }
        if let error = state.lastError {
            NoticeRow(symbol: "exclamationmark.triangle", text: error, tone: .caution)
        }
    }

    private var footer: some View {
        HStack {
            Button("Captions…") { show("captions") }
                .help("Font, size, colours and position of the subtitles, with a live preview.")
            Button("Models…") { show("models") }
                .help("Download speech and translation models, or set up cloud translation.")
            Button {
                show("welcome")
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Take the tour again")
            .accessibilityLabel("Take the tour again")
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }

    private func show(_ window: String) {
        openWindow(id: window)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var previewLanguage: String {
        state.mode.translates ? state.targetLanguage : (state.sourceLanguage == Languages.auto ? "en" : state.sourceLanguage)
    }

    private var autoLabel: String {
        guard let code = state.detectedLanguage,
              let name = Languages.all.first(where: { $0.code == code })?.name else { return "Auto-detect" }
        return "Auto-detect (\(name))"
    }

    private var status: String {
        switch state.phase {
        case .idle:
            state.mode == .synced && state.syncCues.isEmpty
                ? "Choose a subtitle file, then press Start."
                : "Ready. Play a video, then press Start."
        case .loading(let message): message
        case .running: state.mode == .synced ? "Following the subtitle file" : "Listening to your Mac's audio"
        case .failed(let message): message
        }
    }

    private var statusIcon: String {
        switch state.phase {
        case .idle: state.mode == .synced && state.syncCues.isEmpty ? "doc.badge.plus" : "play.circle"
        case .loading: "hourglass"
        case .running: "waveform"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch state.phase {
        case .failed: .red
        case .running: .green
        default: .secondary
        }
    }
}

private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Keeps the window exactly as tall as the panel. The menu bar's window takes the panel's
/// size when it opens but never shrinks after, so switching to a mode with less to show left
/// an empty, see-through strip below it. The top edge stays put, under the menu bar.
private struct FitWindowHeight: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let height = height
        DispatchQueue.main.async {
            guard height > 0, let window = view.window else { return }
            let current = window.contentRect(forFrameRect: window.frame)
            guard abs(current.height - height) > 1 else { return }
            let target = window.frameRect(forContentRect: NSRect(x: current.minX, y: current.maxY - height,
                                                                width: current.width, height: height))
            window.setFrame(target, display: true)
        }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// `@State` stand-in for a measured size (the macro needs Xcode).
final class Measured: ObservableObject {
    @Published var value: CGFloat = 400
}
