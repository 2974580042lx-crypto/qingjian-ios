import Foundation

// Daily backups always go to the app's own Documents/自动备份 folder, which the Files
// app shows under 我的 iPhone › Sermo, so backing up never depends on a picker.
// A folder the user picked once (iCloud Drive, On My iPhone…) gets an extra copy;
// its security-scoped bookmark lets the app write there again later without iCloud
// entitlements, so this works with self-signing.
enum BackupFolder {
    static let localFolderName = "自动备份"
    static let localLocation = "我的 iPhone › Sermo › 自动备份"
    private static let bookmarkKey = "qingjian.backup.folderBookmark"
    private static let nameKey = "qingjian.backup.folderName"
    private static let lastKey = "qingjian.backup.lastDate"
    static let prefix = "Sermo自动备份-"
    // Only files this feature wrote (by name) are ever removed, oldest first.
    static let keepCount = 7

    static var folderName: String? { UserDefaults.standard.string(forKey: nameKey) }
    static var lastBackup: Date? {
        get { UserDefaults.standard.object(forKey: lastKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastKey) }
    }

    /// Saves access to the folder; returns its display name.
    static func remember(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let name = FileManager.default.displayName(atPath: url.path)
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        UserDefaults.standard.set(name, forKey: nameKey)
        return name
    }

    /// Stops the extra copy only; backups into the app's own folder keep running.
    static func forget() {
        for key in [bookmarkKey, nameKey] { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// File name for a given day; one file per day, rewritten if run again that day.
    static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return prefix + formatter.string(from: date) + ".json"
    }

    /// Older automatic backups beyond `keep`, by name (dates sort as text).
    static func expired(_ names: [String], keep: Int = keepCount) -> [String] {
        let ours = names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }.sorted(by: >)
        return Array(ours.dropFirst(keep))
    }

    /// The app's own backup folder inside Documents, created on first use.
    static func localFolder() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        let folder = documents.appendingPathComponent(localFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Writes today's backup into the app's own folder (must succeed) and, when one was
    /// picked, an extra copy into that folder. Returns why the extra copy failed, if it did.
    /// Runs off the main thread.
    @discardableResult
    static func write(_ data: Data, now: Date = Date()) throws -> String? {
        let local = try localFolder()
        try data.write(to: local.appendingPathComponent(fileName(for: now)), options: .atomic)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: local.path)) ?? []
        for name in expired(names) { try? FileManager.default.removeItem(at: local.appendingPathComponent(name)) }
        guard UserDefaults.standard.data(forKey: bookmarkKey) != nil else { return nil }
        do { try writeExtra(data, now: now); return nil } catch { return error.localizedDescription }
    }

    private static func writeExtra(_ data: Data, now: Date) throws {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var stale = false
        let folder = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard folder.startAccessingSecurityScopedResource() else { throw CocoaError(.fileWriteNoPermission) }
        defer { folder.stopAccessingSecurityScopedResource() }
        if stale, let fresh = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var writeError: Error?
        let target = folder.appendingPathComponent(fileName(for: now))
        coordinator.coordinate(writingItemAt: target, options: .forReplacing, error: &coordinationError) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in expired(names) {
            var removeError: NSError?
            coordinator.coordinate(writingItemAt: folder.appendingPathComponent(name), options: .forDeleting, error: &removeError) { url in
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

// A file opened in Sermo from the Files app arrives as the original, not a copy, now that
// the app's own folder is shown in Files. Importers delete what they are handed once read,
// so they get a private copy and the original is never touched.
enum IncomingFile {
    static func privateCopy(of url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Incoming-" + UUID().uuidString, isDirectory: true)
        let target = folder.appendingPathComponent(url.lastPathComponent)
        var coordinationError: NSError?
        var copied = false
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readable in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: readable, to: target)
                copied = true
            } catch {}
        }
        // The system's own inbox copy (older "Open in" path) is ours to clear.
        if copied, url.pathComponents.contains("Inbox"),
           let documents = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
           url.standardizedFileURL.path.hasPrefix(documents.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: url)
        }
        return copied ? target : nil
    }
}
