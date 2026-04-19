import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Top-level chat surface for the Q&A intake window.
///
/// Layout (vertical stack):
///   - Header (title + progress + attachment chips)
///   - Scrollable transcript: user bubbles, card turns, synthesis preview
///   - Composer / pending synthesis footer (swapped based on state)
///
/// The SwiftUI tree is deliberately lean — all logic sits in
/// `IntakeCoordinator`; the view is just a visual projection of
/// `IntakeSession`.
struct IntakeChatView: View {
    /// The same observable session backing the coordinator. Re-reading on
    /// every coordinator update repaints the view.
    @Bindable var session: IntakeSession
    let coordinator: IntakeCoordinator

    @State private var openingText: String = ""
    @State private var freeTextInput: String = ""
    @State private var isDroppingFile: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $isDroppingFile) { providers in
            handleDrop(providers: providers)
        }
        .overlay(alignment: .top) {
            if isDroppingFile {
                Text("拖入 PDF / Markdown / txt 作为参考文档…")
                    .font(.callout)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("AI 规划 · 问答模式")
                    .font(.headline)
                Spacer()
                if let progress = currentProgress {
                    Text("问题 \(progress) / ~10")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if !session.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(session.attachments, id: \.filename) { a in
                            attachmentChip(a)
                        }
                        addAttachmentButton
                            .padding(.leading, 4)
                    }
                }
            } else if session.turns.isEmpty {
                Text("告诉我你想规划什么，我会问你 8-12 个问题来把它拆清楚。可以拖 PDF / Markdown / txt 作为参考。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func attachmentChip(_ a: AttachmentPayload) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "paperclip")
                .font(.caption)
            Text(a.filename)
                .font(.caption)
                .lineLimit(1)
            Text("· \(a.content.count) 字")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button {
                coordinator.removeAttachment(filename: a.filename)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }

    private var addAttachmentButton: some View {
        Button {
            pickAttachment()
        } label: {
            Label("加附件", systemImage: "plus")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var currentProgress: Int? {
        for turn in session.turns.reversed() {
            if case .card(let card, _) = turn {
                return card.progress
            }
        }
        return nil
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if session.turns.isEmpty {
                        emptyStateHint
                    }
                    ForEach(Array(session.turns.enumerated()), id: \.offset) { idx, turn in
                        turnView(turn: turn, index: idx)
                            .id(idx)
                    }
                    if session.isThinking {
                        thinkingRow
                            .id("thinking")
                    }
                    if let err = session.lastError {
                        errorBanner(err)
                            .id("error")
                    }
                }
                .padding(16)
            }
            .onChange(of: session.turns.count) { _, _ in
                withAnimation { proxy.scrollTo(session.turns.count - 1, anchor: .bottom) }
            }
            .onChange(of: session.isThinking) { _, _ in
                if session.isThinking {
                    withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                }
            }
        }
    }

    private var emptyStateHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("试试：")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach([
                "我想写硕士毕业论文",
                "下周要做一次 30 分钟的部门分享",
                "想用一个月学会 Swift 并发",
                "明天下午 5 点要交电费",
            ], id: \.self) { ex in
                Button(ex) {
                    openingText = ex
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func turnView(turn: IntakeTurn, index: Int) -> some View {
        switch turn {
        case .user(let text):
            userBubble(text)
        case .assistant(let text):
            assistantBubble(text)
        case .card(let card, let answers):
            CardTurnView(
                card: card,
                savedAnswers: answers,
                isLocked: !isActiveCard(index: index),
                onSubmit: { newAnswers in
                    Task { await coordinator.submitAnswers(forCardAt: index, answers: newAnswers) }
                }
            )
        case .synthesis(let result):
            SynthesisPreviewView(
                result: result,
                isPending: session.pendingSynthesis == result,
                onConfirm: {
                    _ = coordinator.commit()
                },
                onRevisit: {
                    Task { await coordinator.revisitSynthesis() }
                },
                onCancel: {
                    coordinator.cancelSynthesis()
                }
            )
        }
    }

    private func isActiveCard(index: Int) -> Bool {
        // Only the last card in the transcript is editable. Previous cards
        // freeze once answered.
        var lastCardIndex: Int? = nil
        for (i, t) in session.turns.enumerated() {
            if case .card = t { lastCardIndex = i }
        }
        return lastCardIndex == index && session.pendingSynthesis == nil && !session.isThinking
    }

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer()
            Text(text)
                .textSelection(.enabled)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: 380, alignment: .trailing)
        }
    }

    private func assistantBubble(_ text: String) -> some View {
        HStack {
            Text(text)
                .textSelection(.enabled)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: 420, alignment: .leading)
            Spacer()
        }
    }

    private var thinkingRow: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("思考中…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(msg)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
            Button("重试") {
                Task { await coordinator.retry() }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if session.turns.isEmpty {
            openingComposer
        } else if session.pendingSynthesis != nil {
            // Synthesis is rendered inline in the transcript; keep footer quiet.
            HStack {
                Text("请在上方确认合成的方案。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(16)
        } else if hasActiveCard {
            // User answers via the card UI; free-text fallback is tucked
            // under a subtle disclosure.
            DisclosureGroup {
                freeTextComposer
                    .padding(.top, 8)
            } label: {
                Text("想自己说几句？点这里")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        } else {
            freeTextComposer
                .padding(16)
        }
    }

    private var hasActiveCard: Bool {
        for turn in session.turns.reversed() {
            if case .card = turn { return true }
            if case .synthesis = turn { return false }
        }
        return false
    }

    private var openingComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.secondary)
                Text("第一步：你想规划什么？")
                    .font(.callout)
            }
            TextEditor(text: $openingText)
                .font(.system(size: 13))
                .frame(minHeight: 60, maxHeight: 100)
                .padding(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
            HStack {
                Button("加附件") { pickAttachment() }
                    .controlSize(.small)
                Spacer()
                Button {
                    let topic = openingText
                    openingText = ""
                    Task { await coordinator.start(topic: topic) }
                } label: {
                    Label("开始对话", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.isThinking)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(16)
    }

    private var freeTextComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("补充点什么… (⌘Enter 发送)", text: $freeTextInput, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .font(.system(size: 13))
                .disabled(session.isThinking)

            Button {
                let msg = freeTextInput
                freeTextInput = ""
                Task { await coordinator.submitFreeText(msg) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(session.isThinking || freeTextInput.trimmingCharacters(in: .whitespaces).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    // MARK: - File picking & drop

    private func pickAttachment() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .text, .plainText].compactMap { $0 }
            + [UTType(filenameExtension: "md")].compactMap { $0 }
        panel.message = "选择 PDF / Markdown / txt（最多 \(AttachmentLimits.maxFiles) 个）"
        if panel.runModal() == .OK {
            for url in panel.urls {
                coordinator.addAttachment(from: url)
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var got = false
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    coordinator.addAttachment(from: url)
                }
            }
            got = true
        }
        return got
    }
}

// MARK: - Card turn

private struct CardTurnView: View {
    let card: QuestionCard
    let savedAnswers: [String: String]
    let isLocked: Bool
    let onSubmit: ([String: String]) -> Void

    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let p = card.preamble, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(p)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(card.questions.enumerated()), id: \.element.id) { idx, q in
                questionBlock(index: idx, question: q)
            }

            if !isLocked {
                HStack {
                    Spacer()
                    Button {
                        onSubmit(answers)
                    } label: {
                        Label("提交答案", systemImage: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasAnyAnswer)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(isLocked ? 0.06 : 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accentColor.opacity(isLocked ? 0.1 : 0.25), lineWidth: 1)
        )
        .onAppear {
            if answers.isEmpty && !savedAnswers.isEmpty {
                answers = savedAnswers
            }
        }
    }

    private var hasAnyAnswer: Bool {
        answers.contains { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    @ViewBuilder
    private func questionBlock(index: Int, question q: Question) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Q\(index + 1). \(q.text)")
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if !q.choices.isEmpty {
                WrapHStack(items: q.choices) { choice in
                    choiceChip(choice, for: q)
                }
            }

            if q.allowFreeText {
                TextField(
                    q.choices.isEmpty ? "回答…" : "或者自己填…",
                    text: Binding(
                        get: { answers[q.id] ?? "" },
                        set: { answers[q.id] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .disabled(isLocked)
                .font(.system(size: 13))
            }
        }
    }

    private func choiceChip(_ choice: String, for q: Question) -> some View {
        let selected = answers[q.id] == choice
        return Button {
            if isLocked { return }
            answers[q.id] = selected ? "" : choice
        } label: {
            Text(choice)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    selected ? Color.accentColor : Color.secondary.opacity(0.15),
                    in: Capsule()
                )
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
    }
}

// MARK: - Synthesis preview

private struct SynthesisPreviewView: View {
    let result: IntakeResult
    let isPending: Bool
    let onConfirm: () -> Void
    let onRevisit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(headline)
                    .font(.headline)
                Spacer()
            }

            if let p = result.project {
                projectBody(p)
            } else if let t = result.tempTask {
                tempTaskBody(t)
            }

            if isPending {
                HStack {
                    Button("改一下", action: onRevisit)
                    Button("取消", action: onCancel)
                    Spacer()
                    Button {
                        onConfirm()
                    } label: {
                        Label("确认创建", systemImage: "arrow.right.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(.top, 4)
            } else {
                Text("已确认。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.green.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.green.opacity(0.3), lineWidth: 1)
        )
    }

    private var headline: String {
        switch result.kind {
        case .project:
            guard let p = result.project else { return "将创建项目" }
            return "将创建 \(p.level.displayName)级项目《\(p.name)》"
        case .tempTask:
            return "将创建临时任务"
        }
    }

    private func projectBody(_ p: ProjectSeed) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row("月目标", p.monthGoal)
            row("本周目标", p.weekGoal)
            row("今日动作", p.dayAction)
            row("首步", p.seededNextAction + (p.estimatedMinutes.map { "（\($0) 分钟）" } ?? ""))
            if p.dailyMinutes > 0 {
                row("每天投入", "\(p.dailyMinutes) 分钟")
            }
            if let d = p.deadlineDate {
                row("截止日", Self.formatDate(d))
            }
        }
    }

    private func tempTaskBody(_ t: TempTaskSeed) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row("内容", t.text)
            if let d = t.dueDateDate {
                row("提醒时间", Self.formatDateTime(d))
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(value.isEmpty ? "（未填写）" : value)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private static func formatDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: d)
    }

    private static func formatDateTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: d)
    }
}

// MARK: - Simple wrapping HStack

/// Minimal flow layout for choice chips — SwiftUI's HStack doesn't wrap,
/// so roll our own via Layout protocol.
private struct WrapHStack<Item: Hashable, Content: View>: View {
    let items: [Item]
    let spacing: CGFloat = 6
    let content: (Item) -> Content

    var body: some View {
        FlowLayout(spacing: spacing) {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var firstInRow = true

        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if !firstInRow, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (firstInRow ? 0 : spacing) + size.width
                rowHeight = max(rowHeight, size.height)
                firstInRow = false
            }
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: .init(width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
