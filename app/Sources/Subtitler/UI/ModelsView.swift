import SwiftUI

/// The model library: browse, download, switch and delete models. One tab per job, so
/// speech models and translation models aren't one long list.
struct ModelsView: View {
    @ObservedObject var store: ModelStore
    @ObservedObject private var tab: TabState

    enum Tab: String, CaseIterable, Identifiable {
        case speech, translation, online
        var id: String { rawValue }

        var title: String {
            switch self {
            case .speech: "Speech recognition"
            case .translation: "Translation"
            case .online: "Online (optional)"
            }
        }
    }

    /// The shown tab, shared so another window can ask for one; the last tab is remembered.
    final class TabState: ObservableObject {
        static let shared = TabState(nil)

        @Published var value: Tab { didSet { UserDefaults.standard.set(value.rawValue, forKey: "modelsTab") } }
        init(_ value: Tab?) {
            self.value = value ?? UserDefaults.standard.string(forKey: "modelsTab").flatMap(Tab.init) ?? .speech
        }
    }

    init(store: ModelStore, initialTab: Tab? = nil) {
        self.store = store
        tab = initialTab.map { TabState($0) } ?? .shared
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                Picker("Show", selection: $tab.value) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    content
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: ScreenFit.height(520), idealHeight: ScreenFit.height(760))
        .onAppear { store.refresh(); store.refreshCloud() }
    }

    @ViewBuilder
    private var content: some View {
        switch tab.value {
        case .speech:
            section(
                title: "Speech recognition",
                caption: "Turns what you hear into text. Needed for every mode. Bigger models understand accents and background music better; Recommended fits this Mac.",
                models: ModelCatalog.speech)
        case .translation:
            section(
                title: "AI translation (Gemma 4): recommended for movies",
                caption: "Turns that text into your subtitle language, on this Mac. Gemma is a small AI model that reads the scene like a person would: what was just said, who's who, and whether people talk casually or politely, so dialogue sounds natural. Tuned for the small ones; the larger ones need more memory than most Macs have.",
                models: ModelCatalog.gemma)
            section(
                title: "Fast translation (MADLAD): recommended for live Translate",
                caption: "A translation model that takes one sentence at a time and nothing else. Quickest, so live captions keep up with the speaker, and covers more languages; but it can't see earlier lines, so it can sound literal and mix up names and pronouns.",
                models: ModelCatalog.madlad)
            translationFallback
        case .online:
            CloudSection(store: store)
            FilmBackgroundSection(store: store)
        }
    }

    /// Opens on `tab` next time the window appears (e.g. "No translation model yet" → Translation).
    static func request(_ tab: Tab) {
        TabState.shared.value = tab
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Models").font(.largeTitle.weight(.semibold))
            Text("You need two models: one that hears the words (speech recognition) and one that translates them. Both run on this Mac, so nothing you watch leaves it; switch any time when subtitles are stopped. Online extras are optional.")
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
