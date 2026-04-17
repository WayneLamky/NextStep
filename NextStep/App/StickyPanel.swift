import AppKit

/// NSPanel subclass that can become key (so text fields work)
/// without making the app "main", so other apps keep their menu bar.
final class StickyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
