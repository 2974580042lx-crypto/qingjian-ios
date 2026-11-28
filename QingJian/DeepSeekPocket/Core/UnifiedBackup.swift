import Foundation
import CoreFoundation
import Compression

enum UnifiedRestoreMode: String, CaseIterable, Identifiable, Sendable {
    case merge = "merge"
    case replace = "replace"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .merge: return "合并恢复（推荐）"
        case .replace: return "完整覆盖恢复"
        }
    }
    var summary: String {
        switch self {
        case .merge:
            return "保留本机现有对话、项目和设置；把备份里缺失的对话、项目和指令合并进来，学习项目按备份更新。"
        case .replace:
            return "先自动把本机当前数据另存一份安全快照，再用备份里的对话、项目、指令、学习数据库和设置替换本机数据（API Key 保留）。"
        }
    }
}

struct UnifiedBackupPayload: Codable, Sendable {
    var version: Int = 1
    var format: String = UnifiedBackupCodec.format
    var backupID: UUID = UUID()
    var createdAt: Date = Date()
    var snapshot: AppSnapshot
    var learning: StudyMemoryArchive
    // The bookshelf was removed in 1.47. Both keys stay, always empty, so 1.46 and
    // older can still restore a backup made now; old entries are read and ignored.
    var booksMetadata: [RetiredShelfRecord] = []
    var personas: [RetiredShelfRecord] = []
    var images: [StudyBackupImage]
    var omittedImages: [StudyOmittedImage]? = nil
    var preferences: [String: String]? = nil
    var operationManual: OperationManualBook? = nil
    var localProfile: BackupUserProfile? = nil
    var deliverablesManifest: [String: Data]? = nil

    var isComplete: Bool { omittedImages?.isEmpty != false }
}

/// Stands in for a bookshelf book or persona card in older backups. Decodes any object.
struct RetiredShelfRecord: Codable, Sendable {}

enum DecodedBackupPackage: Sendable {
    case unified(UnifiedBackupPayload)
    case legacyStudy(StudyBackupPayload)
    case legacyChat(AppSnapshot)

    var formatTitle: String {
        switch self {
        case .unified: return "Sermo 完整备份（.sermobackup）"
        case .legacyStudy: return "旧版学习项目备份（.json）"
        case .legacyChat: return "旧版聊天与项目备份（.json）"
        }
    }

    var createdAt: Date? {
        switch self {
        case .unified(let p): return p.createdAt
        case .legacyStudy(let p): return p.createdAt
        case .legacyChat(let p): return p.exportedAt
        }
    }

    var threadCount: Int {
        switch self {
        case .unified(let p): return p.snapshot.threads.count
        case .legacyStudy(let p): return p.snapshot.threads.count
        case .legacyChat(let p): return p.threads.count
        }
    }

    var projectCount: Int {
        switch self {
        case .unified(let p): return (p.snapshot.projects ?? []).count
        case .legacyStudy(let p): return (p.snapshot.projects ?? []).count
        case .legacyChat(let p): return (p.projects ?? []).count
        }
    }

    var presetCount: Int {
        switch self {
        case .unified(let p): return (p.snapshot.systemPromptPresets ?? []).count
        case .legacyStudy: return 0
        case .legacyChat(let p): return (p.systemPromptPresets ?? []).count
        }
    }

    var studyRowCount: Int {
        switch self {
        case .unified(let p): return p.learning.rows.count
        case .legacyStudy(let p): return p.learning.rows.count
        case .legacyChat: return 0
        }
    }

    var imageCount: Int {
        switch self {
        case .unified(let p): return p.images.count
        case .legacyStudy(let p): return p.images.count
        case .legacyChat: return 0
        }
    }

    var omittedImageCount: Int {
        switch self {
        case .unified(let p): return p.omittedImages?.count ?? 0
        case .legacyStudy(let p): return p.omittedImages?.count ?? 0
        case .legacyChat: return 0
        }
    }

