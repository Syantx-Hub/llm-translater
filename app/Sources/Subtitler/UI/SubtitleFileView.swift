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
    @Environment(\.openWindow) private var openWindow

    private var isFinished: Bool {
        if case .finished = job.phase { true } else { false }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { form.padding(24) }
            Divider()
            actions.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 520, height: ScreenFit.height(600))
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Save a translated copy").font(.title2.weight(.semibold))
                Text("Translate a subtitle file ahead of time. The copy keeps the original timing, so it shows exactly when the actors speak, in any video player: it's saved next to the original and named so players load it automatically (Movie.en.srt → Movie.my.srt).")
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
                TranslationEnginePicker(models: models, mode: .synced, inForm: true) { openWindow(id: "models") }
            }
            .disabled(job.isWorking)
            if let provider = models.cloudProvider, job.input != nil, !job.isWorking, !isFinished {
                CloudEstimateView(estimate: job.estimate(target: state.targetLanguage, batchSize: CloudTranslator.defaultBatchSize,
                                                         limits: models.cloudConfig.limits(for: provider)),
                                  provider: provider, freeTier: models.cloudConfig.usesFreeTier(provider))
            }

            status
        }
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
                Label("Stop live subtitles first: both need the translator.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else if !models.translationReady {
                Label("Download a translation model in Models first.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
        case .preparing:
            ProgressView("Loading the translation model…").progressViewStyle(.linear)
        case .translating(let done, let total, let requests, let secondsLeft):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(done), total: Double(max(total, 1))) {
                    Text("Translating \(done) of \(total) sentences")
                } currentValueLabel: {
                    Text([models.cloudProvider != nil ? "\(requests) request\(requests == 1 ? "" : "s") sent" : nil,
                          secondsLeft.map { "about \(Self.duration($0)) left" } ?? "estimating time left…"]
                        .compactMap { $0 }.joined(separator: " · "))
                }
                if let provider = models.cloudProvider { RateLimitCountdown(provider: provider.name) }
            }
        case .finished(let url):
            VStack(alignment: .leading, spacing: 4) {
                Label("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                HelpNote("Open the video in your player; it loads the translated subtitles automatically. In Subtitle file mode, Subtitler reuses this copy, so watching again sends nothing.")
            }
        case .partial(_, let message):
            Label(message, systemImage: "pause.circle").foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }

    private var actions: some View {
        HStack {
            if case .finished(let url) = job.phase {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Translate Another") { job.reset() }
            } else if case .partial(let url, _) = job.phase {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Translate Another") { job.reset() }
            }
            Spacer()
            if job.isWorking {
                Button("Cancel") { job.cancel() }
            } else {
                Button(startTitle) {
                    job.start(source: source, target: state.targetLanguage, translatorSelection: models.selectedTranslation)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
            }
        }
    }

    private var startTitle: String {
        if case .partial = job.phase { return "Continue" }
        return models.cloudProvider == nil ? "Translate" : "Start"
    }

    private var canStart: Bool {
        switch job.phase {
        case .loaded, .partial: break
        default: return false
        }
        return models.translationReady && !state.isRunning && !state.isBusy
    }

    private var translatorName: String {
        models.translationName
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
