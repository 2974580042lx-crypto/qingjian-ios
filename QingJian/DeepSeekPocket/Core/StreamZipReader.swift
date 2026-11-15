import Foundation
import Compression

/// Streaming, low-memory ZIP / ZIP64 reader backed by `FileHandle` (or `Data` for small buffers).
/// Reads only the Central Directory and decompresses entries on demand, enforcing size limits
/// to guard against zip bombs.
final class StreamZipReader {
    static let maximumArchiveBytes = 500 * 1024 * 1024
    static let maximumEntryBytes = 32 * 1024 * 1024
    static let maximumEntryCount = 100_000

    struct Entry: Sendable, Equatable {
        let name: String
        let method: UInt16
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let isEncrypted: Bool
        var isDirectory: Bool { name.hasSuffix("/") }
    }

    private enum Source {
        case file(FileHandle, UInt64)
        case memory(Data)

        var totalSize: UInt64 {
            switch self {
            case .file(_, let size): return size
            case .memory(let data): return UInt64(data.count)
            }
        }

        func read(offset: UInt64, length: Int) throws -> Data {
            guard length >= 0 else { throw ImportFailure("压缩包读取偏移无效。") }
            if length == 0 { return Data() }
            guard offset <= totalSize, UInt64(length) <= totalSize - offset else {
                throw ImportFailure("压缩包文件不完整或已损坏。")
            }
            switch self {
            case .file(let handle, _):
                try handle.seek(toOffset: offset)
                guard let data = try handle.read(upToCount: length), data.count == length else {
                    throw ImportFailure("压缩包读取失败，请确认文件已完整下载。")
                }
                return data
            case .memory(let data):
                let start = data.startIndex + Int(offset)
                return data.subdata(in: start..<(start + length))
            }
        }
    }

    private let source: Source
    let archiveSize: UInt64
    let entries: [Entry]
    private let entryLookup: [String: Entry]

