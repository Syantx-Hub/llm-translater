import CryptoKit
import Foundation

/// Who the characters in a film are, looked up online by title so the translation can
/// get pronouns and politeness right between each pair: a mother and son, a boss and
/// employee, old friends. Only the title and year are sent, never subtitle text.
///
/// Sources, both free: Wikipedia (no key), reading only the lead and the cast section,
/// never the plot; and TMDB, only with the viewer's own key.
struct FilmBackground: Codable, Equatable, Sendable {
    struct Character: Codable, Equatable, Sendable {
        /// As listed: "Peter Parker / Spider-Man".
        var name: String
        var actor: String?
        /// Who they are when the story starts, in one sentence; empty from TMDB.
        var role: String
    }

    /// "Wikipedia", "TMDB" or "Wikipedia + TMDB".
    var source: String
    /// The Wikipedia page or TMDB title it came from.
    var page: String
    /// What the film is, from the lead (no plot).
    var summary: String
    var characters: [Character]
    /// Names as the target language's Wikipedia writes them: "Spider-Man" → "스파이더맨".
    var spellings: [String: String] = [:]

    var isEmpty: Bool { summary.isEmpty && characters.isEmpty }

    // MARK: Editable text

    /// The text the viewer sees and can edit before translating. `parse` reads it back.
    func text(target: String) -> String {
        var lines = ["From \(source): \(page)"]
        if !summary.isEmpty { lines.append(summary) }
        for character in characters {
            let actor = character.actor.map { " (\($0))" } ?? ""
            lines.append("- \(character.name)\(actor)" + (character.role.isEmpty ? "" : ": \(character.role)"))
        }
        if !spellings.isEmpty {
            let names = spellings.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }.joined(separator: ", ")
            lines.append("Names in \(Languages.name(target)): \(names)")
        }
        return lines.joined(separator: "\n")
    }

    /// Reads (possibly edited) background text. Unrecognised lines are ignored.
    static func parse(_ text: String, target: String) -> FilmBackground {
        var background = FilmBackground(source: "", page: "", summary: "", characters: [])
        let spellingPrefix = "Names in \(Languages.name(target)): "
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("From "), let colon = line.range(of: ": "), background.source.isEmpty {
                background.source = String(line[line.index(line.startIndex, offsetBy: 5)..<colon.lowerBound])
                background.page = String(line[colon.upperBound...])
            } else if line.hasPrefix("- ") {
                var entry = String(line.dropFirst(2))
                var role = ""
                if let colon = entry.range(of: ": ") {
                    role = String(entry[colon.upperBound...])
                    entry = String(entry[..<colon.lowerBound])
                }
                var actor: String?
                if entry.hasSuffix(")"), let open = entry.range(of: " (", options: .backwards) {
                    actor = String(entry[open.upperBound..<entry.index(before: entry.endIndex)])
                    entry = String(entry[..<open.lowerBound])
                }
                if !entry.isEmpty { background.characters.append(Character(name: entry, actor: actor, role: role)) }
            } else if line.hasPrefix(spellingPrefix) {
                for pair in line.dropFirst(spellingPrefix.count).components(separatedBy: ", ") {
                    let parts = pair.components(separatedBy: " → ")
                    if parts.count == 2 { background.spellings[parts[0]] = parts[1] }
                }
            } else if line.hasPrefix("Names in ") {
                continue // spellings for another target language
            } else if !line.isEmpty, background.summary.isEmpty, background.characters.isEmpty {
                background.summary = line
            }
        }
        return background
    }

    /// Each character's separate names: "Peter Parker / Spider-Man" → "Peter Parker", "Spider-Man".
    static func nameParts(_ name: String) -> [String] {
        name.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 }
    }
}

// MARK: - Query

/// What's searched for: the title (and year, or season and episode) from the file name.
struct FilmQuery: Equatable, Sendable {
    var title: String
    var year: Int?
    var season: Int?
    var episode: Int?

    var isEpisode: Bool { season != nil }

    /// "Parasite (2019)" → Parasite, 2019; "Breaking Bad S01E01" → Breaking Bad, 1, 1.
    init?(_ filmTitle: String?) {
        guard let filmTitle else { return nil }
        let parsed = SubtitleQuery.parse(filmTitle)
        var title = parsed.title
        if let match = title.range(of: #"\s*\(?\b(19|20)\d{2}\)?$"#, options: .regularExpression) {
            year = Int(title[match].filter(\.isNumber))
            title.removeSubrange(match)
        }
        title = title.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-")))
        guard title.count >= 2 else { return nil }
        self.title = title
        season = parsed.season
        episode = parsed.episode
    }

