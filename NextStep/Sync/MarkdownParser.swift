import Foundation

/// Pure value representing the "narrative" fields of a Project — the stuff
/// that lives in the markdown file. UI state (position, color, etc) stays
/// in SwiftData and never touches the file.
struct ProjectSnapshot: Equatable, Sendable {
    var id: UUID
    var name: String
    var level: ProjectLevel
    var monthGoal: String
    var weekGoal: String
    var dayAction: String
    var currentNextAction: String
    var completed: [CompletedAction]
    var createdAt: Date
    /// Only `"active"` or `"archived"` for now.
    var status: String
}

/// Serialize + deserialize `ProjectSnapshot` to/from the on-disk markdown
/// format. Intentionally split from file I/O so it's trivially unit-testable.
enum MarkdownParser {
    // MARK: - Serialize

    static func serialize(_ snap: ProjectSnapshot) -> String {
        var out = ""
        out += "# \(snap.name.isEmpty ? "未命名项目" : snap.name)\n"
        out += "\n"
        out += "## 元信息\n"
        out += "- id: \(snap.id.uuidString)\n"
        out += "- level: \(snap.level.rawValue)\n"
        out += "- created: \(isoDate.string(from: snap.createdAt))\n"
        out += "- status: \(snap.status)\n"
        out += "\n"
        out += "## 目标层级\n"
        out += "\n"
        out += "### 月目标\n"
        out += "\(snap.monthGoal)\n"
        out += "\n"
        out += "### 本周目标\n"
        out += "\(snap.weekGoal)\n"
        out += "\n"
        out += "### 今日动作\n"
        out += "\(snap.dayAction)\n"
        out += "\n"
        out += "## 当前下一步\n"
        out += "\(snap.currentNextAction)\n"
        out += "\n"
        out += "## 已完成\n"
        if snap.completed.isEmpty {
            out += "(暂无)\n"
        } else {
            // Oldest first, matches how humans read a log.
            for item in snap.completed {
                out += "- [x] \(item.action) — \(isoDate.string(from: item.completedAt))\n"
            }
        }
        return out
    }

    // MARK: - Deserialize

    /// Returns `nil` when the file doesn't look like ours (no `id:` in 元信息).
    /// The parser is deliberately lenient about whitespace / blank lines so
    /// hand-editing doesn't break us.
    static func parse(_ text: String) -> ProjectSnapshot? {
        let lines = text.components(separatedBy: "\n")
        var title: String = ""
        var meta: [String: String] = [:]
        var sections: [String: String] = [:]  // heading → body text
        var history: [CompletedAction] = []

        var currentH2: String? = nil
        var currentH3: String? = nil
        var buffer: [String] = []

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            let body = buffer.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let h3 = currentH3 {
                // Nested under h2 — key as "h2/h3"
                sections[(currentH2 ?? "") + "/" + h3] = body
            } else if let h2 = currentH2 {
                sections[h2] = body
            }
            buffer.removeAll()
        }

