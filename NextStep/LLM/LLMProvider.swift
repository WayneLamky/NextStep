import Foundation

/// Shared shape every provider (Claude / OpenAI / Ollama) consumes.
///
/// Pure value type — no SwiftData references, so it's safe to ferry across
/// actor boundaries when we hop to a background task for the network call.
struct NextActionContext: Sendable {
    let projectName: String
    let level: ProjectLevel
    let monthGoal: String
    let weekGoal: String
    let dayAction: String
    /// Most-recent first, already capped to the last N entries.
    let recentCompleted: [CompletedSnapshot]
    /// Free-form user persona from settings ("研究生，ADHD，不擅长启动…").
    let persona: String

    struct CompletedSnapshot: Sendable {
        let action: String
        let completedAt: Date
    }

    /// Build a context from a `Project` + user settings. Capped at 8 completed
    /// items — the model doesn't need the full history, only enough to know
    /// what's already been done and pick a sensible next micro-step.
    @MainActor
    static func make(from project: Project, persona: String) -> NextActionContext {
        let recent = project.completedHistory
            .suffix(8)
            .map { CompletedSnapshot(action: $0.action, completedAt: $0.completedAt) }
        return NextActionContext(
            projectName: project.name,
            level: project.level,
            monthGoal: project.monthGoal,
            weekGoal: project.weekGoal,
            dayAction: project.dayAction,
            recentCompleted: recent,
            persona: persona
        )
    }
}

/// Structured result every provider must return.
struct NextActionResult: Sendable {
    let nextAction: String
    /// AI's estimate in minutes (1..=60). nil if unparseable.
    let estimatedMinutes: Int?
    /// If the AI thinks the current level's goal is done, which level to
    /// advance to. nil means stay.
    let levelAdvance: ProjectLevel?
}

enum LLMError: LocalizedError {
    case missingAPIKey(providerLabel: String)
    case httpError(status: Int, body: String)
    case decodingFailed(String)
    case noToolUseInResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let label):
            return "未设置 \(label) API Key。请在「设置 › LLM」里填入。"
        case .httpError(let status, let body):
            return "LLM 请求失败 (HTTP \(status))：\(body.prefix(160))"
        case .decodingFailed(let detail):
            return "LLM 响应解析失败：\(detail)"
        case .noToolUseInResponse:
            return "LLM 没有返回结构化结果，请重试。"
        case .cancelled:
            return "已取消。"
        }
    }
}

/// Every provider conforms to this. M3 ships Claude; M7 adds OpenAI + Ollama.
protocol LLMProvider: Sendable {
    func generateNextAction(context: NextActionContext) async throws -> NextActionResult
}

/// Which backend the user picked in Settings. Each kind owns its own
/// UserDefaults keys for base URL / model + (if applicable) Keychain slot.
enum LLMProviderKind: String, CaseIterable, Identifiable, Sendable {
    case anthropic
    case openai
    case ollama

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anthropic: return "Anthropic / Claude"
        case .openai:    return "OpenAI"
        case .ollama:    return "Ollama (本地)"
        }
    }
}

/// Small factory — reads the user's current provider choice and hands back
/// the matching instance. Called fresh on every request so changing the
/// picker in Settings takes effect immediately (no app restart).
enum LLMProviderResolver {
    static let providerKindKey = "llmProviderKind"

    static var currentKind: LLMProviderKind {
        let raw = UserDefaults.standard.string(forKey: providerKindKey) ?? LLMProviderKind.anthropic.rawValue
        return LLMProviderKind(rawValue: raw) ?? .anthropic
    }

    static func current() -> any LLMProvider {
        switch currentKind {
        case .anthropic: return ClaudeProvider.shared
        case .openai:    return OpenAIProvider.shared
        case .ollama:    return OllamaProvider.shared
        }
    }
}
