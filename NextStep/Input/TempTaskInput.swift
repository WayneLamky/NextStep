import AppKit
import SwiftData
import SwiftUI

/// `NSPanel` with `.nonactivatingPanel` has `canBecomeKey == false` by
/// default, which means `makeKeyAndOrderFront` is a no-op and the contained
/// TextField never receives keystrokes. Override to allow key status.
private final class TempTaskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Thin ~420×44 floating panel that captures a temp task on Enter.
///
/// In M2 we persist the task locally; M5 will add the EventKit round-trip.
@MainActor
final class TempTaskInputController: NSObject, NSWindowDelegate {
    static let shared = TempTaskInputController()

    private var panel: NSPanel?

    private override init() { super.init() }

    func toggle() {
        if let panel, panel.isVisible {
            dismiss()
        } else {
            present()
        }
    }

    func present() {
        if panel == nil { makePanel() }
        guard let panel else { return }

        let size = NSSize(width: 420, height: 44)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first!
        let frame = screen.visibleFrame
        let x = min(max(mouse.x - size.width / 2, frame.minX + 16), frame.maxX - size.width - 16)
        let y = min(max(mouse.y - size.height - 12, frame.minY + 16), frame.maxY - size.height - 16)

        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: false)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    private func makePanel() {
        let p = TempTaskPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 44),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.isMovableByWindowBackground = true
        p.isFloatingPanel = true
        p.hidesOnDeactivate = true
        p.hasShadow = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        p.animationBehavior = .utilityWindow
        p.delegate = self

        let host = NSHostingController(
            rootView: TempTaskInputView(
                onSubmit: { [weak self] text in
                    self?.commit(text: text)
                    self?.dismiss()
                },
                onCancel: { [weak self] in
                    self?.dismiss()
                }
            )
            .modelContainer(AppStore.shared.container)
        )
        host.view.wantsLayer = true
        p.contentViewController = host
        panel = p
    }

    private func commit(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Try to extract a date phrase ("明天下午 17:30", "tomorrow 5pm")
        // and strip it from the displayed task body. NSDataDetector handles
        // both English and Chinese natural-language date expressions.
        let (cleaned, due) = extractDate(from: trimmed)

        let task = TempTask(text: cleaned, dueDate: due)
        AppStore.shared.context.insert(task)
        try? AppStore.shared.context.save()

        // M5 — mirror to Reminders.
        RemindersBridge.shared.syncTempTask(taskID: task.id)
    }

    /// Parse a natural-language date out of the user's input. If found,
    /// returns the input with the matched date phrase removed plus the
    /// resolved Date; otherwise returns the original text and nil.
    private func extractDate(from text: String) -> (String, Date?) {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue
        ) else { return (text, nil) }
        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, range: range)
        guard let first = matches.first, let date = first.date else {
            return (text, nil)
        }
        // Strip the matched phrase to keep the visible task tight.
        let nsText = text as NSString
        var cleaned = nsText.replacingCharacters(in: first.range, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse double spaces.
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        if cleaned.isEmpty { cleaned = text }  // Don't lose the whole text.
        return (cleaned, date)
    }

    // NSWindowDelegate — dismiss on focus loss
    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }
}

private struct TempTaskInputView: View {
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))
            TextField("记一条临时任务…  (Enter 保存, Esc 取消)", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit { onSubmit(text) }
                .onExitCommand { onCancel() }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.black.opacity(0.1), lineWidth: 0.5)
        )
        .onAppear {
            // onAppear can fire before the panel has fully become key;
            // delaying a tick lets AppKit settle so .focused lands.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                focused = true
            }
        }
    }
}
