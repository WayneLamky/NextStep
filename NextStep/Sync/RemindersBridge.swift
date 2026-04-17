import AppKit
import EventKit
import Foundation
import SwiftData

/// Bridges NextStep ↔ Apple Reminders via EventKit.
///
/// Project sync (single-direction-write + bidirectional-completion):
/// - Each project's *current* next action becomes one reminder in the
///   "NextStep" list. Old reminders are deleted when the action changes.
/// - The reminder title carries a hidden tag `【NS:<uuid>】` so we can
///   find ours among arbitrary Reminders content.
/// - When the user marks our reminder complete in Reminders.app, we
///   notice via `.EKEventStoreChanged` and trigger the LLM "推下一步" flow.
///
/// Temp task sync (full mirror):
/// - Inserts/updates/deletes both sides.
///
/// Loop suppression: every reminder ID we just wrote/updated/completed is
/// recorded with a timestamp; `EKEventStoreChanged` events that touch
/// those IDs within `echoWindow` (5s) are ignored.
@MainActor
final class RemindersBridge {
    static let shared = RemindersBridge()

    /// EventKit store. Singleton — re-creating wastes the granted access.
    private let store = EKEventStore()

    /// UserDefaults key under which we persist the calendarIdentifier of
    /// the calendar we created. We *never* match by title, because the user
    /// may already have an unrelated calendar called "NextStep".
    private let calendarIDDefaultsKey = "remindersCalendarID_v1"

    /// Cached calendar identifier for the list we own. Resolved lazily.
    private var calendarID: String? {
        get { UserDefaults.standard.string(forKey: calendarIDDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: calendarIDDefaultsKey) }
    }

    /// True once the user has granted full access. Don't call any of the
    /// store APIs while this is false — they'll silently no-op or throw.
    private(set) var hasAccess = false

    /// SwiftData context — we set this in `start` so the change observer
    /// can mutate Project / TempTask rows when external completion fires.
    private weak var modelContext: ModelContext?

    /// Triggered when an external completion is detected on a project's
    /// reminder. The view layer hooks this to fire the LLM next-action
    /// generation (StickyView holds the LLM provider + animation, so it
    /// owns the actual call).
    var onProjectReminderCompleted: ((_ projectID: UUID) -> Void)?

    /// IDs we wrote ourselves recently — ignore EKEventStoreChanged for
    /// these within `echoWindow` to prevent a self-bounce loop.
    private var recentlyTouched: [String: Date] = [:]
    private let echoWindow: TimeInterval = 5.0

    /// EKEventStoreChanged is intentionally vague (no diff). We snapshot
    /// the previous "our reminders" set on each refresh, then diff against
    /// the new set to find what got completed externally.
    private var lastSeenReminders: [String: Bool] = [:]  // ekID → isCompleted

    private var observerToken: NSObjectProtocol?

    private init() {}

    // MARK: - Lifecycle

