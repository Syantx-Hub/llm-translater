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

    /// Checked without reading the Keychain item; refreshed when a key is saved or removed.
    @Published private(set) var hasAPIKey = Secrets.hasOpenSubtitlesAPIKey

    func refreshKey() { hasAPIKey = Secrets.hasOpenSubtitlesAPIKey }

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
        guard !request.title.isEmpty, let client = OpenSubtitlesClient.fromSecrets(withLogin: false) else {
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
                OpenSubtitlesKeySetup { search.refreshKey() }
            } else {
                OpenSubtitlesLoginRow { search.refreshKey() }
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

/// Optional OpenSubtitles sign-in: more downloads a day. The password goes straight to the
/// Keychain and is never shown again.
struct OpenSubtitlesLoginRow: View {
    /// Called after the saved API key is removed.
    var onKeyRemoved: () -> Void = {}
    @StateObject private var login = OpenSubtitlesLogin()

    var body: some View {
        OpenSubtitlesLoginContent(login: login, onKeyRemoved: onKeyRemoved)
    }
}

/// First run: searching OpenSubtitles needs the viewer's own free API key. Nothing secret
/// ships inside the app, so each person gets one (two minutes) and it stays in their Keychain.
struct OpenSubtitlesKeySetup: View {
    var onSaved: () -> Void
    @StateObject private var setup = KeySetup()

    @MainActor
    final class KeySetup: ObservableObject {
        @Published var draft = ""
        @Published var checking = false
        @Published var error: String?

        func save(then done: @escaping () -> Void) {
            let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            checking = true
            error = nil
            Task {
                do {
                    try await OpenSubtitlesClient(apiKey: key).verifyAPIKey()
                    try OpenSubtitlesAccount.saveAPIKey(key)
                    draft = ""
                    done()
                } catch OpenSubtitlesError.http(let code, _) where code == 401 || code == 403 {
                    error = "OpenSubtitles didn't accept that key. Copy the API key from your consumer's page, not your password."
                } catch {
                    self.error = error.localizedDescription
                }
                checking = false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Connect OpenSubtitles (free, about two minutes)", systemImage: "key.fill")
                .font(.headline)
            VStack(alignment: .leading, spacing: 5) {
                step(1, "Create a free account:", link: "opensubtitles.com/en/users/sign_up",
                     url: "https://www.opensubtitles.com/en/users/sign_up")
                step(2, "Add a New consumer (any name):",
                     link: "opensubtitles.com/en/consumers", url: "https://www.opensubtitles.com/en/consumers")
                step(3, "Copy its API key and paste it here.", link: nil, url: nil)
            }
            HStack {
                SecureField("OpenSubtitles API key", text: $setup.draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { setup.save(then: onSaved) }
                if setup.checking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save") { setup.save(then: onSaved) }
                        .disabled(setup.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let error = setup.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HelpNote("The key is checked once with OpenSubtitles, then kept in your Keychain; it's only ever sent to api.opensubtitles.com. No key? You can still choose a subtitle file you already have in Subtitle file mode.")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.08)))
    }

    private func step(_ number: Int, _ text: String, link: String?, url: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            Text(text)
            if let link, let url, let destination = URL(string: url) { Link(link, destination: destination) }
        }
        .font(.callout)
    }
}

@MainActor
final class OpenSubtitlesLogin: ObservableObject {
    @Published var username = OpenSubtitlesAccount.username
    @Published var expanded = false
    @Published var draftName = ""
    @Published var draftPassword = ""
    @Published var checking = false
    @Published var error: String?

    func signIn() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        let password = draftPassword
        guard !name.isEmpty, !password.isEmpty, let key = Secrets.openSubtitlesAPIKey else { return }
        checking = true
        error = nil
        Task {
            do {
                try await OpenSubtitlesClient(apiKey: key, username: name, password: password).verifyLogin()
                try OpenSubtitlesAccount.save(username: name, password: password)
                username = name
                expanded = false
                clear()
            } catch OpenSubtitlesError.http(let code, _) where code == 400 || code == 401 {
                error = "Wrong username or password."
            } catch {
                self.error = error.localizedDescription
            }
            checking = false
        }
    }

    func signOut() {
        try? OpenSubtitlesAccount.signOut()
        username = nil
    }

    func clear() {
        draftName = ""
        draftPassword = ""
    }
}

private struct OpenSubtitlesLoginContent: View {
    @ObservedObject var login: OpenSubtitlesLogin
    var onKeyRemoved: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if OpenSubtitlesAccount.hasAPIKey {
                HStack(spacing: 4) {
                    HelpNote("Your OpenSubtitles API key is in your Keychain.")
                    Button("Remove key") {
                        try? OpenSubtitlesAccount.removeAPIKey()
                        onKeyRemoved()
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
            if let username = login.username {
                HStack(spacing: 8) {
                    Label("Signed in to OpenSubtitles as \(username)", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.callout)
                    Spacer()
                    Button("Sign Out") {
                        login.signOut()
                    }
                }
            } else if login.expanded {
                HStack {
                    TextField("Username", text: $login.draftName)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $login.draftPassword)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(login.signIn)
                    if login.checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Sign In", action: login.signIn)
                            .disabled(login.draftName.trimmingCharacters(in: .whitespaces).isEmpty || login.draftPassword.isEmpty)
                    }
                    Button("Cancel") { login.expanded = false; login.clear() }
                }
                HStack(spacing: 4) {
                    HelpNote("A free account raises the daily download limit. No account yet?")
                    Link("opensubtitles.com", destination: URL(string: "https://www.opensubtitles.com/en/users/sign_up")!)
                        .font(.caption)
                }
            } else {
                HStack(spacing: 4) {
                    HelpNote("Hit the daily download limit?")
                    Button("Sign in to OpenSubtitles (free)") { login.expanded = true }
                        .buttonStyle(.link).font(.caption)
                }
            }
            if let error = login.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
            }
        }
    }
}
