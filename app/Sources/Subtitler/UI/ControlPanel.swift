import SwiftUI

struct ControlPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var models: ModelStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if models.needsSetup {
                setupPrompt
            } else {
                settings
            }
            if let error = state.lastError {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3)
            }
            Divider()
            HStack {
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
                Text(status).font(.caption).foregroundStyle(statusColor).lineLimit(2)
            }
            Spacer()
            Button(state.isRunning ? "Stop" : "Start") {
                state.isRunning ? state.stop() : state.start()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(state.isBusy || models.needsSetup)
        }
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
            Form {
                Picker("Spoken language", selection: $state.sourceLanguage) {
                    Text(autoLabel).tag(Languages.auto)
                    ForEach(Languages.all) { Text($0.name).tag($0.code) }
                }
                Picker("Subtitles in", selection: $state.targetLanguage) {
                    ForEach(Languages.all) { Text($0.name).tag($0.code) }
                }
                Slider(value: $state.fontSize, in: 20...64) { Text("Text size") }
                Toggle("Show original under translation", isOn: $state.showOriginal)
            }
            .disabled(state.isRunning || state.isBusy)

            VStack(alignment: .leading, spacing: 3) {
                modelRow("waveform", models.speechModel?.name ?? "No speech model")
                modelRow("character.bubble", translationName)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if state.isRunning || state.isBusy {
                Text("Changes apply the next time you start.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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
        case .running: "Listening to system audio"
        case .failed(let message): message
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
