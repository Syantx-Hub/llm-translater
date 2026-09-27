import Foundation

/// The three request formats the providers speak.
enum CloudAPIStyle: Sendable {
    /// `POST {base}/chat/completions`, `Authorization: Bearer` (OpenAI, Mistral, DeepSeek,
    /// Groq, OpenRouter, Ollama, LM Studio).
    case openAIChat
    /// `POST /v1/messages`, `x-api-key` + `anthropic-version`.
    case anthropic
    /// `POST /v1beta/models/{model}:generateContent`, `x-goog-api-key`.
    case gemini
}

struct CloudModel: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    /// Published free-tier limits for this model, when the provider publishes them.
    var freeLimits: RateLimits?
}

/// A cloud translation provider. Facts (endpoints, headers, model IDs, free tiers, data
/// use) were taken from each provider's documentation on 2026-09-26; limits and prices
/// change, so the UI always calls them approximate and links the provider's own pages.
struct CloudProvider: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let style: CloudAPIStyle
    /// nil for Custom, whose address the user enters.
    let baseURL: URL?
    let models: [CloudModel]
    let defaultModel: String
    let keyPage: URL?
    let pricingPage: URL?
    let limitsPage: URL?
    /// One line on the free tier, or nil when there is none.
    let freeTier: String?
    /// Details for "Learn more": limits, regions, data use on the free tier.
    let freeTierNotes: [String]
    let dataUse: String
    let keyRequired: Bool
    /// How the provider names the output-length limit.
    let maxTokensField: String

    static func == (a: CloudProvider, b: CloudProvider) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var hasFreeTier: Bool { freeTier != nil }

    func model(_ id: String) -> CloudModel? { models.first { $0.id == id } }

    /// The official host requests may go to (nil for Custom: whatever the user entered,
    /// checked by `CloudHTTP.validate`).
    var officialHost: String? { baseURL?.host }
}

extension CloudProvider {
    static let all: [CloudProvider] = [openRouter, groq, gemini, openAI, anthropic, mistral, deepSeek, custom]

    static func provider(_ id: String) -> CloudProvider? { all.first { $0.id == id } }

    static let changeNote = "Limits change often; check the provider's page for your account."

    static let openAI = CloudProvider(
        id: "openai", name: "OpenAI", style: .openAIChat,
        baseURL: URL(string: "https://api.openai.com/v1")!,
        models: [
            CloudModel(id: "gpt-6-luna", label: "GPT-6 Luna (fast, cheapest)"),
            CloudModel(id: "gpt-6-sol", label: "GPT-6 Sol"),
            CloudModel(id: "gpt-6-astra", label: "GPT-6 Astra (best quality)"),
        ],
        defaultModel: "gpt-6-luna",
        keyPage: URL(string: "https://platform.openai.com/api-keys"),
        pricingPage: URL(string: "https://developers.openai.com/api/docs/pricing"),
        limitsPage: URL(string: "https://developers.openai.com/api/docs/guides/rate-limits"),
        freeTier: "Free tier in some countries; limits aren't published.",
        freeTierNotes: [
            "OpenAI offers a free tier in allowed countries; its per-model limits aren't published, so see your account's limits page.",
            changeNote,
        ],
        dataUse: "OpenAI says API data isn't used for training unless you opt in.",
        keyRequired: true, maxTokensField: "max_completion_tokens")

    static let anthropic = CloudProvider(
        id: "anthropic", name: "Anthropic", style: .anthropic,
        baseURL: URL(string: "https://api.anthropic.com/v1")!,
        models: [
            CloudModel(id: "claude-haiku-4-5", label: "Claude Haiku 4.5 (fast, cheapest)"),
            CloudModel(id: "claude-sonnet-5", label: "Claude Sonnet 5"),
            CloudModel(id: "claude-opus-5-5", label: "Claude Opus 5.5"),
            CloudModel(id: "claude-fable-5-1", label: "Claude Fable 5.1 (best quality)"),
        ],
        defaultModel: "claude-sonnet-5",
        keyPage: URL(string: "https://platform.claude.com/"),
        pricingPage: URL(string: "https://platform.claude.com/docs/en/about-claude/models/overview"),
        limitsPage: URL(string: "https://platform.claude.com/docs/en/api/rate-limits"),
        freeTier: nil,
        freeTierNotes: [],
        dataUse: "Anthropic says API inputs and outputs aren't used for training by default.",
        keyRequired: true, maxTokensField: "max_tokens")