    func start(modelContext: ModelContext) {
        self.modelContext = modelContext

        observerToken = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleStoreChanged() }
        }

        Task { @MainActor in
            // If user previously granted, this is fast and silent.
            _ = await ensureAccess(promptIfNeeded: false)
            if hasAccess && isEnabledInPrefs {
                await refreshAndDiff()
            }
        }
    }

    // MARK: - Permissions / config

    var isEnabledInPrefs: Bool {
        UserDefaults.standard.bool(forKey: "remindersSyncEnabled")
    }

    /// `promptIfNeeded` — pass `true` from a button click; `false` when
    /// silently checking on launch (don't surprise the user with a dialog).
    @discardableResult
    func ensureAccess(promptIfNeeded: Bool) async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .fullAccess:
            hasAccess = true
            return true
        case .notDetermined:
            guard promptIfNeeded else { return false }
            do {
                hasAccess = try await store.requestFullAccessToReminders()
                return hasAccess
            } catch {
                NSLog("RemindersBridge: requestFullAccess failed — \(error)")
                hasAccess = false
                return false
            }
        case .writeOnly, .denied, .restricted:
            hasAccess = false
            return false
        @unknown default:
            hasAccess = false
            return false
        }
    }

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    // MARK: - "NextStep" calendar

    /// Returns the EKCalendar we own, creating it on first call.
    ///
    /// Crucially, we do **not** match by title — the user may have an
    /// unrelated calendar named "NextStep" (e.g., they've been using it
    /// for personal reminders). Instead, we persist the calendarIdentifier
    /// after creation and resolve it back; if it's missing or stale, we
    /// create a fresh calendar. This guarantees we only ever read/write
    /// our own list.
    private func nextStepCalendar() -> EKCalendar? {
        if let id = calendarID, let cal = store.calendar(withIdentifier: id) {
            return cal
        }
        // No persisted ID (or stale). Before creating a new calendar,
        // sniff for an existing one we previously created (matched by the
        // exact title). This is *only* a recovery path — once we adopt one,
        // we re-persist its identifier so subsequent runs go through the
        // fast ID path. Using the exact title we own ("NextStep · 同步")
        // is safe — it's distinct from the user's plain "NextStep" list,
        // which is the collision case we deliberately defended against.
        let mine = "NextStep · 同步"
        if let existing = store.calendars(for: .reminder)
            .first(where: { $0.title == mine && $0.allowsContentModifications }) {
            calendarID = existing.calendarIdentifier
            return existing
        }

        // Otherwise create one. iCloud preferred so it syncs across the
        // user's devices; fall back to local.
        let sources = store.sources
        let source = sources.first(where: { $0.sourceType == .calDAV })
            ?? sources.first(where: { $0.sourceType == .local })
            ?? store.defaultCalendarForNewReminders()?.source
        guard let src = source else { return nil }

        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = mine
        cal.source = src
        cal.cgColor = NSColor.systemTeal.cgColor
        do {
            try store.saveCalendar(cal, commit: true)
            calendarID = cal.calendarIdentifier
            return cal
        } catch {
            NSLog("RemindersBridge: saveCalendar failed — \(error)")
            return nil
        }
    }

    // MARK: - Project sync (write side)

    /// Make sure the project's current next action exists as a reminder.
    /// Replaces any prior reminder for this project. Safe to call often.
    func syncProjectNextAction(projectID: UUID) {
        guard isEnabledInPrefs, hasAccess else { return }
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.id == projectID }
        )
        guard let project = (try? ctx.fetch(descriptor))?.first else { return }
        guard let calendar = nextStepCalendar() else { return }

        let action = project.currentNextAction.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty action → just clear any existing reminder.
        if action.isEmpty || project.isArchived {
            deleteReminder(forProjectID: project.id)
            return
        }

        // Find existing reminder by stored ID (cheap path).
        var existing: EKReminder?
        if let ekID = project.currentEKReminderID,
           let r = store.calendarItem(withIdentifier: ekID) as? EKReminder,
           !r.isCompleted {
            existing = r
        }

        let reminder = existing ?? EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = "\(action) \(taggedSuffix(projectID: project.id))"
        reminder.notes = "由 NextStep 同步 · 项目「\(project.name)」"

        // Estimated minutes → priority hint (low priority for very short
        // actions, normal otherwise). Keeps Reminders sorting reasonable.
        if let min = project.estimatedMinutes, min <= 5 {
            reminder.priority = 1  // High → these are quickest wins
        } else {
            reminder.priority = 0
        }

        do {
            try store.save(reminder, commit: true)
            project.currentEKReminderID = reminder.calendarItemIdentifier
            recentlyTouched[reminder.calendarItemIdentifier] = .now
            // Refresh our snapshot so the change observer doesn't fire on
            // this reminder as "newly seen".
            lastSeenReminders[reminder.calendarItemIdentifier] = false
        } catch {
            NSLog("RemindersBridge: save project reminder failed — \(error)")
        }
    }

    /// Delete the reminder backing a project (used on archive / clear).
    func deleteReminder(forProjectID id: UUID) {
        guard hasAccess, let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.id == id }
        )
        guard let project = (try? ctx.fetch(descriptor))?.first else { return }
        guard let ekID = project.currentEKReminderID else { return }
        guard let r = store.calendarItem(withIdentifier: ekID) as? EKReminder else {
            project.currentEKReminderID = nil
            return
        }
        do {
            recentlyTouched[ekID] = .now
            try store.remove(r, commit: true)
            project.currentEKReminderID = nil
            lastSeenReminders.removeValue(forKey: ekID)
        } catch {
            NSLog("RemindersBridge: remove project reminder failed — \(error)")
        }
    }

    // MARK: - Temp task sync (full mirror)

    func syncTempTask(taskID: UUID) {
        guard isEnabledInPrefs, hasAccess else { return }
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<TempTask>(
            predicate: #Predicate { $0.id == taskID }
        )
        guard let task = (try? ctx.fetch(descriptor))?.first else { return }
        guard let calendar = nextStepCalendar() else { return }

        var existing: EKReminder?
        if let ekID = task.ekReminderID,
           let r = store.calendarItem(withIdentifier: ekID) as? EKReminder {
            existing = r
        }
        let reminder = existing ?? EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = "\(task.text) \(tempTaggedSuffix(taskID: task.id))"
        reminder.notes = "由 NextStep 同步 · 临时任务"
        reminder.isCompleted = task.isCompleted

        if let due = task.dueDate {
            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due
            )
            reminder.dueDateComponents = comps
            // Set an alarm at the due time so user actually gets notified.
            reminder.alarms = [EKAlarm(absoluteDate: due)]
        } else {
            reminder.dueDateComponents = nil
            reminder.alarms = nil
        }

        do {
            try store.save(reminder, commit: true)
            task.ekReminderID = reminder.calendarItemIdentifier
            recentlyTouched[reminder.calendarItemIdentifier] = .now
            lastSeenReminders[reminder.calendarItemIdentifier] = task.isCompleted
        } catch {
            NSLog("RemindersBridge: save temp reminder failed — \(error)")
        }
    }

    func deleteReminder(forTempTaskID id: UUID) {
        guard hasAccess, let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<TempTask>(
            predicate: #Predicate { $0.id == id }
        )
        guard let task = (try? ctx.fetch(descriptor))?.first,
              let ekID = task.ekReminderID,
              let r = store.calendarItem(withIdentifier: ekID) as? EKReminder
        else { return }
        do {
            recentlyTouched[ekID] = .now
            try store.remove(r, commit: true)
            task.ekReminderID = nil
            lastSeenReminders.removeValue(forKey: ekID)
        } catch {
            NSLog("RemindersBridge: remove temp reminder failed — \(error)")
        }
    }

    // MARK: - External change handling

    private func handleStoreChanged() {
        guard isEnabledInPrefs, hasAccess else { return }
        Task { @MainActor in await refreshAndDiff() }
    }

    /// Lightweight Sendable snapshot of one reminder — used to cross the
    /// EventKit-callback / main-actor boundary without sending non-Sendable
    /// `EKReminder` instances.
    private struct ReminderSnapshot: Sendable {
        let id: String
        let title: String
        let isCompleted: Bool
    }

    /// `@unchecked Sendable` box for `EKEventStore` + `NSPredicate`, both
    /// of which are not Sendable. We cross the actor boundary exactly once
    /// per fetch and don't mutate either side, so the unchecked override
    /// is justified.
    private struct EKFetchInput: @unchecked Sendable {
        let store: EKEventStore
        let predicate: NSPredicate
    }

    /// Pull the current reminder state from the NextStep calendar, diff
    /// against `lastSeenReminders`, and react to:
    ///  - reminders newly marked complete that we know belong to a project
    ///    → trigger `onProjectReminderCompleted(projectID)`
    ///  - completed temp tasks → mark `isCompleted` on TempTask
    private func refreshAndDiff() async {
        guard let calendar = nextStepCalendar() else { return }
        let predicate = store.predicateForReminders(in: [calendar])
        // EventKit invokes our completion on its own serial dispatch queue
        // (`com.apple.eventkit.reminders.search`). Under Swift 6 strict
        // concurrency, an inline closure inside a @MainActor method inherits
        // MainActor isolation — so when EK calls it from a non-main queue,
        // the runtime's executor check traps. Hand the work to a fully
        // nonisolated bridge that captures only Sendable values.
        let input = EKFetchInput(store: store, predicate: predicate)
        let snapshots = await Self.fetchSnapshots(input)

        var nextSeen: [String: Bool] = [:]
        for snap in snapshots {
            nextSeen[snap.id] = snap.isCompleted
        }

        for snap in snapshots {
            // Skip our own recent writes — they're echoes, not user actions.
            if let last = recentlyTouched[snap.id],
               Date().timeIntervalSince(last) < echoWindow {
                continue
            }
            let was = lastSeenReminders[snap.id]
            // Newly-completed (or first-seen-as-completed for a reminder we
            // didn't track yet) → fire handlers.
            if snap.isCompleted && was != true {
                handleExternalCompletion(title: snap.title)
            }
        }
        lastSeenReminders = nextSeen

        // Cleanup recentlyTouched older than echoWindow to keep dict small.
        let cutoff = Date().addingTimeInterval(-echoWindow)
        recentlyTouched = recentlyTouched.filter { $0.value > cutoff }
    }

    private func handleExternalCompletion(title: String) {
        if let pid = parseProjectID(from: title) {
            onProjectReminderCompleted?(pid)
        } else if let tid = parseTempID(from: title) {
            markTempTaskCompleted(tid)
        }
        // Otherwise — a manually-added reminder in our calendar; ignore.
    }

    private func markTempTaskCompleted(_ id: UUID) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<TempTask>(
            predicate: #Predicate { $0.id == id }
        )
        guard let task = (try? ctx.fetch(descriptor))?.first else { return }
        if !task.isCompleted {
            task.isCompleted = true
            try? ctx.save()
        }
    }

    // MARK: - Tagging helpers

    /// Hidden marker we stamp into reminder titles so we can recover the
    /// project link without storing a parallel mapping. The user sees the
    /// suffix; it's intentional but unobtrusive.
    private func taggedSuffix(projectID: UUID) -> String {
        "【NS:\(projectID.uuidString.prefix(8))】"
    }

    private func tempTaggedSuffix(taskID: UUID) -> String {
        "【NSt:\(taskID.uuidString.prefix(8))】"
    }

    private func parseProjectID(from title: String?) -> UUID? {
        guard let title else { return nil }
        return parseTaggedID(title: title, prefix: "NS:")
    }

    private func parseTempID(from title: String?) -> UUID? {
        guard let title else { return nil }
        return parseTaggedID(title: title, prefix: "NSt:")
    }

    /// Look up the full UUID by matching on its 8-char prefix from the tag.
    /// We need the SwiftData rows to resolve the full ID — this avoids
    /// embedding 36 chars of UUID in the visible title.
    private func parseTaggedID(title: String, prefix: String) -> UUID? {
        guard let range = title.range(of: "【\(prefix)") else { return nil }
        let after = title[range.upperBound...]
        guard let close = after.firstIndex(of: "】") else { return nil }
        let prefix8 = String(after[..<close]).lowercased()
        guard prefix8.count == 8 else { return nil }

        guard let ctx = modelContext else { return nil }
        if prefix == "NS:" {
            // Match against Project IDs.
            let all = (try? ctx.fetch(FetchDescriptor<Project>())) ?? []
            return all.first(where: { $0.id.uuidString.prefix(8).lowercased() == prefix8 })?.id
        } else {
            let all = (try? ctx.fetch(FetchDescriptor<TempTask>())) ?? []
            return all.first(where: { $0.id.uuidString.prefix(8).lowercased() == prefix8 })?.id
        }
    }

    // MARK: - Nonisolated bridge

    /// Bridges EventKit's callback-based fetch into async/await without
    /// inheriting MainActor isolation. EK invokes the completion on its
    /// own serial queue (`com.apple.eventkit.reminders.search`); under
    /// Swift 6 strict concurrency, an inline closure inside a @MainActor
    /// method would inherit MainActor and trap the runtime executor check.
    /// Marking this `nonisolated` and capturing only Sendable values
    /// (`ReminderSnapshot`) lets the closure run safely off the main actor.
    nonisolated private static func fetchSnapshots(
        _ input: EKFetchInput
    ) async -> [ReminderSnapshot] {
        await withCheckedContinuation { (cont: CheckedContinuation<[ReminderSnapshot], Never>) in
            input.store.fetchReminders(matching: input.predicate) { items in
                let snaps = (items ?? []).map { r in
                    ReminderSnapshot(
                        id: r.calendarItemIdentifier,
                        title: r.title ?? "",
                        isCompleted: r.isCompleted
                    )
                }
                cont.resume(returning: snaps)
            }
        }
    }
}
