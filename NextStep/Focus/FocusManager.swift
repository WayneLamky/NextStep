import AppKit
import Observation
import SwiftUI

/// M6 · 聚焦模式
///
/// 桌面上一次只有一张便利贴被聚焦，其他的压在一张 ~40% 黑色 overlay
/// 背后。overlay 自己 `ignoresMouseEvents`，所以用户点击未聚焦的便利贴
/// 依然能把焦点转过去；ESC / 再次双击退出。
///
/// 视觉三层（从下到上）：
///     1. 未聚焦便利贴（panel.level = .floating）
///     2. FocusOverlayPanel（.floating + 1）
///     3. 聚焦的那张便利贴（.floating + 2）
@MainActor
@Observable
final class FocusManager {
    static let shared = FocusManager()

    /// 当前聚焦的项目。nil = 未进入聚焦模式。
    private(set) var focusedProjectID: UUID?

    /// 用来给 SwiftUI 观察者触发视图更新（breathing 效果等）。
    private(set) var revision: Int = 0

    private var overlay: FocusOverlayPanel?
    private var keyMonitor: Any?

    private init() {}

    // MARK: - API

    func isFocused(_ projectID: UUID) -> Bool {
        focusedProjectID == projectID
    }

    func toggle(_ projectID: UUID) {
        if focusedProjectID == projectID {
            exitFocus()
        } else {
            enterFocus(projectID: projectID)
        }
    }

    func enterFocus(projectID: UUID) {
        focusedProjectID = projectID
        presentOverlay()
        restackPanels()
        installKeyMonitor()
        bump()
    }

    func exitFocus() {
        guard focusedProjectID != nil else { return }
        focusedProjectID = nil
        dismissOverlay()
        restackPanels()
        removeKeyMonitor()
        bump()
    }

    /// Called by WindowRegistry when a new window opens / closes so it can
    /// inherit the correct level relative to the current focus state.
    func applyLevels() {
        restackPanels()
    }

    // MARK: - Overlay

    private func presentOverlay() {
        if overlay == nil {
            overlay = FocusOverlayPanel()
        }
        overlay?.present()
    }

    private func dismissOverlay() {
        overlay?.dismissAnimated()
    }

    // MARK: - Panel levels

    private func restackPanels() {
        let focused = focusedProjectID
        for (pid, controller) in WindowRegistry.shared.controllers {
            if let focused, pid == focused {
                controller.panel.level = NSWindow.Level(
                    rawValue: NSWindow.Level.floating.rawValue + 2
                )
                controller.panel.orderFront(nil)
            } else {
                controller.panel.level = .floating
            }
        }
    }

    // MARK: - ESC

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 53 = ESC
            if event.keyCode == 53, self?.focusedProjectID != nil {
                Task { @MainActor in self?.exitFocus() }
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    private func bump() { revision &+= 1 }
}

// MARK: - Overlay panel

/// Full-screen transparent panel with a soft dim. Lives between non-focused
/// stickies (.floating) and the focused sticky (.floating + 2). Click-through.
@MainActor
final class FocusOverlayPanel: NSPanel {

    init() {
        let frame = Self.unionFrame()
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        let dim = NSView(frame: NSRect(origin: .zero, size: frame.size))
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor
        contentView = dim
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present() {
        setFrame(Self.unionFrame(), display: true)
        alphaValue = 0
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            self.animator().alphaValue = 1
        }
    }

    func dismissAnimated() {
        // Fade, then drop. Completion handler hops back to main actor before
        // calling orderOut so Swift 6 is happy with it. No `override` on
        // `orderOut` — we'd recurse if we tried to animate from inside it.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                self?.orderOut(nil)
            }
        }
    }

    /// Bounding box of every screen, so the overlay covers multi-monitor setups.
    private static func unionFrame() -> NSRect {
        NSScreen.screens.reduce(NSRect.zero) { acc, screen in
            acc == .zero ? screen.frame : acc.union(screen.frame)
        }
    }
}
