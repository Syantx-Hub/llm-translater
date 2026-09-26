import Foundation

/// API keys and other settings kept out of the code, read from `.env` files.
///
/// Looked up in order (first value wins):
/// 1. the process environment,
/// 2. `~/Library/Application Support/Subtitler/.env` (works for every build),
/// 3. `.env` in the repo checkout, for development builds that know it
///    (`scripts/build-app.sh --dev`, `SUBTITLER_REPO`, or running from the repo).
enum Secrets {
    static var openSubtitlesAPIKey: String? { value("OPENSUBTITLES_API_KEY") }
    static var openSubtitlesUsername: String? { value("OPENSUBTITLES_USERNAME") }
    static var openSubtitlesPassword: String? { value("OPENSUBTITLES_PASSWORD") }

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
