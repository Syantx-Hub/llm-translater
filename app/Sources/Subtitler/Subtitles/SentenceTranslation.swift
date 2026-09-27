import Foundation

/// What a translator should know about the whole film, sent with every batch.
struct FilmContext: Sendable, Equatable {
    /// Names that recur, to keep as names.
    var names: [String] = []
    /// Who the characters are to each other and how they speak (casual or polite): the
    /// model's cast sheet from reading the whole script, plus the viewer's own notes.
    var cast = ""
    /// How far into the story this batch is (0–1), so it only uses what the viewer knows by then.
    var position: Double?

    func at(_ group: Int, of total: Int) -> FilmContext {
        var copy = self
        copy.position = total > 0 ? Double(group) / Double(total) : nil
        return copy
    }
}

/// Engines that translate many lines per request with context (LLMs). Batching keeps a
/// film to a few dozen requests, and lets the model see who is talking to whom.
protocol BatchTranslating: Translator {
    /// Sentences per request.
    var batchSize: Int { get }
    /// Returns exactly one translation per line, in order.
    func translateBatch(_ lines: [String], from source: String, to target: String,
                        context: [String], film: FilmContext) async throws -> [String]
    /// Reads the whole script once and describes the characters and their relationships,
    /// so every batch uses the right register between each pair.
    /// - Parameters:
    ///   - title: the film or episode, from the file name, so the model can use what it
    ///     knows about it.
    ///   - background: who the characters are, looked up online (`FilmBackground` text);
    ///     empty when the lookup is off or found nothing.
    func castSheet(dialogue: [String], title: String?, background: String,
                   from source: String, to target: String) async throws -> String
}

/// The film's background text, fetched only when a batch engine needs it (so MADLAD
/// never triggers a lookup).
typealias BackgroundSource = @Sendable () async -> String

