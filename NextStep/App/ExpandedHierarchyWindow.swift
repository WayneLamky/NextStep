import AppKit
import SwiftData
import SwiftUI

/// Host for the "展开为层级视图" modal-style window (Flow 5).
///
/// One window per project at most. ESC closes. Shares the app's model
/// container so edits to the goal fields round-trip through SwiftData →
/// markdown.
@MainActor
final class ExpandedHierarchyWindowController: NSObject, NSWindowDelegate {
    let projectID: UUID
    let window: NSPanel
    private weak var registry: ExpandedHierarchyRegistry?
    private var escMonitor: Any?

    init(
        project: Project,
        container: ModelContainer,
        registry: ExpandedHierarchyRegistry
    ) {
        self.projectID = project.id
        self.registry = registry

        let defaultSize = NSSize(width: 560, height: 540)
        let screenFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screenFrame.midX - defaultSize.width / 2,
            y: screenFrame.midY - defaultSize.height / 2
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: defaultSize),
            styleMask: [
                .titled,
                .closable,
                .resizable,
                .fullSizeContentView,
                .utilityWindow,
                .nonactivatingPanel,
            ],
            backing: .buffered,
            defer: false
        )
        panel.title = "展开 · \(project.name.isEmpty ? "项目" : project.name)"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.tabbingMode = .disallowed
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = NSSize(width: 460, height: 440)
        panel.isReleasedWhenClosed = false

        self.window = panel
        super.init()
        panel.delegate = self

        let root = ExpandedHierarchyView(projectID: project.id) { [weak self] in
            self?.close()
        }
        .modelContainer(container)
        let hosting = NSHostingController(rootView: root)
        hosting.view.wantsLayer = true
        panel.contentViewController = hosting
    }

    func show() {
        // ESC-to-close while this window is key.
        if escMonitor == nil {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if event.keyCode == 53,  // ESC
                   self.window.isKeyWindow {
                    Task { @MainActor in self.close() }
                    return nil
                }
                return event
            }
        }
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }

    // NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
        registry?.windowDidClose(projectID: projectID)
    }
}

@MainActor
final class ExpandedHierarchyRegistry {
    static let shared = ExpandedHierarchyRegistry()

    private var controllers: [UUID: ExpandedHierarchyWindowController] = [:]

    private init() {}

    func toggle(for projectID: UUID) {
        if let existing = controllers[projectID] {
            existing.close()
            return
        }
        open(for: projectID)
    }

    func open(for projectID: UUID) {
        if let existing = controllers[projectID] {
            existing.show()
            return
        }
        let context = AppStore.shared.context
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.id == projectID }
        )
        guard let project = (try? context.fetch(descriptor))?.first else { return }
        let controller = ExpandedHierarchyWindowController(
            project: project,
            container: AppStore.shared.container,
            registry: self
        )
        controllers[projectID] = controller
        controller.show()
    }

    func windowDidClose(projectID: UUID) {
        controllers.removeValue(forKey: projectID)
    }
}