    var manualChapterCount: Int {
        switch self {
        case .unified(let p): return p.operationManual?.chapters.count ?? 0
        case .legacyStudy, .legacyChat: return 0
        }
    }
}

struct UnifiedRestorePreview: Identifiable, Sendable {
    let id = UUID()
    let fileName: String
    let fileSize: Int64
    let package: DecodedBackupPackage
}

enum UnifiedBackupCodec {
    static let format = "sermo.unified-backup.v1"
    static let magicPrefix = "SRMBKP01:"
    static let maximumUncompressedBytes = 240 * 1024 * 1024
    static let maximumImageBudgetBytes = 96 * 1024 * 1024

    static let preferenceKeys: [String] = [
        // Real active theme, typography, layout & personalization keys
        "sermo.interface.style",
        "sermo.appearance.mode",
        "qingjian.font.choice",
        "qingjian.reading.size",
        "qingjian.haptics",
        "sermo.personal.text",
        "sermo.personal.accent",
        "sermo.personal.paper",
        "sermo.personal.bubble",
        "sermo.personal.spacing",
        "sermo.personal.margin",
        "sermo.personal.medium",
        "sermo.personal.boldAccent",
        "sermo.chat.layoutMode.default",
        // Per-provider web search channels
        "sermo.web.channel.chatGPT",
        "sermo.web.channel.deepSeek",
        "sermo.web.channel.colab",
        "sermo.web.channel.compatible",
        // Chat, speech & manual preferences
        "qingjian.newChat.projectID",
        "qingjian.speech.auto",
        "qingjian.speech.voice",
        "qingjian.manual.dismissed",
        // Legacy keys kept for backward compatibility
        "qingjian.theme.paper",
        "qingjian.theme.fontChoice",
        "qingjian.profile.name",
        "qingjian.profile.handle"
    ]

    private static let doublePreferenceKeys: Set<String> = [
        "qingjian.reading.size"
    ]

    static func collectPreferences(from defaults: UserDefaults = .standard) -> [String: String] {
        var result: [String: String] = [:]
        for key in preferenceKeys {
            guard let raw = defaults.object(forKey: key) else { continue }
            if CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID() {
                result[key] = (raw as? Bool == true) ? "true" : "false"
            } else if let str = raw as? String {
                result[key] = str
            } else if let num = raw as? NSNumber {
                result[key] = num.stringValue
            }
        }
        return result
    }

    static func applyPreferences(_ prefs: [String: String]?, to defaults: UserDefaults = .standard) {
        guard let prefs else { return }
        let allowed = Set(preferenceKeys)
        for (key, value) in prefs where allowed.contains(key) {
            if value == "true" || value == "false" {
                defaults.set(value == "true", forKey: key)
            } else if doublePreferenceKeys.contains(key), let number = Double(value) {
                defaults.set(number, forKey: key)
            } else {
                defaults.set(value, forKey: key)
            }
        }
    }

    static func allReferencedImageNames(snapshot: AppSnapshot, learning: StudyMemoryArchive) throws -> Set<String> {
        try StudyBackupCodec.imageReferences(snapshot: snapshot, learning: learning)
    }

