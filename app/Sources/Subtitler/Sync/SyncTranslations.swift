import Foundation
import NaturalLanguage

/// Translations of a subtitle file's sentences, made just ahead of where the video is.
/// Cues that split one sentence are translated together (`SubtitleSentences`), so the
/// work and the results are per sentence group, not per cue.
actor SyncTranslations {
    private let cues: [SubtitleCue]
    let sentences: SubtitleSentences
    private let translator: Translator
    private let source: String
    private let target: String
    private var done: [Int: String]
    private var queue: [Int] = []
    private var working = false

    /// - Parameter existing: translations already on disk (from Save Translated Copy), by group.
    init(cues: [SubtitleCue], sentences: SubtitleSentences, translator: Translator, source: String, target: String,
         existing: [Int: String] = [:]) {
        self.cues = cues
        self.sentences = sentences
        self.translator = translator
        self.source = source
        self.target = target
        done = existing
    }

    func translation(ofGroup group: Int) -> String? { done[group] }

    /// Translates the sentences these cues belong to (in order) unless already done or queued.
    func prefetch(cues indices: [Int]) {
        let new = sentences.groups(of: indices).filter { done[$0] == nil && !queue.contains($0) }
        // Newest request first: after a jump, the lines near the new position matter most.
        queue = new + queue.filter { !new.contains($0) }
        guard !working else { return }
        working = true
        Task { await work() }
    }

    private func work() async {
        while !queue.isEmpty {
            let group = queue.removeFirst()
            guard done[group] == nil else { continue }
            let text = sentences.text(of: group, in: cues)
            let translation = try? await SubtitlePipeline.translate(text, from: source, to: target, context: [], with: translator)
            done[group] = translation ?? text
        }
        working = false
    }

    /// Reuses a translated file made earlier ("Movie.my.srt" next to "Movie.en.srt"), by
    /// sentence group, so nothing has to be translated live. Works both with copies whose
    /// cues match one to one and with copies that joined split sentences into one cue.
    static func existingTranslations(for input: URL, cues: [SubtitleCue], sentences: SubtitleSentences,
                                     target: String) -> [Int: String] {
        let folder = input.deletingLastPathComponent()
        let base = SubtitleFile.outputURL(for: input, target: target).deletingPathExtension().lastPathComponent
        let candidate = folder.appendingPathComponent(base.replacingOccurrences(of: #" \d+$"#, with: "", options: .regularExpression) + ".srt")
        guard candidate != input, let translated = try? SubtitleFile.read(candidate) else { return [:] }
        var result: [Int: String] = [:]
        var next = 0
        for (group, members) in sentences.groups.enumerated() {
            let start = cues[members.first!].start, end = cues[members.last!].end
            var parts: [String] = []
            while next < translated.count, translated[next].start < end - 0.01 {
                guard translated[next].start > start - 0.01 else { return [:] } // timings don't line up
                parts.append(translated[next].text)
                next += 1
            }
            guard !parts.isEmpty else { return [:] }
            result[group] = parts.joined(separator: " ")
        }
        return next == translated.count ? result : [:]
    }
}

enum SubtitleLanguage {
    /// Detects a subtitle file's language from its text (on device, NaturalLanguage).
    static func detect(_ cues: [SubtitleCue]) -> String? {
        let sample = cues.prefix(200).map { SubtitleFile.plainText($0.text) }.joined(separator: " ")
        guard let language = NLLanguageRecognizer.dominantLanguage(for: sample) else { return nil }
        let code = String(language.rawValue.prefix(2)) // "zh-Hans" → "zh"
        return Languages.isSupported(code) ? code : nil
    }
}
