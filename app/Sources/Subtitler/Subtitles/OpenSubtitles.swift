import Foundation

enum OpenSubtitlesError: LocalizedError, Equatable {
    case missingAPIKey
    case http(Int, String?)
    case noDownloadLink

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add your free OpenSubtitles API key above to search."
        case .http(401, _), .http(403, _):
            "OpenSubtitles rejected the API key or login."
        case .http(406, let message), .http(429, let message):
            message ?? "OpenSubtitles download limit reached. It resets daily; logging in raises it."
        case .http(let code, let message):
            message ?? "OpenSubtitles answered with HTTP \(code)."
        case .noDownloadLink:
            "OpenSubtitles didn't return a download link."
        }
    }
}

/// One subtitle file found on OpenSubtitles.
struct SubtitleSearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let fileID: Int
    let fileName: String
    let title: String
    let year: Int?
    let language: String
    let release: String
    let downloads: Int
    /// "S02E05" for TV episodes.
    let episode: String?
    var seasonNumber: Int? = nil
    var episodeNumber: Int? = nil

    /// "Breaking Bad S01E01.en.srt" or "Parasite (2019).ko.srt": what the file is saved as.
    var savedFileName: String {
        let name = episode.map { "\(title) \($0)" } ?? year.map { "\(title) (\($0))" } ?? title
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: " ").split(separator: " ").joined(separator: " ")
        return "\(safe).\(language.isEmpty ? "und" : language).srt"
    }
}

/// What to look for: a title, optionally one TV episode.
struct SubtitleQuery: Equatable, Sendable {
    var title: String
    var season: Int?
    var episode: Int?

    var isEpisode: Bool { season != nil && episode != nil }

    /// Reads "breaking bad s01e01", "breaking bad 1x01" or "breaking bad season 1 episode 1"
    /// out of the title field. Season/episode typed into their own fields win.
    static func parse(_ text: String, season: String = "", episode: String = "") -> SubtitleQuery {
        var title = text
        var parsedSeason: Int?
        var parsedEpisode: Int?
        let patterns = [
            #"(?i)\bs(\d{1,2})\s*e(\d{1,3})\b"#,
            #"(?i)\b(\d{1,2})x(\d{1,3})\b"#,
            #"(?i)\bseason\s*(\d{1,2})\s*,?\s*episode\s*(\d{1,3})\b"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
                  let seasonRange = Range(match.range(at: 1), in: title),
                  let episodeRange = Range(match.range(at: 2), in: title),
                  let whole = Range(match.range, in: title)
            else { continue }
            parsedSeason = Int(title[seasonRange])
            parsedEpisode = Int(title[episodeRange])
            title.removeSubrange(whole)
            break
        }
        let cleaned = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return SubtitleQuery(
            title: cleaned,
            season: Int(season.trimmingCharacters(in: .whitespaces)) ?? parsedSeason,
            episode: Int(episode.trimmingCharacters(in: .whitespaces)) ?? parsedEpisode)
    }
}

