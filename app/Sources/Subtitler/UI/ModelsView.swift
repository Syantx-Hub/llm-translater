import SwiftUI

/// The model library: browse, download, switch and delete models.
struct ModelsView: View {
    @ObservedObject var store: ModelStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                section(
                    title: "Speech recognition",
                    caption: "Turns what you hear into text. Needed for every mode. Bigger models understand accents and background music better; Recommended fits this Mac.",
                    models: ModelCatalog.speech)
                section(
                    title: "Translation (offline)",
                    caption: "Turns that text into your subtitle language, on this Mac. Needed for Translate and Subtitle file modes.",
                    models: ModelCatalog.translation)
                CloudSection(store: store)
                translationFallback
            }
            .padding(24)
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: ScreenFit.height(520), idealHeight: ScreenFit.height(760))
        .onAppear { store.refresh(); store.refreshCloud() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Models").font(.largeTitle.weight(.semibold))
            Text("Offline models run on this Mac, so nothing you watch leaves it. Download what you need and switch any time; stop subtitles first to switch. Cloud translation, below, is optional.")
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Label("\(Hardware.chipName) · \(Hardware.ramGB) GB", systemImage: "cpu")
                Label("\(ByteCountFormatter.string(fromByteCount: store.installedBytes, countStyle: .file)) used",
                      systemImage: "internaldrive")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
    }

    private func section(title: String, caption: String, models: [ModelInfo]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                Text(caption).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(models) { ModelCard(model: $0, store: store) }
        }
    }

    /// The Python sidecar engines, in development builds only.
    private var translationFallback: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.sidecarAvailable {
                Picker("Developer engine", selection: Binding(
                    get: { store.selectedTranslation.hasPrefix(ModelStore.sidecarPrefix) ? store.selectedTranslation : "" },
                    set: { store.selectedTranslation = $0.isEmpty ? ModelCatalog.defaultTranslation : $0 }
                )) {
                    Text("None").tag("")
                    ForEach(SidecarEngine.allCases) { engine in
                        Text(engine.label).tag(ModelStore.sidecarPrefix + engine.rawValue)
                    }
                }
                .frame(maxWidth: 420)
                Text("Uses python/translate_server.py from the repo. Development builds only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
