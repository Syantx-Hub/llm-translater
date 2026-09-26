import SwiftUI
import UniformTypeIdentifiers

/// Translate an existing subtitle file ahead of time. The result keeps the original timing,
/// so captions appear exactly when the actors speak — no live delay.
struct SubtitleFileView: View {
    @ObservedObject var job: SubtitleJob
    @ObservedObject var state: AppState
    @ObservedObject var models: ModelStore
    /// The subtitles' language; MADLAD detects it by itself, so Auto-detect is fine.
    @AppStorage("subtitleSourceLanguage") private var source: String = Languages.auto

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Translate a subtitle file").font(.title2.weight(.semibold))
                Text("Have subtitles for a film? Translate them ahead of time and they'll show exactly when the actors speak. The translated file is saved next to the original, named so video players load it automatically.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            dropZone

            Form {
                Picker("Subtitles are in", selection: $source) {
                    Text("Detect automatically").tag(Languages.auto)
                    ForEach(Languages.all) { Text($0.name).tag($0.code) }
                }
                Picker("Translate to", selection: $state.targetLanguage) {
                    ForEach(Languages.all) { Text($0.name).tag($0.code) }
                }
                LabeledContent("Translator", value: translatorName)
            }
            .disabled(job.isWorking)

            status
            Spacer(minLength: 0)
            actions
        }
        .padding(24)
        .frame(width: 520, height: 560)
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: job.input == nil ? "doc.badge.plus" : "doc.text")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
            if let input = job.input {
                Text(input.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                if case .loaded(let cues, let duration) = job.phase {
                    Text("\(cues) lines · \(Self.duration(duration))").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Drop an .srt or .vtt file here").font(.headline)
            }
            Button(job.input == nil ? "Choose File…" : "Choose Another…") { chooseFile() }
                .disabled(job.isWorking)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(job.isDropTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(job.isDropTargeted ? Color.accentColor : Color.primary.opacity(0.12),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .onDrop(of: [.fileURL], isTargeted: $job.isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, SubtitleFile.readableExtensions.contains(url.pathExtension.lowercased()) else { return }
                Task { @MainActor in job.load(url) }
            }
            return true
        }
    }

    @ViewBuilder
    private var status: some View {
        switch job.phase {
        case .idle, .loaded:
            if state.isRunning || state.isBusy {
                Label("Stop live subtitles first — both need the translation model's memory.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else if models.translationModel == nil {
                Label("Download a translation model in Models first.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
        case .preparing:
            ProgressView("Loading the translation model…").progressViewStyle(.linear)
        case .translating(let done, let total, let secondsLeft):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text("Translating \(done) of \(total) lines")
            } currentValueLabel: {
                Text(secondsLeft.map { "About \(Self.duration($0)) left" } ?? "Estimating time left…")
            }
        case .finished(let url):
            Label("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }

    private var actions: some View {
        HStack {
            if case .finished(let url) = job.phase {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Translate Another") { job.reset() }
            }
            Spacer()
            if job.isWorking {
                Button("Cancel") { job.cancel() }
            } else {
                Button("Translate") {
                    job.start(source: source, target: state.targetLanguage, translatorSelection: models.selectedTranslation)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
            }
        }
    }

    private var canStart: Bool {
        guard case .loaded = job.phase else { return false }
        return models.translationModel != nil && !state.isRunning && !state.isBusy
    }

    private var translatorName: String {
        models.translationModel?.name ?? "None downloaded"
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SubtitleFile.readableExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        job.load(url)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : seconds >= 60 ? [.minute] : [.second]
        formatter.unitsStyle = .short
        return formatter.string(from: max(seconds, 1)) ?? ""
    }
}
