import Foundation
import Observation

/// State container for a single intake conversation. Observable so the
/// SwiftUI view rebinds on every turn.
///
/// Holds **UI-facing** state only — the actual LLM call lives in
/// `IntakeCoordinator`. This split lets the view render a "thinking…"
/// spinner while the coordinator is mid-request without tangling request
/// mechanics into view code.
@MainActor
@Observable
final class IntakeSession {
    /// Full visible turn history. Grows linearly; card turns are rendered
    /// as interactive widgets, plain assistant turns (preamble text) as
    /// simple chat bubbles.
    var turns: [IntakeTurn] = []

    /// Attachments the user has dropped / picked. Capped per `AttachmentLimits`.
    var attachments: [AttachmentPayload] = []

    /// Free-form opening topic from the user (populated on first submit).
    var topic: String = ""

    /// True while a request is in flight. The view disables inputs + shows
    /// a "思考中…" row.
    var isThinking: Bool = false

    /// Latest error surfaced to the user (network failure, attachment too
    /// big, etc.). View shows a red banner and a retry / dismiss affordance.
    var lastError: String?

    /// Set once the LLM calls `synthesize_plan`. The view swaps its
    /// bottom composer for a confirmation card and calls the coordinator's
    /// `commit` / `cancelSynthesis` based on user choice.
    var pendingSynthesis: IntakeResult?

    /// True after `commit` finishes — the window will auto-close.
    var didFinish: Bool = false

    // MARK: - Derived

    /// Raw provider-facing message history (user + assistant text only).
    /// Re-computed on demand so we don't duplicate state.
    var providerMessages: [ChatMessage] {
        turns.compactMap { turn in
            switch turn {
            case .user(let text):
                return ChatMessage(role: .user, content: text)
            case .assistant(let text):
                return ChatMessage(role: .assistant, content: text)
            case .card, .synthesis:
                return nil  // synthetic UI turns — reconstructed into assistant below
            }
        } + cardAssistantEchoes()
    }

    /// Provider-facing messages including a reconstructed assistant-side
    /// "I asked X" for each card we rendered. Keeps the LLM's chain of
    /// thought coherent between turns.
    func messagesForNextTurn() -> [ChatMessage] {
        var out: [ChatMessage] = []
        for turn in turns {
            switch turn {
            case .user(let text):
                out.append(ChatMessage(role: .user, content: text))
            case .assistant(let text):
                out.append(ChatMessage(role: .assistant, content: text))
            case .card(let card, _):
                out.append(ChatMessage(role: .assistant, content: describeCard(card)))
            case .synthesis:
                // Synthesis ends the loop; shouldn't show up as input.
                break
            }
        }
        return out
    }

    /// If the session is empty, seed it with the opening user prompt. This
    /// is what the coordinator sends on the very first request — combines
    /// the free-form topic + any attached docs.
    func seedOpeningMessage() -> ChatMessage {
        let text = IntakePrompt.openingUserPrompt(
            topic: topic,
            attachments: attachments
        )
        return ChatMessage(role: .user, content: text)
    }

    // MARK: - Helpers

    private func cardAssistantEchoes() -> [ChatMessage] {
        turns.compactMap { turn in
            if case .card(let card, _) = turn {
                return ChatMessage(role: .assistant, content: describeCard(card))
            }
            return nil
        }
    }

    /// JSON-ish compact representation of the card so the assistant history
    /// is consistent across providers. Kept terse to save context.
    private func describeCard(_ card: QuestionCard) -> String {
        var lines: [String] = []
        if let p = card.preamble, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(p)
        }
        for (i, q) in card.questions.enumerated() {
            lines.append("Q\(i+1). \(q.text)")
            if !q.choices.isEmpty {
                lines.append("   选项: \(q.choices.joined(separator: " / "))")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Union of rendered turns in the chat transcript.
enum IntakeTurn: Sendable, Equatable, Identifiable {
    case user(text: String)
    case assistant(text: String)
    case card(QuestionCard, answers: [String: String])
    case synthesis(IntakeResult)

    var id: String {
        switch self {
        case .user(let t):        return "u:\(t.hashValue)"
        case .assistant(let t):   return "a:\(t.hashValue)"
        case .card(let c, _):     return "c:\(c.questions.map(\.id).joined(separator: ","))"
        case .synthesis(let r):   return "s:\(r.kind.rawValue):\(r.project?.name ?? r.tempTask?.text ?? "")"
        }
    }
}
