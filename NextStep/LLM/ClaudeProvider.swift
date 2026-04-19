import Foundation

/// Anthropic Messages API provider.
///
/// There is no official Swift SDK, so we hit `/v1/messages` via URLSession.
/// We force structured output through a single tool (`record_next_action`)
/// and a `tool_choice` override — this sidesteps prose/JSON parsing and
/// hands us back a validated object.
///
/// The system prompt is static ("frozen") which lets Anthropic's prompt
/// cache kick in once it passes the minimum prefix length. If the system
/// prompt ever grows below/above the cache threshold, verify via
/// `usage.cache_read_input_tokens` > 0 on the second call.
final class ClaudeProvider: LLMProvider, @unchecked Sendable {
    static let shared = ClaudeProvider()

    /// Default Anthropic base URL. Users can override via Settings to point
    /// at Anthropic-compatible proxies (MiniMax, self-hosted gateways, etc.).
    static let defaultBaseURL = "https://api.anthropic.com"
    static let defaultModel = "claude-sonnet-4-6"

    private let apiVersion = "2023-06-01"
    private let maxTokens = 1024

    /// Pulls the user-configured base URL + model from UserDefaults on every
    /// request — cheap, and avoids a restart after changing settings.
    private var endpoint: URL {
        let base = UserDefaults.standard.string(forKey: "llmBaseURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? Self.defaultBaseURL
        let normalized = base.isEmpty ? Self.defaultBaseURL : base
        // Strip trailing slashes so we don't produce `...//v1/messages`.
        let trimmed = normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
        return URL(string: "\(trimmed)/v1/messages")!
    }

    private var model: String {
        let raw = UserDefaults.standard.string(forKey: "llmModel")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? Self.defaultModel
        return raw.isEmpty ? Self.defaultModel : raw
    }

    /// True when we're talking to Anthropic's own API. Third-party compatible
    /// endpoints (MiniMax etc.) may reject unknown fields like `cache_control`,
    /// so we only send them to the official endpoint.
    private var isOfficialAnthropic: Bool {
        endpoint.host?.hasSuffix("anthropic.com") == true
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 45
        c.timeoutIntervalForResource = 90
        return URLSession(configuration: c)
    }()

    private init() {}

    func generateNextAction(context: NextActionContext) async throws -> NextActionResult {
        guard let apiKey = KeychainStore.get(.anthropic),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.missingAPIKey(providerLabel: "Anthropic")
        }

        let body = try buildRequestBody(context: context)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
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
        // Build JSON by hand via JSONSerialization so we can embed the raw
        // tool input_schema without re-encoding each Codable layer.
        guard let schemaObj = try JSONSerialization.jsonObject(
            with: Data(NextActionPrompt.toolSchemaJSON.utf8)
        ) as? [String: Any] else {
            throw LLMError.decodingFailed("tool schema is not a JSON object")
        }

        // `cache_control` is an Anthropic-only optimization; compatible
        // proxies (MiniMax etc.) may 400 on unknown fields, so only send it
        // to the official API.
        var systemTextBlock: [String: Any] = [
            "type": "text",
            "text": NextActionPrompt.systemPrompt,
        ]
        if isOfficialAnthropic {
            systemTextBlock["cache_control"] = ["type": "ephemeral"]
        }
        let systemBlocks: [[String: Any]] = [systemTextBlock]

        let userPrompt = NextActionPrompt.buildUserPrompt(context: context)

        let messages: [[String: Any]] = [
            [
                "role": "user",
                "content": [
                    ["type": "text", "text": userPrompt]
                ],
            ]
        ]

        let tools: [[String: Any]] = [
            [
                "name": NextActionPrompt.toolName,
                "description": NextActionPrompt.toolDescription,
                "input_schema": schemaObj,
            ]
        ]

        let payload: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemBlocks,
            "messages": messages,
            "tools": tools,
            "tool_choice": [
                "type": "tool",
                "name": NextActionPrompt.toolName,
            ],
        ]

        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    // MARK: - Response decoding

