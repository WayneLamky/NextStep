import Foundation
import SwiftUI

enum ProjectLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case month
    case week
    case day

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .month: return "月"
        case .week:  return "周"
        case .day:   return "日"
        }
    }

    var fullName: String {
        switch self {
        case .month: return "月目标"
        case .week:  return "周目标"
        case .day:   return "日目标"
        }
    }

    /// Max number of concurrent active projects at this level.
    var capacity: Int {
        switch self {
        case .month: return 1
        case .week:  return 4
        case .day:   return 3
        }
    }

    /// Accent color used for badges and borders.
    var accent: Color {
        switch self {
        case .month: return Color(red: 0.85, green: 0.35, blue: 0.35)
        case .week:  return Color(red: 0.35, green: 0.55, blue: 0.85)
        case .day:   return Color(red: 0.35, green: 0.75, blue: 0.55)
        }
    }
}

extension ProjectLevel: Comparable {
    static func < (lhs: Self, rhs: Self) -> Bool {
        let order: [Self: Int] = [.day: 0, .week: 1, .month: 2]
        return (order[lhs] ?? 0) < (order[rhs] ?? 0)
    }
}
