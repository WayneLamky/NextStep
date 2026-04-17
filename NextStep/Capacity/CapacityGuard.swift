import Foundation
import SwiftData

struct CapacityCounts {
    let month: Int
    let week: Int
    let day: Int

    var total: Int { month + week + day }
    var cap: Int {
        ProjectLevel.month.capacity + ProjectLevel.week.capacity + ProjectLevel.day.capacity
    }

    func count(for level: ProjectLevel) -> Int {
        switch level {
        case .month: return month
        case .week:  return week
        case .day:   return day
        }
    }

    func isOver(_ level: ProjectLevel) -> Bool {
        count(for: level) >= level.capacity
    }
}

enum CapacityDecision {
    case allowed
    case overLimit(current: Int, cap: Int, level: ProjectLevel)
}

@MainActor
enum CapacityGuard {
    /// Count active (non-archived) projects per level.
    static func counts(context: ModelContext) -> CapacityCounts {
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { !$0.isArchived }
        )
        let projects = (try? context.fetch(descriptor)) ?? []
        let m = projects.filter { $0.level == .month }.count
        let w = projects.filter { $0.level == .week  }.count
        let d = projects.filter { $0.level == .day   }.count
        return CapacityCounts(month: m, week: w, day: d)
    }

    static func check(
        creating level: ProjectLevel,
        context: ModelContext
    ) -> CapacityDecision {
        let c = counts(context: context)
        if c.isOver(level) {
            return .overLimit(current: c.count(for: level), cap: level.capacity, level: level)
        }
        return .allowed
    }
}