    init(title: String, year: Int? = nil, season: Int? = nil, episode: Int? = nil) {
        self.title = title
        self.year = year
        self.season = season
        self.episode = episode
    }

    /// Wikipedia page titles to try, most specific first.
    var wikipediaCandidates: [String] {
        if isEpisode {
            return (year.map { ["\(title) (\($0) TV series)"] } ?? []) + ["\(title) (TV series)", title]
        }
        return (year.map { ["\(title) (\($0) film)"] } ?? []) + ["\(title) (film)", title]
    }

    /// The cache key: the same film asked for into the same language.
    func cacheKey(target: String) -> String {
        [title.lowercased(), year.map(String.init) ?? "", season.map { "s\($0)" } ?? "", episode.map { "e\($0)" } ?? "", target]
            .joined(separator: "|")
    }
}

// MARK: - Wikipedia

enum Wikipedia {
    static let api = URL(string: "https://en.wikipedia.org/w/api.php")!

    static func url(_ parameters: [String: String], base: URL = api) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = (parameters.merging(["format": "json", "formatversion": "2"]) { $1 })
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    /// The first candidate page that exists and isn't a disambiguation page.
    static func resolvePage(_ data: Data, candidates: [String]) -> String? {
        guard let query = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["query"] as? [String: Any]
        else { return nil }
        func map(_ key: String) -> [String: String] {
            (query[key] as? [[String: Any]] ?? []).reduce(into: [:]) { result, item in
                if let from = item["from"] as? String, let to = item["to"] as? String { result[from] = to }
            }
        }
        let normalized = map("normalized"), redirects = map("redirects")
        var usable: Set<String> = []
        for page in query["pages"] as? [[String: Any]] ?? [] {
            guard page["missing"] == nil, page["invalid"] == nil, let title = page["title"] as? String else { continue }
            if let props = page["pageprops"] as? [String: Any], props["disambiguation"] != nil { continue }
            usable.insert(title)
        }
        for candidate in candidates {
            let title = normalized[candidate] ?? candidate
            let final = redirects[title] ?? title
            if usable.contains(final) { return final }
        }
        return nil
    }

    /// A search's top result, when it's the same title apart from punctuation and a
    /// "(… film)" qualifier: file names can't hold ":", so "Spider-Man Brand New Day" has to
    /// find "Spider-Man: Brand New Day". Anything looser could be a different film.
    static func searchMatch(_ data: Data, query: FilmQuery) -> String? {
        guard let results = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["query"] as? [String: Any])?["search"]
                as? [[String: Any]],
              let top = results.first?["title"] as? String else { return nil }
        let bare = top.replacingOccurrences(of: #"\s*\([^)]*\)$"#, with: "", options: .regularExpression)
        return comparable(bare) == comparable(query.title) ? top : nil
    }

    static func comparable(_ title: String) -> String {
        String(title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// The lead's first sentences, if it describes a film or series (the bare title can be
    /// anything: "Parasite" is also an organism). With a year, the lead must mention it.
    static func summary(_ data: Data, query: FilmQuery) -> String? {
        guard let pages = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["query"] as? [String: Any])?["pages"]
                as? [[String: Any]],
              let extract = pages.first?["extract"] as? String else { return nil }
        let lead = extract.components(separatedBy: "\n").first ?? extract
        let kinds = query.isEpisode ? ["series", "show", "sitcom", "drama", "anime"] : ["film", "movie", "series"]
        guard kinds.contains(where: { lead.localizedCaseInsensitiveContains($0) }) else { return nil }
        if let year = query.year, !lead.contains(String(year)) { return nil }
        return firstSentences(lead, count: 2, maxLength: 400)
    }

    /// The section holding the cast: "Cast", "Cast and characters", "Voice cast", "Characters".
    static func castSection(_ data: Data) -> String? {
        guard let sections = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["parse"] as? [String: Any])?["sections"]
                as? [[String: Any]] else { return nil }
        let names = ["cast", "cast and characters", "voice cast", "characters", "main cast", "starring"]
        let match = sections.first { names.contains(($0["line"] as? String ?? "").lowercased()) }
            ?? sections.first { ($0["line"] as? String ?? "").lowercased().contains("cast") }
        return match?["index"] as? String
    }

