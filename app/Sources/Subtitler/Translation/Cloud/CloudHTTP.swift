import Foundation

enum CloudError: LocalizedError, Equatable {
    /// The endpoint isn't https (or http on this Mac), so the key could be read in transit.
    case insecureEndpoint(String)
    case missingKey(String)
    case redirected
    case http(status: Int, message: String)
    /// The provider's quota for today (or the account's credit) is used up.
    case quotaExhausted(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .insecureEndpoint(let url):
            "\(url) isn't a secure address. Use https://, or http:// only for a server on this Mac (localhost)."
        case .missingKey(let provider): "Add your \(provider) API key in Models › Cloud."
        case .redirected: "The server tried to redirect the request to another address, so it wasn't sent."
        case .http(let status, let message): "The provider returned an error (\(status)): \(message)"
        case .quotaExhausted(let message): "Limit reached: \(message)"
        case .badResponse(let detail): "The provider's reply couldn't be read (\(detail))."
        }
    }
}

/// What a cloud request is doing, for the UI (e.g. a rate-limit countdown).
enum CloudEvent: Sendable, Equatable {
    case waiting(until: Date)
    case requestFinished
}

/// Sends API requests the careful way: an ephemeral session (no cache, cookies or stored
/// credentials), no redirects to another host (the auth header would follow them), https
/// only except for local servers, timeouts, and backoff on rate limits.
final class CloudHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let shared = CloudHTTP()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.badResponse("not HTTP") }
        // A refused redirect arrives as the 3xx response itself.
        if (300..<400).contains(http.statusCode) { throw CloudError.redirected }
        return (data, http)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        Self.allowsRedirect(from: task.originalRequest?.url, to: request.url) ? request : nil
    }

    /// Same scheme and host only: the Authorization header must never reach anyone else.
    static func allowsRedirect(from original: URL?, to target: URL?) -> Bool {
        guard let original, let target else { return false }
        return original.host?.lowercased() == target.host?.lowercased()
            && original.scheme?.lowercased() == target.scheme?.lowercased()
            && original.port == target.port
    }

    /// https anywhere; plain http only to this Mac (Ollama, LM Studio).
    static func validate(_ url: URL) throws {
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased() ?? ""
        if scheme == "https", !host.isEmpty { return }
        if scheme == "http", ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) { return }
        throw CloudError.insecureEndpoint(url.absoluteString)
    }

    // MARK: Retries

    /// Sends with retries: on 429 (and 5xx overload) waits for `retry-after` when the
    /// provider sends it, else 2, 4, 8 s. A long wait or a "quota"/"per day" error means
    /// today's limit is used up, which retrying won't fix.
    static func sendWithRetry(_ request: URLRequest, send: Send, secrets: [String],
                              onEvent: @Sendable (CloudEvent) -> Void,
                              sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                              maxAttempts: Int = 4) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            let (data, response) = try await send(request)
            let status = response.statusCode
            if (200..<300).contains(status) {
                onEvent(.requestFinished)
                return data
            }
            let message = redact(errorMessage(data) ?? HTTPURLResponse.localizedString(forStatusCode: status), secrets: secrets)
            let retryable = status == 429 || [500, 502, 503, 504, 529].contains(status)
            if status == 429 || status == 402, looksLikeQuota(message) { throw CloudError.quotaExhausted(message) }
            guard retryable, attempt < maxAttempts else {
                if status == 429 { throw CloudError.quotaExhausted(message) }
                throw CloudError.http(status: status, message: message)
            }
            let wait = retryAfter(response) ?? pow(2, Double(attempt))
            // Waiting minutes for a rate limit means a daily or hourly quota.
            if wait > 120 { throw CloudError.quotaExhausted(message) }
            onEvent(.waiting(until: Date().addingTimeInterval(wait)))
            try await sleep(wait)
        }
    }

    /// `retry-after` in seconds or as an HTTP date.
    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "retry-after")?.trimmingCharacters(in: .whitespaces) else {
            return nil
        }
        if let seconds = Double(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }

    static func looksLikeQuota(_ message: String) -> Bool {
        let lower = message.lowercased()
        return ["per day", "perday", "daily", "insufficient_quota", "quota exceeded", "exceeded your current quota",
                "credit balance", "insufficient balance", "billing"].contains { lower.contains($0) }
    }

    /// The human-readable part of a provider's error JSON: `error.message` (OpenAI style,
    /// Anthropic, Gemini) or `message` / `detail`.
    static func errorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data.prefix(300), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let error = object["error"] as? String { return error }
        return object["message"] as? String ?? object["detail"] as? String
    }

    // MARK: Redaction

    /// Removes the key, and anything shaped like one, from text shown or logged. Providers
    /// sometimes echo part of a rejected key back in their error messages.
    static func redact(_ text: String, secrets: [String]) -> String {
        var text = text
        for secret in secrets where secret.count >= 4 {
            text = text.replacingOccurrences(of: secret, with: "[key]")
        }
        let patterns = [
            #"(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}"#,
            #"sk-[A-Za-z0-9_-]{8,}"#,          // OpenAI, Anthropic (sk-ant-), DeepSeek, OpenRouter (sk-or-)
            #"AIza[0-9A-Za-z_-]{20,}"#,        // Google
            #"gsk_[A-Za-z0-9]{8,}"#,           // Groq
            #"(?i)(key|token)=[^&\s"]+"#,      // keys in echoed URLs
            #"\b[A-Za-z0-9_-]{32,}\b"#,        // any other long token (Mistral keys are 32)
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: "[key]", options: .regularExpression)
        }
        return text
    }
}
