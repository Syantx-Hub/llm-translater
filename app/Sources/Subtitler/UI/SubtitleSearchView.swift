import SwiftUI

/// Search state for the Find Subtitles window.
@MainActor
final class SubtitleSearch: ObservableObject {
    @Published var query = ""
    @Published var language = "en"
    /// Search one episode of a show instead of films.
    @Published var isEpisode = false
    @Published var season = ""
    @Published var episode = ""
    @Published private(set) var results: [SubtitleSearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var downloading: String?
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    /// The file just loaded for Subtitle file mode: the window then offers to start.
    @Published private(set) var loaded: URL?

    var hasAPIKey: Bool { Secrets.openSubtitlesAPIKey != nil }

    func search() {
        var request = SubtitleQuery.parse(query, season: isEpisode ? season : "", episode: isEpisode ? episode : "")
        // "breaking bad s01e01" typed in the title: switch to episode search and show it.
        if request.isEpisode {
            isEpisode = true
            season = String(request.season!)
            episode = String(request.episode!)
            query = request.title
        } else if isEpisode {
            error = "Enter both a season and an episode number, or switch off TV episode."
            return
        }
        request.title = request.title.trimmingCharacters(in: .whitespaces)
        guard !request.title.isEmpty, let client = OpenSubtitlesClient.fromSecrets() else {
            error = OpenSubtitlesError.missingAPIKey.localizedDescription
            return
        }
        isSearching = true
        error = nil
        message = nil
        loaded = nil
        Task {
            do {
                results = try await client.search(request, languages: [language])
                if results.isEmpty {
                    message = request.isEpisode
                        ? "No subtitles for that episode. Check the show's title and the numbers, or try another language."
                        : "No subtitles found. Try the original title, or another language."
                }
            } catch {
                self.error = error.localizedDescription
            }
            isSearching = false
        }
    }

    func download(_ result: SubtitleSearchResult, into state: AppState) {
        guard downloading == nil, let client = OpenSubtitlesClient.fromSecrets() else { return }
        downloading = result.id
        error = nil
        Task {
            do {
                let text = try await client.download(result)
                let url = try state.loadDownloadedSubtitles(text, named: result.savedFileName)
                state.mode = .synced
                loaded = url
                message = nil
            } catch {
                self.error = error.localizedDescription
            }
            downloading = nil
        }
    }
}

/// Find subtitles on OpenSubtitles and load them for Subtitle-file mode.
struct SubtitleSearchView: View {
    @ObservedObject var search: SubtitleSearch
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Find subtitles").font(.title2.weight(.semibold))
                Text("Search OpenSubtitles for what you're watching, in the language being spoken. Subtitler follows the video and shows them translated, on time.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !search.hasAPIKey {
                Label("Add OPENSUBTITLES_API_KEY to \(Secrets.appSupportFile.path) or the repo's .env to search.",
                      systemImage: "key")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                TextField("Film or show title, or \"breaking bad s01e01\"", text: $search.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search.search() }
                Picker("", selection: $search.language) {
                    ForEach(Languages.all) { Text($0.name).tag($0.code) }
                }
                .labelsHidden()
                .frame(width: 130)
                Button("Search") { search.search() }
                    // Once a file is loaded, Return means Start Now instead.
                    .keyboardShortcut(search.loaded == nil ? .defaultAction : nil)
                    .disabled(search.isSearching || search.query.isEmpty)
            }
            HelpNote("Choose the language the actors speak (Korean for a K-drama), not your subtitle language: Subtitler matches what it hears to these words, then translates them.")
            HStack(spacing: 10) {
                Toggle("TV episode", isOn: $search.isEpisode)
                if search.isEpisode {
                    TextField("Season", text: $search.season)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onSubmit { search.search() }
                    TextField("Episode", text: $search.episode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onSubmit { search.search() }
                }
                Spacer()
                if search.isSearching { ProgressView().controlSize(.small) }
            }
            List(search.results) { result in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text([result.title, result.year.map(String.init), result.episode].compactMap { $0 }.joined(separator: " · "))
                            .font(.headline)
                        Text(result.release.isEmpty ? result.fileName : result.release)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text("\(result.language.uppercased()) · \(result.downloads.formatted()) downloads")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if search.downloading == result.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Use") { search.download(result, into: state) }
                            .disabled(search.downloading != nil || state.isRunning || state.isBusy)
                            .help("Load these subtitles for Subtitle file mode.")
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 160)
            .overlay {
                if search.results.isEmpty, !search.isSearching {
                    VStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.tertiary)
                        Text("Results appear here. Pick one with a release name like your video (WEB-DL, BluRay) for the best timing.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .frame(maxWidth: 340)
                    }
                }
            }
            if let loaded = search.loaded { ready(loaded) }
            if let message = search.message {
                Label(message, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
            }
            if let error = search.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 560, height: ScreenFit.height(600))
        .onAppear {
            if state.sourceLanguage != Languages.auto { search.language = state.sourceLanguage }
        }
    }

    /// After "Use": the next step is right here, not only in the menu bar panel.
    private func ready(_ file: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ready: \(file.lastPathComponent)", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            HelpNote("Play the video, then press Start Now. Subtitler listens for a clear line of dialogue to find its place, then shows these subtitles translated, on time. You can also start later from \(Image(systemName: "captions.bubble")) in the menu bar.")
            HStack {
                Button("Start Now") {
                    state.start()
                    backToPanel()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(state.isRunning || state.isBusy)
                Button("Back to Subtitler") { backToPanel() }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.green.opacity(0.10)))
    }

    /// Closes this window and shows the panel, where the session's status and Stop live.
    private func backToPanel() {
        dismissWindow(id: "find-subtitles")
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
