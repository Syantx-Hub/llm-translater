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
                    caption: "Turns what you hear into text. Bigger models understand accents and noise better.",
                    models: ModelCatalog.speech)
                section(
                    title: "Translation",
                    caption: "Turns that text into your subtitle language.",
                    models: ModelCatalog.translation)
                translationFallback
            }
            .padding(24)
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 520, idealHeight: 760)
        .onAppear { store.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Models").font(.largeTitle.weight(.semibold))
            Text("Everything runs on this Mac — nothing you watch leaves it. Download what you need and switch any time.")
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

    /// Show-original mode, plus the Python sidecar engines in development builds.
    private var translationFallback: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Don't translate — show the original text", isOn: Binding(
                get: { store.selectedTranslation == ModelStore.translationOff },
                set: { off in store.selectedTranslation = off ? ModelStore.translationOff : ModelCatalog.defaultTranslation }
            ))
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
