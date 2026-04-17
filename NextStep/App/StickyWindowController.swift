import AppKit
import SwiftData
import SwiftUI

@MainActor
final class StickyWindowController: NSObject, NSWindowDelegate {
    let projectID: UUID
    let panel: StickyPanel
    private weak var registry: WindowRegistry?

    init(project: Project, container: ModelContainer, registry: WindowRegistry) {
        self.projectID = project.id
        self.registry = registry

        let frame = NSRect(
            x: project.positionX,
            y: project.positionY,
            width: max(project.width, 260),
            height: max(project.height, 220)
        )
        let panel = StickyPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.tabbingMode = .disallowed
        panel.animationBehavior = .utilityWindow
        panel.minSize = NSSize(width: 240, height: 200)

        self.panel = panel
        super.init()
        panel.delegate = self

        let root = StickyView(projectID: project.id)
            .modelContainer(container)
        let hosting = NSHostingController(rootView: root)
        hosting.view.wantsLayer = true
        panel.contentViewController = hosting
    }

    func show() { panel.orderFront(nil) }

    // NSWindowDelegate
    func windowDidMove(_ notification: Notification) {
        registry?.persistFrame(for: projectID, frame: panel.frame)
    }

    func windowDidResize(_ notification: Notification) {
        registry?.persistFrame(for: projectID, frame: panel.frame)
    }

    func windowWillClose(_ notification: Notification) {
        registry?.windowDidClose(projectID: projectID)
    }
}