/// Client for the OpenSubtitles REST API (https://opensubtitles.stoplight.io). Searching
/// needs an API key; downloading also works without an account, with a small daily limit
/// that a (free) login raises.
actor OpenSubtitlesClient {
    private let apiKey: String
    private let username: String?
    private let password: String?
    private var baseURL = URL(string: "https://api.opensubtitles.com/api/v1")!
    private var token: String?
    private let session: URLSession

    init(apiKey: String, username: String? = nil, password: String? = nil, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.username = username
        self.password = password
        self.session = session
    }

    /// A client configured from `Secrets`, or nil when there's no API key. The login (and so
    /// the Keychain) is only read when `withLogin`: downloading needs it, searching doesn't.
    static func fromSecrets(withLogin: Bool = true) -> OpenSubtitlesClient? {
        guard let key = Secrets.openSubtitlesAPIKey else { return nil }
        let login = withLogin ? Secrets.openSubtitlesLogin : nil
        return OpenSubtitlesClient(apiKey: key, username: login?.username, password: login?.password)
    }

    /// Checks the API key with a tiny lookup. (The `infos` endpoints answer any key, so they
    /// can't tell a wrong one; `features` rejects it with 401, `subtitles` with 403.)
    func verifyAPIKey() async throws {
        _ = try await send(URLRequest(url: Self.url(baseURL, "features", [URLQueryItem(name: "query", value: "matrix")])))
    }

    /// Checks a username and password by logging in once.
    func verifyLogin() async throws {
        token = nil
        try await logInIfConfigured()
        if token == nil { throw OpenSubtitlesError.http(401, nil) }
    }

    /// - Parameter languages: Whisper/ISO 639-1 codes to filter by (empty = any).
    func search(_ query: String, languages: [String]) async throws -> [SubtitleSearchResult] {
        try await search(SubtitleQuery(title: query), languages: languages)
    }

    /// Searches a film, or one episode of a show. For episodes the show is looked up first,
    /// so "breaking bad" can't match a film with the same words (El Camino).
    func search(_ query: SubtitleQuery, languages: [String]) async throws -> [SubtitleSearchResult] {
        var showID: Int?
        if query.isEpisode { showID = try? await findShow(query.title) }
        let data = try await send(URLRequest(url: searchURL(query, languages: languages, showID: showID)))
        return Self.rank(try Self.parseSearch(data), for: query)
    }

    /// The OpenSubtitles id of the TV show best matching `name`.
    func findShow(_ name: String) async throws -> Int? {
        let url = Self.url(baseURL, "features", [URLQueryItem(name: "query", value: name), URLQueryItem(name: "type", value: "tvshow")])
        let data = try await send(URLRequest(url: url))
        return Self.parseShowID(data)
    }

    /// Downloads the file and returns its text.
    func download(_ result: SubtitleSearchResult) async throws -> String {
        try await logInIfConfigured()
        var request = URLRequest(url: baseURL.appendingPathComponent("download"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["file_id": result.fileID])
        let data = try await send(request)
        guard let link = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["link"] as? String,
              let url = URL(string: link)
        else { throw OpenSubtitlesError.noDownloadLink }
        let (file, _) = try await session.data(from: url)
        guard let text = SubtitleFile.decode(file) else { throw SubtitleFileError.unreadable }
        return text
    }

    /// OpenSubtitles wants parameters sorted by name and lowercased; otherwise it answers
    /// with a redirect to the canonical URL.
    func searchURL(_ query: String, languages: [String]) -> URL {
        searchURL(SubtitleQuery(title: query), languages: languages, showID: nil)
    }

    func searchURL(_ query: SubtitleQuery, languages: [String], showID: Int?) -> URL {
        var items: [URLQueryItem] = []
        if let showID {
            items.append(URLQueryItem(name: "parent_feature_id", value: String(showID)))
        } else {
            items.append(URLQueryItem(name: "query", value: query.title))
        }
        if let season = query.season, let episode = query.episode {
            items += [URLQueryItem(name: "season_number", value: String(season)),
                      URLQueryItem(name: "episode_number", value: String(episode)),
                      URLQueryItem(name: "type", value: "episode")]
        }
        if !languages.isEmpty {
            items.append(URLQueryItem(name: "languages", value: languages.map(Self.apiLanguage).sorted().joined(separator: ",")))
        }
        return Self.url(baseURL, "subtitles", items)
    }

    /// OpenSubtitles wants parameters sorted by name, values lowercased and spaces as "+";
    /// anything else gets a 301 redirect to that canonical form.
    static func url(_ base: URL, _ path: String, _ items: [URLQueryItem]) -> URL {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        let query = items.sorted { $0.name < $1.name }.map { item in
            let value = (item.value ?? "").lowercased()
                .addingPercentEncoding(withAllowedCharacters: allowed)!
                .replacingOccurrences(of: "%20", with: "+")
            return "\(item.name)=\(value)"
        }.joined(separator: "&")
        return URL(string: base.appendingPathComponent(path).absoluteString + "?" + query)!
    }

    private func logInIfConfigured() async throws {
        guard token == nil, let username, let password else { return }
        var request = URLRequest(url: baseURL.appendingPathComponent("login"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        let data = try await send(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        token = json?["token"] as? String
        // Accounts can be served from another host (e.g. vip-api.opensubtitles.com).
        if let host = json?["base_url"] as? String, let url = URL(string: "https://\(host)/api/v1") { baseURL = url }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("Subtitler v0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw OpenSubtitlesError.http(status, message)
        }
        return data
    }

    /// OpenSubtitles uses ISO 639-1 codes, except for Chinese and Portuguese variants.
    static func apiLanguage(_ code: String) -> String {
        switch code {
        case "zh": "zh-cn"
        case "pt": "pt-br"
        default: code
        }
    }

    static func parseShowID(_ data: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["data"] as? [[String: Any]])?.first else { return nil }
        let attributes = first["attributes"] as? [String: Any]
        let raw = attributes?["feature_id"] ?? first["id"]
        return (raw as? Int) ?? (raw as? String).flatMap(Int.init)
    }

    /// Exact episode matches first. Otherwise the API's relevance order is kept between
    /// titles, and within a title, common good rips and then the most downloaded come first.
    static func rank(_ results: [SubtitleSearchResult], for query: SubtitleQuery) -> [SubtitleSearchResult] {
        func exact(_ result: SubtitleSearchResult) -> Bool {
            query.isEpisode && result.seasonNumber == query.season && result.episodeNumber == query.episode
        }
        func ripScore(_ result: SubtitleSearchResult) -> Int {
            let release = result.release.lowercased()
            if ["web-dl", "webdl", "webrip", "bluray", "blu-ray", "bdrip"].contains(where: release.contains) { return 2 }
            if ["hdtv", "dvdrip", "hdrip"].contains(where: release.contains) { return 1 }
            return 0
        }
        var titleOrder: [String: Int] = [:]
        for result in results where titleOrder[result.title] == nil { titleOrder[result.title] = titleOrder.count }
        return results.sorted {
            if exact($0) != exact($1) { return exact($0) }
            if titleOrder[$0.title] != titleOrder[$1.title] { return titleOrder[$0.title]! < titleOrder[$1.title]! }
            if ripScore($0) != ripScore($1) { return ripScore($0) > ripScore($1) }
            return $0.downloads > $1.downloads
        }
    }

    static func parseSearch(_ data: Data) throws -> [SubtitleSearchResult] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let attributes = item["attributes"] as? [String: Any],
                  let file = (attributes["files"] as? [[String: Any]])?.first,
                  let fileID = file["file_id"] as? Int
            else { return nil }
            let feature = attributes["feature_details"] as? [String: Any] ?? [:]
            let season = feature["season_number"] as? Int
            let episode = feature["episode_number"] as? Int
            let language = (attributes["language"] as? String ?? "").lowercased()
            return SubtitleSearchResult(
                id: item["id"] as? String ?? String(fileID),
                fileID: fileID,
                fileName: file["file_name"] as? String ?? "subtitles.srt",
                title: feature["parent_title"] as? String ?? feature["title"] as? String ?? feature["movie_name"] as? String ?? "Unknown title",
                year: feature["year"] as? Int,
                language: String(language.prefix(2)),
                release: attributes["release"] as? String ?? "",
                downloads: attributes["download_count"] as? Int ?? 0,
                episode: season.flatMap { s in episode.map { String(format: "S%02dE%02d", s, $0) } },
                seasonNumber: season, episodeNumber: episode)
        }
    }
}
