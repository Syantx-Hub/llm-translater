import Foundation

/// Translation by a cloud (or local OpenAI-compatible) LLM, with the user's own key.
/// Only subtitle text is sent; audio never leaves the Mac.
///
/// The key is read from the Keychain for each request and not kept: it lives only as
/// long as building and sending that request.
actor CloudTranslator: BatchTranslating {
    /// Sentences per request: enough context for the model, small enough to redo cheaply.
    static let defaultBatchSize = 25
    nonisolated let batchSize = CloudTranslator.defaultBatchSize
    nonisolated let provider: CloudProvider
    private let model: String
    private let baseURL: URL
    private let secrets: SecretStore
    private let send: CloudHTTP.Send
    /// Requests are spaced to stay inside a published per-minute limit.
    private let minInterval: TimeInterval
    private var lastRequest: Date?
    private let onEvent: @Sendable (CloudEvent) -> Void

    init(provider: CloudProvider, model: String, baseURL: URL, secrets: SecretStore, limits: RateLimits? = nil,
         send: @escaping CloudHTTP.Send = { try await CloudHTTP.shared.send($0) },
         onEvent: @escaping @Sendable (CloudEvent) -> Void = { _ in }) {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.secrets = secrets
        self.send = send
        self.onEvent = onEvent
        minInterval = limits?.requestsPerMinute.map { 60 / Double(max($0, 1)) } ?? 0
    }

    func start() async throws {
        try CloudHTTP.validate(baseURL)
        if provider.keyRequired, !secrets.contains(provider.id) { throw CloudError.missingKey(provider.name) }
    }

    func stop() async {}

    func translate(_ text: String, from source: String, to target: String, context: [String]) async throws -> String {
        let reply = try await complete(CloudAdapter.Prompt(system: LLMPrompt.system(from: source, to: target),
                                                           user: LLMPrompt.single(text, context: context), maxTokens: 2048))
        return LLMPrompt.cleanSingle(reply)
    }

    /// One request per batch. If the reply doesn't have one numbered line per input, the
    /// batch is split in half and retried, down to single lines.
    func translateBatch(_ lines: [String], from source: String, to target: String,
                        context: [String], film: FilmContext) async throws -> [String] {
        guard lines.count > 1 else {
            return [try await translate(lines[0], from: source, to: target, context: context)]
        }
        let reply = try await complete(CloudAdapter.Prompt(
            system: LLMPrompt.system(from: source, to: target),
            user: LLMPrompt.batch(lines, context: context, film: film)))
        if let parsed = LLMPrompt.parseNumbered(reply, count: lines.count) { return parsed }
        Trace.log("cloud: \(lines.count)-line reply didn't line up; splitting")
        let half = lines.count / 2
        let first = try await translateBatch(Array(lines[..<half]), from: source, to: target, context: context, film: film)
        let second = try await translateBatch(Array(lines[half...]), from: source, to: target,
                                              context: context + lines[..<half], film: film)
        return first + second
    }

    func castSheet(dialogue: [String], title: String?, background: String,
                   from source: String, to target: String) async throws -> String {
        let reply = try await complete(CloudAdapter.Prompt(
            system: LLMPrompt.castSystem(from: source, to: target),
            user: LLMPrompt.castRequest(dialogue, title: title, background: background), maxTokens: 4096))
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The one-line request behind the Test button: checks the key, model and address.
    func test() async throws -> String {
        try await start()
        return try await translate("Hello, how are you?", from: "en", to: "my", context: [])
    }

    private func complete(_ prompt: CloudAdapter.Prompt) async throws -> String {
        if let lastRequest, minInterval > 0 {
            let wait = minInterval - Date().timeIntervalSince(lastRequest)
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        }
        lastRequest = Date()
        let started = Date()
        let data: Data
        do {
            // Only a local here; the Keychain store caches it so macOS asks at most once.
            let key = secrets.read(provider.id)
            if provider.keyRequired, key?.isEmpty != false { throw CloudError.missingKey(provider.name) }
            let request = try CloudAdapter.request(provider: provider, model: model, baseURL: baseURL, key: key, prompt: prompt)
            data = try await CloudHTTP.sendWithRetry(request, send: send, secrets: key.map { [$0] } ?? [], onEvent: onEvent)
        } catch let error as URLError {
            throw CloudError.badResponse(error.localizedDescription)
        }
        Trace.log("cloud: \(provider.id) \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        return try CloudAdapter.text(style: provider.style, from: data)
    }
}

/// Non-secret cloud settings, in UserDefaults: chosen model, custom address, free tier.
/// Keys are never here; they're in the Keychain (`KeychainStore`).
struct CloudConfig {
    let defaults: UserDefaults

    func model(for provider: CloudProvider) -> String {
        defaults.string(forKey: "cloud.\(provider.id).model") ?? provider.defaultModel
    }

    func setModel(_ model: String, for provider: CloudProvider) {
        defaults.set(model, forKey: "cloud.\(provider.id).model")
    }

    var customBaseURL: String {
        get { defaults.string(forKey: "cloud.custom.baseURL") ?? "" }
        nonmutating set { defaults.set(newValue, forKey: "cloud.custom.baseURL") }
    }

    /// Whether to pace requests to the free tier's published limits (on by default where
    /// there is a free tier).
    func usesFreeTier(_ provider: CloudProvider) -> Bool {
        provider.hasFreeTier && (defaults.object(forKey: "cloud.\(provider.id).freeTier") as? Bool ?? true)
    }

    func setUsesFreeTier(_ value: Bool, for provider: CloudProvider) {
        defaults.set(value, forKey: "cloud.\(provider.id).freeTier")
    }

    func baseURL(for provider: CloudProvider) -> URL? {
        provider.baseURL ?? URL(string: customBaseURL.trimmingCharacters(in: .whitespaces))
    }

    /// Published limits that apply, when the free tier is in use.
    func limits(for provider: CloudProvider) -> RateLimits? {
        usesFreeTier(provider) ? provider.model(model(for: provider))?.freeLimits : nil
    }

    /// Ready to use: a key saved (when needed), and for Custom an address and a model.
    func isConfigured(_ provider: CloudProvider, secrets: SecretStore) -> Bool {
        guard baseURL(for: provider) != nil, !model(for: provider).isEmpty else { return false }
        return !provider.keyRequired || secrets.contains(provider.id)
    }

    func translator(for provider: CloudProvider, secrets: SecretStore,
                    onEvent: @escaping @Sendable (CloudEvent) -> Void = { _ in }) throws -> CloudTranslator {
        guard let baseURL = baseURL(for: provider) else { throw CloudError.insecureEndpoint(customBaseURL) }
        try CloudHTTP.validate(baseURL)
        return CloudTranslator(provider: provider, model: model(for: provider), baseURL: baseURL, secrets: secrets,
                               limits: limits(for: provider), onEvent: onEvent)
    }
}

/// What cloud requests are doing right now, for countdowns in the UI.
@MainActor
final class CloudActivity: ObservableObject {
    static let shared = CloudActivity()
    /// Set while waiting out a rate limit.
    @Published private(set) var waitingUntil: Date?
    @Published private(set) var requests = 0

    /// Callable from any thread (the translator's events).
    nonisolated static func post(_ event: CloudEvent) {
        Task { @MainActor in shared.apply(event) }
    }

    private func apply(_ event: CloudEvent) {
        switch event {
        case .waiting(let until): waitingUntil = until
        case .requestFinished:
            waitingUntil = nil
            requests += 1
        }
    }
}
