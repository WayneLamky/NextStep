import AppKit
import Carbon.HIToolbox

/// Registers a single app-wide hotkey via the Carbon HotKey API.
///
/// `NSEvent.addGlobalMonitor` cannot intercept keystrokes (it only observes),
/// and `addLocalMonitor` only fires when the app is frontmost — which this
/// LSUIElement app never is. Carbon is the supported path for a menu-bar app.
@MainActor
final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private let handler: () -> Void
    private let id: UInt32

    private static var registry: [UInt32: GlobalHotkey] = [:]
    private static var eventHandlerInstalled = false

    init(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.id = id
        self.handler = handler
        Self.installEventHandlerIfNeeded()

        let hkID = EventHotKeyID(signature: fourCharCode("NxSt"), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hkID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            self.hotKeyRef = ref
            Self.registry[id] = self
        } else {
            NSLog("NextStep: failed to register hotkey id=\(id) status=\(status)")
        }
    }
    // Hotkeys live for the lifetime of the app (held by AppDelegate), so no
    // Carbon-side teardown is necessary — we deliberately skip deinit cleanup
    // to avoid touching MainActor state from a nonisolated context.

    fileprivate func fire() { handler() }

    // MARK: - Carbon plumbing

    private static func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, _ -> OSStatus in
                guard let eventRef else { return OSStatus(eventNotHandledErr) }
                var hkID = EventHotKeyID()
                let err = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                guard err == noErr else { return err }
                Task { @MainActor in
                    GlobalHotkey.registry[hkID.id]?.fire()
                }
                return noErr
            },
            1,
            &spec,
            nil,
            nil
        )
    }
}

private func fourCharCode(_ s: String) -> FourCharCode {
    var result: FourCharCode = 0
    for ch in s.utf8.prefix(4) {
        result = (result << 8) | FourCharCode(ch)
    }
    return result
}

/// Named IDs for hotkeys we register.
enum HotkeyID {
    static let newProject: UInt32 = 1
    static let newTempTask: UInt32 = 2
}

/// Carbon virtual key codes we need.
enum KeyCode {
    static let p: UInt32 = UInt32(kVK_ANSI_P)
    static let n: UInt32 = UInt32(kVK_ANSI_N)
}

/// Convenience modifier mask for ⌥⌘.
let optionCommandModifiers: UInt32 = UInt32(optionKey | cmdKey)