        for raw in lines {
            let line = raw

            if title.isEmpty, line.hasPrefix("# "), !line.hasPrefix("## ") {
                title = String(line.dropFirst(2))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }

            if line.hasPrefix("## ") {
                flushBuffer()
                currentH2 = String(line.dropFirst(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                currentH3 = nil
                continue
            }

            if line.hasPrefix("### ") {
                flushBuffer()
                currentH3 = String(line.dropFirst(4))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }

            // Meta lines under "## 元信息" — parse as "- key: value"
            if currentH2 == "元信息", line.hasPrefix("- ") {
                let rest = line.dropFirst(2)
                if let colon = rest.firstIndex(of: ":") {
                    let key = rest[..<colon].trimmingCharacters(in: .whitespaces)
                    let value = rest[rest.index(after: colon)...]
                        .trimmingCharacters(in: .whitespaces)
                    meta[key] = value
                }
                continue
            }

            // Completed history lines
            if currentH2 == "已完成", line.hasPrefix("- [x]") || line.hasPrefix("- [X]") {
                let rest = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                // Accept "action — date" or "action - date" or just "action"
                let (action, date) = splitActionDate(String(rest))
                history.append(CompletedAction(action: action, completedAt: date ?? .now))
                continue
            }

            buffer.append(line)
        }
        flushBuffer()

        guard
            let idStr = meta["id"],
            let id = UUID(uuidString: idStr)
        else { return nil }

        let level = meta["level"].flatMap { ProjectLevel(rawValue: $0) } ?? .week
        let created = meta["created"].flatMap { isoDate.date(from: $0) } ?? .now
        let status = meta["status"] ?? "active"

        return ProjectSnapshot(
            id: id,
            name: title,
            level: level,
            monthGoal: sectionBody(sections, "目标层级/月目标"),
            weekGoal: sectionBody(sections, "目标层级/本周目标"),
            dayAction: sectionBody(sections, "目标层级/今日动作"),
            currentNextAction: sectionBody(sections, "当前下一步"),
            completed: history,
            createdAt: created,
            status: status
        )
    }

    // MARK: - helpers

    private static func sectionBody(_ map: [String: String], _ key: String) -> String {
        let s = map[key] ?? ""
        // Sections with placeholder `(暂无)` should decode as empty.
        return s == "(暂无)" ? "" : s
    }

    private static func splitActionDate(_ s: String) -> (String, Date?) {
        // Try em dash first, then hyphen (with spaces).
        let separators = [" — ", " - ", " – "]
        for sep in separators {
            if let range = s.range(of: sep, options: .backwards) {
                let action = String(s[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let datePart = String(s[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                let date = isoDate.date(from: datePart)
                return (action, date)
            }
        }
        return (s.trimmingCharacters(in: .whitespaces), nil)
    }

    private static let isoDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()
}

// MARK: - Bridging Project ↔ snapshot

extension ProjectSnapshot {
    @MainActor
    init(from project: Project) {
        self.init(
            id: project.id,
            name: project.name,
            level: project.level,
            monthGoal: project.monthGoal,
            weekGoal: project.weekGoal,
            dayAction: project.dayAction,
            currentNextAction: project.currentNextAction,
            completed: project.completedHistory,
            createdAt: project.createdAt,
            status: project.isArchived ? "archived" : "active"
        )
    }

    /// Writes the snapshot's narrative fields onto a Project without touching
    /// UI state. Returns true if any field changed — callers use this to
    /// skip redundant saves and animations.
    @MainActor
    @discardableResult
    func apply(to project: Project) -> Bool {
        var changed = false
        if project.name != name { project.name = name; changed = true }
        if project.level != level { project.level = level; changed = true }
        if project.monthGoal != monthGoal { project.monthGoal = monthGoal; changed = true }
        if project.weekGoal != weekGoal { project.weekGoal = weekGoal; changed = true }
        if project.dayAction != dayAction { project.dayAction = dayAction; changed = true }
        if project.currentNextAction != currentNextAction {
            project.currentNextAction = currentNextAction
            changed = true
        }

        // Only replace history if it actually differs — re-encoding causes
        // SwiftData churn.
        let current = project.completedHistory
        if !CompletedAction.arraysEqual(current, completed) {
            project.completedHistory = completed
            changed = true
        }

        let shouldArchive = (status == "archived")
        if project.isArchived != shouldArchive {
            project.isArchived = shouldArchive
            project.archivedAt = shouldArchive ? .now : nil
            changed = true
        }

        if changed { project.modifiedAt = .now }
        return changed
    }
}

private extension CompletedAction {
    static func arraysEqual(_ a: [CompletedAction], _ b: [CompletedAction]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            if x.action != y.action { return false }
            // Accept 1-minute drift from date-only round-tripping.
            if abs(x.completedAt.timeIntervalSince(y.completedAt)) > 60 { return false }
        }
        return true
    }
}
