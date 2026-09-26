import Foundation
import NaturalLanguage

/// What an LLM is asked to do. MADLAD takes no instructions; an LLM can be told how
/// subtitles should sound, which names to keep, and what came before.
enum LLMPrompt {
    static func system(from source: String, to target: String) -> String {
        let from = source.isEmpty || source == Languages.auto ? "the original language" : Languages.name(source)
        let to = Languages.name(target)
        var rules = """
        You translate film and TV subtitles from \(from) into \(to).
        - Write natural spoken \(to), the way these characters would really say it: not word for word, not stiff or bookish.
        - Keep names of people and places as names. Transliterate them into \(to) script; never translate their meaning.
        - Choose politeness and register from context: how the speakers relate (friends, family, lovers, strangers, a boss). Casual speech stays casual.
        - Keep each line's meaning. Don't add explanations, and don't merge, split or skip lines.
        - Output only the translation.
        """
        if let note = registerNote[target] { rules += "\n- \(note)" }
        return rules
    }

    /// Where the default register of a language's machine translation goes wrong.
    private static let registerNote: [String: String] = [
        "my": "Use colloquial spoken Burmese (endings like တယ်, ဘူး, မလား), not literary Burmese (သည်, ၏, ၍), unless the speaker is giving a formal speech.",
        "ko": "Use 반말 between close friends and family, and 존댓말 to strangers and superiors, as the context shows.",
        "ja": "Match casual speech (タメ口) or polite speech (です/ます) to the relationship shown in context.",
        "th": "Use natural spoken Thai; choose particles (ครับ/ค่ะ/นะ) and pronouns by the speakers' relationship.",
    ]

    /// One line in live Translate mode, with the lines before it for context.
    static func single(_ text: String, context: [String]) -> String {
        var message = ""
        if !context.isEmpty {
            message += "Earlier lines, for context only (don't translate them):\n"
            message += context.map { "> \($0)" }.joined(separator: "\n") + "\n\n"
        }
        return message + "Translate this line:\n\(text)"
    }

    /// A numbered batch, with earlier lines and the film's names.
    static func batch(_ lines: [String], context: [String], names: [String]) -> String {
        var message = ""
        if !names.isEmpty {
            message += "Names in this film (keep them as names): \(names.joined(separator: ", "))\n\n"
        }
        if !context.isEmpty {
            message += "Earlier lines, for context only (don't translate them):\n"
            message += context.map { "> \($0)" }.joined(separator: "\n") + "\n\n"
        }
        message += "Translate these \(lines.count) lines. Reply with exactly \(lines.count) lines, each starting with its number, like \"1. …\":\n"
        message += lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return message
    }

    /// Maps "1. …" lines back to the inputs; nil unless every number 1…count is there
    /// exactly once (then the caller splits the batch and tries again).
    static func parseNumbered(_ reply: String, count: Int) -> [String]? {
        var result = [String?](repeating: nil, count: count)
        let regex = try! NSRegularExpression(pattern: #"^\s*(?:\*\*)?(\d+)(?:\*\*)?\s*[.):：](?:\*\*)?\s*(.*)$"#)
        for line in reply.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let numberRange = Range(match.range(at: 1), in: line),
                  let textRange = Range(match.range(at: 2), in: line),
                  let number = Int(line[numberRange]), (1...count).contains(number)
            else { continue }
            guard result[number - 1] == nil else { return nil } // a number twice: ambiguous
            let text = line[textRange].trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            result[number - 1] = text
        }
        let lines = result.compactMap { $0 }
        return lines.count == count ? lines : nil
    }

    /// A plain reply to a single line: without quotes or a "Translation:" label models
    /// sometimes add.
    static func cleanSingle(_ reply: String) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.components(separatedBy: .newlines).filter { !$0.hasPrefix("```") }.joined(separator: "\n")
        }
        for label in ["Translation:", "翻译：", "Translated:"] where text.hasPrefix(label) {
            text = String(text.dropFirst(label.count))
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 1, let first = text.first, let last = text.last, "\"“「".contains(first), "\"”」".contains(last) {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }
}

/// Names that recur in a subtitle file (people, places, organisations), so the model
/// keeps them consistent across batches. Two signals, both on device: NaturalLanguage's
/// name tagger, and (for scripts with capitals) words that are capitalised mid-sentence
/// and never appear in lower case, like "Jin-woo" or "Mina".
enum NameGlossary {
    static func names(in texts: [String], limit: Int = 40) -> [String] {
        var counts = capitalised(texts)
        let text = texts.joined(separator: "\n")
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var tagged: [String: Int] = [:]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) {
                tagged[String(text[range]), default: 0] += 1
            }
            return true
        }
        for (name, count) in tagged where count >= 2 { counts[name] = max(counts[name] ?? 0, count) }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map(\.key)
    }

    /// Capitalised words seen at least twice, at least once mid-sentence, never in lower case.
    private static func capitalised(_ texts: [String]) -> [String: Int] {
        var total: [String: Int] = [:], midSentence = Set<String>(), lower = Set<String>()
        for text in texts {
            var sentenceStart = true
            for raw in text.split(whereSeparator: { $0.isWhitespace }) {
                let word = raw.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "-'")))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
                defer { sentenceStart = raw.last.map { ".!?".contains($0) } ?? false }
                guard word.count >= 2, let first = word.first, first.isLetter else { continue }
                if first.isLowercase { lower.insert(word.lowercased()); continue }
                guard first.isUppercase, word.dropFirst().contains(where: \.isLowercase) else { continue } // skip "OK", "I"
                total[word, default: 0] += 1
                if !sentenceStart { midSentence.insert(word) }
            }
        }
        return total.filter { $0.value >= 2 && midSentence.contains($0.key) && !lower.contains($0.key.lowercased()) }
    }
}
