import Foundation
import NaturalLanguage

/// Translations of a subtitle file's lines, made just ahead of where the video is.
actor SyncTranslations {
    private let cues: [SubtitleCue]
    private let translator: Translator
    private let source: String
    private let target: String
    private var done: [Int: String]
    private var queue: [Int] = []
    private var working = false

    /// - Parameter existing: translations already on disk (from Translate Subtitles), by index.
    init(cues: [SubtitleCue], translator: Translator, source: String, target: String, existing: [Int: String] = [:]) {
        self.cues = cues
        self.translator = translator
        self.source = source
        self.target = target
        done = existing
    }

    func translation(of index: Int) -> String? { done[index] }

    /// Translates these lines (in order) unless already done or queued.
    func prefetch(_ indices: [Int]) {
        let new = indices.filter { done[$0] == nil && !queue.contains($0) }
        // Newest request first: after a jump, the lines near the new position matter most.
        queue = new + queue.filter { !new.contains($0) }
        guard !working else { return }
        working = true
        Task { await work() }
    }

    private func work() async {
        while !queue.isEmpty {
            let index = queue.removeFirst()
            guard done[index] == nil else { continue }
            let text = SubtitleFile.plainText(cues[index].text)
            let translation = try? await SubtitlePipeline.translate(text, from: source, to: target, context: [], with: translator)
            done[index] = translation ?? text
        }
        working = false
    }

    /// Reuses a translated file made earlier ("Movie.my.srt" next to "Movie.en.srt") when
    /// its lines line up with these, so nothing has to be translated live.
    static func existingTranslations(for input: URL, cues: [SubtitleCue], target: String) -> [Int: String] {
        let folder = input.deletingLastPathComponent()
        let base = SubtitleFile.outputURL(for: input, target: target).deletingPathExtension().lastPathComponent
        let candidate = folder.appendingPathComponent(base.replacingOccurrences(of: #" \d+$"#, with: "", options: .regularExpression) + ".srt")
        guard candidate != input, let translated = try? SubtitleFile.read(candidate), translated.count == cues.count,
              zip(translated, cues).allSatisfy({ abs($0.start - $1.start) < 0.01 })
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: translated.enumerated().map { ($0.offset, $0.element.text) })
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