/// "Parasite (2019)" or "Breaking Bad S01E01", from a subtitle file's name: release tags,
/// the language code and dots are dropped.
enum FilmTitle {
    static func from(_ file: URL?) -> String? {
        guard let file else { return nil }
        var name = file.deletingPathExtension().lastPathComponent
        // "Movie.en" → "Movie"
        if let dot = name.lastIndex(of: "."), name.distance(from: dot, to: name.endIndex) <= 4 {
            let suffix = name[name.index(after: dot)...].lowercased()
            if Languages.isSupported(suffix) || ["eng", "kor", "jpn", "chi", "zho", "mya", "bur"].contains(suffix) {
                name = String(name[..<dot])
            }
        }
        name = name.replacingOccurrences(of: #"[._]"#, with: " ", options: .regularExpression)
        // Cut at the first release tag ("1080p", "WEB-DL", "x264", …), keeping a year or episode.
        let tags = #"(?i)\b(2160p|1080p|720p|480p|web[- ]?dl|webrip|bluray|brrip|bdrip|dvdrip|hdtv|x26[45]|h ?26[45]|hevc|aac|ddp?5 1|proper|repack|extended|remux|10bit|amzn|nf|hmax|dsnp)\b.*$"#
        name = name.replacingOccurrences(of: tags, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-[]")))
        return name.count >= 2 ? name : nil
    }
}

extension FilmContext {
    /// Everything known about the film before translating: names found on device, the
    /// film's background (looked up online, if turned on), the model's cast sheet (one
    /// request; skipped if it fails), and the viewer's notes.
    static func prepare(cues: [SubtitleCue], title: String?, from source: String, to target: String,
                        with batcher: BatchTranslating, notes: String,
                        background: BackgroundSource = { "" }) async -> FilmContext {
        let dialogue = cues.map { SubtitleFile.plainText($0.text) }
        let facts = await background()
        let sheet = (try? await batcher.castSheet(dialogue: dialogue, title: title, background: facts,
                                                  from: source, to: target)) ?? ""
        let viewer = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let cast = [sheet, viewer.isEmpty ? "" : "From the viewer (trust this over the above):\n" + viewer]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        return FilmContext(names: NameGlossary.names(in: dialogue), cast: cast)
    }
}

/// Translating a subtitle file's sentence groups, resumably: whatever is done is kept,
/// and a later run only translates the rest.
enum SentenceTranslation {
    struct Step: Sendable {
        let done: [Int: String]
        let requestsDone: Int
    }

    /// Thrown when a run stops early (quota, network, cancel) with work already done.
    struct Partial: Error {
        let done: [Int: String]
        let underlying: Error
    }

    /// Earlier sentences given to the model with each batch.
    static let contextLines = 6

    /// - Parameters:
    ///   - order: groups to translate, in the order to do them (e.g. from the current
    ///     position onwards); groups already in `done` are skipped.
    ///   - onStep: called after every request with everything translated so far.
    static func run(order: [Int], cues: [SubtitleCue], sentences: SubtitleSentences,
                    from source: String, to target: String, with translator: Translator,
                    done initial: [Int: String] = [:], title: String? = nil, notes: String = "",
                    background: BackgroundSource = { "" },
                    onStep: @Sendable (Step) async -> Void = { _ in }) async throws -> [Int: String] {
        var done = initial
        var requests = 0
        let pending = order.filter { done[$0] == nil }
        do {
            if let batcher = translator as? BatchTranslating {
                let film = pending.isEmpty ? FilmContext()
                    : await FilmContext.prepare(cues: cues, title: title, from: source, to: target, with: batcher,
                                                notes: notes, background: background)
                for batch in batches(pending, size: batcher.batchSize) {
                    try Task.checkCancellation()
                    let lines = batch.map { sentences.text(of: $0, in: cues) }
                    let context = (max(0, batch[0] - contextLines)..<batch[0]).map { sentences.text(of: $0, in: cues) }
                    let translations = try await batcher.translateBatch(lines, from: source, to: target,
                                                                        context: context,
                                                                        film: film.at(batch[0], of: sentences.groups.count))
                    for (group, translation) in zip(batch, translations) { done[group] = translation }
                    requests += 1
                    await onStep(Step(done: done, requestsDone: requests))
                }
            } else {
                // One sentence at a time; identical lines ("Yes.", "What?") once.
                var cache: [String: String] = [:]
                for group in pending {
                    try Task.checkCancellation()
                    let text = sentences.text(of: group, in: cues)
                    if text.isEmpty {
                        done[group] = ""
                    } else if let cached = cache[text] {
                        done[group] = cached
                    } else {
                        let translation = try await SubtitlePipeline.translate(text, from: source, to: target,
                                                                               context: [], with: translator)
                        cache[text] = translation
                        done[group] = translation
                        requests += 1
                    }
                    await onStep(Step(done: done, requestsDone: requests))
                }
            }
        } catch {
            throw Partial(done: done, underlying: error)
        }
        return done
    }

    /// Consecutive runs of at most `size`; a gap (a group already done) starts a new batch
    /// so each batch is one stretch of dialogue.
    static func batches(_ groups: [Int], size: Int) -> [[Int]] {
        var result: [[Int]] = []
        for group in groups {
            if let last = result.last, last.count < size, last.last! + 1 == group {
                result[result.count - 1].append(group)
            } else {
                result.append([group])
            }
        }
        return result
    }

    /// The translated file: one cue per translated group, spanning its cues.
    static func cues(_ done: [Int: String], sentences: SubtitleSentences, cues: [SubtitleCue]) -> [SubtitleCue] {
        done.keys.sorted().map { group in
            let members = sentences.groups[group]
            return SubtitleCue(start: cues[members.first!].start, end: cues[members.last!].end, text: done[group]!)
        }
    }
}

/// How big a whole-file cloud run is, shown before anything is sent.
struct CloudEstimate: Equatable {
    let cues: Int
    let groups: Int
    /// Groups still to translate (the rest are cached).
    let remaining: Int
    let requests: Int
    /// Rough duration, in seconds.
    let seconds: ClosedRange<Double>
    /// Share of today's free requests, when the daily limit is known.
    let dailyShare: Double?

    init(cues: Int, groups: Int, remaining: Int, batchSize: Int, limits: RateLimits?) {
        self.cues = cues
        self.groups = groups
        self.remaining = remaining
        // The batches, plus one request for the cast sheet.
        let requests = remaining == 0 ? 0 : Int((Double(remaining) / Double(max(batchSize, 1))).rounded(.up)) + 1
        self.requests = requests
        // Requests go one after another: each takes a few seconds for a batch reply, and a
        // requests-per-minute limit spaces them out further.
        let interval = limits?.requestsPerMinute.map { 60 / Double(max($0, 1)) } ?? 0
        let low = Double(requests) * max(interval, Self.fastReply)
        let high = Double(requests) * max(interval * 1.2, Self.slowReply)
        seconds = low...max(low, high)
        dailyShare = limits?.requestsPerDay.map { Double(requests) / Double(max($0, 1)) }
    }

    static let fastReply: Double = 4
    static let slowReply: Double = 10

    /// "about 4–5 min"
    var durationText: String {
        let low = Int((seconds.lowerBound / 60).rounded(.up)), high = Int((seconds.upperBound / 60).rounded(.up))
        if high <= 1 { return "under a minute" }
        return low == high ? "about \(low) min" : "about \(low)–\(high) min"
    }
}

/// A provider's limits for one model, as published (approximate; they change).
struct RateLimits: Hashable, Sendable {
    var requestsPerMinute: Int?
    var requestsPerDay: Int?
}

/// The viewer's notes about a film's characters ("Mina and Jin-woo are siblings"), kept per
/// subtitle file name so they're there next time. Not secret; stored in UserDefaults.
enum CharacterNotes {
    static func key(_ file: URL) -> String { "characterNotes." + file.deletingPathExtension().lastPathComponent }

    static func get(for file: URL?, defaults: UserDefaults = .standard) -> String {
        file.flatMap { defaults.string(forKey: key($0)) } ?? ""
    }

    static func set(_ notes: String, for file: URL?, defaults: UserDefaults = .standard) {
        guard let file else { return }
        defaults.set(notes, forKey: key(file))
    }
}