    static func capture(
        snapshot: AppSnapshot,
        learning: StudyMemoryArchive,
        preferences: [String: String]? = nil,
        operationManual: OperationManualBook? = nil,
        localProfile: BackupUserProfile? = nil,
        deliverablesManifest: [String: Data]? = nil,
        imageBudgetBytes: Int = maximumImageBudgetBytes,
        imageSize: (String) throws -> Int,
        imageLoader: (String) throws -> Data
    ) throws -> UnifiedBackupPayload {
        try snapshot.validate(isLocalStore: true)
        let names = try allReferencedImageNames(snapshot: snapshot, learning: learning).sorted()
        var images: [StudyBackupImage] = []
        var omitted: [StudyOmittedImage] = []
        var usedBytes = 0
        for name in names {
            guard imageBudgetBytes > 0,
                  let size = try? imageSize(name), size >= 0, size <= 40 * 1024 * 1024,
                  let raw = try? imageLoader(name) else {
                omitted.append(.init(name: name, sha256: nil, bytes: 0, reason: imageBudgetBytes == 0 ? "capacity" : "unavailable"))
                continue
            }
            let hash = StudyCoding.hash(raw)
            guard (try? StudyBackupCodec.validateImage(raw)) != nil else {
                omitted.append(.init(name: name, sha256: hash, bytes: raw.count, reason: "invalid"))
                continue
            }
            if usedBytes + raw.count <= imageBudgetBytes {
                images.append(.init(name: name, data: raw, sha256: hash))
                usedBytes += raw.count
            } else if let compressed = try? StudyBackupCodec.compressedCopy(raw),
                      usedBytes + compressed.count <= imageBudgetBytes {
                images.append(.init(name: name, data: compressed, sha256: StudyCoding.hash(compressed), originalSHA256: hash))
                usedBytes += compressed.count
            } else {
                omitted.append(.init(name: name, sha256: hash, bytes: raw.count, reason: "capacity"))
            }
        }
        return UnifiedBackupPayload(
            version: 1,
            format: format,
            backupID: UUID(),
            createdAt: Date(),
            snapshot: snapshot,
            learning: learning,
            images: images,
            omittedImages: omitted.isEmpty ? nil : omitted,
            preferences: preferences,
            operationManual: operationManual,
            localProfile: localProfile,
            deliverablesManifest: deliverablesManifest
        )
    }

    static func contentFingerprint(of payload: UnifiedBackupPayload) throws -> String {
        struct Canonical: Encodable {
            var settings: AppSettings
            var threads: [ChatThread]
            var projects: [ChatProject]?
            var usage: UsageLedger?
            var presets: [SystemPromptPreset]?
            var studySubjects: [StudySubject]?
            var learning: StudyMemoryArchive
            var imageHashes: [String]
            var preferences: [String: String]?
            var manual: OperationManualBook?
            var profile: BackupUserProfile?
            var deliverables: [String: Data]?
        }
        let canonical = Canonical(
            settings: payload.snapshot.settings,
            threads: payload.snapshot.threads,
            projects: payload.snapshot.projects,
            usage: payload.snapshot.usage,
            presets: payload.snapshot.systemPromptPresets,
            studySubjects: payload.snapshot.installedStudySubjects,
            learning: payload.learning,
            imageHashes: payload.images.map { "\($0.name):\($0.sha256)" },
            preferences: payload.preferences,
            manual: payload.operationManual,
            profile: payload.localProfile,
            deliverables: payload.deliverablesManifest
        )
        return StudyCoding.hash(try StudyCoding.encode(canonical))
    }

    static func encode(_ payload: UnifiedBackupPayload) throws -> Data {
        try validate(payload)
        let json = try StudyCoding.encode(payload)
        guard json.count <= maximumUncompressedBytes else {
            throw ChatError.invalidBackup("备份总数据量超过安全上限。")
        }
        let sha = StudyCoding.hash(json)
        if let compressed = deflate(json), compressed.count + 128 < json.count {
            let header = "\(magicPrefix)\(json.count):\(sha)\n"
            var out = Data(header.utf8)
            out.append(compressed)
            return out
        }
        let header = "\(magicPrefix)RAW:\(sha)\n"
        var out = Data(header.utf8)
        out.append(json)
        return out
    }

