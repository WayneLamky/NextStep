import SwiftData
import SwiftUI

/// Flow 5 — "展开为层级视图".
///
/// Temporary brainstorm modal: month at the top, week in the middle, day at
/// the bottom, with connecting lines between the three goals. Below that, a
/// faded list of completed actions as "leaves" so the user can see how far
/// they've come without the sticky being cluttered with history.
///
/// This is a transient view — editing here round-trips through SwiftData and
/// the markdown file. Closing the window leaves the sticky untouched.
struct ExpandedHierarchyView: View {
    let projectID: UUID
    let onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query private var projects: [Project]

    init(projectID: UUID, onClose: @escaping () -> Void) {
        self.projectID = projectID
        self.onClose = onClose
        _projects = Query(filter: #Predicate<Project> { $0.id == projectID })
    }

    var body: some View {
        if let project = projects.first {
            ExpandedHierarchyContent(project: project, onClose: onClose)
        } else {
            Color.clear.onAppear(perform: onClose)
        }
    }
}

private struct ExpandedHierarchyContent: View {
    @Bindable var project: Project
    let onClose: () -> Void

    @Environment(\.modelContext) private var modelContext

    private var accent: Color { project.level.accent }
    private var paperColor: Color { ProjectPalette.color(at: project.colorIndex) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.15)
            radial
            Divider().opacity(0.15)
            completedFooter
        }
        .background(
            LinearGradient(
                colors: [paperColor.opacity(0.35), paperColor.opacity(0.18)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(project.level.displayName)
                .font(.caption2.bold())
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(accent.opacity(0.28), in: Capsule())

            Text(project.name.isEmpty ? "未命名项目" : project.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            Button(action: onClose) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.up.square")
                    Text("收起为单张")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("收起此展开视图（ESC）")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Radial hierarchy

    private var radial: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let H = geo.size.height
            let centerX = W / 2
            let monthY  = H * 0.18
            let weekY   = H * 0.50
            let dayY    = H * 0.82

            ZStack {
                // Connection lines — drawn behind the nodes.
                Canvas { ctx, _ in
                    var path = Path()
                    path.move(to: CGPoint(x: centerX, y: monthY))
                    path.addLine(to: CGPoint(x: centerX, y: weekY))
                    path.move(to: CGPoint(x: centerX, y: weekY))
                    path.addLine(to: CGPoint(x: centerX, y: dayY))
                    ctx.stroke(
                        path,
                        with: .color(accent.opacity(0.35)),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])
                    )
                }
                .allowsHitTesting(false)

                // Month — largest, topmost.
                hierarchyNode(
                    level: .month,
                    text: $project.monthGoal,
                    size: .large
                )
                .position(x: centerX, y: monthY)

                // Week — mid.
                hierarchyNode(
                    level: .week,
                    text: $project.weekGoal,
                    size: .medium
                )
                .position(x: centerX, y: weekY)

                // Day — smallest, closest to earth.
                hierarchyNode(
                    level: .day,
                    text: $project.dayAction,
                    size: .small
                )
                .position(x: centerX, y: dayY)
            }
        }
        .frame(minHeight: 360)
    }

    // MARK: Node

    private enum NodeSize {
        case small, medium, large

        var width: CGFloat {
            switch self {
            case .small:  return 240
            case .medium: return 320
            case .large:  return 400
            }
        }

        var font: Font {
            switch self {
            case .small:  return .system(size: 12, weight: .medium)
            case .medium: return .system(size: 14, weight: .semibold)
            case .large:  return .system(size: 16, weight: .semibold)
            }
        }
    }

    private func hierarchyNode(
        level: ProjectLevel,
        text: Binding<String>,
        size: NodeSize
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(levelIcon(level))
                Text(level.fullName)
                    .font(.caption2.bold())
                    .foregroundStyle(level.accent)
            }
            TextField(placeholderFor(level), text: text, axis: .vertical)
                .font(size.font)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .foregroundStyle(.primary)
                .onChange(of: text.wrappedValue) { _, _ in touch() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: size.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(level.accent.opacity(0.45), lineWidth: 1)
        )
    }

    private func levelIcon(_ level: ProjectLevel) -> String {
        switch level {
        case .month: return "📅"
        case .week:  return "📆"
        case .day:   return "📌"
        }
    }

    private func placeholderFor(_ level: ProjectLevel) -> String {
        switch level {
        case .month: return "月目标（大方向，1 个月内想抵达的状态）"
        case .week:  return "本周目标（这周要推进到哪儿）"
        case .day:   return "今日动作（现在能启动的那一步）"
        }
    }

    // MARK: Completed history

    private var completedFooter: some View {
        let history = project.completedHistory
        return Group {
            if history.isEmpty {
                Text("还没有已完成的动作 — 回到便利贴，点「完成并推下一步」开始积累。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(history.suffix(16).reversed(), id: \.id) { item in
                            leafChip(item)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .frame(height: 50)
            }
        }
    }

    private func leafChip(_ item: CompletedAction) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 10))
                .foregroundStyle(accent.opacity(0.6))
            Text(item.action)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .strikethrough(true, color: .secondary.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(accent.opacity(0.08))
        )
        .help(item.action)
    }

    // MARK: Actions

    private func touch() {
        project.modifiedAt = .now
        try? modelContext.save()
        MarkdownBridge.shared.syncSoon(projectID: project.id)
    }
}
