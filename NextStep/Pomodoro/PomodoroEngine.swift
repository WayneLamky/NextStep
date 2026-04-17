import AppKit
import Foundation
import Observation
import SwiftData

/// 项目番茄钟
///
/// 设计：
/// - 同时只允许一个番茄钟。启动新的会自动结束旧的。
/// - 结束 = wall-clock `startedAt + duration <= now`。Timer 只驱动 UI 刷新，
///   不负责计时本身——这样 Mac 合盖 5 分钟再打开也能继续走。
/// - 状态（startedAt / duration）持久化到 Project 模型，App 重启后扫描
///   未到期的自动重新接管。
/// - 结束动作：系统提示音 + 便利贴呼吸动画 + 将那张便利贴 order front。
@MainActor
@Observable
final class PomodoroEngine {
    static let shared = PomodoroEngine()

    /// 当前在跑的项目 ID。nil = 没有任何项目在番茄中。
    private(set) var activeProjectID: UUID?
    /// 倒计时秒数。仅用于 UI 显示，由 tick 驱动。
    private(set) var remaining: TimeInterval = 0
    /// revision bump — SwiftUI 观察者用。
    private(set) var revision: Int = 0

    /// 默认工作时长 25 分钟。休息阶段留待后续版本。
    static let defaultDuration: TimeInterval = 25 * 60

    private var context: ModelContext { AppStore.shared.context }
    private var ticker: Timer?

    private init() {}

    // MARK: - Lifecycle

    /// App 启动时调用——把数据库里未到期的番茄钟恢复回来。
    func resumeActiveAfterLaunch() {
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { !$0.isArchived && $0.pomodoroStartedAt != nil }
        )
        let projects = (try? context.fetch(descriptor)) ?? []
        guard let proj = projects.first,
              let startedAt = proj.pomodoroStartedAt,
              let duration = proj.pomodoroDuration else {
            return
        }
        let elapsed = Date.now.timeIntervalSince(startedAt)
        if elapsed >= duration {
            // 已经过期了——当场结束，释放状态。
            finish(projectID: proj.id, silently: true)
        } else {
            activeProjectID = proj.id
            remaining = duration - elapsed
            startTicker()
            bump()
        }
    }

    // MARK: - Start / stop

    func start(projectID: UUID, duration: TimeInterval = PomodoroEngine.defaultDuration) {
        // 一次只能一个——把旧的清空。
        if let current = activeProjectID, current != projectID {
            stop(projectID: current, silently: true)
        }
        guard let proj = fetchProject(id: projectID) else { return }
        proj.pomodoroStartedAt = .now
        proj.pomodoroDuration = duration
        proj.pomodoroPaused = false
        try? context.save()

        activeProjectID = projectID
        remaining = duration
        startTicker()
        bump()
    }

    func stop(projectID: UUID, silently: Bool = false) {
        guard let proj = fetchProject(id: projectID) else { return }
        proj.pomodoroStartedAt = nil
        proj.pomodoroDuration = nil
        proj.pomodoroPaused = false
        try? context.save()

        if activeProjectID == projectID {
            activeProjectID = nil
            remaining = 0
            stopTicker()
        }
        bump()
        if !silently { NSSound(named: NSSound.Name("Pop"))?.play() }
    }

    func isRunning(_ projectID: UUID) -> Bool {
        activeProjectID == projectID
    }

    // MARK: - Ticker

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let pid = activeProjectID,
              let proj = fetchProject(id: pid),
              let startedAt = proj.pomodoroStartedAt,
              let duration = proj.pomodoroDuration else {
            stopTicker()
            return
        }
        let elapsed = Date.now.timeIntervalSince(startedAt)
        if elapsed >= duration {
            finish(projectID: pid, silently: false)
        } else {
            remaining = duration - elapsed
            bump()
        }
    }

    // MARK: - Finish

    private func finish(projectID: UUID, silently: Bool) {
        if !silently { NSSound(named: NSSound.Name("Glass"))?.play() }
        stop(projectID: projectID, silently: true)

        // 把便利贴顶上来，让用户看到。
        if let proj = fetchProject(id: projectID) {
            WindowRegistry.shared.openWindow(for: proj)
            if let panel = WindowRegistry.shared.controllers[projectID]?.panel {
                panel.orderFrontRegardless()
            }
        }
        NotificationCenter.default.post(
            name: .nextStepPomodoroFinished,
            object: nil,
            userInfo: ["projectID": projectID]
        )
    }

    // MARK: - Helpers

    private func fetchProject(id: UUID) -> Project? {
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.id == id }
        )
        return try? context.fetch(descriptor).first
    }

    private func bump() { revision &+= 1 }
}

extension Notification.Name {
    static let nextStepPomodoroFinished = Notification.Name("NextStep.pomodoroFinished")
}
