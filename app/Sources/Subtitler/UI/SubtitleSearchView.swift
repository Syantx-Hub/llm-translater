import SwiftUI

/// Search state for the Find Subtitles window.
@MainActor
final class SubtitleSearch: ObservableObject {
    @Published var query = ""
    @Published var language = "en"
    @Published private(set) var results: [SubtitleSearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var downloading: String?
    @Published private(set) var message: String?
    @Published private(set) var error: String?

    var hasAPIKey: Bool { Secrets.openSubtitlesAPIKey != nil }

    func search() {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let client = OpenSubtitlesClient.fromSecrets() else {
            error = OpenSubtitlesError.missingAPIKey.localizedDescription
            return
        }
        isSearching = true
        error = nil
        message = nil
        Task {
            do {
                results = try await client.search(query, languages: [language])
                if results.isEmpty { message = "No subtitles found. Try the original title, or another language." }
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
                let url = try state.loadDownloadedSubtitles(text, named: result.fileName)
                state.mode = .synced
                message = "Loaded \(url.lastPathComponent). Play the video and press Start."
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
                TextField("Film or show title", text: $search.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search.search() }
                Picker("", selection: $search.language) {
                    ForEach(Languages.all) { Text($0.name).tag($0.code) }
                }
                .labelsHidden()
                .frame(width: 130)
                Button("Search") { search.search() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(search.isSearching || search.query.isEmpty)
            }
            if search.isSearching { ProgressView().controlSize(.small) }
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
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 260)
            if let message = search.message {
                Label(message, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
            }
            if let error = search.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
        .onAppear {
            if state.sourceLanguage != Languages.auto { search.language = state.sourceLanguage }
        }
    }
}
