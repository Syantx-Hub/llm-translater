import SwiftUI
import UniformTypeIdentifiers

struct ControlPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var models: ModelStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if models.needsSetup && !state.isRunning && !state.isBusy {
                setupPrompt
            } else {
                settings
            }
            if let notice = state.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if let error = state.lastError {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3)
            }
            Divider()
            Button {
                show("subtitles")
            } label: {
                Label("Translate a subtitle file…", systemImage: "doc.text")
            }
            .buttonStyle(.link)
            HStack {
                Button("Captions…") { show("captions") }
                Button("Models…") { show("models") }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Subtitler").font(.headline)
                Label(status, systemImage: statusIcon)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
            }
            Spacer()
            Button(primaryActionTitle) {
                state.isRunning || state.isBusy ? state.stop() : state.start()
            }
            .keyboardShortcut(.defaultAction)
            // Stopping and cancelling must always work, even if a model was just removed.
            .disabled(!state.isRunning && !state.isBusy && models.needsSetup)
        }
    }

    private var primaryActionTitle: String {
        state.isRunning ? "Stop" : state.isBusy ? "Cancel" : "Start"
    }

    private var setupPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Download a speech model to get started.")
            Button("Set up Subtitler…") { show("welcome") }
                .buttonStyle(.borderedProminent)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode", selection: $state.mode) {
                ForEach(CaptionMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(state.isRunning || state.isBusy)

            if state.mode == .synced { syncSettings }

            Form {
                if state.mode != .synced {
                    Picker("Spoken language", selection: $state.sourceLanguage) {
                        Text(autoLabel).tag(Languages.auto)
                        ForEach(Languages.all) { Text($0.name).tag($0.code) }
                    }
                }
                if state.mode.translates {
                    Picker("Subtitles in", selection: $state.targetLanguage) {
                        ForEach(Languages.all) { Text($0.name).tag($0.code) }
                    }
                }
                Picker("Responsiveness", selection: $state.responsiveness) {
                    ForEach(Responsiveness.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Hide lines that were hard to hear", isOn: $state.hidesUnclearLines)
                    .help("Skips lines the speech model wasn't sure about, instead of showing (and translating) misheard words.")
            }
            .disabled(state.isRunning || state.isBusy)

            if state.mode == .synced {
                EmptyView()
            } else if models.speechModel?.isBuiltIn == true {
                if state.sourceLanguage == Languages.auto {
                    Toggle("Detect the language, then switch to Apple Speech", isOn: $state.appleAutoHandover)
                        .font(.caption)
                        .disabled(state.isRunning || state.isBusy)
                    Text(state.appleAutoHandover
                         ? "The first line uses Whisper to find the language; after that captions are instant."
                         : "Apple Speech needs the spoken language. With Auto-detect, Whisper is used instead.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Apple Speech shows words as they're spoken. Languages it can't hear use Whisper.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(state.responsiveness.detail)
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                modelRow("waveform", models.speechModel?.name ?? "No speech model")
                if state.mode.translates {
                    modelRow("character.bubble", translationName)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if state.isRunning || state.isBusy {
                Text("Changes apply the next time you start. Caption style changes apply right away.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Subtitle-file mode: which file to follow, its language, and how the sync is going.
    private var syncSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(state.syncFile?.lastPathComponent ?? "No subtitle file", systemImage: "doc.text")
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseSyncFile() }
                Button("Find Online…") { show("find-subtitles") }
            }
            .disabled(state.isRunning || state.isBusy)
            if !state.syncCues.isEmpty {
                Picker("File is in", selection: $state.syncLanguage) {
                    ForEach(Languages.all) { Text($0.name).tag($0.code) }
                }
                .disabled(state.isRunning || state.isBusy)
            }
            Text(syncStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var syncStatusText: String {
        switch state.syncStatus {
        case .searching?:
            "Listening for dialogue to find your place in the video…"
        case .synced(let time)?:
            "In sync at \(Self.clock(time)). Lines show on the file's own timing."
        case .paused(let time)?:
            "Paused at \(Self.clock(time))."
        case nil:
            state.syncCues.isEmpty
                ? "Choose the subtitles for what you're watching, in the language being spoken. They'll show translated, on time."
                : "\(state.syncCues.count) lines. Press Start while the video plays; the first clear line of dialogue syncs it."
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

    private func modelRow(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
    }

    private var translationName: String {
        let selection = models.selectedTranslation
        if selection == ModelStore.translationOff { return "No translation (original text)" }
        if selection.hasPrefix(ModelStore.sidecarPrefix) {
            return SidecarEngine(rawValue: String(selection.dropFirst(ModelStore.sidecarPrefix.count)))?.label ?? selection
        }
        return models.translationModel?.name ?? "Translation model not downloaded"
    }

    private func show(_ window: String) {
        openWindow(id: window)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var autoLabel: String {
        guard let code = state.detectedLanguage,
              let name = Languages.all.first(where: { $0.code == code })?.name else { return "Auto-detect" }
        return "Auto-detect (\(name))"
    }

    private var status: String {
        switch state.phase {
        case .idle: "Stopped"
        case .loading(let message): message
        case .running: state.latency.map { String(format: "Listening · lag %.1f s", $0) } ?? "Listening to system audio"
        case .failed(let message): message
        }
    }

    private var statusIcon: String {
        switch state.phase {
        case .idle: "stop.circle"
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
