import Foundation

// Every write goes through one serial queue, so a background save started
// during streaming can never land after, and overwrite, a newer one.
final class AppPersistence: @unchecked Sendable {
    private let directory: URL
    private let file: URL
    private let queue = DispatchQueue(label: "com.xiaolong.qingjian.persistence", qos: .utility)
    init() throws {
        directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("QingJian", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("conversations.json")
    }
    func load() throws -> AppSnapshot? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try AppSnapshot.decode(Data(contentsOf: file))
    }
    func save(_ snapshot: AppSnapshot) throws {
        try queue.sync { try write(snapshot) }
    }
    // Encoding every conversation takes long enough to drop frames, so streamed
    // text is saved off the main thread. A failure here is quiet: the save when
    // the answer finishes runs on the main path and reports errors.
    func saveInBackground(_ snapshot: AppSnapshot) {
        queue.async { [self] in try? write(snapshot) }
    }
    private func write(_ snapshot: AppSnapshot) throws {
        let data = try snapshot.encoded()
        try data.write(to: file, options: [.atomic, .completeFileProtection])
    }
    func export(_ snapshot: AppSnapshot) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sermo备份-\(formatter.string(from: Date())).json")
        try snapshot.encoded().write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}
