import AppKit
import SwiftData
import SwiftUI

/// Single-window host for the 归档库. One instance at a time; calling
/// `ArchiveWindowController.shared.show()` either brings up the existing
/// window or creates a fresh one.
@MainActor
final class ArchiveWindowController: NSObject, NSWindowDelegate {
    static let shared = ArchiveWindowController()

    private var window: NSWindow?

    private override init() { super.init() }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let size = NSSize(width: 520, height: 480)
        let screen = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2
        )

        let win = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "归档库"
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 420, height: 360)
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = ArchiveView()
            .modelContainer(AppStore.shared.container)
        let hosting = NSHostingController(rootView: root)
        hosting.view.wantsLayer = true
        win.contentViewController = hosting
        win.delegate = self

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
