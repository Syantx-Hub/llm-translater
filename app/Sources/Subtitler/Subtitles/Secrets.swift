import Foundation

/// API keys and other settings kept out of the code, read from `.env` files.
///
/// Looked up in order (first value wins):
/// 1. the process environment,
/// 2. `~/Library/Application Support/Subtitler/.env` (works for every build),
/// 3. `.env` in the repo checkout, for development builds that know it
///    (`scripts/build-app.sh --dev`, `SUBTITLER_REPO`, or running from the repo).
///
/// Nothing secret is ever built into the app, where anyone with a copy could read it. An
/// OpenSubtitles account signed in from the app (`OpenSubtitlesAccount`, Keychain) wins
/// over a login in a `.env` file.
enum Secrets {
    /// The viewer's own key, saved from Find Subtitles (Keychain), or one in a `.env` file.
    static var openSubtitlesAPIKey: String? {
        OpenSubtitlesAccount.hasAPIKey ? OpenSubtitlesAccount.apiKey : value("OPENSUBTITLES_API_KEY")
    }

    /// Whether a key is set up, without reading the Keychain item (which can ask permission).
    static var hasOpenSubtitlesAPIKey: Bool {
        OpenSubtitlesAccount.hasAPIKey || value("OPENSUBTITLES_API_KEY")?.isEmpty == false
    }

    static var openSubtitlesLogin: (username: String, password: String)? {
        if let username = OpenSubtitlesAccount.username {
            return OpenSubtitlesAccount.password.map { (username, $0) }
        }
        guard let username = value("OPENSUBTITLES_USERNAME"),
              let password = value("OPENSUBTITLES_PASSWORD") else { return nil }
        return (username, password)
    }

    static var appSupportFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Subtitler/.env")
    }

    static var files: [URL] {
        [appSupportFile] + (SidecarLocation.resolve().map { [$0.repoRoot.appendingPathComponent(".env")] } ?? [])
    }

    static func value(_ key: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty { return value }
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if let value = parse(text)[key], !value.isEmpty { return value }
        }
        return nil
    }

    /// `KEY=value` lines; `#` comments, `export` prefixes and surrounding quotes allowed.
    static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let split = line.firstIndex(of: "=") else { continue }
            let key = line[..<split].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'",
               let close = value.dropFirst().firstIndex(of: quote) {
                // Quoted: everything up to the closing quote, even "#"; a comment may follow.
                value = String(value[value.index(after: value.startIndex)..<close])
            } else if let comment = value.range(of: " #") {
                value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            values[key] = value
        }
        return values
    }
}

/// The viewer's OpenSubtitles setup from Find Subtitles: their free API key (needed to
/// search) in the Keychain, and optionally a login (more downloads a day), the name in
/// UserDefaults and the password in the Keychain.
enum OpenSubtitlesAccount {
    private static let usernameKey = "openSubtitlesUsername"
    static var store: SecretStore = KeychainStore(servicePrefix: "com.syantxhub.subtitler.opensubtitles.",
                                                  itemLabel: "Subtitler OpenSubtitles login")
    static var defaults: UserDefaults = .standard

    static var username: String? { defaults.string(forKey: usernameKey) }
    /// Reads the Keychain: only when logging in.
    static var password: String? { store.read("password") }

    static func save(username: String, password: String) throws {
        try store.save(password, for: "password")
        defaults.set(username, forKey: usernameKey)
    }

    static func signOut() throws {
        try store.delete("password")
        defaults.removeObject(forKey: usernameKey)
    }

    static var hasAPIKey: Bool { store.contains("apiKey") }
    /// Reads the Keychain: only when building a request.
    static var apiKey: String? { store.read("apiKey") }

    static func saveAPIKey(_ key: String) throws {
        try store.save(key.trimmingCharacters(in: .whitespacesAndNewlines), for: "apiKey")
    }

    static func removeAPIKey() throws {
        try store.delete("apiKey")
    }
}
