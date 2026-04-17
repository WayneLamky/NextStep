import Foundation

/// Ollama local provider — talks to `http://localhost:11434/api/chat`.
///
/// Uses the `format` parameter with a JSON schema (supported since Ollama
/// 0.5) to force structured output. Models that ignore `format` will still
/// often return valid JSON thanks to the system prompt, but Qwen / Llama-3.1
/// / gpt-oss all do the right thing here.
///
/// No API key — this hits the local daemon. If the user is running Ollama
/// somewhere else, they can override `llmOllamaBaseURL`.
final class OllamaProvider: LLMProvider, @unchecked Sendable {
    static let shared = OllamaProvider()

    static let defaultBaseURL = "http://localhost:11434"
    static let defaultModel = "llama3.1"

    static let baseURLKey = "llmOllamaBaseURL"
    static let modelKey   = "llmOllamaModel"

    private var endpoint: URL {
        let base = UserDefaults.standard.string(forKey: Self.baseURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? Self.defaultBaseURL
        let normalized = base.isEmpty ? Self.defaultBaseURL : base
        let trimmed = normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
        return URL(string: "\(trimmed)/api/chat")!
    }

    private var model: String {
        let raw = UserDefaults.standard.string(forKey: Self.modelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? Self.defaultModel
        return raw.isEmpty ? Self.defaultModel : raw
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        // Local inference can be slow on CPU — give it more breathing room.
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 240
        return URLSession(configuration: c)
    }()

    private init() {}

    func generateNextAction(context: NextActionContext) async throws -> NextActionResult {
        let body = try buildRequestBody(context: context)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.httpError(status: -1, body: "no response (is ollama running on \(endpoint.host ?? "?"):\(endpoint.port ?? -1)?)")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            throw LLMError.httpError(status: http.statusCode, body: bodyStr)
        }

        return try parseResponse(data: data)
    }

    // MARK: - Request encoding

    private func buildRequestBody(context: NextActionContext) throws -> Data {
        guard let schemaObj = try JSONSerialization.jsonObject(
            with: Data(NextActionPrompt.toolSchemaJSON.utf8)
        ) as? [String: Any] else {
            throw LLMError.decodingFailed("tool schema is not a JSON object")
        }

        let payload: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": NextActionPrompt.systemPrompt],
                ["role": "user", "content": NextActionPrompt.buildUserPrompt(context: context)],
            ],
            // Ollama ≥ 0.5 accepts a full JSON schema here. Older daemons
            // treat unknown keys as "json" mode, which is also fine.
            "format": schemaObj,
            "options": [
                "temperature": 0.2,
            ],
        ]

        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    // MARK: - Response decoding

    private func parseResponse(data: Data) throws -> NextActionResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.decodingFailed("missing message.content")
        }

        guard let payloadData = content.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw LLMError.decodingFailed("content is not JSON: \(content.prefix(120))")
        }

        let action = (payload["next_action"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty else {
            throw LLMError.decodingFailed("empty next_action")
        }

        let minutes: Int?
        if let n = payload["estimated_minutes"] as? Int {
            minutes = n
        } else if let d = payload["estimated_minutes"] as? Double {
            minutes = Int(d)
        } else {
            minutes = nil
        }

        let advance: ProjectLevel?
        if let raw = payload["level_advance"] as? String {
            advance = ProjectLevel(rawValue: raw)
        } else {
            advance = nil
        }

        return NextActionResult(
            nextAction: action,
            estimatedMinutes: minutes,
            levelAdvance: advance
        )
    }
}