    static let gemini = CloudProvider(
        id: "gemini", name: "Google Gemini", style: .gemini,
        baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        models: [
            CloudModel(id: "gemini-3.1-flash-lite", label: "Gemini 3.1 Flash-Lite (cheapest)"),
            CloudModel(id: "gemini-3.5-flash-lite", label: "Gemini 3.5 Flash-Lite (fast)"),
            CloudModel(id: "gemini-3.8-flash", label: "Gemini 3.8 Flash"),
            CloudModel(id: "gemini-3.1-pro-preview", label: "Gemini 3.1 Pro preview (best quality)"),
        ],
        defaultModel: "gemini-3.5-flash-lite",
        keyPage: URL(string: "https://aistudio.google.com/apikey"),
        pricingPage: URL(string: "https://ai.google.dev/gemini-api/docs/pricing"),
        limitsPage: URL(string: "https://aistudio.google.com/rate-limit"),
        freeTier: "Free tier on every model; limits shown in AI Studio.",
        freeTierNotes: [
            "Free-tier requests per minute and per day aren't published any more; AI Studio shows yours.",
            "On the free tier Google may use submitted text to improve its products, and human reviewers may read it.",
            "The Gemini API isn't available in every country (Myanmar isn't on Google's list), and in the EEA, Switzerland and the UK only paid use is allowed.",
            changeNote,
        ],
        dataUse: "Free tier: Google may use submitted text to improve its products.",
        keyRequired: true, maxTokensField: "maxOutputTokens")

    static let mistral = CloudProvider(
        id: "mistral", name: "Mistral", style: .openAIChat,
        baseURL: URL(string: "https://api.mistral.ai/v1")!,
        models: [
            CloudModel(id: "mistral-small-2603", label: "Mistral Small 4 (fast)"),
            CloudModel(id: "ministral-3-14b-2512", label: "Ministral 3 14B (cheapest)"),
            CloudModel(id: "mistral-large-2512", label: "Mistral Large 3"),
            CloudModel(id: "mistral-medium-2604", label: "Mistral Medium 3.5 (best quality)"),
        ],
        defaultModel: "mistral-small-2603",
        keyPage: URL(string: "https://console.mistral.ai"),
        pricingPage: URL(string: "https://mistral.ai/pricing/api"),
        limitsPage: URL(string: "https://admin.mistral.ai/plateforme/limits"),
        freeTier: "Free plan with monthly credits; limits shown in the console.",
        freeTierNotes: [
            "Mistral's free plan limits are shown only in its admin console.",
            "Check Admin › Privacy in Mistral's console for whether your data may be used to improve models, and opt out if you want.",
            changeNote,
        ],
        dataUse: "Check Mistral's privacy setting (Admin › Privacy) to opt out of training.",
        keyRequired: true, maxTokensField: "max_tokens")

    static let deepSeek = CloudProvider(
        id: "deepseek", name: "DeepSeek", style: .openAIChat,
        baseURL: URL(string: "https://api.deepseek.com")!,
        models: [
            CloudModel(id: "deepseek-flash", label: "DeepSeek Flash (fast, cheap)"),
            CloudModel(id: "deepseek-v4-pro", label: "DeepSeek V4 Pro (best quality)"),
        ],
        defaultModel: "deepseek-flash",
        keyPage: URL(string: "https://platform.deepseek.com"),
        pricingPage: URL(string: "https://api-docs.deepseek.com/quick_start/pricing"),
        limitsPage: URL(string: "https://api-docs.deepseek.com/quick_start/rate_limit"),
        freeTier: nil,
        freeTierNotes: [],
        dataUse: "DeepSeek's privacy policy says inputs may be used for training and are stored in China.",
        keyRequired: true, maxTokensField: "max_tokens")

