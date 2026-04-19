import AppKit
import SwiftUI

/// Single-window host for the Q&A intake. One instance at a time; calling
/// `IntakeChatWindowController.shared.show()` either brings up the existing
/// window or creates a fresh one with a new session.
@MainActor
final class IntakeChatWindowController: NSObject, NSWindowDelegate {
    static let shared = IntakeChatWindowController()

    private var window: NSWindow?

    private override init() { super.init() }

    func show() {
        // Fresh conversation every time the user reopens the window.
        // Old chats that went nowhere shouldn't follow them back.
        if window == nil {
            IntakeCoordinator.shared.startNew()
        }

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let size = NSSize(width: 560, height: 720)
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
        win.title = "AI 规划"
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 460, height: 520)
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Auto-close the window once the user successfully commits.
        IntakeCoordinator.shared.onFinish = { [weak self] in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                self?.window?.close()
            }
        }

        let root = IntakeChatView(
            session: IntakeCoordinator.shared.session,
            coordinator: IntakeCoordinator.shared
        )
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
        // Clear the onFinish callback — next open will rewire.
        IntakeCoordinator.shared.onFinish = nil
    }
}
