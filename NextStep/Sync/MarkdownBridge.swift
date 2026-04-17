import Foundation
import SwiftData

/// Bidirectional sync between SwiftData `Project` rows and markdown files
/// on disk. Markdown is the source of truth for the **narrative** fields
/// (name, goals, current next action, completion history, archived flag);
/// SwiftData retains UI-only state (position, color, minimized, etc).
///
/// Loop suppression strategy: every path we write ourselves is recorded in
/// `recentlyWroteAt[path]`. When `FSWatcher` fires an event for a path, we
/// drop it if our own write happened within the last ~2s. Keeps the
/// sticky ↔ file feedback loop from bouncing.
///
/// Conflict policy: on read-in, if the file's parsed snapshot would
/// **overwrite** a project whose `modifiedAt` is strictly newer than the
/// file's mtime, we copy the file to `<name>.md.conflict` and leave the
/// project unchanged. This surfaces the diff to the user rather than
/// silently losing work.
@MainActor
final class MarkdownBridge {
    static let shared = MarkdownBridge()

    private weak var modelContext: ModelContext?
    private var watcher: FSWatcher?

    /// Per-project debounced writes — keep rewrites at ≥300ms intervals so
    /// typing in the sticky doesn't hammer the disk.
    private var pendingWrites: [UUID: DispatchWorkItem] = [:]
    private let writeDebounce: TimeInterval = 0.35

    /// Path → wall-clock time of our last write. FSEvents within 2s are
    /// treated as echoes of our own write and ignored.
    private var recentlyWroteAt: [String: Date] = [:]
    private let echoWindow: TimeInterval = 2.0

    /// True while we're in the middle of applying a parsed file to
    /// SwiftData — used to ensure we don't re-queue a write for the same
    /// change we just read.
    private var isApplyingExternal = false

    private init() {}

    // MARK: - Lifecycle

    /// Called once at app launch. If a folder is already picked, starts
    /// watching; otherwise no-op (user picks via Settings).
    func start(modelContext: ModelContext) {
        self.modelContext = modelContext
        restartWatcher()
    }

    /// Re-read the folder from `MarkdownFolderStore` and rebuild the watcher.
    /// Call this after the user picks a folder in Settings.
    func restartWatcher() {
        watcher?.stop()
        watcher = nil

        guard let folder = MarkdownFolderStore.shared.currentURL else { return }
        MarkdownFolderStore.shared.ensureFolderExists()

        let w = FSWatcher { [weak self] paths in
            self?.handleExternalChange(paths: paths)
        }
        w.start(watching: folder)
        watcher = w

        // Initial reconcile: pull files → projects (creates missing projects,
        // updates existing ones); then push any project missing a file back
        // to disk.
        reconcileFromDisk()
        writeMissingFiles()
    }

    // MARK: - Write path (project → file)

    /// Debounced write. Call whenever a project's narrative field changes.
    func syncSoon(projectID: UUID) {
        guard MarkdownFolderStore.shared.currentURL != nil else { return }

        pendingWrites[projectID]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.writeNow(projectID: projectID)
        }
        pendingWrites[projectID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + writeDebounce, execute: work)
    }

    /// Fetch the project and write its markdown file. Safe to call from
    /// the main actor.
    private func writeNow(projectID: UUID) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.id == projectID }
        )
        guard let project = (try? ctx.fetch(descriptor))?.first else { return }
        writeSync(project)
    }

    /// Synchronous write — used by `writeNow` and initial bootstrap.
    private func writeSync(_ project: Project) {
        guard let url = MarkdownFolderStore.shared.markdownURL(
            forProjectID: project.id,
            projectName: project.name
        ) else { return }

        let snapshot = ProjectSnapshot(from: project)
        let text = MarkdownParser.serialize(snapshot)

        // Ensure parent folder exists (user may have deleted it).
        MarkdownFolderStore.shared.ensureFolderExists()

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            project.markdownFilePath = url.path
            recentlyWroteAt[url.path] = .now
        } catch {
            NSLog("MarkdownBridge: write failed for \(project.name) — \(error)")
        }
    }

    /// Write every project that doesn't yet have a backing file. Called
    /// after folder selection so existing projects get materialized.
    private func writeMissingFiles() {
        guard let ctx = modelContext else { return }
        let all = (try? ctx.fetch(FetchDescriptor<Project>())) ?? []
        for project in all {
            guard let url = MarkdownFolderStore.shared.markdownURL(
                forProjectID: project.id,
                projectName: project.name
            ) else { continue }
            if !FileManager.default.fileExists(atPath: url.path) {
                writeSync(project)
            }
        }
    }

    // MARK: - Read path (file → project)

    /// Called by the watcher with a set of changed file paths.
    private func handleExternalChange(paths: Set<String>) {
        for path in paths where path.hasSuffix(".md") {
            // Skip the echoes of our own writes.
            if let last = recentlyWroteAt[path],
               Date().timeIntervalSince(last) < echoWindow {
                continue
            }
            applyFile(at: path)
        }
    }

    /// Parse a single `.md` file and merge into SwiftData.
    private func applyFile(at path: String) {
        guard let ctx = modelContext else { return }
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: path) else {
            // File was deleted externally. For v1 we don't auto-archive —
            // just log. User can recreate by picking folder again.
            NSLog("MarkdownBridge: file disappeared — \(path)")
            return
        }

        guard
            let text = try? String(contentsOf: url, encoding: .utf8),
            let snapshot = MarkdownParser.parse(text)
        else {
            NSLog("MarkdownBridge: parse failed for \(path)")
            return
        }

        let snapshotID = snapshot.id
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.id == snapshotID }
        )
        let existing = (try? ctx.fetch(descriptor))?.first

        if let project = existing {
            // Conflict check: if the in-memory project changed AFTER the
            // file was saved, the user has edits the file doesn't have.
            let fileMTime = (try? FileManager.default
                .attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .now
            if project.modifiedAt > fileMTime.addingTimeInterval(1) {
                copyToConflict(url: url)
                NSLog("MarkdownBridge: conflict — project \(project.name) newer than file; saved \(url.lastPathComponent).conflict")
                return
            }

            isApplyingExternal = true
            let changed = snapshot.apply(to: project)
            isApplyingExternal = false
            if changed {
                try? ctx.save()
            }
        } else {
            // New project discovered on disk — insert it.
            isApplyingExternal = true
            let project = Project(
                id: snapshot.id,
                name: snapshot.name,
                level: snapshot.level,
                currentNextAction: snapshot.currentNextAction,
                monthGoal: snapshot.monthGoal,
                weekGoal: snapshot.weekGoal,
                dayAction: snapshot.dayAction
            )
            project.createdAt = snapshot.createdAt
            project.completedHistory = snapshot.completed
            project.isArchived = (snapshot.status == "archived")
            if project.isArchived {
                project.archivedAt = .now
            }
            project.markdownFilePath = path
            ctx.insert(project)
            try? ctx.save()
            isApplyingExternal = false
        }
    }

    /// Initial pass on folder pick: parse every `.md` and upsert.
    private func reconcileFromDisk() {
        guard let folder = MarkdownFolderStore.shared.currentURL else { return }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in items where url.pathExtension.lowercased() == "md" {
            applyFile(at: url.path)
        }
    }

    /// Copy a conflicting external version to `<name>.md.conflict` so the
    /// user can diff manually. Overwrites any previous conflict file.
    private func copyToConflict(url: URL) {
        let conflictURL = url.appendingPathExtension("conflict")
        try? FileManager.default.removeItem(at: conflictURL)
        try? FileManager.default.copyItem(at: url, to: conflictURL)
    }
}
