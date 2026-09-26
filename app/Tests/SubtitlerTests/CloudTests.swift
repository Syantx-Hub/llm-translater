import Foundation
import Testing
@testable import Subtitler

/// A batch engine for tests: numbers its lines, can run out of quota after some batches.
actor FakeBatchTranslator: BatchTranslating {
    nonisolated let batchSize: Int
    private let quotaAfter: Int?
    private(set) var batches: [[String]] = []
    private(set) var contexts: [[String]] = []

    init(batchSize: Int = 3, quotaAfter: Int? = nil) {
        self.batchSize = batchSize
        self.quotaAfter = quotaAfter
    }

    func start() async throws {}
    func stop() async {}
    func translate(_ text: String, from source: String, to target: String, context: [String]) async throws -> String {
        "[\(target)] \(text)"
    }

    func translateBatch(_ lines: [String], from source: String, to target: String,
                        context: [String], names: [String]) async throws -> [String] {
        if let quotaAfter, batches.count >= quotaAfter { throw CloudError.quotaExhausted("per day") }
        batches.append(lines)
        contexts.append(context)
        return lines.map { "[\(target)] \($0)" }
    }
}

@Suite struct CloudEstimateTests {
    @Test func cuesToBatchesToRequestsToMinutes() {
        // 100 sentences in batches of 30 → 4 requests; 10 requests a minute → ≥ 6 s apart.
        let estimate = CloudEstimate(cues: 120, groups: 100, remaining: 100, batchSize: 30,
                                     limits: RateLimits(requestsPerMinute: 10, requestsPerDay: 200))
        #expect(estimate.requests == 4)
        #expect(estimate.seconds.lowerBound == 24) // 4 × 6 s
        #expect(estimate.seconds.upperBound == 40) // 4 × max(7.2, 10) s
        #expect(estimate.dailyShare == 0.02)
        #expect(estimate.durationText == "under a minute")
    }

    @Test func slowLimitsDominate() {
        let estimate = CloudEstimate(cues: 1200, groups: 1000, remaining: 1000, batchSize: 25,
                                     limits: RateLimits(requestsPerMinute: 5))
        #expect(estimate.requests == 40)
        #expect(estimate.seconds == 480...576) // 40 × 12 s … 40 × 14.4 s
        #expect(estimate.durationText == "about 8–10 min")
        #expect(estimate.dailyShare == nil)
    }

    @Test func cachedSentencesAreNotCounted() {
        #expect(CloudEstimate(cues: 50, groups: 40, remaining: 0, batchSize: 30, limits: nil).requests == 0)
        #expect(CloudEstimate(cues: 50, groups: 40, remaining: 31, batchSize: 30, limits: nil).requests == 2)
    }
}

@Suite struct LLMPromptTests {
    @Test func parsesNumberedReplies() {
        let reply = """
        Here you go:
        1. မင်္ဂလာပါ
        2) ဘယ်သွားမလဲ
        **3.** အိမ်ပြန်မယ်
        """
        #expect(LLMPrompt.parseNumbered(reply, count: 3) == ["မင်္ဂလာပါ", "ဘယ်သွားမလဲ", "အိမ်ပြန်မယ်"])
    }

    @Test func rejectsMissingOrDuplicatedNumbers() {
        #expect(LLMPrompt.parseNumbered("1. a\n3. c", count: 3) == nil)
        #expect(LLMPrompt.parseNumbered("1. a\n1. b\n2. c", count: 2) == nil)
        #expect(LLMPrompt.parseNumbered("1. a\n2.", count: 2) == nil)
    }

    @Test func batchPromptNumbersLinesAndListsNames() {
        let prompt = LLMPrompt.batch(["Hi, Jin.", "Where to?"], context: ["We're late."], names: ["Jin"])
        #expect(prompt.contains("Names in this film (keep them as names): Jin"))
        #expect(prompt.contains("> We're late."))
        #expect(prompt.hasSuffix("1. Hi, Jin.\n2. Where to?"))
    }

