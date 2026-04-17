import AppKit
import Foundation

/// Owns the "where do we put markdown files" folder URL.
///
/// The app is sandboxed, so we can only touch paths the user explicitly
/// grants via `NSOpenPanel`. We persist a **security-scoped bookmark** in
/// `UserDefaults`, then resolve + `startAccessingSecurityScopedResource()`
/// on next launch. Without this, a relaunch would silently lose access.
@MainActor
final class MarkdownFolderStore {
    static let shared = MarkdownFolderStore()

    private let bookmarkKey = "projectsFolderBookmark_v1"

    /// The currently-resolved folder URL, or `nil` if the user hasn't picked
    /// one yet. While non-nil, we hold an active security-scoped access —
    /// don't read this from code that expects an inactive URL.
    private(set) var currentURL: URL?

    /// True once we've called `startAccessingSecurityScopedResource()` on
    /// `currentURL`. Paired stop lives in `deinit` / `teardown()`.
    private var isAccessing = false

    private init() {
        _ = restoreFromBookmark()
    }

    // MARK: - Folder selection

    /// Present the Cocoa folder picker. Returns the chosen URL, or `nil` if
    /// the user canceled / we failed to bookmark. Caller is expected to be
    /// on the main thread (NSOpenPanel requires it anyway).
    @discardableResult
    func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择项目文件夹"
        panel.message = "NextStep 会把每个项目保存为一个 markdown 文件到此文件夹。"

        // Suggest ~/Documents/NextStep/projects/ as the default location so
        // users who just want the recommended setup can tap Enter.
        if let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first {
            let suggested = docs
                .appendingPathComponent("NextStep", isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
            // Don't pre-create — let the user decide. Just point the panel.
            panel.directoryURL = suggested.deletingLastPathComponent()
            panel.nameFieldStringValue = "projects"
        }

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        // Release the old scope before adopting the new one.
        teardown()

        // Save a security-scoped bookmark so we can re-open on next launch.
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            NSLog("MarkdownFolderStore: bookmark failed — \(error)")
            // Keep going anyway — we still have access during this launch.
        }

        adopt(url)
        return url
    }

    /// Forget the saved folder (does not delete any files).
    func clearFolder() {
        teardown()
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    // MARK: - iCloud Drive shortcut

    /// The canonical iCloud Drive path for this app's projects folder.
    /// Always returns a URL (even if iCloud is disabled or not mounted) — use
    /// `iCloudAvailable()` to gate UI.
    ///
    /// We live under the user's generic "iCloud Drive" visible namespace
    /// (`~/Library/Mobile Documents/com~apple~CloudDocs/NextStep/projects/`)
    /// rather than a per-app ubiquity container, so:
    ///   - The folder is visible in Finder's sidebar under "iCloud Drive".
    ///   - Users can edit the markdown from any other Mac / iPad / VS Code.
    ///   - We don't depend on an iCloud container entitlement.
    static func suggestedICloudURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
            .appendingPathComponent("NextStep", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// True when the user is signed into iCloud and iCloud Drive is enabled
    /// on this Mac. Checks the container's mount point, which is present
    /// only when Drive is active.
    static func iCloudAvailable() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let mount = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: mount.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    /// Whether a given URL lives inside iCloud Drive. Used by Settings to
    /// show the ☁️ badge on the current folder.
    static func isICloudURL(_ url: URL) -> Bool {
        // The canonical path contains `/Mobile Documents/`; that's the
        // marker Finder uses internally too.
        let resolved = url.resolvingSymlinksInPath().path
        return resolved.contains("/Mobile Documents/")
    }

    /// Skip the folder picker and adopt the iCloud Drive default directly.
    /// Creates it if missing. Returns the URL on success.
    ///
    /// Bookmarks still work for iCloud paths — even if the file isn't
    /// downloaded yet, the URL resolves and macOS triggers download on first
    /// read.
    @discardableResult
    func adoptICloudDefault() -> URL? {
        guard Self.iCloudAvailable() else { return nil }
        let url = Self.suggestedICloudURL()

        // Ensure the parent chain exists before bookmarking.
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true
            )
        } catch {
            NSLog("MarkdownFolderStore: create iCloud folder failed — \(error)")
            return nil
        }

        // Release any previous scope before adopting the new one.
        teardown()

        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            NSLog("MarkdownFolderStore: bookmark iCloud failed — \(error)")
            // Keep going — we still have access this launch.
        }

        adopt(url)
        return url
    }

    // MARK: - Restore on launch

    /// Resolve the saved bookmark. Returns the URL, or `nil` if we never
    /// had one or the bookmark is stale (user moved/deleted the folder).
    @discardableResult
    func restoreFromBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return nil
        }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            adopt(url)

            // If stale, try to refresh the bookmark so we don't break next launch.
            if stale {
                if let fresh = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    UserDefaults.standard.set(fresh, forKey: bookmarkKey)
                }
            }

            return url
        } catch {
            NSLog("MarkdownFolderStore: restore failed — \(error)")
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return nil
        }
    }

    // MARK: - File paths

    /// The filesystem URL for a project's markdown file. Returns `nil` if
    /// no folder is picked. Uses the project's `id` (not name) in the
    /// filename to avoid collisions / rename churn.
    func markdownURL(forProjectID id: UUID, projectName: String) -> URL? {
        guard let folder = currentURL else { return nil }

        // A stable, filesystem-safe filename: `<slug>-<id8>.md`
        // Using id prefix keeps two same-named projects from colliding.
        let idPrefix = id.uuidString.prefix(8).lowercased()
        let slug = slugify(projectName).isEmpty ? "project" : slugify(projectName)
        let filename = "\(slug)-\(idPrefix).md"
        return folder.appendingPathComponent(filename)
    }

    /// Ensure the folder actually exists on disk. No-op if it does.
    /// Returns false on failure (e.g. permissions).
    @discardableResult
    func ensureFolderExists() -> Bool {
        guard let url = currentURL else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true
            )
            return true
        } catch {
            NSLog("MarkdownFolderStore: create folder failed — \(error)")
            return false
        }
    }

    // MARK: - Scope lifecycle

    private func adopt(_ url: URL) {
        currentURL = url
        isAccessing = url.startAccessingSecurityScopedResource()
    }

    private func teardown() {
        if isAccessing, let url = currentURL {
            url.stopAccessingSecurityScopedResource()
        }
        isAccessing = false
        currentURL = nil
    }

    // MARK: - Helpers

    /// Very conservative slug: strip path separators + collapse whitespace.
    /// We keep CJK characters — macOS filesystems handle UTF-8 fine, and
    /// users reading the folder directly should see recognizable names.
    private func slugify(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let noSlashes = trimmed.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        // Collapse runs of whitespace.
        let parts = noSlashes.split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ")
    }
}
