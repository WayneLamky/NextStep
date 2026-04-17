import Foundation
import SwiftData

@Model
final class TempTask {
    @Attribute(.unique) var id: UUID
    var text: String
    var dueDate: Date?
    var ekReminderID: String?
    var isCompleted: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        text: String,
        dueDate: Date? = nil,
        ekReminderID: String? = nil,
        isCompleted: Bool = false
    ) {
        self.id = id
        self.text = text
        self.dueDate = dueDate
        self.ekReminderID = ekReminderID
        self.isCompleted = isCompleted
        self.createdAt = .now
    }
}