    @Test func systemPromptAsksForSpokenBurmese() {
        let system = LLMPrompt.system(from: "ko", to: "my")
        #expect(system.contains("from Korean into Burmese"))
        #expect(system.contains("colloquial spoken Burmese"))
        #expect(system.contains("Transliterate"))
    }

    @Test func cleansSingleReplies() {
        #expect(LLMPrompt.cleanSingle("\"ဘာလဲ\"") == "ဘာလဲ")
        #expect(LLMPrompt.cleanSingle("Translation: ဘာလဲ\n") == "ဘာလဲ")
    }

    @Test func findsRecurringNames() {
        let lines = ["Jin-woo, wait!", "Where is Jin-woo going?", "Tell Mina I said hi.", "Mina is at home.",
                     "London is far.", "Where are you?", "Where did you go?"]
        let names = NameGlossary.names(in: lines)
        #expect(names.contains("Jin-woo"))
        #expect(names.contains("Mina"))
        #expect(!names.contains("London")) // only once
        #expect(!names.contains("Where")) // only ever starts a sentence
    }
}

@Suite struct CloudHTTPTests {
    @Test func httpOnlyToThisMac() throws {
        try CloudHTTP.validate(URL(string: "https://api.example.com/v1")!)
        try CloudHTTP.validate(URL(string: "http://localhost:11434/v1")!)
        try CloudHTTP.validate(URL(string: "http://127.0.0.1:1234/v1")!)
        #expect(throws: CloudError.self) { try CloudHTTP.validate(URL(string: "http://api.example.com/v1")!) }
        #expect(throws: CloudError.self) { try CloudHTTP.validate(URL(string: "http://192.168.1.5:11434/v1")!) }
        #expect(throws: CloudError.self) { try CloudHTTP.validate(URL(string: "ftp://localhost/v1")!) }
    }

    @Test func refusesRedirectsToAnotherHost() {
        let api = URL(string: "https://api.openai.com/v1/chat/completions")
        #expect(CloudHTTP.allowsRedirect(from: api, to: URL(string: "https://api.openai.com/v1/other")))
        #expect(!CloudHTTP.allowsRedirect(from: api, to: URL(string: "https://evil.example.com/v1/chat/completions")))
        #expect(!CloudHTTP.allowsRedirect(from: api, to: URL(string: "http://api.openai.com/v1/chat/completions")))
        #expect(!CloudHTTP.allowsRedirect(from: api, to: URL(string: "https://api.openai.com:8443/v1")))
    }

    @Test func redactsKeysFromErrors() {
        let key = "sk-test-FAKEKEY0123456789abcdef"
        let message = "Incorrect API key provided: \(key). Also AIzaSyFAKE_fake-FAKE0123456789 and gsk_FAKE12345678 and Bearer abc.def.ghi123"
        let redacted = CloudHTTP.redact(message, secrets: [key])
        #expect(!redacted.contains("FAKE"))
        #expect(!redacted.contains("abc.def"))
        #expect(redacted.contains("Incorrect API key provided: [key]"))
    }

