import Foundation

/// Automatic cross-device sync of the Face Off training log via a
/// user-chosen iCloud Drive folder — "Option A": no iCloud entitlements, no
/// paid developer account, works with the folder-based workflow already in
/// use. (The zero-setup "Option B" — a real iCloud container/CloudKit — is
/// documented in the README to-do.)
///
/// Design: **one file per writer, merge on read.** Each device writes its
/// full merged history to `faceoffs-<deviceID>.jsonl` in the folder and
/// imports every *other* `.jsonl` it finds there (including manual exports
/// like `Sorted-faceoffs*.jsonl`, so the old workflow keeps feeding in).
/// Writers never touch each other's files, so there are no write conflicts;
/// reads converge because `FaceOffLog.importData` is an idempotent merge.
///
/// Access is remembered as a bookmark (security-scoped where the platform
/// sandbox requires it — iOS always; harmless on the unsandboxed Mac app).
/// Sync is best-effort and silent: a failure (folder offline, file
/// dataless and not yet downloaded) just means that pass adds nothing.
enum FaceOffSync {
    private static let bookmarkKey = "Sorted.sync.folderBookmark"
    private static let deviceIDKey = "Sorted.sync.deviceID"

    /// Stable per-install writer identity, minted on first use.
    private static var deviceID: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceIDKey) { return existing }
        let fresh = String(UUID().uuidString.prefix(8))
        defaults.set(fresh, forKey: deviceIDKey)
        return fresh
    }

    private static var ownFileName: String { "faceoffs-\(deviceID).jsonl" }

    // MARK: Configuration

    static var isConfigured: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    /// The chosen folder's name, for display in Settings; nil when off.
    static var folderDisplayName: String? {
        resolveFolder()?.lastPathComponent
    }

    /// Remembers the folder and runs a first sync. The URL must come from a
    /// folder picker (it carries the access grant we turn into a bookmark).
    static func configure(folder url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        guard let bookmark = try? url.bookmarkData(
            options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }

    static func disable() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    private static func resolveFolder() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark, options: options,
            relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        if stale {
            // Refresh the bookmark while we still can resolve it.
            configure(folder: url)
        }
        return url
    }

    // MARK: Sync

    /// One pass: import every other writer's `.jsonl` from the folder, then
    /// publish this device's full merged history. Returns how many new
    /// judgments were merged in (0 when unconfigured or unreachable).
    @discardableResult
    static func sync() -> Int {
        guard let folder = resolveFolder() else { return 0 }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        var imported = 0
        let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in entries
        where url.pathExtension == "jsonl" && url.lastPathComponent != ownFileName {
            // Nudge iCloud to materialize dataless files; if this pass can't
            // read one yet, the next sync picks it up.
            try? fm.startDownloadingUbiquitousItem(at: url)
            if let data = try? Data(contentsOf: url) {
                imported += FaceOffLog.importData(data)
            }
        }

        let history = FaceOffLog.exportData()
        if !history.isEmpty {
            try? history.write(to: folder.appendingPathComponent(ownFileName), options: .atomic)
        }
        return imported
    }
}