    static func decode(_ data: Data) throws -> UnifiedBackupPayload {
        guard data.count <= maximumUncompressedBytes + 1024 else {
            throw ChatError.invalidBackup("备份文件体积超出上限。")
        }
        let prefixBytes = Data(magicPrefix.utf8)
        let jsonData: Data
        if data.starts(with: prefixBytes) {
            guard let newlineIndex = data.firstIndex(of: 0x0A) else {
                throw ChatError.invalidBackup("备份文件头损坏。")
            }
            let headerLine = String(decoding: data[data.startIndex..<newlineIndex], as: UTF8.self)
            let parts = headerLine.split(separator: ":")
            guard parts.count == 3, parts[0] == "SRMBKP01" else {
                throw ChatError.invalidBackup("备份文件格式标识不匹配。")
            }
            let sizeSpec = String(parts[1])
            let expectedSHA = String(parts[2])
            let body = data[data.index(after: newlineIndex)...]
            if sizeSpec == "RAW" {
                jsonData = Data(body)
            } else {
                guard let expectedSize = Int(sizeSpec), expectedSize > 0, expectedSize <= maximumUncompressedBytes else {
                    throw ChatError.invalidBackup("备份文件大小记录异常。")
                }
                jsonData = try inflate(Data(body), expectedSize: expectedSize)
            }
            guard StudyCoding.hash(jsonData) == expectedSHA else {
                throw ChatError.invalidBackup("备份文件校验失败（SHA-256 不一致），文件可能未下载完整或已损坏。")
            }
        } else {
            jsonData = data
        }
        let payload = try StudyCoding.decode(UnifiedBackupPayload.self, from: jsonData)
        try validate(payload)
        return payload
    }

    static func decodeAny(_ data: Data) throws -> DecodedBackupPackage {
        if data.starts(with: Data(magicPrefix.utf8)) {
            return .unified(try decode(data))
        }
        if let unified = try? decode(data), unified.format == format {
            return .unified(unified)
        }
        if let study = try? StudyBackupCodec.decode(data) {
            return .legacyStudy(study)
        }
        let chat = try AppSnapshot.decodeLocal(data)
        return .legacyChat(chat)
    }

    static func validate(_ payload: UnifiedBackupPayload) throws {
        guard payload.version == 1, payload.format == format else {
            throw ChatError.invalidBackup("不支持这个完整备份的版本。")
        }
        try payload.snapshot.validate(isLocalStore: true)
        guard payload.learning.version == 1, payload.learning.rows.count <= 200_000 else {
            throw ChatError.invalidBackup("备份中的学习数据库格式不支持。")
        }
        var studyProjectIDs = Set((payload.snapshot.projects ?? []).filter { $0.studySubject != nil }.map(\.id))
        for row in payload.learning.rows where row.kind == "archived_project" {
            studyProjectIDs.insert(row.projectID)
        }
        do {
            try StudyBackupCodec.validateArchive(payload.learning, projectIDs: studyProjectIDs)
        } catch {
            throw ChatError.invalidBackup(error.localizedDescription)
        }
        guard payload.booksMetadata.count <= 500, payload.personas.count <= 500 else {
            throw ChatError.invalidBackup("备份中的旧书架记录数量超出上限。")
        }
        if let profile = payload.localProfile {
            guard profile.name.count <= 100, profile.handle.count <= 100, (profile.avatar?.count ?? 0) <= 8 * 1024 * 1024 else {
                throw ChatError.invalidBackup("备份中的个人资料数据异常。")
            }
        }
        if let deliverables = payload.deliverablesManifest {
            let totalDeliverableBytes = deliverables.values.reduce(0) { $0 + $1.count }
            guard deliverables.count <= 2_000, totalDeliverableBytes <= maximumImageBudgetBytes else {
                throw ChatError.invalidBackup("备份中的项目成果附件超出体积上限。")
            }
        }
        for image in payload.images {
            guard StudyBackupCodec.safeImageName(image.name),
                  StudyCoding.hash(image.data) == image.sha256 else {
                throw ChatError.invalidBackup("备份中的图片校验未通过：\(image.name)")
            }
            _ = try StudyBackupCodec.validateImage(image.data)
        }
    }

    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = max(data.count, 1024)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let to = target.bindMemory(to: UInt8.self).baseAddress,
                      let from = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(to, capacity, from, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }

    private static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0, expectedSize <= maximumUncompressedBytes else {
            throw ChatError.invalidBackup("解压尺寸无效。")
        }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let to = target.bindMemory(to: UInt8.self).baseAddress,
                      let from = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(to, expectedSize, from, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else {
            throw ChatError.invalidBackup("备份文件解压不完整，请确认文件未损坏。")
        }
        return output
    }
}
