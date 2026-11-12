import Foundation
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
            return "保留本机现有对话、项目、书架和设置；把备份里缺失的对话、项目、指令、书架档案和人物卡合并进来，学习项目按备份更新。"
        case .replace:
            return "先自动把本机当前数据另存一份安全快照，再用备份里的对话、项目、指令、学习数据库、书架档案和设置替换本机数据（API Key 与小说正文保留）。"
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
    var booksMetadata: [Book]
    var personas: [PersonaCard]
    var images: [StudyBackupImage]
    var omittedImages: [StudyOmittedImage]? = nil
    var preferences: [String: String]? = nil

    var isComplete: Bool { omittedImages?.isEmpty != false }
}

enum DecodedBackupPackage: Sendable {
    case unified(UnifiedBackupPayload)
    case legacyStudy(StudyBackupPayload)
    case legacyShelf(ShelfArchive)
    case legacyChat(AppSnapshot)

    var formatTitle: String {
        switch self {
        case .unified: return "Sermo 完整备份（.sermobackup）"
        case .legacyStudy: return "旧版学习项目备份（.json）"
        case .legacyShelf: return "旧版完整书架备份（.json）"
        case .legacyChat: return "旧版聊天与项目备份（.json）"
        }
    }

    var createdAt: Date? {
        switch self {
        case .unified(let p): return p.createdAt
        case .legacyStudy(let p): return p.createdAt
        case .legacyShelf(let p): return p.exportedAt
        case .legacyChat(let p): return p.exportedAt
        }
    }

    var threadCount: Int {
        switch self {
        case .unified(let p): return p.snapshot.threads.count
        case .legacyStudy(let p): return p.snapshot.threads.count
        case .legacyShelf(let p): return p.stories.count
        case .legacyChat(let p): return p.threads.count
        }
    }

    var projectCount: Int {
        switch self {
        case .unified(let p): return (p.snapshot.projects ?? []).count
        case .legacyStudy(let p): return (p.snapshot.projects ?? []).count
        case .legacyShelf(let p): return (p.projects ?? []).count
        case .legacyChat(let p): return (p.projects ?? []).count
        }
    }

    var presetCount: Int {
        switch self {
        case .unified(let p): return (p.snapshot.systemPromptPresets ?? []).count
        case .legacyStudy: return 0
        case .legacyShelf: return 0
        case .legacyChat(let p): return (p.systemPromptPresets ?? []).count
        }
    }

    var studyRowCount: Int {
        switch self {
        case .unified(let p): return p.learning.rows.count
        case .legacyStudy(let p): return p.learning.rows.count
        case .legacyShelf, .legacyChat: return 0
        }
    }

    var bookCount: Int {
        switch self {
        case .unified(let p): return p.booksMetadata.count
        case .legacyShelf(let p): return p.books.count
        case .legacyStudy, .legacyChat: return 0
        }
    }

    var personaCount: Int {
        switch self {
        case .unified(let p): return p.personas.count
        case .legacyShelf(let p): return p.personas.count
        case .legacyStudy, .legacyChat: return 0
        }
    }

    var imageCount: Int {
        switch self {
        case .unified(let p): return p.images.count
        case .legacyStudy(let p): return p.images.count
        case .legacyShelf(let p): return p.images.count
        case .legacyChat: return 0
        }
    }

    var omittedImageCount: Int {
        switch self {
        case .unified(let p): return p.omittedImages?.count ?? 0
        case .legacyStudy(let p): return p.omittedImages?.count ?? 0
        case .legacyShelf, .legacyChat: return 0
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
        "qingjian.theme.paper",
        "qingjian.theme.fontChoice",
        "qingjian.profile.name",
        "qingjian.profile.handle",
        "qingjian.newChat.projectID",
        "qingjian.speech.auto",
        "qingjian.speech.voice",
        "qingjian.manual.dismissed"
    ]

    static func collectPreferences(from defaults: UserDefaults = .standard) -> [String: String] {
        var result: [String: String] = [:]
        for key in preferenceKeys {
            if let str = defaults.string(forKey: key) {
                result[key] = str
            } else if defaults.object(forKey: key) != nil {
                result[key] = defaults.bool(forKey: key) ? "true" : "false"
            }
        }
        return result
    }

    static func applyPreferences(_ prefs: [String: String]?, to defaults: UserDefaults = .standard) {
        guard let prefs else { return }
        for (key, value) in prefs where preferenceKeys.contains(key) {
            if value == "true" || value == "false" {
                defaults.set(value == "true", forKey: key)
            } else {
                defaults.set(value, forKey: key)
            }
        }
    }

    static func allReferencedImageNames(snapshot: AppSnapshot, learning: StudyMemoryArchive) throws -> Set<String> {
        var names = try StudyBackupCodec.imageReferences(snapshot: snapshot, learning: learning)
        for thread in snapshot.threads {
            for cp in thread.storyCheckpoints ?? [] {
                for msg in cp.messages {
                    for img in msg.images ?? [] where StudyBackupCodec.safeImageName(img) {
                        names.insert(img)
                    }
                }
            }
        }
        return names
    }

    static func capture(
        snapshot: AppSnapshot,
        learning: StudyMemoryArchive,
        booksMetadata: [Book],
        personas: [PersonaCard],
        preferences: [String: String]? = nil,
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
        let cleanBooks = booksMetadata.map { book -> Book in
            var copy = book
            if copy.status == .reading { copy.status = .imported }
            return copy
        }
        return UnifiedBackupPayload(
            version: 1,
            format: format,
            backupID: UUID(),
            createdAt: Date(),
            snapshot: snapshot,
            learning: learning,
            booksMetadata: cleanBooks,
            personas: personas,
            images: images,
            omittedImages: omitted.isEmpty ? nil : omitted,
            preferences: preferences
        )
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
        guard data.count <= maximumUncompressedBytes else {
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let shelf = try? decoder.decode(ShelfArchive.self, from: data), (try? shelf.validate()) != nil {
            return .legacyShelf(shelf)
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
        guard payload.booksMetadata.count <= 500, payload.personas.count <= 500 else {
            throw ChatError.invalidBackup("备份中的书架或人物卡数量超出上限。")
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
