import AppKit
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class WindowRegistry {
    static let shared = WindowRegistry()

    private(set) var controllers: [UUID: StickyWindowController] = [:]
    /// Increment to force SwiftUI observers to refresh on change.
    private(set) var revision: Int = 0

    private var container: ModelContainer { AppStore.shared.container }
    private var context: ModelContext { AppStore.shared.context }

    private init() {}

    // MARK: - Restore

    func restoreAll() {
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { !$0.isArchived }
        )
        let projects = (try? context.fetch(descriptor)) ?? []
        for project in projects {
            openWindow(for: project)
        }
        bump()
    }

    // MARK: - Create

    @discardableResult
    func createProject(level: ProjectLevel, at point: NSPoint? = nil) -> Project {
        let anchor = point ?? defaultSpawnPoint()
        let project = Project(
            name: "",
            level: level,
            colorIndex: Int.random(in: 0..<ProjectPalette.count),
            positionX: Double(anchor.x),
            positionY: Double(anchor.y)
        )
        context.insert(project)
        try? context.save()
        openWindow(for: project)
        bump()
        MarkdownBridge.shared.syncSoon(projectID: project.id)
        return project
    }

    /// Create a fully-populated project in one shot. Used by the Q&A intake
    /// synthesis path — the sticky appears with `currentNextAction`, all
    /// three goal tiers, and (optionally) deadline / dailyMinutes already
    /// filled in. Also kicks off markdown + reminders sync immediately so
    /// the user sees state propagate without manual edits.
    @discardableResult
    func createProject(seeded seed: ProjectSeed, at point: NSPoint? = nil) -> Project {
        let anchor = point ?? defaultSpawnPoint()
        let project = Project(
            name: seed.name,
            level: seed.level,
            currentNextAction: seed.seededNextAction,
            monthGoal: seed.monthGoal,
            weekGoal: seed.weekGoal,
            dayAction: seed.dayAction,
            colorIndex: Int.random(in: 0..<ProjectPalette.count),
            positionX: Double(anchor.x),
            positionY: Double(anchor.y),
            deadline: seed.deadlineDate,
            dailyMinutes: seed.dailyMinutes,
            estimatedMinutes: seed.estimatedMinutes
        )
        // The seeded first action counts as a "filled current next step" —
        // stamp modifiedAt forward so md writeback + reminder sync below
        // actually run (they no-op on an untouched row).
        project.modifiedAt = .now
        context.insert(project)
        try? context.save()
        openWindow(for: project)
        bump()
        MarkdownBridge.shared.syncSoon(projectID: project.id)
        RemindersBridge.shared.syncProjectNextAction(projectID: project.id)
        return project
    }

    // MARK: - Window lifecycle

    func openWindow(for project: Project) {
        if let existing = controllers[project.id] {
            existing.show()
            return
        }
        let controller = StickyWindowController(
            project: project,
            container: container,
            registry: self
        )
        controllers[project.id] = controller
        controller.show()
        // Any newly opened sticky must respect the current focus stack.
        FocusManager.shared.applyLevels()
        bump()
    }

    func closeWindow(for projectID: UUID) {
        controllers[projectID]?.panel.close()
    }

    func windowDidClose(projectID: UUID) {
        controllers.removeValue(forKey: projectID)
        // If the focused sticky just went away, unwind focus.
        if FocusManager.shared.focusedProjectID == projectID {
            FocusManager.shared.exitFocus()
        }
        bump()
    }

    func persistFrame(for projectID: UUID, frame: NSRect) {
        guard let project = fetchProject(id: projectID) else { return }
        project.positionX = Double(frame.origin.x)
        project.positionY = Double(frame.origin.y)
        project.width = Double(frame.size.width)
        project.height = Double(frame.size.height)
        project.modifiedAt = .now
        try? context.save()
    }

    // MARK: - Archive

    func archive(projectID: UUID) {
        guard let project = fetchProject(id: projectID) else { return }
        project.isArchived = true
        project.archivedAt = .now
        try? context.save()
        MarkdownBridge.shared.syncSoon(projectID: projectID)
        // Pull the now-irrelevant reminder from Reminders.app.
        RemindersBridge.shared.deleteReminder(forProjectID: projectID)
        // Celebratory chime when a project actually ships.
        CompletionFX.playProjectArchived()
        closeWindow(for: projectID)
        bump()
    }

    // MARK: - Queries

    func hiddenProjects() -> [Project] {
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\Project.modifiedAt, order: .reverse)]
        )
        let projects = (try? context.fetch(descriptor)) ?? []
        return projects.filter { controllers[$0.id] == nil }
    }

    func capacityCounts() -> CapacityCounts {
        CapacityGuard.counts(context: context)
    }

    private func fetchProject(id: UUID) -> Project? {
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.id == id }
        )
        return try? context.fetch(descriptor).first
    }

    private func defaultSpawnPoint() -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let frame = screen.visibleFrame
        let jitter = CGFloat.random(in: -60...60)
        return NSPoint(
            x: frame.midX - 140 + jitter,
            y: frame.midY - 120 + jitter
        )
    }

    private func bump() { revision &+= 1 }
}
