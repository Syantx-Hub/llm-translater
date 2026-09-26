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

    init(cues: [SubtitleCue]) {
        self.cues = cues
        normalized = cues.map { Self.normalize(SubtitleFile.plainText($0.text)) }
    }

    var isSynced: Bool { anchor != nil }

    /// When the speech of a line that was just shown ended: the pipeline reports how long
    /// the line took after the segmenter closed it, and the segmenter closes a line
    /// `endSilence` after the last word (Apple Speech reports the end itself: pass 0).
    static func speechEnd(lineShownAt shown: Date, latency: TimeInterval, endSilence: TimeInterval) -> Date {
        shown.addingTimeInterval(-latency - endSilence)
    }

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

    /// Feeds a line the recognizer heard, ending at `speechEndedAt`. Returns the matched cue
    /// when it moved or confirmed the clock.
    @discardableResult
    func observe(_ heard: String, speechEndedAt: Date) -> Int? {
        let text = Self.normalize(heard)
        guard text.count >= 6, pausedAt == nil else { return nil }
        let expected = videoTime(at: speechEndedAt)
        let near = expected.map { ($0 - searchWindow)...($0 + searchWindow) }
        // Look near where the clock says we are first; if nothing matches there, the video
        // may have jumped, so search the whole file.
        var match = bestMatch(text, near: near)
        if near != nil, (match?.score ?? 0) < minScore { match = bestMatch(text, near: nil) }
        guard let match, match.score >= minScore else { return nil }
        // Anchor on the end of speech; subtitles end roughly when the words do.
        let candidate = speechEndedAt.addingTimeInterval(-cues[match.last].end)

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
