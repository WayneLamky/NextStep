import Foundation

struct CompletedAction: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var action: String
    var completedAt: Date

    init(id: UUID = UUID(), action: String, completedAt: Date = .now) {
        self.id = id
        self.action = action
        self.completedAt = completedAt
    }
}
