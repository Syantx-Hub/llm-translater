import Foundation

/// Subtitle files often split one sentence over two or three cues ("I told you…" /
/// "…not to go there."). Translated separately, each half comes out as a sentence of its
/// own, and in verb-final languages like Burmese the halves can't even be put back
/// together. So cues are grouped into sentences, and each group is translated, and shown,
/// as one.
struct SubtitleSentences: Equatable {
    /// Cue indices of each sentence, in order; every cue is in exactly one group.
    let groups: [[Int]]
    /// The group each cue is in.
    let groupOf: [Int]

    /// A pause longer than this between cues means a new sentence, whatever the punctuation.
    static let maxGap: TimeInterval = 1.5
    static let maxCues = 3

    init(cues: [SubtitleCue]) {
        let texts = cues.map { SubtitleFile.plainText($0.text) }
        // Files without sentence punctuation (common in Korean subtitles) give no signal
        // where a sentence ends, so their cues stay as they are.
        let punctuated = !texts.isEmpty
            && Double(texts.filter { Self.endsSentence($0) || Self.trails($0) }.count) >= Double(texts.count) * 0.3
        var groups: [[Int]] = []
        for index in cues.indices {
            if let last = groups.last?.last, last == index - 1, groups[groups.count - 1].count < Self.maxCues,
               Self.continues(cues[last], texts[last], into: cues[index], texts[index], punctuated: punctuated) {
                groups[groups.count - 1].append(index)
            } else {
                groups.append([index])
            }
        }
        self.groups = groups
        var groupOf = [Int](repeating: 0, count: cues.count)
        for (group, members) in groups.enumerated() { for cue in members { groupOf[cue] = group } }
        self.groupOf = groupOf
    }

    /// The sentence's words, for translation.
    func text(of group: Int, in cues: [SubtitleCue]) -> String {
        groups[group].map { SubtitleFile.plainText(cues[$0].text) }.joined(separator: " ")
    }

    /// The groups of these cues, in order, each once.
    func groups(of cues: [Int]) -> [Int] {
        var seen = Set<Int>()
        return cues.map { groupOf[$0] }.filter { seen.insert($0).inserted }
    }

    private static func continues(_ cue: SubtitleCue, _ text: String, into next: SubtitleCue, _ nextText: String,
                                  punctuated: Bool) -> Bool {
        guard !text.isEmpty, !nextText.isEmpty, next.start - cue.end <= maxGap else { return false }
        // "- Where?\n- Home." is two speakers; so is a cue starting with a dash.
        if isDialogue(cue.text) || isDialogue(next.text) { return false }
        if trails(text) {
            // "I thought…" can end a sentence; "I thought…" / "…you'd left." doesn't.
            let first = nextText.first!
            return nextText.hasPrefix("...") || nextText.hasPrefix("…") || first.isLowercase
        }
        if endsSentence(text) { return false }
        return punctuated
    }

    private static func isDialogue(_ text: String) -> Bool {
        text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("-") }
    }

    /// Ends with an ellipsis ("..." or "…").
    static func trails(_ text: String) -> Bool {
        let trimmed = stripClosers(text)
        return trimmed.hasSuffix("...") || trimmed.hasSuffix("…")
    }

    static func endsSentence(_ text: String) -> Bool {
        !trails(text) && SubtitlePipeline.endsSentence(stripClosers(text))
    }

    /// Without closing quotes and brackets: `He said "go."` ends with the full stop.
    private static func stripClosers(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespaces)
        while let last = text.last, "\"'”’)]」』".contains(last) { text.removeLast() }
        return text
    }
}
