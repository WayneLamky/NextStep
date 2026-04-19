import Foundation
import SwiftData

@Model
final class Project {
    @Attribute(.unique) var id: UUID
    var name: String
    var levelRaw: String
    var currentNextAction: String
    var estimatedMinutes: Int?

    var monthGoal: String
    var weekGoal: String
    var dayAction: String

    // Completion history stored as JSON-encoded [CompletedAction]
    var completedHistoryJSON: Data

    var positionX: Double
    var positionY: Double
    var width: Double
    var height: Double
    var colorIndex: Int
    var isMinimized: Bool
    var isExpanded: Bool
    var isArchived: Bool
    var archivedAt: Date?

    var markdownFilePath: String?
    var currentEKReminderID: String?

    var pomodoroStartedAt: Date?
    var pomodoroDuration: TimeInterval?
    var pomodoroPaused: Bool

    /// Target completion date the user committed to during Q&A intake.
    /// `nil` for open-ended projects. Surfaced in markdown + expanded view.
    var deadline: Date?
    /// Minutes per day the user said they'd allocate. `0` means unset.
    /// The LLM uses this to size the next-action; UI also shows it as a
    /// target line under the hero CTA.
    var dailyMinutes: Int

    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        name: String = "",
        level: ProjectLevel = .week,
        currentNextAction: String = "",
        monthGoal: String = "",
        weekGoal: String = "",
        dayAction: String = "",
        colorIndex: Int = 0,
        positionX: Double = 200,
        positionY: Double = 200,
        width: Double = 280,
        height: Double = 240,
        deadline: Date? = nil,
        dailyMinutes: Int = 0,
        estimatedMinutes: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.levelRaw = level.rawValue
        self.currentNextAction = currentNextAction
        self.estimatedMinutes = estimatedMinutes
        self.monthGoal = monthGoal
        self.weekGoal = weekGoal
        self.dayAction = dayAction
        self.completedHistoryJSON = Self.encode([])
        self.positionX = positionX
        self.positionY = positionY
        self.width = width
        self.height = height
        self.colorIndex = colorIndex
        self.isMinimized = false
        self.isExpanded = false
        self.isArchived = false
        self.archivedAt = nil
        self.markdownFilePath = nil
        self.currentEKReminderID = nil
        self.pomodoroStartedAt = nil
        self.pomodoroDuration = nil
        self.pomodoroPaused = false
        self.deadline = deadline
        self.dailyMinutes = dailyMinutes
        self.createdAt = .now
        self.modifiedAt = .now
    }

    var level: ProjectLevel {
        get { ProjectLevel(rawValue: levelRaw) ?? .week }
        set { levelRaw = newValue.rawValue }
    }

    var completedHistory: [CompletedAction] {
        get { (try? JSONDecoder().decode([CompletedAction].self, from: completedHistoryJSON)) ?? [] }
        set { completedHistoryJSON = Self.encode(newValue) }
    }

    func pushCompleted(_ action: String) {
        guard !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var history = completedHistory
        history.append(CompletedAction(action: action))
        completedHistory = history
        modifiedAt = .now
    }

    private static func encode(_ items: [CompletedAction]) -> Data {
        (try? JSONEncoder().encode(items)) ?? Data("[]".utf8)
    }
}
