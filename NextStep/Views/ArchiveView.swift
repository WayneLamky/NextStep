import SwiftData
import SwiftUI

/// 归档库 — lists every project the user has marked as done.
///
/// Two actions per row:
///   - "恢复" returns the project to active (re-opens its sticky at last
///     known position, restart markdown + reminders sync).
///   - "永久删除" removes it entirely — including its markdown file if the
///     folder is mounted. Destructive, so it confirms first.
struct ArchiveView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<Project> { $0.isArchived },
        sort: [SortDescriptor(\Project.archivedAt, order: .reverse)]
    )
    private var archived: [Project]

    @State private var confirmingDeleteID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if archived.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(archived) { project in
                        row(for: project)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox.fill")
                .foregroundStyle(.secondary)
            Text("归档库")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Text(archived.isEmpty ? "" : "\(archived.count) 个项目")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "archivebox")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("还没有归档的项目")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("在便利贴的 ⋯ 菜单里选「归档项目」，完成的项目会出现在这里。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for project: Project) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(project.level.displayName)
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(project.level.accent.opacity(0.25), in: Capsule())

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name.isEmpty ? "（未命名）" : project.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let archivedAt = project.archivedAt {
                        Text("归档于 " + Self.relativeDate(archivedAt))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    let doneCount = project.completedHistory.count
                    if doneCount > 0 {
                        Text("· 完成 \(doneCount) 步")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if confirmingDeleteID == project.id {
                Text("确定?")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("永久删除") { confirmDelete(project) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                Button("取消") { confirmingDeleteID = nil }
                    .buttonStyle(.bordered)
            } else {
                Button("恢复") { restore(project) }
                    .buttonStyle(.borderedProminent)
                Button("永久删除") { confirmingDeleteID = project.id }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Actions

    private func restore(_ project: Project) {
        project.isArchived = false
        project.archivedAt = nil
        project.modifiedAt = .now
        try? modelContext.save()
        WindowRegistry.shared.openWindow(for: project)
        MarkdownBridge.shared.syncSoon(projectID: project.id)
        RemindersBridge.shared.syncProjectNextAction(projectID: project.id)
    }

    private func confirmDelete(_ project: Project) {
        let projectID = project.id
        // Pull the markdown file too so we don't leave orphan files behind.
        if let url = MarkdownFolderStore.shared.markdownURL(
            forProjectID: project.id,
            projectName: project.name
        ) {
            try? FileManager.default.removeItem(at: url)
        }
        RemindersBridge.shared.deleteReminder(forProjectID: projectID)
        modelContext.delete(project)
        try? modelContext.save()
        confirmingDeleteID = nil
    }

    private static func relativeDate(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: .now)
    }
}
