import Foundation

// Every write goes through one serial queue, so a background save started
// during streaming can never land after, and overwrite, a newer one.
struct SafetySnapshotInfo: Identifiable, Sendable {
    var id: String { url.path }
    let name: String
    let size: Int64
    let date: Date
    let url: URL
}

final class AppPersistence: @unchecked Sendable {
    private let directory: URL
    private let safetyDirectory: URL
    let file: URL
    private let queue = DispatchQueue(label: "com.xiaolong.qingjian.persistence", qos: .utility)
    private var lastNonEmptyThreadCount = 0
    var onBackgroundError: (@Sendable (String) -> Void)?

    init() throws {
        directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("QingJian", isDirectory: true)
        safetyDirectory = directory.appendingPathComponent("Safety", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: safetyDirectory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: safetyDirectory.path)
        file = directory.appendingPathComponent("conversations.json")
        if FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        }
    }
    func load() throws -> AppSnapshot? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let loaded = try AppSnapshot.decodeLocal(Data(contentsOf: file))
        lastNonEmptyThreadCount = loaded.threads.filter { !$0.messages.isEmpty }.count
        return loaded
    }
    func save(_ snapshot: AppSnapshot, allowShrink: Bool = false) throws {
        try queue.sync { try write(snapshot, allowShrink: allowShrink) }
    }
    func saveInBackground(_ snapshot: AppSnapshot) {
        queue.async { [self] in
            do { try write(snapshot, allowShrink: false) }
            catch { onBackgroundError?(error.localizedDescription) }
        }
    }
    private func write(_ snapshot: AppSnapshot, allowShrink: Bool) throws {
        let data = try snapshot.encoded(pretty: false, isLocalStore: true)
        let newNonEmpty = snapshot.threads.filter { !$0.messages.isEmpty }.count
        if !allowShrink, FileManager.default.fileExists(atPath: file.path) {
            let oldSize = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let drasticByteDrop = oldSize > 100 * 1024 && data.count * 5 < oldSize
            let drasticThreadDrop = lastNonEmptyThreadCount >= 5 && newNonEmpty == 0
            if drasticByteDrop || drasticThreadDrop {
                _ = try? createSafetyCopy(prefix: "before-shrink")
                throw ChatError.server("检测到对话记录异常骤减，原文件已保护在 Safety 目录并停止覆盖。")
            }
        }
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        lastNonEmptyThreadCount = newNonEmpty
    }
    @discardableResult
    func createSafetyCopy(prefix: String = "manual-safety", keep: Int = 5) throws -> URL? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(prefix)-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4)).json"
        let target = safetyDirectory.appendingPathComponent(name)
        let raw = try Data(contentsOf: file)
        try raw.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        pruneSafetyCopies(keep: keep)
        return target
    }
    private func pruneSafetyCopies(keep: Int) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: safetyDirectory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        let sorted = urls.filter { $0.pathExtension == "json" }.sorted {
            let d0 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let d1 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return d0 > d1
        }
        for old in sorted.dropFirst(max(1, keep)) {
            try? FileManager.default.removeItem(at: old)
        }
    }
    func safetySnapshots() -> [SafetySnapshotInfo] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: safetyDirectory, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let date = values?.contentModificationDate ?? values?.creationDate ?? .distantPast
            return SafetySnapshotInfo(name: url.lastPathComponent, size: size, date: date, url: url)
        }.sorted { $0.date > $1.date }
    }
    func fileStats() -> (size: Int64, modified: Date?) {
        guard FileManager.default.fileExists(atPath: file.path),
              let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return (0, nil)
        }
        return (Int64(values.fileSize ?? 0), values.contentModificationDate)
    }
    func export(_ snapshot: AppSnapshot) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sermo备份-\(formatter.string(from: Date())).json")
        try snapshot.encoded(pretty: true, isLocalStore: false).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }
}
