import AppKit
import Foundation

/// Drives a single intake conversation: sends turns to the LLM, updates the
/// session state, and — on user confirmation — materializes the synthesis
/// into a real `Project` or `TempTask`.
///
/// Singleton because there's exactly one intake window at a time. The
/// session itself is recreated on every `startNew()`, so state doesn't
/// leak between independent intakes.
@MainActor
final class IntakeCoordinator {
    static let shared = IntakeCoordinator()

    private(set) var session = IntakeSession()

    /// Called after a successful commit — the window controller watches
    /// this to animate close.
    var onFinish: (() -> Void)?

    private init() {}

    // MARK: - Lifecycle

    /// Reset to a fresh session. Called when the window is (re)opened so
    /// the user never inherits a stale conversation.
    func startNew() {
        session = IntakeSession()
    }

    // MARK: - Attachments

    /// Ingest one file URL, validating against limits. Returns the payload
    /// on success; caller shows `.lastError` on failure.
    func addAttachment(from url: URL) {
        do {
            let payload = try AttachmentIngest.extract(from: url)
            try AttachmentIngest.validate(adding: payload, to: session.attachments)
            session.attachments.append(payload)
            session.lastError = nil
        } catch {
            session.lastError = error.localizedDescription
        }
    }

    func removeAttachment(filename: String) {
        session.attachments.removeAll { $0.filename == filename }
    }

    // MARK: - Send user turn

    /// Called on the very first submit. Seeds `topic`, runs the first LLM
    /// turn (the user message is synthesized from `IntakePrompt.openingUserPrompt`).
    func start(topic: String) async {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        session.topic = trimmed
        // Render the user-facing opener as a chat bubble (what they typed),
        // even though provider receives the wrapped opener prompt.
        if !trimmed.isEmpty {
            session.turns.append(.user(text: trimmed))
        } else {
            session.turns.append(.user(text: "（先问我问题吧）"))
        }
        await runTurn(firstTurn: true)
    }

    /// Called whenever the user answers the most recent card. `answers`
    /// maps question.id → raw text the user typed or chose.
    func submitAnswers(forCardAt turnIndex: Int, answers: [String: String]) async {
        guard case .card(let card, _) = session.turns[turnIndex] else { return }

        // Overwrite the card with the populated answers so re-renders show
        // the user's picks inline. Freeze it — further edits disabled.
        session.turns[turnIndex] = .card(card, answers: answers)

        // Append a user-facing summary turn so the history + provider
        // context both show what the user said.
        let summary = renderAnswers(card: card, answers: answers)
        session.turns.append(.user(text: summary))

        await runTurn(firstTurn: false)
    }

    /// Submit a free-form user message (used when the user ignores the
    /// card and types something in the composer instead).
    func submitFreeText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.turns.append(.user(text: trimmed))
        await runTurn(firstTurn: false)
    }

    /// Retry the last LLM call (after a network failure). Leaves the user
    /// turn history intact.
    func retry() async {
        session.lastError = nil
        let firstTurn = session.turns.count == 1  // only the opener
        await runTurn(firstTurn: firstTurn)
    }

    // MARK: - Finalization

    /// User accepted the synthesis. Materialize it into a real Project or
    /// TempTask, respecting `CapacityGuard`. Returns `true` on success.
    @discardableResult
    func commit() -> Bool {
        guard let result = session.pendingSynthesis else { return false }

        switch result.kind {
        case .project:
            guard let seed = result.project else {
                session.lastError = "合成结果缺少项目字段。"
                return false
            }
            let decision = CapacityGuard.check(
                creating: seed.level,
                context: AppStore.shared.context
            )
            if case .overLimit(let current, let cap, let level) = decision {
                session.lastError = "已达到\(level.displayName)级目标上限 (\(current)/\(cap))。请先归档一个现有\(level.displayName)级项目，再回来创建。"
                return false
            }
            _ = WindowRegistry.shared.createProject(seeded: seed)
            CompletionFX.playNextStep()
            session.didFinish = true
            onFinish?()
            return true

        case .tempTask:
            guard let seed = result.tempTask else {
                session.lastError = "合成结果缺少临时任务字段。"
                return false
            }
            let task = TempTask(
                text: seed.text,
                dueDate: seed.dueDateDate
            )
            AppStore.shared.context.insert(task)
            try? AppStore.shared.context.save()
            RemindersBridge.shared.syncTempTask(taskID: task.id)
            CompletionFX.playNextStep()
            session.didFinish = true
            onFinish?()
            return true
        }
    }

    /// User hit "改一下" on the synthesis card. Drop it and re-ask the LLM
    /// for more questions.
    func revisitSynthesis() async {
        session.pendingSynthesis = nil
        session.turns.append(
            .user(text: "这个合成还不太对。能再多问我一两个问题吗？我想调整一下。")
        )
        await runTurn(firstTurn: false)
    }

    /// User dismissed the synthesis ("取消"). Drop it; session stays open.
    func cancelSynthesis() {
        session.pendingSynthesis = nil
    }

    // MARK: - Internal turn driver

    private func runTurn(firstTurn: Bool) async {
        guard !session.isThinking else { return }
        session.isThinking = true
        session.lastError = nil

        let provider = LLMProviderResolver.current()
        let systemPrompt = IntakePrompt.systemPrompt

        // Build messages to send. On the first turn we append the wrapped
        // opener (with attachments) rather than the raw user topic text.
        var messages = session.messagesForNextTurn()
        if firstTurn {
            // Replace the last user message with the wrapped opener so the
            // model sees attachments + today's date.
            if let lastIdx = messages.indices.last, messages[lastIdx].role == .user {
                messages.removeLast()
            }
            messages.append(session.seedOpeningMessage())
        }

        do {
            let result = try await provider.chat(
                messages: messages,
                systemPrompt: systemPrompt
            )

            switch result {
            case .card(let card):
                session.turns.append(.card(card, answers: [:]))
            case .synthesis(let synth):
                session.turns.append(.synthesis(synth))
                session.pendingSynthesis = synth
            }
        } catch {
            session.lastError = error.localizedDescription
        }

        session.isThinking = false
    }

    /// Turn a card + user's answers into a readable user-facing summary.
    /// Also used as the provider-facing user turn body for the next round.
    private func renderAnswers(card: QuestionCard, answers: [String: String]) -> String {
        var lines: [String] = []
        for (i, q) in card.questions.enumerated() {
            let raw = answers[q.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let value = raw.isEmpty ? "（跳过）" : raw
            lines.append("Q\(i+1) \(q.text)\n答：\(value)")
        }
        return lines.joined(separator: "\n\n")
    }
}