    @Test func rateLimitWaitsUseRetryAfter() async throws {
        let url = URL(string: "https://api.example.com/v1")!
        let replies = Recorder<Int>()
        let send: CloudHTTP.Send = { _ in
            replies.append(1)
            let limited = replies.values.count == 1
            let response = HTTPURLResponse(url: url, statusCode: limited ? 429 : 200, httpVersion: nil,
                                           headerFields: limited ? ["Retry-After": "7"] : [:])!
            return (Data((limited ? #"{"error":{"message":"Rate limit"}}"# : "ok").utf8), response)
        }
        let slept = Recorder<TimeInterval>()
        let events = Recorder<CloudEvent>()
        let started = Date()
        let data = try await CloudHTTP.sendWithRetry(URLRequest(url: url), send: send, secrets: [],
                                                     onEvent: { events.append($0) }, sleep: { slept.append($0) })
        #expect(String(data: data, encoding: .utf8) == "ok")
        #expect(slept.values == [7])
        guard case .waiting(let until) = events.values.first else { Issue.record("no countdown"); return }
        #expect(abs(until.timeIntervalSince(started) - 7) < 1)
        #expect(events.values.last == .requestFinished)
    }

    @Test func dailyQuotaStopsInsteadOfRetrying() async {
        let url = URL(string: "https://api.example.com/v1")!
        let send: CloudHTTP.Send = { _ in
            (Data(#"{"error":{"message":"Quota exceeded for requests per day"}}"#.utf8),
             HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: [:])!)
        }
        await #expect(throws: CloudError.quotaExhausted("Quota exceeded for requests per day")) {
            _ = try await CloudHTTP.sendWithRetry(URLRequest(url: url), send: send, secrets: [], onEvent: { _ in },
                                                  sleep: { _ in })
        }
    }
}

@Suite(.serialized) struct KeychainStoreTests {
    @Test func storesReadsAndDeletesAKey() throws {
        let store = KeychainStore(servicePrefix: "com.syantxhub.subtitler.tests.\(UUID().uuidString).")
        defer { try? store.delete("openai") }
        #expect(store.read("openai") == nil)
        try store.save("sk-test-FAKE-1234", for: "openai")
        #expect(store.read("openai") == "sk-test-FAKE-1234")
        #expect(store.hint("openai") == "••••1234")
        #expect(store.contains("openai"))
        try store.save("sk-test-FAKE-5678", for: "openai") // replace
        #expect(store.read("openai") == "sk-test-FAKE-5678")
        #expect(store.hint("openai") == "••••5678")
        try store.delete("openai")
        #expect(store.read("openai") == nil)
        #expect(!store.contains("openai") && store.hint("openai") == nil)
    }
}

@Suite struct CloudFileRunTests {
    private func cues(_ count: Int) -> [SubtitleCue] {
        (0..<count).map { SubtitleCue(start: Double($0) * 3, end: Double($0) * 3 + 2, text: "Line \($0 + 1).") }
    }

    @Test func batchesWithContext() async throws {
        let translator = FakeBatchTranslator(batchSize: 3)
        let result = try await SubtitleTranslator.translate(cues(7), from: "en", to: "my", with: translator) { _ in }
        #expect(result.count == 7)
        #expect(await translator.batches.map(\.count) == [3, 3, 1])
        #expect(await translator.contexts[1] == ["Line 1.", "Line 2.", "Line 3."])
    }

    @Test func quotaStopSavesPartialAndNextRunResumes() async throws {
        let folder = try makeTemporaryDirectory()
        let input = folder.appendingPathComponent("Movie.en.srt")
        let cues = cues(8)
        try SubtitleFile.srt(cues).write(to: input, atomically: true, encoding: .utf8)

        // First run: two batches of 3, then the daily limit.
        var partial: SubtitleTranslator.Stopped?
        do {
            _ = try await SubtitleTranslator.translate(cues, from: "en", to: "my",
                                                       with: FakeBatchTranslator(batchSize: 3, quotaAfter: 2)) { _ in }
        } catch let stopped as SubtitleTranslator.Stopped {
            partial = stopped
        }
        let stopped = try #require(partial)
        #expect(stopped.translated == 6 && stopped.total == 8)
        if case CloudError.quotaExhausted = stopped.underlying {} else { Issue.record("expected quota") }
        let cache = SubtitleFile.translationURL(for: input, target: "my")
        try SubtitleFile.srt(stopped.cues).write(to: cache, atomically: true, encoding: .utf8)

        // Next run: only the last two sentences are sent.
        let sentences = SubtitleSentences(cues: cues)
        let existing = SyncTranslations.existingTranslations(for: input, cues: cues, sentences: sentences, target: "my")
        #expect(existing.count == 6)
        let estimate = CloudEstimate(cues: 8, groups: 8, remaining: 8 - existing.count, batchSize: 3, limits: nil)
        #expect(estimate.requests == 1)
        let translator = FakeBatchTranslator(batchSize: 3)
        let result = try await SubtitleTranslator.translate(cues, from: "en", to: "my", with: translator,
                                                            existing: existing) { _ in }
        #expect(await translator.batches == [["Line 7.", "Line 8."]])
        #expect(result.map(\.text) == cues.map { "[my] \($0.text)" })
    }
}

@Suite struct CloudAdapterTests {
    private let key = "sk-test-FAKE-0000-1234"
    private let prompt = CloudAdapter.Prompt(system: "rules", user: "1. Hi", maxTokens: 100)

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    }

    private func expectKeyOnlyInHeader(_ request: URLRequest, header: String, value: String) {
        #expect(request.value(forHTTPHeaderField: header) == value)
        #expect(!(request.url?.absoluteString.contains(key) ?? true))
        #expect(!String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains(key))
    }

    @Test func openAIChatCompletions() throws {
        let provider = CloudProvider.openAI
        let request = try CloudAdapter.request(provider: provider, model: "gpt-6-luna", baseURL: provider.baseURL!,
                                               key: key, prompt: prompt)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        expectKeyOnlyInHeader(request, header: "Authorization", value: "Bearer \(key)")
        let json = try body(request)
        #expect(json["model"] as? String == "gpt-6-luna")
        #expect(json["max_completion_tokens"] as? Int == 100)
        #expect(json["max_tokens"] == nil)
        #expect(json["reasoning_effort"] as? String == "none")
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "rules"], ["role": "user", "content": "1. Hi"]])
    }

    @Test func openAIReasoningModelsGetNoTemperature() throws {
        let request = try CloudAdapter.request(provider: .openAI, model: "gpt-6-astra", baseURL: CloudProvider.openAI.baseURL!,
                                               key: key, prompt: prompt)
        #expect(try body(request)["temperature"] == nil)
    }

    @Test func anthropicMessages() throws {
        let provider = CloudProvider.anthropic
        let request = try CloudAdapter.request(provider: provider, model: "claude-sonnet-5", baseURL: provider.baseURL!,
                                               key: key, prompt: prompt)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        expectKeyOnlyInHeader(request, header: "x-api-key", value: key)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let json = try body(request)
        #expect(json["system"] as? String == "rules")
        #expect(json["max_tokens"] as? Int == 100)
        #expect(json["temperature"] == nil)
    }

    @Test func geminiGenerateContentWithTheKeyInAHeader() throws {
        let provider = CloudProvider.gemini
        let request = try CloudAdapter.request(provider: provider, model: "gemini-3.5-flash-lite", baseURL: provider.baseURL!,
                                               key: key, prompt: prompt)
        #expect(request.url?.absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent")
        #expect(request.url?.query == nil) // no ?key=
        expectKeyOnlyInHeader(request, header: "x-goog-api-key", value: key)
        let json = try body(request)
        let config = try #require(json["generationConfig"] as? [String: Any])
        #expect(config["maxOutputTokens"] as? Int == 100)
        #expect(((json["systemInstruction"] as? [String: Any])?["parts"] as? [[String: String]]) == [["text": "rules"]])
    }

    @Test func providerSpecifics() throws {
        let deepSeek = try body(CloudAdapter.request(provider: .deepSeek, model: "deepseek-flash",
                                                     baseURL: CloudProvider.deepSeek.baseURL!, key: key, prompt: prompt))
        #expect((deepSeek["thinking"] as? [String: String]) == ["type": "disabled"])
        #expect(deepSeek["max_tokens"] as? Int == 100)
        let groq = try CloudAdapter.request(provider: .groq, model: "openai/gpt-oss-120b",
                                            baseURL: CloudProvider.groq.baseURL!, key: key, prompt: prompt)
        #expect(groq.url?.absoluteString == "https://api.groq.com/openai/v1/chat/completions")
        #expect(try body(groq)["max_completion_tokens"] as? Int == 100)
        let openRouter = try CloudAdapter.request(provider: .openRouter, model: "google/gemma-4-31b-it:free",
                                                  baseURL: CloudProvider.openRouter.baseURL!, key: key, prompt: prompt)
        #expect(openRouter.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(openRouter.value(forHTTPHeaderField: "X-OpenRouter-Title") == "Subtitler")
    }

    @Test func customLocalServerNeedsNoKeyButMustBeLocalForHTTP() throws {
        let local = try CloudAdapter.request(provider: .custom, model: "gemma3", baseURL: URL(string: "http://localhost:11434/v1")!,
                                             key: nil, prompt: prompt)
        #expect(local.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(local.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(throws: CloudError.self) {
            _ = try CloudAdapter.request(provider: .custom, model: "x", baseURL: URL(string: "http://example.com/v1")!,
                                         key: key, prompt: prompt)
        }
    }

    @Test func readsEachReplyFormat() throws {
        #expect(try CloudAdapter.text(style: .openAIChat, from: Data(#"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#.utf8)) == "ok")
        #expect(try CloudAdapter.text(style: .openAIChat, from: Data("\n\n{\"choices\":[{\"message\":{\"content\":\"queued\"}}]}".utf8)) == "queued")
        #expect(try CloudAdapter.text(style: .anthropic, from: Data(#"{"content":[{"type":"thinking","thinking":"hm"},{"type":"text","text":"ok"}]}"#.utf8)) == "ok")
        #expect(try CloudAdapter.text(style: .gemini, from: Data(#"{"candidates":[{"content":{"parts":[{"text":"hm","thought":true},{"text":"ok"}]}}]}"#.utf8)) == "ok")
        #expect(throws: CloudError.self) {
            _ = try CloudAdapter.text(style: .openAIChat, from: Data(#"{"choices":[{"message":{"content":""},"finish_reason":"error"}]}"#.utf8))
        }
    }
}