    static func wikitext(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["parse"] as? [String: Any])?["wikitext"] as? String
    }

    /// "* [[Tom Holland]] as [[Peter Parker (MCU)|Peter Parker / Spider-Man]]: A young hero…"
    /// → Peter Parker / Spider-Man, Tom Holland, "A young hero…" (first sentence only: the
    /// rest of an entry often runs into the story).
    static func characters(inCast wikitext: String, limit: Int = 25) -> [FilmBackground.Character] {
        var result: [FilmBackground.Character] = []
        for raw in wikitext.components(separatedBy: .newlines) where raw.hasPrefix("*") && !raw.hasPrefix("**") {
            let line = plainText(String(raw.drop { $0 == "*" || $0 == ":" }))
            guard let asRange = line.range(of: " as ") else { continue }
            let actor = String(line[..<asRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            var rest = String(line[asRange.upperBound...])
            var role = ""
            if let colon = rest.range(of: ":") ?? rest.range(of: ", ") {
                role = firstSentences(String(rest[colon.upperBound...]), count: 1, maxLength: 160)
                rest = String(rest[..<colon.lowerBound])
            }
            let name = rest.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.count <= 80, !actor.isEmpty, actor.count <= 60 else { continue }
            result.append(FilmBackground.Character(name: name, actor: actor, role: role))
            if result.count == limit { break }
        }
        return result
    }

    /// Target-language page titles for names, without "(…)" qualifiers. Redirects are
    /// skipped: "Peter Parker" redirects to "Spider-Man", whose title isn't his name.
    static func spellings(_ data: Data) -> [String: String] {
        guard let pages = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["query"] as? [String: Any])?["pages"]
                as? [[String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for page in pages {
            guard page["redirect"] == nil, let title = page["title"] as? String,
                  let link = (page["langlinks"] as? [[String: Any]])?.first?["title"] as? String else { continue }
            let written = link.replacingOccurrences(of: #"\s*\([^)]*\)$"#, with: "", options: .regularExpression)
            if !written.isEmpty { result[title] = written }
        }
        return result
    }

    /// Wikitext to plain text: links to their label, templates, references, comments and
    /// markup removed.
    static func plainText(_ wikitext: String) -> String {
        var text = wikitext
        let replacements: [(String, String)] = [
            (#"<!--[\s\S]*?-->"#, ""),
            (#"<ref[^>]*/>"#, ""),
            (#"<ref[^>]*>[\s\S]*?</ref>"#, ""),
            (#"<br\s*/?>"#, " "),
            (#"\{\{(?:nowrap|small|nobr)\|([^{}|]*)\}\}"#, "$1"),
        ]
        for (pattern, template) in replacements {
            text = text.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        // Nested templates: remove innermost first.
        while let range = text.range(of: #"\{\{[^{}]*\}\}"#, options: .regularExpression) { text.removeSubrange(range) }
        text = text.replacingOccurrences(of: #"\[\[[^\]|]*\|([^\]]*)\]\]"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[\[([^\]]*)\]\]"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "'''", with: "").replacingOccurrences(of: "''", with: "")
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func firstSentences(_ text: String, count: Int, maxLength: Int) -> String {
        var result = "", sentences = 0
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, stop in
            guard let sentence else { return }
            result += sentence
            sentences += 1
            if sentences == count { stop = true }
        }
        result = result.trimmingCharacters(in: .whitespaces)
        return result.count > maxLength ? String(result.prefix(maxLength - 1)) + "…" : result
    }
}

// MARK: - TMDB

/// The Movie Database, with the viewer's own "API Read Access Token" (sent as a Bearer
/// header, never in the URL).
enum TMDB {
    static let secretName = "tmdb"
    static let api = URL(string: "https://api.themoviedb.org/3/")!

    static func request(_ path: String, _ parameters: [String: String], token: String) -> URLRequest {
        var components = URLComponents(url: api.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func search(_ query: FilmQuery, token: String) -> URLRequest {
        var parameters = ["query": query.title, "include_adult": "false"]
        if let year = query.year { parameters[query.isEpisode ? "first_air_date_year" : "year"] = String(year) }
        return request(query.isEpisode ? "search/tv" : "search/movie", parameters, token: token)
    }

    /// The one result whose title matches exactly (and the year, when known); nil when
    /// none, or when several films share the title and nothing tells them apart.
    static func match(_ data: Data, query: FilmQuery) -> (id: Int, title: String)? {
        guard let results = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]]
        else { return nil }
        let titleKeys = query.isEpisode ? ["name", "original_name"] : ["title", "original_title"]
        let dateKey = query.isEpisode ? "first_air_date" : "release_date"
        let exact = results.filter { result in
            titleKeys.contains { (result[$0] as? String)?.caseInsensitiveCompare(query.title) == .orderedSame }
                && query.year.map { ((result[dateKey] as? String) ?? "").hasPrefix(String($0)) } ?? true
        }
        guard exact.count == 1, let id = exact[0]["id"] as? Int else { return nil }
        return (id, exact[0][titleKeys[0]] as? String ?? query.title)
    }

    static func credits(_ query: FilmQuery, id: Int, token: String) -> URLRequest {
        if let season = query.season, let episode = query.episode {
            return request("tv/\(id)/season/\(season)/episode/\(episode)/credits", [:], token: token)
        }
        return request(query.isEpisode ? "tv/\(id)/aggregate_credits" : "movie/\(id)/credits", [:], token: token)
    }

    /// Billed cast in order: movie credits, an episode's cast and guest stars, or a series'
    /// aggregate cast.
    static func characters(_ data: Data, limit: Int = 20) -> [FilmBackground.Character] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let people = (object["cast"] as? [[String: Any]] ?? []) + (object["guest_stars"] as? [[String: Any]] ?? [])
        return people.compactMap { person -> FilmBackground.Character? in
            let character = person["character"] as? String
                ?? (person["roles"] as? [[String: Any]])?.first?["character"] as? String
            let name = (character ?? "").replacingOccurrences(of: " (voice)", with: "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return FilmBackground.Character(name: name, actor: person["name"] as? String, role: "")
        }.prefix(limit).map { $0 }
    }
}

// MARK: - Lookup

/// Off unless the viewer turns it on. Stored in UserDefaults; not secret.
struct FilmBackgroundSettings {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var lookupEnabled: Bool {
        get { defaults.bool(forKey: "filmBackground.lookup") }
        nonmutating set { defaults.set(newValue, forKey: "filmBackground.lookup") }
    }

    static let toggleLabel = "Look up the film's cast online (sends only the film's title to Wikipedia/TMDB)"
}

/// Lookups saved on disk, one file per film and target language, so watching again sends
/// nothing. "Nothing found" is saved too.
struct FilmBackgroundCache: Sendable {
    let folder: URL

    static let app = FilmBackgroundCache(folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Subtitler/Film backgrounds", isDirectory: true))

    private struct Entry: Codable { var background: FilmBackground? }

    private func file(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(String(hash.prefix(32)) + ".json")
    }

    /// nil: never looked up. `.some(nil)`: looked up, nothing found.
    func get(_ key: String) -> FilmBackground?? {
        guard let data = try? Data(contentsOf: file(key)), let entry = try? JSONDecoder().decode(Entry.self, from: data)
        else { return nil }
        return .some(entry.background)
    }

    func set(_ background: FilmBackground?, for key: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Entry(background: background)).write(to: file(key), options: .atomic)
    }

    var count: Int { (try? FileManager.default.contentsOfDirectory(atPath: folder.path).count) ?? 0 }

    func clear() { try? FileManager.default.removeItem(at: folder) }
}

struct FilmBackgroundLookup: Sendable {
    var settings: @Sendable () -> Bool = { FilmBackgroundSettings().lookupEnabled }
    var cache: FilmBackgroundCache = .app
    var secrets: SecretStore = KeychainStore.app
    var send: CloudHTTP.Send = Self.defaultSend

    /// A plain session: no cookies, no cache, no identifying headers beyond the User-Agent.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.httpAdditionalHeaders = ["User-Agent": "Subtitler/1.0"]
        return URLSession(configuration: configuration)
    }()

    static let defaultSend: CloudHTTP.Send = { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// The film's background, or nil when the lookup is off, nothing matches clearly, or
    /// anything fails. Never throws: a translation doesn't depend on it.
    func lookup(_ query: FilmQuery?, target: String) async -> FilmBackground? {
        guard settings(), let query else { return nil }
        let key = query.cacheKey(target: target)
        if let cached = cache.get(key) { return cached }
        var background = await wikipedia(query, target: target)
        if let tmdb = await tmdb(query) {
            if var found = background {
                let known = Set(found.characters.flatMap { FilmBackground.nameParts($0.name).map { $0.lowercased() } })
                let extra = tmdb.characters.filter { !FilmBackground.nameParts($0.name).contains { known.contains($0.lowercased()) } }
                found.characters += extra.prefix(max(0, 25 - found.characters.count))
                if !extra.isEmpty { found.source = "Wikipedia + TMDB" }
                background = found
            } else {
                background = tmdb
            }
        }
        if Task.isCancelled { return background }
        cache.set(background, for: key)
        return background
    }

    private func get(_ request: URLRequest) async -> Data? {
        guard request.url?.scheme == "https", let (data, response) = try? await send(request),
              (200..<300).contains(response.statusCode) else { return nil }
        return data
    }

    private func get(_ url: URL) async -> Data? { await get(URLRequest(url: url)) }

    private func wikipedia(_ query: FilmQuery, target: String) async -> FilmBackground? {
        let candidates = query.wikipediaCandidates
        var page: String?
        if let pages = await get(Wikipedia.url(["action": "query", "titles": candidates.joined(separator: "|"),
                                                "redirects": "1", "prop": "pageprops", "ppprop": "disambiguation"])) {
            page = Wikipedia.resolvePage(pages, candidates: candidates)
        }
        if page == nil {
            let search = [query.title, query.year.map(String.init), query.isEpisode ? "TV series" : "film"]
                .compactMap { $0 }.joined(separator: " ")
            if let results = await get(Wikipedia.url(["action": "query", "list": "search", "srsearch": search,
                                                      "srlimit": "1", "srprop": ""])) {
                page = Wikipedia.searchMatch(results, query: query)
            }
        }
        guard let page,
              let lead = await get(Wikipedia.url(["action": "query", "titles": page, "prop": "extracts",
                                                  "exintro": "1", "explaintext": "1"])),
              let summary = Wikipedia.summary(lead, query: query)
        else { return nil }
        var characters: [FilmBackground.Character] = []
        if let sections = await get(Wikipedia.url(["action": "parse", "page": page, "prop": "sections"])),
           let index = Wikipedia.castSection(sections),
           let cast = await get(Wikipedia.url(["action": "parse", "page": page, "section": index, "prop": "wikitext"])),
           let wikitext = Wikipedia.wikitext(cast) {
            characters = Wikipedia.characters(inCast: wikitext)
        }
        var background = FilmBackground(source: "Wikipedia", page: page, summary: summary, characters: characters)
        let names = Array(Set(characters.flatMap { FilmBackground.nameParts($0.name) })).sorted().prefix(50)
        if target != "en", LocalLLMPrompt.script(of: target) != nil, !names.isEmpty,
           let links = await get(Wikipedia.url(["action": "query", "titles": names.joined(separator: "|"),
                                                "prop": "langlinks", "lllang": target, "lllimit": "max"])) {
            background.spellings = Wikipedia.spellings(links)
        }
        return background
    }

    private func tmdb(_ query: FilmQuery) async -> FilmBackground? {
        // No key, no TMDB, and no error: it's optional.
        guard secrets.contains(TMDB.secretName), let token = secrets.read(TMDB.secretName), !token.isEmpty,
              let results = await get(TMDB.search(query, token: token)),
              let match = TMDB.match(results, query: query),
              let credits = await get(TMDB.credits(query, id: match.id, token: token))
        else { return nil }
        let characters = TMDB.characters(credits)
        guard !characters.isEmpty else { return nil }
        return FilmBackground(source: "TMDB", page: match.title, summary: "", characters: characters)
    }
}

// MARK: - Per file

/// The background text for one subtitle file, as last looked up or edited by the viewer,
/// kept in UserDefaults by file name like `CharacterNotes`.
enum FilmBackgroundNotes {
    static func key(_ file: URL) -> String { "filmBackground." + file.deletingPathExtension().lastPathComponent }

    static func get(for file: URL?, defaults: UserDefaults = .standard) -> String {
        file.flatMap { defaults.string(forKey: key($0)) } ?? ""
    }

    static func set(_ text: String, for file: URL?, defaults: UserDefaults = .standard) {
        guard let file else { return }
        defaults.set(text, forKey: key(file))
    }

    /// Forgets every file's background (with the disk cache, when the viewer clears it).
    static func clearAll(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("filmBackground.") && key != "filmBackground.lookup" {
            defaults.removeObject(forKey: key)
        }
    }

    /// The file's background: the viewer's copy if there is one, otherwise a lookup (when
    /// turned on), saved as the viewer's copy. Empty when off or nothing was found.
    static func resolve(for file: URL?, target: String, lookup: FilmBackgroundLookup = FilmBackgroundLookup(),
                        defaults: UserDefaults = .standard) async -> String {
        let saved = get(for: file, defaults: defaults)
        if !saved.isEmpty { return saved }
        guard let background = await lookup.lookup(FilmQuery(FilmTitle.from(file)), target: target), !background.isEmpty
        else { return "" }
        let text = background.text(target: target)
        set(text, for: file, defaults: defaults)
        return text
    }
}
