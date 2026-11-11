import Foundation
import ImageIO

enum StudyBackupError: LocalizedError {
    case invalid(String), conflict(String), unavailable
    var errorDescription: String? {
        switch self {
        case .invalid(let message), .conflict(let message): return message
        case .unavailable: return "学习备份暂时无法完成，待传记录已保留。"
        }
    }
}
struct StudyBackupImage: Codable, Sendable {
    let name: String
    let data: Data
    let sha256: String
    var originalSHA256: String? = nil
}
struct StudyOmittedImage: Codable, Sendable {
    let name: String
    let sha256: String?
    let bytes: Int
    let reason: String
}
struct StudyImageCapacity: Sendable {
    let count: Int
    let bytes: Int
    let unavailable: Int
    var warning: Bool { bytes >= StudyBackupCodec.imageWarningBytes || unavailable > 0 }
}
struct StudyBackupPayload: Codable, Sendable {
    let version: Int
    let backupID: UUID
    let deviceID: String
    let createdAt: Date
    let projectIDs: [UUID]
    let snapshot: AppSnapshot
    let learning: StudyMemoryArchive
    let images: [StudyBackupImage]
    var omittedImages: [StudyOmittedImage]? = nil
    var originalImageBytes: Int? = nil
    var isComplete: Bool { omittedImages?.isEmpty != false }
    var contentFingerprint: String {
        struct Content: Encodable { let snapshot: AppSnapshot; let learning: StudyMemoryArchive; let images: [String]; var omitted: [String]? = nil }
        var stable = snapshot; stable.exportedAt = Date(timeIntervalSince1970: 0)
        return (try? StudyCoding.hash(StudyCoding.encode(Content(snapshot: stable, learning: learning,
            images: images.sorted { $0.name < $1.name }.map { $0.name + "/" + $0.sha256 },
            omitted: omittedImages?.isEmpty == false ? omittedImages!.map { $0.name + "/" + ($0.sha256 ?? "unavailable") }.sorted() : nil)))) ?? ""
    }
}
struct StudyBackupEnvelope: Codable {
    let format: String
    let sha256: String
    let payload: Data
}
enum StudyBackupCodec {
    static let format = "sermo.study-backup.v1"
    static let maximumBytes = 160 * 1024 * 1024
    static let maximumImageBytes = 64 * 1024 * 1024
    static let imageWarningBytes = 52 * 1024 * 1024
    static let supportedKinds: Set<String> = ["memory", "event", "pending", "operation", "checkpoint", "summary", "archived_project",
        "word_pack", "word_session", "word_progress", "word_event", "word_operation", "reading_catalog", "reading_passage", "reading_session",
        "reading_answer", "reading_event", "reading_operation", "topic", "topic_session", "topic_event", "practice", "practice_event",
        "lesson_operation", "history_pack", "weekly_report", "temporary_map"]
    static func safeImageName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_-]{1,160}\.jpg$"#, options: .regularExpression) != nil
    }
    static func validateImage(_ data: Data) throws -> (width: Int, height: Int) {
        guard data.count <= 40 * 1024 * 1024, data.count > 3, data[0] == 0xff, data[1] == 0xd8,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetStatus(source).rawValue == 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 40_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == width, image.height == height else { throw StudyBackupError.invalid("备份里的图片无法完整打开。") }
        return (width, height)
    }
    /// Images in revision history and archived projects remain necessary, even
    /// when their original chat has been removed. No path is taken from a URL.
    static func imageReferences(snapshot: AppSnapshot, learning: StudyMemoryArchive) throws -> Set<String> {
        var names = Set(snapshot.threads.flatMap { $0.messages.flatMap { $0.images ?? [] } })
        func walk(_ value: Any) throws {
            if let object = value as? [String: Any] {
                for (key, child) in object {
                    if key == "attachmentIDs" || key == "images" {
                        if child is NSNull { continue }
                        guard let images = child as? [String] else { throw StudyBackupError.invalid("图片关联格式不正确。") }
                        names.formUnion(images)
                    } else { try walk(child) }
                }
            } else if let array = value as? [Any] { for child in array { try walk(child) } }
        }
        for row in learning.rows { try walk(JSONSerialization.jsonObject(with: row.payload)) }
        guard names.count <= 2000, names.allSatisfy(safeImageName) else { throw StudyBackupError.invalid("图片名称或数量不符合备份格式。") }
        return names
    }
    static func scopedSnapshot(_ snapshot: AppSnapshot, learning: StudyMemoryArchive) throws -> (AppSnapshot, Set<UUID>) {
        let studyProjects = (snapshot.projects ?? []).filter { $0.studySubject != nil }
        let ids = Set(studyProjects.map(\.id)).union(learning.rows.map(\.projectID))
        var kept = Set<UUID>()
        for row in learning.rows where row.kind == "archived_project" {
            let archived = try StudyCoding.decode(StudyArchivedProject.self, from: row.payload)
            kept.formUnion(archived.keptThreadIDs)
        }
        var threads = snapshot.threads.filter { $0.projectID.map(ids.contains) == true || kept.contains($0.id) }
        ChatModelSelection.migrate(&threads, projects: snapshot.projects ?? [], settings: snapshot.settings)
        var result = AppSnapshot(settings: snapshot.settings, threads: threads,
            activeThreadID: threads.contains(where: { $0.id == snapshot.activeThreadID }) ? snapshot.activeThreadID : nil,
            projects: studyProjects, installedStudySubjects: snapshot.installedStudySubjects)
        result.exportedAt = snapshot.exportedAt
        try result.validate()
        return (result, ids)
    }
    static func capture(snapshot: AppSnapshot, learning: StudyMemoryArchive, deviceID: String,
                        imageLoader: (String) throws -> Data) throws -> StudyBackupPayload {
        let (selected, ids) = try scopedSnapshot(snapshot, learning: learning)
        var images: [StudyBackupImage] = [], bytes = 0
        for name in try imageReferences(snapshot: selected, learning: learning).sorted() {
            let data = try imageLoader(name); bytes += data.count
            guard bytes <= maximumImageBytes else { throw StudyBackupError.invalid("图片总量超过当前备份的64MB上限，本次没有省略图片或标记成功。") }
            _ = try validateImage(data)
            images.append(.init(name: name, data: data, sha256: StudyCoding.hash(data)))
        }
        let payload = StudyBackupPayload(version: 1, backupID: UUID(), deviceID: deviceID, createdAt: Date(), projectIDs: ids.sorted { $0.uuidString < $1.uuidString }, snapshot: selected, learning: learning, images: images)
        try validate(payload)
        return payload
    }
    static func imageCapacity(snapshot: AppSnapshot, learning: StudyMemoryArchive, size: (String) throws -> Int) throws -> StudyImageCapacity {
        let (selected, _) = try scopedSnapshot(snapshot, learning: learning)
        let names = try imageReferences(snapshot: selected, learning: learning)
        var bytes = 0, unavailable = 0
        for name in names {
            if let amount = try? size(name), amount >= 0 { bytes += amount }
            else { unavailable += 1 }
        }
        return .init(count: names.count, bytes: bytes, unavailable: unavailable)
    }
    /// Re-encode only backup copies, without resizing or touching local pictures.
    static func compressedCopy(_ data: Data) throws -> Data {
        _ = try validateImage(data)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw StudyBackupError.unavailable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { throw StudyBackupError.unavailable }
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.65]
        if let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let orientation = p[kCGImagePropertyOrientation] { options[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw StudyBackupError.unavailable }
        let result = output as Data
        return result.count < data.count ? result : data
    }
    static func captureResilient(snapshot: AppSnapshot, learning: StudyMemoryArchive, deviceID: String,
                                 imageBudgetBytes: Int = maximumImageBytes,
                                 imageSize: (String) throws -> Int, imageLoader: (String) throws -> Data) throws -> StudyBackupPayload {
        guard (0...maximumImageBytes).contains(imageBudgetBytes) else { throw StudyBackupError.invalid("图片预算无效。") }
        let (selected, ids) = try scopedSnapshot(snapshot, learning: learning)
        let capacity = try imageCapacity(snapshot: snapshot, learning: learning, size: imageSize)
        let compress = capacity.bytes >= min(imageWarningBytes, imageBudgetBytes)
        var images: [StudyBackupImage] = [], omitted: [StudyOmittedImage] = [], stored = 0
        for name in try imageReferences(snapshot: selected, learning: learning).sorted() {
            guard let size = try? imageSize(name), size >= 0, size <= 40 * 1024 * 1024,
                  let data = try? imageLoader(name) else {
                omitted.append(.init(name: name, sha256: nil, bytes: 0, reason: "unavailable")); continue
            }
            let originalHash = StudyCoding.hash(data)
            guard (try? validateImage(data)) != nil else {
                omitted.append(.init(name: name, sha256: originalHash, bytes: data.count, reason: "invalid")); continue
            }
            let copy = compress ? ((try? compressedCopy(data)) ?? data) : data
            if stored + copy.count <= imageBudgetBytes {
                images.append(.init(name: name, data: copy, sha256: StudyCoding.hash(copy), originalSHA256: copy == data ? nil : originalHash)); stored += copy.count
            } else { omitted.append(.init(name: name, sha256: originalHash, bytes: data.count, reason: "capacity")) }
        }
        let changed = !omitted.isEmpty || images.contains { $0.originalSHA256 != nil }
        let result = StudyBackupPayload(version: changed ? 2 : 1, backupID: UUID(), deviceID: deviceID, createdAt: Date(),
            projectIDs: ids.sorted { $0.uuidString < $1.uuidString }, snapshot: selected, learning: learning, images: images,
            omittedImages: omitted.isEmpty ? nil : omitted, originalImageBytes: capacity.bytes)
        try validate(result); return result
    }
    /// If JSON overhead exhausts the package limit, preserve all records and an
    /// explicit image inventory instead of losing the entire backup attempt.
    static func encodeResilient(_ payload: StudyBackupPayload) throws -> (Data, StudyBackupPayload) {
        try validate(payload)
        let bytes = try StudyCoding.encode(payload)
        let data = try StudyCoding.encode(StudyBackupEnvelope(format: payload.version == 1 ? format : "sermo.study-backup.v2", sha256: StudyCoding.hash(bytes), payload: bytes))
        if data.count <= maximumBytes { return (data, payload) }
        var omitted = payload.omittedImages ?? []
        omitted += payload.images.map { .init(name: $0.name, sha256: $0.originalSHA256 ?? $0.sha256, bytes: $0.data.count, reason: "capacity") }
        let recovery = StudyBackupPayload(version: 2, backupID: payload.backupID, deviceID: payload.deviceID, createdAt: payload.createdAt,
            projectIDs: payload.projectIDs, snapshot: payload.snapshot, learning: payload.learning, images: [], omittedImages: omitted, originalImageBytes: payload.originalImageBytes)
        return (try encode(recovery), recovery)
    }
    static func encode(_ payload: StudyBackupPayload) throws -> Data {
        try validate(payload)
        let bytes = try StudyCoding.encode(payload)
        let envelope = StudyBackupEnvelope(format: payload.version == 1 ? format : "sermo.study-backup.v2", sha256: StudyCoding.hash(bytes), payload: bytes)
        let data = try StudyCoding.encode(envelope)
        guard data.count <= maximumBytes else { throw StudyBackupError.invalid("完整学习备份超过160MB，本次没有截断或上传。") }
        return data
    }
    static func decode(_ data: Data) throws -> StudyBackupPayload {
        guard data.count <= maximumBytes else { throw StudyBackupError.invalid("学习备份文件过大。") }
        let envelope = try StudyCoding.decode(StudyBackupEnvelope.self, from: data)
        guard [format, "sermo.study-backup.v2"].contains(envelope.format), envelope.sha256 == StudyCoding.hash(envelope.payload) else { throw StudyBackupError.invalid("学习备份版本或校验值不正确，未修改本机记录。") }
        let payload = try StudyCoding.decode(StudyBackupPayload.self, from: envelope.payload)
        guard (payload.version == 1) == (envelope.format == format) else { throw StudyBackupError.invalid("备份版本标记不一致。") }
        try validate(payload); return payload
    }
    static func validateArchive(_ archive: StudyMemoryArchive, projectIDs: Set<UUID>) throws {
        guard archive.version == 1, archive.rows.count <= 150_000 else { throw StudyBackupError.invalid("学习库格式或数据量不支持。") }
        var unique = Set<String>(), total = 0
        for row in archive.rows {
            total += row.payload.count
            guard projectIDs.contains(row.projectID), supportedKinds.contains(row.kind), !row.id.isEmpty, row.id.count <= 300,
                  row.payload.count <= 32 * 1024 * 1024, total <= 64 * 1024 * 1024,
                  unique.insert(row.projectID.uuidString + "/" + row.kind + "/" + row.id).inserted else { throw StudyBackupError.invalid("学习库含重复、跨项目或不支持的数据；未恢复。") }
            _ = try JSONSerialization.jsonObject(with: row.payload)
            if row.kind == "event" { guard try StudyCoding.decode(StudyMemoryEvent.self, from: row.payload).projectID == row.projectID else { throw StudyMemoryError.conflict } }
            if row.kind == "pending" { guard try StudyCoding.decode(StudyPendingOperation.self, from: row.payload).scopeProject == row.projectID else { throw StudyMemoryError.conflict } }
            if row.kind == "weekly_report" { guard try StudyCoding.decode(StudyWeeklyReport.self, from: row.payload).projectID == row.projectID else { throw StudyMemoryError.conflict } }
            if row.kind == "archived_project" { guard try StudyCoding.decode(StudyArchivedProject.self, from: row.payload).project.id == row.projectID else { throw StudyMemoryError.conflict } }
            if row.kind == "temporary_map" { _ = try StudyTemporaryMap.decode(row.payload) }
        }
        for id in projectIDs {
            func rows<T: Decodable>(_ type: T.Type, _ kind: String) throws -> [T] { try archive.rows.filter { $0.projectID == id && $0.kind == kind }.map { try StudyCoding.decode(type, from: $0.payload) } }
            let passages = try rows(StudyReadingPassage.self, "reading_passage"), reading = try rows(StudyReadingSession.self, "reading_session")
            for s in reading {
                guard let p = passages.first(where: { $0.id == s.passageID }), !p.paragraphs.isEmpty, s.passageFingerprint == p.fingerprint,
                      (1...p.paragraphs.count).contains(s.paragraph), s.revision > 0,
                      s.question == nil || p.questions.contains(where: { $0.number == s.question }) else { throw StudyBackupError.invalid("阅读现场无法对应资料版本或段落。") }
            }
            for a in try rows(StudyReadingAnswer.self, "reading_answer") {
                guard let s = reading.first(where: { $0.id == a.sessionID }), let p = passages.first(where: { $0.id == s.passageID }),
                      p.questions.contains(where: { $0.number == a.question }), a.revision > 0 else { throw StudyBackupError.invalid("阅读作答与原任务关联不完整。") }
            }
            let words = Set(try rows(StudyWordPack.self, "word_pack").flatMap { $0.cards.map(\.id) })
            for s in try rows(StudyWordSession.self, "word_session") {
                guard s.position >= 0, s.position <= s.wordIDs.count, s.revision > 0, s.wordIDs.allSatisfy(words.contains) else { throw StudyBackupError.invalid("背词位置或词库关联不完整。") }
            }
            let topics = Set(try rows(StudyTopic.self, "topic").map(\.id))
            for s in try rows(StudyTopicSession.self, "topic_session") {
                guard topics.contains(s.topicID), s.revision > 0 else { throw StudyBackupError.invalid("历史政治现场缺少对应专题。") }
            }
            _ = try rows(StudyPractice.self, "practice"); _ = try rows(StudyMemoryRecord.self, "memory")
        }
    }
    static func validate(_ payload: StudyBackupPayload) throws {
        let ids = Set(payload.projectIDs)
        guard [1,2].contains(payload.version), !payload.deviceID.isEmpty, payload.deviceID.count <= 200,
              ids.count == payload.projectIDs.count, ids.count <= 200,
              (payload.snapshot.projects ?? []).allSatisfy({ $0.studySubject != nil && ids.contains($0.id) }) else { throw StudyBackupError.invalid("备份的项目范围不正确。") }
        try payload.snapshot.validate()
        try validateArchive(payload.learning, projectIDs: ids)
        let references = try imageReferences(snapshot: payload.snapshot, learning: payload.learning)
        let omitted = payload.omittedImages ?? []
        guard payload.version == 2 || (omitted.isEmpty && payload.images.allSatisfy { $0.originalSHA256 == nil }),
              Set(payload.images.map(\.name)).union(omitted.map(\.name)) == references,
              payload.images.count + omitted.count == references.count,
              omitted.allSatisfy({ safeImageName($0.name) && $0.bytes >= 0 && ["capacity","unavailable","invalid"].contains($0.reason) }),
              payload.images.reduce(0, { $0 + $1.data.count }) <= maximumImageBytes else { throw StudyBackupError.invalid("图片实体与记录引用不完整，未恢复。") }
        for image in payload.images {
            guard safeImageName(image.name), StudyCoding.hash(image.data) == image.sha256 else { throw StudyBackupError.invalid("图片校验失败，未恢复。") }
            _ = try validateImage(image.data)
        }
        var allowed = Set(payload.snapshot.threads.filter { $0.projectID.map(ids.contains) == true }.map(\.id))
        for row in payload.learning.rows where row.kind == "archived_project" {
            allowed.formUnion(try StudyCoding.decode(StudyArchivedProject.self, from: row.payload).keptThreadIDs)
        }
        guard payload.snapshot.threads.allSatisfy({ allowed.contains($0.id) }) else { throw StudyBackupError.invalid("备份含范围以外的对话。") }
    }
    static func merge(_ backup: StudyBackupPayload, into current: AppSnapshot, currentLearning: StudyMemoryArchive) throws -> AppSnapshot {
        try validate(backup)
        let ids = Set(backup.projectIDs), incomingThreads = Set(backup.snapshot.threads.map(\.id))
        var replaceThreads = Set(current.threads.filter { $0.projectID.map(ids.contains) == true }.map(\.id))
        for row in currentLearning.rows where ids.contains(row.projectID) && row.kind == "archived_project" {
            replaceThreads.formUnion(try StudyCoding.decode(StudyArchivedProject.self, from: row.payload).keptThreadIDs)
        }
        guard !(current.projects ?? []).contains(where: { ids.contains($0.id) && $0.studySubject == nil }),
              !current.threads.contains(where: { incomingThreads.contains($0.id) && !replaceThreads.contains($0.id) }) else {
            throw StudyBackupError.conflict("相同标识已用于其他项目或对话，未覆盖。请先核对这些冲突。")
        }
        var next = current
        next.projects = (current.projects ?? []).filter { !ids.contains($0.id) } + (backup.snapshot.projects ?? [])
        next.threads = current.threads.filter { !replaceThreads.contains($0.id) } + backup.snapshot.threads
        next.installedStudySubjects = StudySubject.allCases.filter { Set((current.installedStudySubjects ?? []) + (backup.snapshot.installedStudySubjects ?? [])).contains($0) }
        if !next.threads.contains(where: { $0.id == next.activeThreadID }) { next.activeThreadID = backup.snapshot.activeThreadID ?? next.threads.first?.id }
        try next.validate(); return next
    }
}

