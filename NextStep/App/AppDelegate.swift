import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var settingsWindow: NSWindow?
    private var hotkeys: [GlobalHotkey] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        _ = AppStore.shared

        menuBarController = MenuBarController(
            onNewProject:    { [weak self] level in self?.handleNewProject(level: level) },
            onNewTempTask:   { [weak self] in self?.handleNewTempTask() },
            onOpenIntake:    { [weak self] in self?.showIntake() },
            onOpenProject:   { project in WindowRegistry.shared.openWindow(for: project) },
            onOpenSettings:  { [weak self] in self?.showSettings() },
            onOpenArchive:   { ArchiveWindowController.shared.show() },
            onOpenAbout:     { AboutWindow.show() },
            onQuit:          { NSApp.terminate(nil) }
        )

        WindowRegistry.shared.restoreAll()
        menuBarController?.refreshStatusItem()

        // Markdown sync: picks up saved folder bookmark if any, and starts
        // FSEvent watcher. No-op when no folder is picked yet — user kicks
        // it off from Settings → 同步.
        MarkdownBridge.shared.start(modelContext: AppStore.shared.context)

        // Pomodoro: reattach any timer that was running when we quit /
        // slept. Wall-clock based, so a long gap just ends it.
        // Reminders sync: silently re-attaches if the user previously
        // granted full access. When a reminder we wrote gets ticked in
        // Reminders.app, fire the project's "推下一步" flow via notification.
        PomodoroEngine.shared.resumeActiveAfterLaunch()

        RemindersBridge.shared.start(modelContext: AppStore.shared.context)
        RemindersBridge.shared.onProjectReminderCompleted = { projectID in
            // Bring the sticky to front so the user sees the flip, then
            // post a notification the StickyView observes to trigger LLM.
            if let project = AppStore.shared.context.fetchProject(id: projectID) {
                WindowRegistry.shared.openWindow(for: project)
            }
            NotificationCenter.default.post(
                name: .nextStepRemindersCompleted,
                object: nil,
                userInfo: ["projectID": projectID]
            )
        }

        registerHotkeys()
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        hotkeys.append(
            GlobalHotkey(
                id: HotkeyID.newProject,
                keyCode: KeyCode.p,
                modifiers: optionCommandModifiers
            ) { [weak self] in
                self?.handleNewProject(level: .week)
            }
        )
        hotkeys.append(
            GlobalHotkey(
                id: HotkeyID.newTempTask,
                keyCode: KeyCode.n,
                modifiers: optionCommandModifiers
            ) { [weak self] in
                self?.handleNewTempTask()
            }
        )
    }

    // MARK: - Project creation

    private func handleNewProject(level: ProjectLevel) {
        let decision = CapacityGuard.check(creating: level, context: AppStore.shared.context)
        switch decision {
        case .allowed:
            _ = WindowRegistry.shared.createProject(level: level)
            menuBarController?.refreshStatusItem()
        case .overLimit(let current, let cap, let overLevel):
            presentOverLimitSheet(current: current, cap: cap, level: overLevel)
        }
    }

    private func presentOverLimitSheet(current: Int, cap: Int, level: ProjectLevel) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "已达到\(level.displayName)级目标上限 (\(current)/\(cap))"
        alert.informativeText = """
        NextStep 限制每个级别的活跃项目数，以保持专注：
        月 ≤1、周 ≤4、日 ≤3。

        请先归档一个现有\(level.displayName)级项目，或选择其他级别。
        """
        alert.addButton(withTitle: "好")
        for other in ProjectLevel.allCases where other != level {
            let remaining = other.capacity - WindowRegistry.shared.capacityCounts().count(for: other)
            if remaining > 0 {
                alert.addButton(withTitle: "改为\(other.displayName)级")
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        let alternatives = ProjectLevel.allCases.filter { other in
            other != level &&
            (other.capacity - WindowRegistry.shared.capacityCounts().count(for: other)) > 0
        }
        let idx = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if idx >= 1, idx - 1 < alternatives.count {
            let fallback = alternatives[idx - 1]
            _ = WindowRegistry.shared.createProject(level: fallback)
            menuBarController?.refreshStatusItem()
        }
    }

    // MARK: - Temp task

    private func handleNewTempTask() {
        TempTaskInputController.shared.present()
    }

    // MARK: - Intake

    private func showIntake() {
        IntakeChatWindowController.shared.show()
    }

    // MARK: - Settings

    private func showSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "NextStep 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 380))
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
