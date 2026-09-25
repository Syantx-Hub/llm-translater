import SwiftUI

struct ControlPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            Form {
                Picker("Spoken language", selection: $state.sourceLanguage) {
                    Text(autoLabel).tag(Languages.auto)
                    ForEach(Languages.all) { Text($0.name).tag($0.code) }
                }
                Picker("Subtitles in", selection: $state.targetLanguage) {
                    ForEach(Languages.all) { Text($0.name).tag($0.code) }
                }
                Picker("Translator", selection: $state.engine) {
                    ForEach(TranslationEngine.allCases) { Text($0.label).tag($0) }
                }
                Slider(value: $state.fontSize, in: 20...64) { Text("Text size") }
                Toggle("Show original under translation", isOn: $state.showOriginal)
                TextField("Speech model", text: $state.whisperModel, prompt: Text(Transcriber.recommendedModel))
            }
            .disabled(state.isRunning || state.isBusy)

            if state.isRunning || state.isBusy {
                Text("Settings apply the next time you start.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = state.lastError {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3)
            }
            Divider()
            HStack {
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
            .disabled(state.isBusy)
        }
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
