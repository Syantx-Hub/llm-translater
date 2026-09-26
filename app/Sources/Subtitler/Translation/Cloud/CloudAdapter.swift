import Foundation

/// Builds requests and reads replies for each API style. Pure functions, so tests can
/// check exactly what would be sent without any network.
enum CloudAdapter {
    struct Prompt: Sendable {
        let system: String
        let user: String
        /// Room for the reply, including any hidden reasoning the model does.
        var maxTokens = 8192
    }

    /// The key goes only in a header, never the URL.
    static func request(provider: CloudProvider, model: String, baseURL: URL, key: String?,
                        prompt: Prompt) throws -> URLRequest {
        try CloudHTTP.validate(baseURL)
        var request: URLRequest
        var body: [String: Any]
        switch provider.style {
        case .openAIChat:
            request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
            if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            body = [
                "model": model,
                "messages": [["role": "system", "content": prompt.system], ["role": "user", "content": prompt.user]],
                provider.maxTokensField: prompt.maxTokens,
            ]
            body.merge(openAIOptions(provider: provider, model: model)) { $1 }
            if provider.id == CloudProvider.openRouter.id {
                request.setValue("Subtitler", forHTTPHeaderField: "X-OpenRouter-Title")
            }
        case .anthropic:
            request = URLRequest(url: baseURL.appendingPathComponent("messages"))
            if let key { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            // Current Claude models reject non-default temperature, so none is sent.
            body = [
                "model": model,
                "max_tokens": prompt.maxTokens,
                "system": prompt.system,
                "messages": [["role": "user", "content": prompt.user]],
            ]
        case .gemini:
            let path = "models/\(model):generateContent"
            request = URLRequest(url: baseURL.appendingPathComponent(path))
            if let key { request.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
            body = [
                "systemInstruction": ["parts": [["text": prompt.system]]],
                "contents": [["role": "user", "parts": [["text": prompt.user]]]],
                "generationConfig": ["temperature": 0.3, "maxOutputTokens": prompt.maxTokens],
            ]
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Per-provider options that make translation fast and steady. Newer OpenAI models only
    /// take `temperature` with reasoning off; DeepSeek thinks unless told not to.
    static func openAIOptions(provider: CloudProvider, model: String) -> [String: Any] {
        switch provider.id {
        case CloudProvider.openAI.id:
            if ["gpt-6-luna", "gpt-6-sol"].contains(model) { return ["reasoning_effort": "none", "temperature": 0.3] }
            if model == "gpt-6-astra" { return ["reasoning_effort": "low"] }
            return [:] // a typed-in model: send nothing it might reject
        case CloudProvider.deepSeek.id:
            return ["thinking": ["type": "disabled"], "temperature": 0.3]
        case CloudProvider.anthropic.id:
            return [:]
        default:
            return ["temperature": 0.3]
        }
    }

    /// The generated text, or the error a 200 reply can still carry (OpenRouter).
    static func text(style: CloudAPIStyle, from data: Data) throws -> String {
        // DeepSeek sends blank lines while a request is queued.
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
            throw CloudError.badResponse("not JSON")
        }
        if let error = object["error"] {
            let message = (error as? [String: Any])?["message"] as? String ?? "\(error)"
            throw CloudError.badResponse(message)
        }
        switch style {
        case .openAIChat:
            guard let choice = (object["choices"] as? [[String: Any]])?.first else { throw CloudError.badResponse("no choices") }
            if choice["finish_reason"] as? String == "error" { throw CloudError.badResponse("the model stopped with an error") }
            guard let content = (choice["message"] as? [String: Any])?["content"] as? String else {
                throw CloudError.badResponse("no message content")
            }
            return content
        case .anthropic:
            let blocks = object["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw CloudError.badResponse("no text") }
            return text
        case .gemini:
            let parts = ((object["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"]
                as? [[String: Any]] ?? []
            let text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw CloudError.badResponse("no text") }
            return text
        }
    }
}
