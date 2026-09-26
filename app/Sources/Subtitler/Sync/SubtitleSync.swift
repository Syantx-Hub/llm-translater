import Foundation

/// Finds where a subtitle file is in the video you're watching, by matching what the
/// speech recognizer hears against the file's lines, then keeps the file's clock running
/// so each line can be shown at its own time — exactly with the actor, or even early.
///
/// The clock is an *anchor*: the wall-clock moment the video was at 0:00. The video time
/// is then `now - anchor`, frozen while playback is paused.
///
/// Not thread-safe; used from the main actor.
final class SubtitleSync {
    enum Status: Equatable {
        /// Listening for a line to find the place in the video.
        case searching
        case synced(videoTime: TimeInterval)
        case paused(videoTime: TimeInterval)
    }

    let cues: [SubtitleCue]
    private let normalized: [String]
    private(set) var anchor: Date?
    private var pausedAt: Date?
    /// A match that disagreed with the current anchor; a second one that agrees with it
    /// means the video jumped (seek, ad break, next episode).
    private var pendingAnchor: Date?

    /// Two matches agreeing within this are the same position.
    private let agreement: TimeInterval = 1.5
    /// How far from the expected position a synced search looks.
    private let searchWindow: TimeInterval = 45
    private let minScore = 0.55
    private let strongScore = 0.8

    /// A constant bias to take out of the clock: how late each kind of anchor comes out with
    /// each engine (positive: subtitles would show late). Measured on Tears of Steel (real
    /// dialogue over music and effects, its official SRT) with `--file --realtime --sync`;
    /// see docs/09-subtitle-sync.md.
    struct Bias: Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
        static let zero = Bias(start: 0, end: 0)
        /// The segmenter finds speech onsets accurately (−0.02 s on clean speech), but real
        /// subtitle files start a cue ~0.4 s before the words (lead-in): +0.39 s, median of
        /// 25 lines, so the clock follows the file's own timing.
        static let segmenter = Bias(start: 0.39, end: -0.17)
        /// Apple's phrase ranges also begin with some of the silence before the words:
        /// −0.84 s, median of 64 lines.
        static let appleSpeech = Bias(start: -0.84, end: -0.17)

