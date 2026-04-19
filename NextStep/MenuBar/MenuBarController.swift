import AppKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let onNewProject: (ProjectLevel) -> Void
    private let onNewTempTask: () -> Void
    private let onOpenIntake: () -> Void
    private let onOpenProject: (Project) -> Void
    private let onOpenSettings: () -> Void
    private let onOpenArchive: () -> Void
    private let onOpenAbout: () -> Void
    private let onQuit: () -> Void

    init(
        onNewProject: @escaping (ProjectLevel) -> Void,
        onNewTempTask: @escaping () -> Void,
        onOpenIntake: @escaping () -> Void,
        onOpenProject: @escaping (Project) -> Void,
        onOpenSettings: @escaping () -> Void,
        onOpenArchive: @escaping () -> Void,
        onOpenAbout: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onNewProject = onNewProject
        self.onNewTempTask = onNewTempTask
        self.onOpenIntake = onOpenIntake
        self.onOpenProject = onOpenProject
        self.onOpenSettings = onOpenSettings
        self.onOpenArchive = onOpenArchive
        self.onOpenAbout = onOpenAbout
        self.onQuit = onQuit

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        refreshStatusItem()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Update the status bar image + capacity badge.
    func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        let counts = WindowRegistry.shared.capacityCounts()
        let badge = "\(counts.total)/\(counts.cap)"
        let image = NSImage(
            systemSymbolName: "square.stack.3d.up",
            accessibilityDescription: "NextStep"
        )
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.title = " " + badge
        button.toolTip = "NextStep — \(badge) 活跃项目"
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshStatusItem()
        rebuild(menu: menu)
    }

    private func rebuild(menu: NSMenu) {
        menu.removeAllItems()

        let counts = WindowRegistry.shared.capacityCounts()

        // Section: new project by level
        let levelHeader = NSMenuItem()
        levelHeader.title = "新建项目"
        levelHeader.isEnabled = false
        menu.addItem(levelHeader)

        for lvl in ProjectLevel.allCases {
            let n = counts.count(for: lvl)
            let cap = lvl.capacity
            let title = "  \(lvl.displayName)目标  (\(n)/\(cap))"
            let item = NSMenuItem(
                title: title,
                action: #selector(handleNewProject(_:)),
                keyEquivalent: lvl == .week ? "p" : ""
            )
            if lvl == .week {
                item.keyEquivalentModifierMask = [.command, .option]
            }
            item.target = self
            item.representedObject = lvl.rawValue
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let tempTask = NSMenuItem(
            title: "记一条临时任务…",
            action: #selector(handleNewTempTask),
            keyEquivalent: "n"
        )
        tempTask.keyEquivalentModifierMask = [.command, .option]
        tempTask.target = self
        menu.addItem(tempTask)

        let intake = NSMenuItem(
            title: "AI 规划…",
            action: #selector(handleIntake),
            keyEquivalent: ""
        )
        intake.target = self
        menu.addItem(intake)

        // Hidden projects
        let hidden = WindowRegistry.shared.hiddenProjects()
        if !hidden.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem()
            header.title = "打开隐藏的项目"
            header.isEnabled = false
            menu.addItem(header)
            for project in hidden.prefix(20) {
                let name = project.name.isEmpty ? "（未命名）" : project.name
                let title = "  [\(project.level.displayName)] " + name
                let item = NSMenuItem(
                    title: title,
                    action: #selector(handleOpenProject(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = project.id
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let archive = NSMenuItem(
            title: "归档库…",
            action: #selector(handleArchive),
            keyEquivalent: ""
        )
        archive.target = self
        menu.addItem(archive)

        let settings = NSMenuItem(
            title: "设置…",
            action: #selector(handleSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let about = NSMenuItem(
            title: "关于 NextStep",
            action: #selector(handleAbout),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "退出 NextStep",
            action: #selector(handleQuit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func handleNewProject(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let level = ProjectLevel(rawValue: raw)
        else { return }
        onNewProject(level)
    }

    @objc private func handleNewTempTask() { onNewTempTask() }
    @objc private func handleIntake()      { onOpenIntake() }
    @objc private func handleSettings()    { onOpenSettings() }
    @objc private func handleArchive()     { onOpenArchive() }
    @objc private func handleAbout()       { onOpenAbout() }
    @objc private func handleQuit()        { onQuit() }

    @objc private func handleOpenProject(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        let hidden = WindowRegistry.shared.hiddenProjects()
        guard let project = hidden.first(where: { $0.id == id }) else { return }
        onOpenProject(project)
    }
}