/// Recovery journal is separate from export/CI/Drive payloads. Old images are
/// never replaced; missing ones are added only after every collision is checked.
enum StudyRestoreEngine {
    struct Outcome { let snapshot: AppSnapshot; let recoveryBackup: URL?; let missingPreviousImages: [String] }
    struct Journal: Codable {
        let before: AppSnapshot
        let learning: StudyMemoryArchive
        let projectIDs: [UUID]
        let addedImages: [String]
        let previousImages: [StudyBackupImage]
        let missingPreviousImages: [String]
        let committed: Bool
    }
    static func restore(_ backup: StudyBackupPayload, current: AppSnapshot, store: StudyMemoryStore, imagesDirectory: URL,
                        recoveryDirectory: URL, saveSnapshot: (AppSnapshot) throws -> Void,
                        checkpoint: (String) throws -> Void = { _ in }) throws -> Outcome {
        let all = try store.exportAllStudyData()
        let next = try StudyBackupCodec.merge(backup, into: current, currentLearning: all)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let journalURL = recoveryDirectory.appendingPathComponent("restore-active.json")
        guard !FileManager.default.fileExists(atPath: journalURL.path) else { throw StudyBackupError.invalid("先处理上次中断的恢复，原记录保持不变。") }
        var newNames: [String] = []
        for image in backup.images {
            let target = imagesDirectory.appendingPathComponent(image.name)
            if FileManager.default.fileExists(atPath: target.path) {
                let hash = StudyCoding.hash(try Data(contentsOf: target))
                guard hash == image.sha256 || hash == image.originalSHA256 else { throw StudyBackupError.conflict("本机已有同名但内容不同的图片，未覆盖：\(image.name)") }
            } else { newNames.append(image.name) }
        }
        for image in backup.omittedImages ?? [] {
            let target = imagesDirectory.appendingPathComponent(image.name)
            if FileManager.default.fileExists(atPath: target.path), let expected = image.sha256 {
                guard StudyCoding.hash(try Data(contentsOf: target)) == expected else { throw StudyBackupError.conflict("保底包中的图片引用与本机同名文件不一致，未覆盖。") }
            }
        }
        let ids = Set(backup.projectIDs)
        let beforeRows = StudyMemoryArchive(version: 1, rows: all.rows.filter { ids.contains($0.projectID) })
        let (previousScope, _) = try StudyBackupCodec.scopedSnapshot(current, learning: beforeRows)
        var previousImages: [StudyBackupImage] = [], missing: [String] = []
        for name in try StudyBackupCodec.imageReferences(snapshot: previousScope, learning: beforeRows).sorted() {
            let path = imagesDirectory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) {
                let data = try Data(contentsOf: path)
                previousImages.append(.init(name: name, data: data, sha256: StudyCoding.hash(data)))
            } else { missing.append(name) }
        }
        let before = Journal(before: current, learning: beforeRows, projectIDs: backup.projectIDs, addedImages: newNames,
            previousImages: previousImages, missingPreviousImages: missing, committed: false)
        var recoveryBackup: URL?
        if let complete = try? StudyBackupCodec.capture(snapshot: current, learning: all, deviceID: "local-recovery", imageLoader: { name in
            try Data(contentsOf: imagesDirectory.appendingPathComponent(name))
        }) {
            let url = recoveryDirectory.appendingPathComponent("before-restore-backup-\(UUID().uuidString).json")
            try StudyBackupCodec.encode(complete).write(to: url, options: .atomic); recoveryBackup = url
        }
        try StudyCoding.encode(before).write(to: journalURL, options: .atomic)
        // A dated independent copy remains available after a successful restore.
        let retained = recoveryDirectory.appendingPathComponent("before-restore-\(UUID().uuidString).json")
        try StudyCoding.encode(before).write(to: retained, options: .atomic)
        do {
            for image in backup.images where newNames.contains(image.name) {
                try image.data.write(to: imagesDirectory.appendingPathComponent(image.name), options: .withoutOverwriting)
            }
            try checkpoint("images")
            try store.replaceStudyData(backup.learning, projectIDs: ids)
            try checkpoint("database")
            try saveSnapshot(next)
            try checkpoint("snapshot")
            let completed = Journal(before: current, learning: beforeRows, projectIDs: backup.projectIDs, addedImages: newNames,
                previousImages: previousImages, missingPreviousImages: missing, committed: true)
            try StudyCoding.encode(completed).write(to: journalURL, options: .atomic)
            try FileManager.default.removeItem(at: journalURL)
            return Outcome(snapshot: next, recoveryBackup: recoveryBackup, missingPreviousImages: missing)
        } catch {
            try recover(store: store, imagesDirectory: imagesDirectory, recoveryDirectory: recoveryDirectory, saveSnapshot: saveSnapshot)
            throw error
        }
    }
    @discardableResult static func recover(store: StudyMemoryStore, imagesDirectory: URL, recoveryDirectory: URL,
                                           saveSnapshot: (AppSnapshot) throws -> Void) throws -> Bool {
        let path = recoveryDirectory.appendingPathComponent("restore-active.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        let journal = try StudyCoding.decode(Journal.self, from: Data(contentsOf: path))
        if !journal.committed {
            try store.replaceStudyData(journal.learning, projectIDs: Set(journal.projectIDs), trustedRecovery: true)
            try saveSnapshot(journal.before)
            for name in journal.addedImages {
                guard StudyBackupCodec.safeImageName(name) else { throw StudyBackupError.invalid("恢复日志中的图片路径不正确。") }
                let image = imagesDirectory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: image.path) { try FileManager.default.removeItem(at: image) }
            }
            for image in journal.previousImages {
                guard StudyBackupCodec.safeImageName(image.name), StudyCoding.hash(image.data) == image.sha256 else { throw StudyBackupError.invalid("恢复前图片快照校验失败。") }
                try image.data.write(to: imagesDirectory.appendingPathComponent(image.name), options: .atomic)
            }
        }
        try FileManager.default.removeItem(at: path)
        return !journal.committed
    }
}
