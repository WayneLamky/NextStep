import Foundation

/// OpenAI Chat Completions provider.
///
/// Uses the `response_format.json_schema` strict mode, which forces the
/// model to return a JSON object that validates against our schema —
/// equivalent role to Claude's tool_use trick. No official Swift SDK;
/// we hit `/v1/chat/completions` directly.
///
/// Supports the OpenAI API plus any OpenAI-compatible endpoint the user
/// points `llmOpenAIBaseURL` at (Groq, Together, LocalAI, etc.).
final class OpenAIProvider: LLMProvider, @unchecked Sendable {
    static let shared = OpenAIProvider()

    static let defaultBaseURL = "https://api.openai.com"
    static let defaultModel = "gpt-4.1-mini"

    static let baseURLKey = "llmOpenAIBaseURL"
    static let modelKey   = "llmOpenAIModel"

    private var endpoint: URL {
        let base = UserDefaults.standard.string(forKey: Self.baseURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? Self.defaultBaseURL
        let normalized = base.isEmpty ? Self.defaultBaseURL : base
        let trimmed = normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
        return URL(string: "\(trimmed)/v1/chat/completions")!
    }

    private var model: String {
        let raw = UserDefaults.standard.string(forKey: Self.modelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? Self.defaultModel
        return raw.isEmpty ? Self.defaultModel : raw
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 45
        c.timeoutIntervalForResource = 90
        return URLSession(configuration: c)
    }()

    private init() {}

    func generateNextAction(context: NextActionContext) async throws -> NextActionResult {
        guard let apiKey = KeychainStore.get(.openai),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.missingAPIKey(providerLabel: "OpenAI")
        }

        let body = try buildRequestBody(context: context)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.httpError(status: -1, body: "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            throw LLMError.httpError(status: http.statusCode, body: bodyStr)
        }

        return try parseResponse(data: data)
    }

    // MARK: - Request encoding

    private func buildRequestBody(context: NextActionContext) throws -> Data {
        // OpenAI's strict json_schema requires every property to be listed
        // under `required` and `additionalProperties: false`. Build it inline
        // rather than reusing Anthropic's schema (which has `estimated_minutes`
        // optional and level_advance outside the strict shape).
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["next_action", "estimated_minutes", "level_advance"],
            "properties": [
                "next_action": [
                    "type": "string",
                    "description": "单句动作，动词开头，15 分钟内可启动。",
                ],
                "estimated_minutes": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 60,
                ],
                // strict mode: union with null instead of making the field optional
                "level_advance": [
                    "type": ["string", "null"],
                    "enum": ["week", "day", NSNull()],
                ],
            ],
        ]

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": NextActionPrompt.systemPrompt],
                ["role": "user", "content": NextActionPrompt.buildUserPrompt(context: context)],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": NextActionPrompt.toolName,
                    "strict": true,
                    "schema": schema,
                ],
            ],
        ]

        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    // MARK: - Response decoding

    private func parseResponse(data: Data) throws -> NextActionResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.decodingFailed("missing choices[0].message.content")
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
