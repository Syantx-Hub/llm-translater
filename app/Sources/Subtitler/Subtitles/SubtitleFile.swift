import Foundation

/// One timed subtitle.
struct SubtitleCue: Equatable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
    /// Lines of text, as in the file (without the index or timing).
    var text: String
}

enum SubtitleFileError: LocalizedError, Equatable {
    case unreadable
    case noCues

    var errorDescription: String? {
        switch self {
        case .unreadable: "The file couldn't be read as text."
        case .noCues: "No subtitles were found in the file. Subtitler reads .srt and .vtt files."
        }
    }
}

/// Reads SubRip (.srt) and WebVTT (.vtt) subtitles, and writes SubRip.
enum SubtitleFile {
    static let readableExtensions = ["srt", "vtt"]

    static func read(_ url: URL) throws -> [SubtitleCue] {
        guard let data = try? Data(contentsOf: url), let text = decode(data) else { throw SubtitleFileError.unreadable }
        let cues = parse(text)
        guard !cues.isEmpty else { throw SubtitleFileError.noCues }
        return cues
    }

    /// Subtitle files come in many encodings; try the common ones.
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
    }

    /// Parses SRT or VTT text. Malformed blocks are skipped rather than failing the file.
    static func parse(_ text: String) -> [SubtitleCue] {
        let normalized = text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // The timing line may follow an index (SRT) or a cue identifier (VTT).
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }),
                  let (start, end) = parseTiming(lines[timingIndex])
            else { continue }
            let body = lines[(timingIndex + 1)...].joined(separator: "\n")
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: body))
        }
        return cues
    }

    /// "00:01:02,500 --> 00:01:04,000" (SRT) or "01:02.500 --> 01:04.000 align:start" (VTT).
    static func parseTiming(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let start = parseTime(parts[0].trimmingCharacters(in: .whitespaces)),
              let endField = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first,
              let end = parseTime(String(endField))
        else { return nil }
        return (start, end)
    }

    static func parseTime(_ field: String) -> TimeInterval? {
        let clock = field.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(clock.count) else { return nil }
        let numbers = clock.map { Double($0) }
        guard numbers.allSatisfy({ $0 != nil }) else { return nil }
        return numbers.reduce(0) { $0 * 60 + $1! }
    }

    static func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let milliseconds = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60,
                      milliseconds / 1000 % 60, milliseconds % 1000)
    }

    /// The cue's words for translation: one line, without formatting tags like `<i>` or
    /// `{\an8}`, and without speaker dashes' line breaks.
    static func plainText(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Where the translation goes: next to the original, named so video players load it
    /// automatically. "Movie.en.srt" → "Movie.my.srt"; "Movie.srt" → "Movie.my.srt".
    /// An existing file is never overwritten.
    /// Language tags players use in subtitle names ("Movie.en.srt", "Movie.eng.srt").
    private static let languageSuffixes = Set(Languages.all.map(\.code))
        .union(["eng", "kor", "jpn", "chi", "zho", "chs", "cht", "mya", "bur", "tha", "vie", "spa", "fre", "fra", "ger", "deu"])

    /// "Movie.en.srt" → "Movie.my.srt", whether or not it exists: where a translation of
    /// this file is looked for, and continued.
    static func translationURL(for input: URL, target: String) -> URL {
        let base = input.deletingPathExtension().lastPathComponent
        let parts = base.split(separator: ".")
        let stem = parts.count > 1 && parts.last.map({ languageSuffixes.contains($0.lowercased()) }) == true
            ? parts.dropLast().joined(separator: ".") : base
        return input.deletingLastPathComponent().appendingPathComponent("\(stem).\(target).srt")
    }

    static func outputURL(for input: URL, target: String) -> URL {
        let first = translationURL(for: input, target: target)
        let base = first.deletingPathExtension().lastPathComponent
        var candidate = first
        var copy = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = first.deletingLastPathComponent().appendingPathComponent("\(base) \(copy).srt")
            copy += 1
        }
        return candidate
    }
}