@Suite struct CloudTranslatorTests {
    private func reply(_ text: String) -> Data {
        let json = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text]]]])
        return json
    }

    @Test func splitsABatchWhoseReplyDoesNotLineUp() async throws {
        let sent = Recorder<String>()
        let secrets = MemorySecretStore(["groq": "gsk_FAKE0000"])
        let translator = CloudTranslator(provider: .groq, model: "openai/gpt-oss-20b", baseURL: CloudProvider.groq.baseURL!,
                                         secrets: secrets) { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let user = ((body["messages"] as! [[String: String]])[1])["content"]!
            sent.append(user)
            let url = request.url!
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!
            // The 3-line batch comes back with a line missing; halves are answered properly.
            if user.contains("Translate these 3 lines") { return (self.reply("1. a\n2. b"), ok) }
            if user.contains("Translate these 2 lines") { return (self.reply("1. B\n2. C"), ok) }
            return (self.reply("A"), ok)
        }
        let result = try await translator.translateBatch(["one", "two", "three"], from: "en", to: "my", context: [], names: [])
        #expect(result == ["A", "B", "C"])
        #expect(sent.values.count == 3)
    }

    @Test func refusesToStartWithoutAKey() async {
        let translator = CloudTranslator(provider: .openAI, model: "gpt-6-luna", baseURL: CloudProvider.openAI.baseURL!,
                                         secrets: MemorySecretStore())
        await #expect(throws: CloudError.missingKey("OpenAI")) { try await translator.start() }
    }

    @Test func factoryPicksTheCloudEngine() throws {
        let defaults = makeDefaults()
        let secrets = MemorySecretStore(["openrouter": "sk-or-FAKE"])
        #expect(try TranslatorFactory.make(selection: "cloud:openrouter", defaults: defaults, secrets: secrets) is CloudTranslator)
        #expect(throws: TranslatorSelectionError.self) {
            try TranslatorFactory.make(selection: "cloud:openai", defaults: defaults, secrets: secrets) // no key
        }
        CloudConfig(defaults: defaults).customBaseURL = "http://localhost:11434/v1"
        CloudConfig(defaults: defaults).setModel("gemma3", for: .custom)
        #expect(try TranslatorFactory.make(selection: "cloud:custom", defaults: defaults, secrets: secrets) is CloudTranslator)
        #expect(try TranslatorFactory.make(selection: "off", defaults: defaults, secrets: secrets) is PassthroughTranslator)
    }
}
