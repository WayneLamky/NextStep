import SwiftData
import SwiftUI

struct StickyView: View {
    let projectID: UUID

    @Environment(\.modelContext) private var modelContext
    @Query private var projects: [Project]

    init(projectID: UUID) {
        self.projectID = projectID
        _projects = Query(filter: #Predicate<Project> { $0.id == projectID })
    }

    var body: some View {
        if let project = projects.first {
            StickyContent(project: project)
        } else {
            Color.clear
        }
    }
}

private struct StickyContent: View {
    @Bindable var project: Project
    @Environment(\.modelContext) private var modelContext
    @State private var showPalette = false
    @State private var isGenerating = false
    @State private var generationError: String?
    @State private var heroFlipID = UUID()
    @State private var focusPulse = false
    @FocusState private var nextActionFocused: Bool
    @FocusState private var nameFocused: Bool
    @AppStorage("userPersona") private var persona: String = ""

    // Observing the FocusManager makes the glow redraw on enter/exit.
    private var focus: FocusManager { FocusManager.shared }
    private var isFocusedHere: Bool { focus.focusedProjectID == project.id }

    private var paperColor: Color { ProjectPalette.color(at: project.colorIndex) }
    private var accent: Color { project.level.accent }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            hero
            if project.isExpanded {
                Divider().opacity(0.2)
                hierarchyDrawer
            }
            Divider().opacity(0.2)
            footer
        }
        .background(paperColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isFocusedHere ? accent.opacity(focusPulse ? 0.85 : 0.45) : .black.opacity(0.08),
                    lineWidth: isFocusedHere ? 2 : 0.5
                )
        )
        .shadow(
            color: isFocusedHere ? accent.opacity(focusPulse ? 0.55 : 0.25) : .clear,
            radius: isFocusedHere ? (focusPulse ? 22 : 10) : 0
        )
        .animation(.easeInOut(duration: 1.1), value: focusPulse)
        .animation(.easeInOut(duration: 0.25), value: isFocusedHere)
        // Double-click anywhere on the sticky chrome to enter / exit focus.
        // TextFields claim their own double-click for word selection, so this
        // only fires on non-text regions (header padding, paper, footer).
        .onTapGesture(count: 2) {
            FocusManager.shared.toggle(project.id)
        }
        .onAppear(perform: startFocusPulse)
        // M5 — when the user ticks our reminder in Reminders.app, behave
        // exactly as if they tapped "完成并推下一步" inside the sticky.
        .onReceive(NotificationCenter.default.publisher(for: .nextStepRemindersCompleted)) { note in
            guard let pid = note.userInfo?["projectID"] as? UUID,
                  pid == project.id else { return }
            complete()
        }
    }

    private func startFocusPulse() {
        // Continuous softly-breathing accent on any focused sticky. The
        // animation is a no-op visually unless `isFocusedHere` is true, so
        // the cost of running it everywhere is trivial.
        guard !focusPulse else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                focusPulse = true
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(project.level.displayName)
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(accent.opacity(0.25), in: Capsule())
                .foregroundStyle(.black.opacity(0.75))

            TextField("项目名", text: $project.name)
                .font(.system(size: 13, weight: .semibold))
                .textFieldStyle(.plain)
                .foregroundStyle(.black.opacity(0.85))
                .focused($nameFocused)
                .onChange(of: project.name) { _, _ in touch() }

            Spacer(minLength: 4)
            paletteButton
            moreMenu
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var paletteButton: some View {
        Button {
            showPalette.toggle()
        } label: {
            Circle()
                .fill(paperColor)
                .overlay(Circle().strokeBorder(.black.opacity(0.3), lineWidth: 0.5))
                .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPalette, arrowEdge: .top) {
            HStack(spacing: 8) {
                ForEach(0..<ProjectPalette.count, id: \.self) { idx in
                    Button {
                        project.colorIndex = idx
                        touch()
                        showPalette = false
                    } label: {
                        Circle()
                            .fill(ProjectPalette.color(at: idx))
                            .overlay(
                                Circle().strokeBorder(
                                    idx == project.colorIndex ? .black.opacity(0.7) : .black.opacity(0.2),
                                    lineWidth: idx == project.colorIndex ? 1.5 : 0.5
                                )
                            )
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
    }

    private var moreMenu: some View {
        Menu {
            Menu("改变层级") {
                ForEach(ProjectLevel.allCases, id: \.self) { lvl in
                    Button(lvl.displayName) {
                        project.level = lvl
                        touch()
                    }
                    .disabled(lvl == project.level)
                }
            }
            Divider()
            Button(isFocusedHere ? "退出聚焦" : "聚焦此项目") {
                FocusManager.shared.toggle(project.id)
            }
            Button("展开为层级视图") {
                ExpandedHierarchyRegistry.shared.open(for: project.id)
            }
            Button("归档项目") { archive() }
            Button("关闭窗口") { closeWindow() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black.opacity(0.55))
                .frame(width: 18, height: 18)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            heroField
            if let generationError {
                Text(generationError)
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.85))
                    .lineLimit(3)
            }
            completeButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var heroField: some View {
        if isGenerating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("生成中…")
                    .font(.system(size: 14))
                    .foregroundStyle(.black.opacity(0.55))
                Spacer(minLength: 0)
            }
            .frame(minHeight: 72, alignment: .topLeading)
            .transition(.opacity)
        } else {
            TextField(
                "点击下方按钮生成下一步，或在此处手动填写",
                text: $project.currentNextAction,
                axis: .vertical
            )
            .font(.system(size: 15, weight: .medium))
            .textFieldStyle(.plain)
            .foregroundStyle(.black.opacity(0.88))
            .lineLimit(4, reservesSpace: true)
            .focused($nextActionFocused)
            .onChange(of: project.currentNextAction) { _, _ in touch() }
            .id(heroFlipID)
            .transition(.heroFlip)
        }
    }

    private var completeButton: some View {
        Button(action: complete) {
            HStack(spacing: 6) {
                Image(systemName: isGenerating ? "hourglass" : "checkmark.circle.fill")
                Text(ctaLabel)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(accent.opacity(isGenerating ? 0.5 : 0.85), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(isGenerating)
    }

    private var ctaLabel: String {
        if isGenerating { return "生成中…" }
        return project.currentNextAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "生成下一步"
            : "完成并推下一步"
    }

    // MARK: Hierarchy drawer

    private var hierarchyDrawer: some View {
        VStack(alignment: .leading, spacing: 8) {
            goalRow(icon: "📅", label: "月", text: $project.monthGoal, placeholder: "月目标")
            goalRow(icon: "📆", label: "周", text: $project.weekGoal, placeholder: "本周目标")
            goalRow(icon: "📌", label: "今", text: $project.dayAction, placeholder: "今日动作")

            if !project.completedHistory.isEmpty {
                Divider().opacity(0.15).padding(.vertical, 2)
                Text("已完成")
                    .font(.caption2.bold())
                    .foregroundStyle(.black.opacity(0.55))
                ForEach(project.completedHistory.suffix(5).reversed(), id: \.id) { item in
                    HStack(alignment: .top, spacing: 4) {
                        Text("•").foregroundStyle(.black.opacity(0.4))
                        Text(item.action)
                            .font(.system(size: 11))
                            .foregroundStyle(.black.opacity(0.6))
                            .strikethrough(true, color: .black.opacity(0.4))
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func goalRow(icon: String, label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(icon).font(.system(size: 11))
            TextField(placeholder, text: text, axis: .vertical)
                .font(.system(size: 11))
                .textFieldStyle(.plain)
                .foregroundStyle(.black.opacity(0.75))
                .lineLimit(1...3)
                .onChange(of: text.wrappedValue) { _, _ in touch() }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            pomodoroButton
            Spacer()
            Button {
                project.isExpanded.toggle()
                touch()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: project.isExpanded ? "chevron.up" : "chevron.down")
                    Text(project.isExpanded ? "收起" : "展开层级")
                }
                .font(.system(size: 11))
                .foregroundStyle(.black.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var pomodoroButton: some View {
        let engine = PomodoroEngine.shared
        let running = engine.isRunning(project.id)
        return Button {
            if running {
                engine.stop(projectID: project.id)
            } else {
                engine.start(projectID: project.id)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: running ? "stop.circle.fill" : "timer")
                    .font(.system(size: 13))
                if running {
                    Text(Self.formatSeconds(engine.remaining))
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .foregroundStyle(running ? accent.opacity(0.9) : .black.opacity(0.55))
            .frame(height: 22)
            .padding(.horizontal, running ? 6 : 2)
            .background(
                running ? accent.opacity(focusPulse ? 0.22 : 0.10) : .clear,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .help(running ? "停止番茄钟" : "开始 25 分钟番茄钟")
    }

    private static func formatSeconds(_ s: TimeInterval) -> String {
        let total = max(0, Int(s.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Actions

    private func touch() {
        project.modifiedAt = .now
        try? modelContext.save()
        // M4 sync — debounced, safely no-ops if no folder picked.
        MarkdownBridge.shared.syncSoon(projectID: project.id)
        // M5 sync — push current next action to Reminders. Safe no-op
        // when toggle is off / no permission.
        RemindersBridge.shared.syncProjectNextAction(projectID: project.id)
    }

    private func complete() {
        let trimmed = project.currentNextAction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // Flow 2: commit current action into history, then immediately
            // ask the LLM for the next one so the sticky never goes blank.
            project.pushCompleted(trimmed)
            project.currentNextAction = ""
            touch()
        }
        generateNextAction()
    }

    private func generateNextAction() {
        guard !isGenerating else { return }
        generationError = nil
        isGenerating = true
        let snapshot = NextActionContext.make(from: project, persona: persona)
        let projectID = project.id
        let advisoryLevel = project.level

        Task { @MainActor in
            defer { isGenerating = false }
            do {
                // Resolved on each call so switching provider in Settings
                // takes effect without restart.
                let provider = LLMProviderResolver.current()
                let result = try await provider.generateNextAction(context: snapshot)
                applyResult(result, projectID: projectID, advisoryLevel: advisoryLevel)
            } catch {
                generationError = (error as? LLMError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func applyResult(
        _ result: NextActionResult,
        projectID: UUID,
        advisoryLevel: ProjectLevel
    ) {
        // Re-fetch the project in case its identity lifecycle shifted.
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.id == projectID }
        )
        guard let proj = (try? modelContext.fetch(descriptor))?.first else { return }

        withAnimation(.easeInOut(duration: 0.4)) {
            proj.currentNextAction = result.nextAction
            proj.estimatedMinutes = result.estimatedMinutes
            heroFlipID = UUID()  // force the transition to play
        }
        // Audible tick once the new action actually lands.
        CompletionFX.playNextStep()

        // Level advance is advisory — the model can suggest "this week's goal
        // is done, move to the next day's action"; we just bump the field for
        // now. M6+ will do the full promotion logic.
        if let advance = result.levelAdvance, advance != advisoryLevel {
            proj.level = advance
        }

        touch()
    }

    private func archive() {
        WindowRegistry.shared.archive(projectID: project.id)
    }

    private func closeWindow() {
        WindowRegistry.shared.closeWindow(for: project.id)
    }
}