    convenience init(url: URL, maxArchiveBytes: Int = maximumArchiveBytes) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        guard fileSize > 0 else { throw ImportFailure("这个压缩包是空的。") }
        guard fileSize <= UInt64(maxArchiveBytes) else {
            let mb = maxArchiveBytes / (1024 * 1024)
            throw ImportFailure("压缩包超过 \(mb) MB 上限，无法读取。")
        }
        let handle = try FileHandle(forReadingFrom: url)
        try self.init(source: .file(handle, fileSize))
    }

    convenience init(data: Data, maxArchiveBytes: Int = maximumArchiveBytes) throws {
        guard !data.isEmpty else { throw ImportFailure("这个压缩包是空的。") }
        guard data.count <= maxArchiveBytes else {
            let mb = maxArchiveBytes / (1024 * 1024)
            throw ImportFailure("压缩包超过 \(mb) MB 上限，无法读取。")
        }
        try self.init(source: .memory(data))
    }

    private init(source: Source) throws {
        self.source = source
        self.archiveSize = source.totalSize
        self.entries = try Self.parseCentralDirectory(from: source)
        var lookup: [String: Entry] = [:]
        lookup.reserveCapacity(entries.count)
        for entry in entries where lookup[entry.name] == nil {
            lookup[entry.name] = entry
        }
        self.entryLookup = lookup
    }

    deinit {
        if case .file(let handle, _) = source {
            try? handle.close()
        }
    }

    func entry(named path: String) -> Entry? {
        if let exact = entryLookup[path] { return exact }
        let lower = path.lowercased()
        return entries.first { $0.name.lowercased() == lower }
    }

    func readEntry(_ entry: Entry, maxBytes: Int = maximumEntryBytes) throws -> Data {
        guard !entry.isEncrypted else {
            throw ImportFailure("压缩包中的「\(entry.name)」已加密，无法读取。")
        }
        guard entry.uncompressedSize <= UInt64(maxBytes) else {
            let mb = maxBytes / (1024 * 1024)
            throw ImportFailure("「\(entry.name)」解压后超过 \(mb) MB 上限，已跳过。")
        }
        guard entry.compressedSize <= UInt64(maxBytes) * 2 + 1024 else {
            throw ImportFailure("「\(entry.name)」压缩体积异常，已跳过。")
        }

        let header = try source.read(offset: entry.localHeaderOffset, length: 30)
        guard Self.u32(header, 0) == 0x04034B50 else {
            throw ImportFailure("压缩包中的「\(entry.name)」本地文件头损坏。")
        }
        let nameLen = Int(Self.u16(header, 26))
        let extraLen = Int(Self.u16(header, 28))
        let dataOffset = entry.localHeaderOffset + 30 + UInt64(nameLen) + UInt64(extraLen)
        let compressed = try source.read(offset: dataOffset, length: Int(entry.compressedSize))

        switch entry.method {
        case 0:
            return compressed
        case 8:
            let expectedSize = Int(entry.uncompressedSize)
            if expectedSize == 0 && compressed.isEmpty { return Data() }
            return try Self.inflate(compressed, expectedSize: max(expectedSize, 1), maxBytes: maxBytes, name: entry.name)
        default:
            throw ImportFailure("「\(entry.name)」使用了不支持的压缩算法（method \(entry.method)）。")
        }
    }

    // MARK: - Central Directory Parsing

    private static func parseCentralDirectory(from source: Source) throws -> [Entry] {
        let total = source.totalSize
        guard total >= 22 else { throw ImportFailure("这个文件不是有效的 ZIP/IPA 压缩包。") }

        let tailSize = Int(min(total, 65_557))
        let tailOffset = total - UInt64(tailSize)
        let tail = try source.read(offset: tailOffset, length: tailSize)

        var eocdPos = -1
        var cursor = tail.count - 22
        while cursor >= 0 {
            if tail[cursor] == 0x50, tail[cursor + 1] == 0x4B,
               tail[cursor + 2] == 0x05, tail[cursor + 3] == 0x06 {
                let commentLen = Int(u16(tail, cursor + 20))
                if cursor + 22 + commentLen == tail.count {
                    eocdPos = cursor
                    break
                }
                if eocdPos < 0 { eocdPos = cursor }
            }
            cursor -= 1
        }
        guard eocdPos >= 0 else { throw ImportFailure("未找到 ZIP 目录尾记录，文件可能不是有效的 ZIP/IPA。") }

        var entryCount = UInt64(u16(tail, eocdPos + 10))
        var cdSize = UInt64(u32(tail, eocdPos + 12))
        var cdOffset = UInt64(u32(tail, eocdPos + 16))

        // Check for ZIP64 EOCD Locator immediately before EOCD
        if entryCount == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF {
            let locatorPos = eocdPos - 20
            if locatorPos >= 0, u32(tail, locatorPos) == 0x07064B50 {
                let zip64EOCDOffset = u64(tail, locatorPos + 8)
                let zip64EOCD = try source.read(offset: zip64EOCDOffset, length: 56)
                guard u32(zip64EOCD, 0) == 0x06064B50 else {
                    throw ImportFailure("ZIP64 目录头损坏。")
                }
                entryCount = u64(zip64EOCD, 32)
                cdSize = u64(zip64EOCD, 40)
                cdOffset = u64(zip64EOCD, 48)
            }
        }

        guard entryCount <= UInt64(maximumEntryCount) else {
            throw ImportFailure("压缩包内文件数量超过 \(maximumEntryCount) 个上限，已拒绝读取。")
        }
        guard cdSize <= 64 * 1024 * 1024 else {
            throw ImportFailure("压缩包目录过大，已拒绝读取。")
        }

        let cdData = try source.read(offset: cdOffset, length: Int(cdSize))
        var result: [Entry] = []
        result.reserveCapacity(Int(min(entryCount, 4096)))

        var offset = 0
        while offset + 46 <= cdData.count && result.count < Int(entryCount) {
            guard u32(cdData, offset) == 0x02014B50 else { break }
            let flags = u16(cdData, offset + 8)
            let method = u16(cdData, offset + 10)
            var compressedSize = UInt64(u32(cdData, offset + 20))
            var uncompressedSize = UInt64(u32(cdData, offset + 24))
            let nameLen = Int(u16(cdData, offset + 28))
            let extraLen = Int(u16(cdData, offset + 30))
            let commentLen = Int(u16(cdData, offset + 32))
            var localOffset = UInt64(u32(cdData, offset + 42))

            guard offset + 46 + nameLen + extraLen <= cdData.count else { break }
            let nameRange = (offset + 46)..<(offset + 46 + nameLen)
            let nameBytes = cdData.subdata(in: nameRange)
            let name = String(data: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self)

            if compressedSize == 0xFFFFFFFF || uncompressedSize == 0xFFFFFFFF || localOffset == 0xFFFFFFFF {
                let extraStart = offset + 46 + nameLen
                let extraEnd = extraStart + extraLen
                parseZIP64Extra(cdData, start: extraStart, end: extraEnd,
                                uncompressedSize: &uncompressedSize,
                                compressedSize: &compressedSize,
                                localOffset: &localOffset)
            }

            result.append(Entry(
                name: name,
                method: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset,
                isEncrypted: (flags & 0x0001) != 0
            ))
            offset += 46 + nameLen + extraLen + commentLen
        }

        guard !result.isEmpty else { throw ImportFailure("这个压缩包里没有可读的文件。") }
        return result
    }

    private static func parseZIP64Extra(_ data: Data, start: Int, end: Int,
                                        uncompressedSize: inout UInt64,
                                        compressedSize: inout UInt64,
                                        localOffset: inout UInt64) {
        var pos = start
        while pos + 4 <= end {
            let tag = u16(data, pos)
            let size = Int(u16(data, pos + 2))
            pos += 4
            guard pos + size <= end else { break }
            if tag == 0x0001 {
                var fieldPos = pos
                if uncompressedSize == 0xFFFFFFFF && fieldPos + 8 <= pos + size {
                    uncompressedSize = u64(data, fieldPos)
                    fieldPos += 8
                }
                if compressedSize == 0xFFFFFFFF && fieldPos + 8 <= pos + size {
                    compressedSize = u64(data, fieldPos)
                    fieldPos += 8
                }
                if localOffset == 0xFFFFFFFF && fieldPos + 8 <= pos + size {
                    localOffset = u64(data, fieldPos)
                }
                return
            }
            pos += size
        }
    }

    private static func inflate(_ compressed: Data, expectedSize: Int, maxBytes: Int, name: String) throws -> Data {
        let capacity = min(max(expectedSize, 64), maxBytes)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { target -> Int in
            compressed.withUnsafeBytes { source -> Int in
                guard let dst = target.bindMemory(to: UInt8.self).baseAddress,
                      let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, capacity, src, compressed.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else {
            throw ImportFailure("「\(name)」解压失败，文件可能已损坏。")
        }
        return output.prefix(written)
    }

    // MARK: - Little-Endian Readers

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(u16(data, offset)) | (UInt32(u16(data, offset + 2)) << 16)
    }

    private static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(u32(data, offset)) | (UInt64(u32(data, offset + 4)) << 32)
    }
}
