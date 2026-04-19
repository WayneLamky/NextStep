import Foundation

// MARK: - Chat turn result (LLM → UI)

/// Two-branch union of what the LLM can return on any turn of the intake
/// chat: either another **question card** (still gathering signal) or a
/// **synthesis** (enough info, here's the final plan).
///
/// Providers emit this as a single value so the UI doesn't have to know
/// which of the two JSON shapes it's decoding — that's the coordinator's job.
enum ChatTurnResult: Sendable, Equatable {
    case card(QuestionCard)
    case synthesis(IntakeResult)
}

/// A single round of 1–4 questions the UI renders as a card. The LLM also
/// tags the card with `progress` so the UI can show "3 / ~10".
struct QuestionCard: Codable, Sendable, Equatable {
    /// Free-form preamble shown above the question block (e.g. "好的，
    /// 我来帮你把这个项目拆清楚。先确认几件事："). Optional.
    let preamble: String?
    /// 1–4 questions for this turn.
    let questions: [Question]
    /// Approximate 1-based count (e.g. 3) — UI shows "问题 3 / ~10".
    /// The LLM self-tracks this; we don't enforce it.
    let progress: Int?
}

struct Question: Codable, Sendable, Equatable, Identifiable {
    /// LLM-supplied stable ID so we can thread answers back. Falls back to
    /// a UUID if the model returns nothing.
    let id: String
    let text: String
    /// Optional list of suggested answers. If non-empty the UI shows pills.
    let choices: [String]
    /// Whether the user may type an answer instead of / in addition to
    /// picking a choice. Default true for choice-less questions.
    let allowFreeText: Bool

    enum CodingKeys: String, CodingKey {
        case id, text, choices, allowFreeText
    }

    init(id: String, text: String, choices: [String] = [], allowFreeText: Bool = true) {
        self.id = id
        self.text = text
        self.choices = choices
        self.allowFreeText = allowFreeText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        self.text = try c.decode(String.self, forKey: .text)
        self.choices = (try? c.decode([String].self, forKey: .choices)) ?? []
        self.allowFreeText = (try? c.decode(Bool.self, forKey: .allowFreeText)) ?? true
    }
}

// MARK: - Synthesis result

/// Terminal output of the intake conversation. Either a long-term project
/// (with all four sticky fields pre-populated) OR a temp task that goes
/// straight to Reminders.
struct IntakeResult: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case project
        case tempTask = "temp_task"
    }

    let kind: Kind
    let project: ProjectSeed?
    let tempTask: TempTaskSeed?

    enum CodingKeys: String, CodingKey {
        case kind, project
        case tempTask = "temp_task"
    }
}

/// All the fields needed to materialize a `Project` + its first next action
/// in one shot. Carries no SwiftData references — pure value type.
struct ProjectSeed: Codable, Sendable, Equatable {
    let name: String
    let level: ProjectLevel
    let monthGoal: String
    let weekGoal: String
    let dayAction: String
    let seededNextAction: String
    let estimatedMinutes: Int?
    let dailyMinutes: Int
    /// ISO-8601 date string (YYYY-MM-DD) or nil for open-ended.
    let deadline: String?

    enum CodingKeys: String, CodingKey {
        case name, level
        case monthGoal = "month_goal"
        case weekGoal = "week_goal"
        case dayAction = "day_action"
        case seededNextAction = "seeded_next_action"
        case estimatedMinutes = "estimated_minutes"
        case dailyMinutes = "daily_minutes"
        case deadline
    }

    /// Parse the deadline string into a `Date` (UTC midnight).
    var deadlineDate: Date? {
        guard let d = deadline?.trimmingCharacters(in: .whitespacesAndNewlines),
              !d.isEmpty else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: d)
    }
}

/// Temp-task synthesis result. `dueDate` optional ISO-8601.
struct TempTaskSeed: Codable, Sendable, Equatable {
    let text: String
    /// ISO-8601 timestamp or nil.
    let dueDate: String?

    enum CodingKeys: String, CodingKey {
        case text
        case dueDate = "due_date"
    }

    var dueDateDate: Date? {
        guard let s = dueDate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        // Accept full ISO-8601 first, then date-only.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        if let d = f.date(from: s) { return d }
        f.dateFormat = "yyyy-MM-dd HH:mm"
        if let d = f.date(from: s) { return d }
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}

// MARK: - Chat message envelope

/// Minimal value-type chat message that providers consume. Deliberately
/// does NOT carry tool-use blocks — those are provider-internal; the
/// coordinator only ever sees user + assistant text.
struct ChatMessage: Sendable, Equatable, Identifiable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    var id: UUID = UUID()
    let role: Role
    let content: String
}

// MARK: - Decoding helpers

enum IntakeDecoding {
    /// Try to parse a raw tool-input / json-object dict as either a card or
    /// a synthesis. Returns nil if neither shape matches.
    static func decodeTurn(fromDict dict: [String: Any]) throws -> ChatTurnResult {
        // Heuristic: synthesis always has `kind` at top level.
        if let kindStr = dict["kind"] as? String,
           IntakeResult.Kind(rawValue: kindStr) != nil {
            let data = try JSONSerialization.data(withJSONObject: dict)
            let result = try JSONDecoder().decode(IntakeResult.self, from: data)
            return .synthesis(result)
        }
        // Otherwise treat as a question card.
        let data = try JSONSerialization.data(withJSONObject: dict)
        var card = try JSONDecoder().decode(QuestionCard.self, from: data)
        if card.questions.isEmpty {
            throw LLMError.decodingFailed("question card had 0 questions")
        }
        // Make sure every question has an id so answers thread cleanly.
        let patched = card.questions.enumerated().map { idx, q -> Question in
            if q.id.isEmpty {
                return Question(
                    id: "q\(idx)",
                    text: q.text,
                    choices: q.choices,
                    allowFreeText: q.allowFreeText
                )
            }
            return q
        }
        card = QuestionCard(
            preamble: card.preamble,
            questions: patched,
            progress: card.progress
        )
        return .card(card)
    }

    /// Pull the embedded JSON string out of a provider response whose
    /// `content` is supposed to be pure JSON but might be wrapped in
    /// ```json … ``` fences (some models do this despite schema mode).
    static func extractJSONObject(from raw: String) throws -> [String: Any] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip fenced code block if present.
        let stripped: String
        if trimmed.hasPrefix("```") {
            var body = trimmed.drop(while: { $0 == "`" })
            // optional language tag
            if let nl = body.firstIndex(of: "\n") {
                body = body[body.index(after: nl)...]
            }
            if let end = body.range(of: "```", options: .backwards) {
                body = body[..<end.lowerBound]
            }
            stripped = String(body).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            stripped = trimmed
        }
        guard let data = stripped.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decodingFailed("LLM content is not a JSON object: \(raw.prefix(120))")
        }
        return obj
    }
}