        static func of(_ source: SpokenSpan.Source) -> Bias {
            switch source {
            case .segmenter: segmenter
            case .appleSpeech: appleSpeech
            }
        }
    }

    /// nil: each line's own engine decides (the app); a fixed bias for tests.
    let bias: Bias?

    init(cues: [SubtitleCue], bias: Bias? = nil) {
        self.cues = cues
        self.bias = bias
        normalized = cues.map { Self.normalize(SubtitleFile.plainText($0.text)) }
    }

    var isSynced: Bool { anchor != nil }

    func status(at now: Date) -> Status {
        guard let time = videoTime(at: now) else { return .searching }
        return pausedAt == nil ? .synced(videoTime: time) : .paused(videoTime: time)
    }

    func videoTime(at now: Date) -> TimeInterval? {
        anchor.map { (pausedAt ?? now).timeIntervalSince($0) }
    }

    /// The lines to show now, in order.
    func activeCues(at now: Date) -> [Int] {
        guard let time = videoTime(at: now) else { return [] }
        return cues.indices.filter { cues[$0].start <= time && time < cues[$0].end }
    }

    /// The next few lines from now, to translate before they're due.
    func upcomingCues(at now: Date, count: Int) -> [Int] {
        guard let time = videoTime(at: now) else { return [] }
        guard let first = cues.firstIndex(where: { $0.end > time }) else { return [] }
        return Array(first..<min(first + count, cues.count))
    }

    // MARK: Matching

    /// One heard line matched to the file, with the clock each end of it implies; for
    /// `--file --sync` measurements.
    struct Observation {
        let first: Int
        let last: Int
        let score: Double
        /// The anchor from the start of speech and the first cue's start, when both line up.
        let startAnchor: Date?
        /// The anchor from the end of speech and the last cue's end.
        let endAnchor: Date
        let usedStart: Bool
    }

    private(set) var lastObservation: Observation?

    @discardableResult
    func observe(_ heard: String, speechEndedAt: Date) -> Int? {
        observe(heard, spoken: SpokenSpan(start: nil, end: speechEndedAt))
    }

    /// Feeds a line the recognizer heard, spoken during `spoken`. Returns the matched cue
    /// when it moved or confirmed the clock.
    ///
    /// The clock is anchored on the *start* of speech against the cue's start when it can
    /// be: subtitlers time cue starts to the first word, while cue ends are padded for
    /// reading time (or trimmed), and a voice-activity detector notices the end of speech
    /// late under music. The end is the fallback: when the line began mid-speech, or began
    /// part-way into its cue.
    @discardableResult
    func observe(_ heard: String, spoken: SpokenSpan) -> Int? {
        let speechEndedAt = spoken.end
        let text = Self.normalize(heard)
        guard text.count >= 6, pausedAt == nil else { return nil }
        let expected = videoTime(at: spoken.start ?? speechEndedAt)
        let near = expected.map { ($0 - searchWindow)...($0 + searchWindow) }
        // Look near where the clock says we are first; if nothing matches there, the video
        // may have jumped, so search the whole file.
        var match = bestMatch(text, near: near)
        if near != nil, (match?.score ?? 0) < minScore { match = bestMatch(text, near: nil) }
        guard let match, match.score >= minScore else { return nil }
        let endAnchor = speechEndedAt.addingTimeInterval(-cues[match.last].end)
        // The start only counts if the heard line begins where the first cue does.
        let startAnchor = spoken.start.flatMap { start in
            Self.sameEdge(text, normalized[match.first], atStart: true)
                ? start.addingTimeInterval(-cues[match.first].start) : nil
        }
        let bias = self.bias ?? Bias.of(spoken.source)
        let candidate = startAnchor.map { $0.addingTimeInterval(-bias.start) } ?? endAnchor.addingTimeInterval(-bias.end)
        lastObservation = Observation(first: match.first, last: match.last, score: match.score,
                                      startAnchor: startAnchor, endAnchor: endAnchor, usedStart: startAnchor != nil)

        if let anchor {
            if abs(candidate.timeIntervalSince(anchor)) < agreement {
                // Same position: nudge towards it to follow small drift.
                self.anchor = anchor.addingTimeInterval(candidate.timeIntervalSince(anchor) * 0.3)
                pendingAnchor = nil
                return match.last
            }
            return adopt(candidate, strong: false, cue: match.last)
        }
        let strong = match.score >= strongScore && text.count >= 20
        return adopt(candidate, strong: strong, cue: match.last)
    }

    /// Takes a new position once it is confirmed: one strong match, or two agreeing ones.
    private func adopt(_ candidate: Date, strong: Bool, cue: Int) -> Int? {
        if strong || pendingAnchor.map({ abs($0.timeIntervalSince(candidate)) < agreement }) == true {
            anchor = candidate
            pendingAnchor = nil
            return cue
        }
        pendingAnchor = candidate
        return nil
    }

    private struct Match {
        let first: Int
        let last: Int
        let score: Double
    }

    /// Best run of 1–4 consecutive cues whose text matches `text`.
    private func bestMatch(_ text: String, near window: ClosedRange<TimeInterval>?) -> Match? {
        let heard = Self.bigrams(text)
        var best: Match?
        for first in cues.indices {
            if let window, !window.contains(cues[first].start) { continue }
            var joined = ""
            for last in first..<min(first + 4, cues.count) {
                joined += normalized[last]
                let score = Self.dice(heard, Self.bigrams(joined))
                if score > (best?.score ?? 0) { best = Match(first: first, last: last, score: score) }
                if joined.count > text.count * 2 { break }
            }
        }
        return best
    }

    // MARK: Pause

    /// Playback stopped (the system went digitally silent) at `time`.
    func pause(at time: Date) {
        guard anchor != nil, pausedAt == nil else { return }
        pausedAt = time
    }

    /// Playback resumed: the clock skips the paused stretch.
    func resume(at time: Date) {
        guard let pausedAt, let anchor else { return }
        self.anchor = anchor.addingTimeInterval(time.timeIntervalSince(pausedAt))
        self.pausedAt = nil
    }

    // MARK: Text similarity

    /// Lowercased letters and digits only, so punctuation, tags and spacing don't matter.
    /// Spaces are dropped too, which also makes Chinese and Japanese comparable.
    static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Whether two texts begin (or end) with the same words, compared on their first (or
    /// last) dozen characters: a line heard from the middle of a cue doesn't.
    static func sameEdge(_ heard: String, _ cue: String, atStart: Bool, length: Int = 12) -> Bool {
        let n = min(length, heard.count, cue.count)
        guard n >= 4 else { return false }
        let a = atStart ? String(heard.prefix(n)) : String(heard.suffix(n))
        let b = atStart ? String(cue.prefix(n)) : String(cue.suffix(n))
        return dice(bigrams(a), bigrams(b)) >= 0.5
    }

    static func bigrams(_ text: String) -> [String: Int] {
        let characters = Array(text)
        guard characters.count > 1 else { return characters.isEmpty ? [:] : [String(characters): 1] }
        var counts: [String: Int] = [:]
        for index in 0..<(characters.count - 1) {
            counts[String(characters[index...index + 1]), default: 0] += 1
        }
        return counts
    }

    /// Sørensen–Dice similarity of two bigram bags, 0–1.
    static func dice(_ a: [String: Int], _ b: [String: Int]) -> Double {
        let total = a.values.reduce(0, +) + b.values.reduce(0, +)
        guard total > 0 else { return 0 }
        let shared = a.reduce(0) { $0 + min($1.value, b[$1.key] ?? 0) }
        return 2 * Double(shared) / Double(total)
    }
}

/// Detects that playback paused: when a player pauses, the Mac's output goes digitally
/// silent (exact zeros), which a quiet scene never is.
final class PlaybackSilenceDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var silentSamples = 0
    private var isSilent = false
    private let threshold: Int
    var onChange: (@Sendable (_ silent: Bool, _ since: Date) -> Void)?

    /// - Parameter seconds: how long output must be silent to count as paused.
    init(seconds: Double = 0.6, sampleRate: Double = SystemAudioCapture.sampleRate) {
        threshold = Int(seconds * sampleRate)
    }

    func append(_ samples: [Float]) {
        let silentChunk = samples.allSatisfy { abs($0) < 1e-5 }
        lock.lock()
        silentSamples = silentChunk ? silentSamples + samples.count : 0
        let nowSilent = silentSamples >= threshold
        let changed = nowSilent != isSilent
        isSilent = nowSilent
        let silentFor = Double(silentSamples) / SystemAudioCapture.sampleRate
        lock.unlock()
        guard changed else { return }
        onChange?(nowSilent, Date().addingTimeInterval(nowSilent ? -silentFor : 0))
    }
}
