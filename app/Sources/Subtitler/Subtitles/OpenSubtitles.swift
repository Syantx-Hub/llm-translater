import Foundation

enum OpenSubtitlesError: LocalizedError, Equatable {
    case missingAPIKey
    case http(Int, String?)
    case noDownloadLink

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add OPENSUBTITLES_API_KEY to a .env file (see README) to search OpenSubtitles."
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

    /// A client configured from `.env`, or nil when there's no API key.
    static func fromSecrets() -> OpenSubtitlesClient? {
        guard let key = Secrets.openSubtitlesAPIKey else { return nil }
        return OpenSubtitlesClient(apiKey: key, username: Secrets.openSubtitlesUsername, password: Secrets.openSubtitlesPassword)
    }

    /// - Parameter languages: Whisper/ISO 639-1 codes to filter by (empty = any).
    func search(_ query: String, languages: [String]) async throws -> [SubtitleSearchResult] {
        var components = URLComponents(url: baseURL.appendingPathComponent("subtitles"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "query", value: query.lowercased())]
        if !languages.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "languages", value: languages.map(Self.apiLanguage).sorted().joined(separator: ",")))
        }
        let data = try await send(URLRequest(url: components.url!))
        return try Self.parseSearch(data)
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
                episode: season.flatMap { s in episode.map { String(format: "S%02dE%02d", s, $0) } })
        }
    }
}
