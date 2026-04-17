import Foundation
import SwiftData

/// Notifications fired by the sync bridges. Views observe these to react
/// to external changes without depending on the bridge singletons directly.
extension Notification.Name {
    /// Fired when the user marks a project's reminder complete in
    /// Reminders.app. `userInfo["projectID"]` is the `UUID` of the project.
    /// StickyView observes this to kick off "推下一步".
    static let nextStepRemindersCompleted = Notification.Name(
        "com.claw.nextstep.reminderCompleted"
    )
}

extension ModelContext {
    /// Convenience — fetch one project by id, returning nil if missing.
    func fetchProject(id: UUID) -> Project? {
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.id == id }
        )
        return (try? fetch(descriptor))?.first
    }
}