    static let groq = CloudProvider(
        id: "groq", name: "Groq", style: .openAIChat,
        baseURL: URL(string: "https://api.groq.com/openai/v1")!,
        models: [
            CloudModel(id: "openai/gpt-oss-120b", label: "GPT-OSS 120B",
                       freeLimits: RateLimits(requestsPerMinute: 30, requestsPerDay: 1000)),
            CloudModel(id: "openai/gpt-oss-20b", label: "GPT-OSS 20B (fastest)",
                       freeLimits: RateLimits(requestsPerMinute: 30, requestsPerDay: 1000)),
            CloudModel(id: "qwen/qwen3.8-27b", label: "Qwen 3.8 27B (preview)",
                       freeLimits: RateLimits(requestsPerMinute: 30, requestsPerDay: 1000)),
        ],
        defaultModel: "openai/gpt-oss-120b",
        keyPage: URL(string: "https://console.groq.com/keys"),
        pricingPage: URL(string: "https://console.groq.com/docs/models"),
        limitsPage: URL(string: "https://console.groq.com/docs/rate-limits"),
        freeTier: "Free plan: about 30 requests/min, 1,000/day per model.",
        freeTierNotes: [
            "Groq's free plan allows about 30 requests a minute and 1,000 a day per model (tokens are limited too).",
            changeNote,
        ],
        dataUse: "Groq says it doesn't keep request data by default.",
        keyRequired: true, maxTokensField: "max_completion_tokens")

    static let openRouter = CloudProvider(
        id: "openrouter", name: "OpenRouter", style: .openAIChat,
        baseURL: URL(string: "https://openrouter.ai/api/v1")!,
        models: [
            CloudModel(id: "google/gemma-4-31b-it:free", label: "Gemma 4 31B (free)",
                       freeLimits: RateLimits(requestsPerMinute: 20, requestsPerDay: 50)),
            CloudModel(id: "qwen/qwen3.8-27b:free", label: "Qwen 3.8 27B (free)",
                       freeLimits: RateLimits(requestsPerMinute: 20, requestsPerDay: 50)),
            CloudModel(id: "openai/gpt-6-luna", label: "GPT-6 Luna (cheap)"),
            CloudModel(id: "google/gemini-3.8-flash", label: "Gemini 3.8 Flash"),
            CloudModel(id: "anthropic/claude-sonnet-5", label: "Claude Sonnet 5"),
        ],
        defaultModel: "google/gemma-4-31b-it:free",
        keyPage: URL(string: "https://openrouter.ai"),
        pricingPage: URL(string: "https://openrouter.ai/models"),
        limitsPage: URL(string: "https://openrouter.ai/docs/api/reference/limits"),
        freeTier: "Free models (\":free\"): about 20 requests/min, 50/day.",
        freeTierNotes: [
            "Free models allow about 20 requests a minute and 50 a day, or 1,000 a day once you've bought $10 of credits.",
            "Providers serving free models may use submitted text for training; OpenRouter's privacy settings control this.",
            changeNote,
        ],
        dataUse: "Free models: the serving provider may train on submitted text.",
        keyRequired: true, maxTokensField: "max_tokens")

    /// Any OpenAI-compatible server, including local ones (Ollama, LM Studio).
    static let custom = CloudProvider(
        id: "custom", name: "Custom (OpenAI-compatible)", style: .openAIChat,
        baseURL: nil, models: [], defaultModel: "",
        keyPage: nil, pricingPage: nil, limitsPage: nil,
        freeTier: nil, freeTierNotes: [],
        dataUse: "Local servers (Ollama, LM Studio) keep everything on this Mac.",
        keyRequired: false, maxTokensField: "max_tokens")

    /// Addresses of the common local servers, offered as presets for Custom.
    static let localPresets: [(name: String, url: String)] = [
        ("Ollama", "http://localhost:11434/v1"),
        ("LM Studio", "http://localhost:1234/v1"),
    ]
}