    private func parseResponse(data: Data) throws -> NextActionResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decodingFailed("response is not a JSON object")
        }
        guard let content = root["content"] as? [[String: Any]] else {
            throw LLMError.decodingFailed("missing content array")
        }

        // Find the first tool_use block — with tool_choice set, the model is
        // required to call exactly our tool, but we still defend.
        for block in content {
            guard let type = block["type"] as? String, type == "tool_use" else { continue }
            guard let name = block["name"] as? String,
                  name == NextActionPrompt.toolName else { continue }
            guard let input = block["input"] as? [String: Any] else {
                throw LLMError.decodingFailed("tool_use input missing")
            }

            let action = (input["next_action"] as? String) ?? ""
            let trimmedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedAction.isEmpty else {
                throw LLMError.decodingFailed("empty next_action")
            }

            let minutes: Int?
            if let n = input["estimated_minutes"] as? Int {
                minutes = n
            } else if let d = input["estimated_minutes"] as? Double {
                minutes = Int(d)
            } else {
                minutes = nil
            }

            let advance: ProjectLevel?
            if let raw = input["level_advance"] as? String {
                advance = ProjectLevel(rawValue: raw)
            } else {
                advance = nil
            }

            return NextActionResult(
                nextAction: trimmedAction,
                estimatedMinutes: minutes,
                levelAdvance: advance
            )
        }

        throw LLMError.noToolUseInResponse
    }

    // MARK: - Q&A Intake chat

    func chat(messages: [ChatMessage], systemPrompt: String) async throws -> ChatTurnResult {
        guard let apiKey = KeychainStore.get(.anthropic),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.missingAPIKey(providerLabel: "Anthropic")
        }

        let body = try buildChatRequestBody(messages: messages, systemPrompt: systemPrompt)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.httpError(status: -1, body: "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            throw LLMError.httpError(status: http.statusCode, body: bodyStr)
        }

        return try parseChatResponse(data: data)
    }

    private func buildChatRequestBody(messages: [ChatMessage], systemPrompt: String) throws -> Data {
        guard let askSchema = try JSONSerialization.jsonObject(
            with: Data(IntakePrompt.askQuestionsSchemaJSON.utf8)
        ) as? [String: Any] else {
            throw LLMError.decodingFailed("ask_questions schema is not a JSON object")
        }
        guard let synthSchema = try JSONSerialization.jsonObject(
            with: Data(IntakePrompt.synthesizePlanSchemaJSON.utf8)
        ) as? [String: Any] else {
            throw LLMError.decodingFailed("synthesize_plan schema is not a JSON object")
        }

        var systemBlock: [String: Any] = [
            "type": "text",
            "text": systemPrompt,
        ]
        if isOfficialAnthropic {
            systemBlock["cache_control"] = ["type": "ephemeral"]
        }

        let apiMessages: [[String: Any]] = messages.map { msg in
            [
                "role": msg.role.rawValue,
                "content": [
                    ["type": "text", "text": msg.content]
                ],
            ]
        }

        let tools: [[String: Any]] = [
            [
                "name": IntakePrompt.askQuestionsToolName,
                "description": IntakePrompt.askQuestionsToolDesc,
                "input_schema": askSchema,
            ],
            [
                "name": IntakePrompt.synthesizeToolName,
                "description": IntakePrompt.synthesizeToolDesc,
                "input_schema": synthSchema,
            ],
        ]

        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "system": [systemBlock],
            "messages": apiMessages,
            "tools": tools,
            // tool_choice: any forces the model to call exactly one of our
            // two tools — no prose, no deciding to skip. "any" disallows
            // non-tool responses; "auto" would let Claude answer in text.
            "tool_choice": ["type": "any"],
        ]

        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    private func parseChatResponse(data: Data) throws -> ChatTurnResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decodingFailed("response is not a JSON object")
        }
        guard let content = root["content"] as? [[String: Any]] else {
            throw LLMError.decodingFailed("missing content array")
        }

        for block in content {
            guard let type = block["type"] as? String, type == "tool_use" else { continue }
            guard let name = block["name"] as? String else { continue }
            guard let input = block["input"] as? [String: Any] else {
                throw LLMError.decodingFailed("tool_use input missing")
            }

            if name == IntakePrompt.synthesizeToolName {
                let inputData = try JSONSerialization.data(withJSONObject: input)
                let result = try JSONDecoder().decode(IntakeResult.self, from: inputData)
                return .synthesis(result)
            }
            if name == IntakePrompt.askQuestionsToolName {
                let inputData = try JSONSerialization.data(withJSONObject: input)
                let card = try JSONDecoder().decode(QuestionCard.self, from: inputData)
                guard !card.questions.isEmpty else {
                    throw LLMError.decodingFailed("ask_questions returned 0 questions")
                }
                return .card(card)
            }
        }

        throw LLMError.noToolUseInResponse
    }
}
