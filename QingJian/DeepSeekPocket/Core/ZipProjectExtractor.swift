import Foundation

/// Extracts a readable directory tree and prioritized source/config contents from a `.zip` archive
/// up to 100 MB, filtering out build artifacts, VCS internals, and binary media.
enum ZipProjectExtractor {
    static let maximumZipBytes = 100 * 1024 * 1024
    static let defaultCharacterBudget = 95_000

    private static let ignoredDirectorySegments: Set<String> = [
        ".git", "node_modules", "pods", "deriveddata", "build", ".build",
        "__pycache__", ".venv", "venv", ".trash", "__macosx", ".idea", ".gradle"
    ]

    private static let ignoredFileNames: Set<String> = [
        ".ds_store", "thumbs.db", "desktop.ini"
    ]

    private static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "ico",
        "mp3", "mp4", "mov", "wav", "m4a", "aac", "ogg", "flac", "avi", "mkv",
        "ttf", "otf", "woff", "woff2", "eot",
        "o", "a", "so", "dylib", "dll", "exe", "bin", "class", "jar", "war",
        "pyc", "nib", "car", "pdf", "zip", "ipa", "gz", "tar", "7z", "rar",
        "sqlite", "db", "realm", "metallib"
    ]

    private static let priorityConfigNames: Set<String> = [
        "package.swift", "package.json", "podfile", "cargo.toml", "pyproject.toml",
        "requirements.txt", "go.mod", "cmakelists.txt", "makefile", "dockerfile",
        "tsconfig.json", "info.plist", "gemfile", "rakefile"
    ]

    static func extract(url: URL, maxCharacters: Int = defaultCharacterBudget) throws -> ImportedTextDocument {
        let reader = try StreamZipReader(url: url, maxArchiveBytes: maximumZipBytes)
        return try extract(reader: reader, fileName: url.lastPathComponent, maxCharacters: maxCharacters)
    }

    static func extract(data: Data, fileName: String = "archive.zip", maxCharacters: Int = defaultCharacterBudget) throws -> ImportedTextDocument {
        let reader = try StreamZipReader(data: data, maxArchiveBytes: maximumZipBytes)
        return try extract(reader: reader, fileName: fileName, maxCharacters: maxCharacters)
    }

    static func extract(reader: StreamZipReader, fileName: String, maxCharacters: Int = defaultCharacterBudget) throws -> ImportedTextDocument {
        let allFiles = reader.entries.filter { !$0.isDirectory }
        var keptFiles: [StreamZipReader.Entry] = []
        var skippedDirs: Set<String> = []
        var binaryCount = 0

        for entry in allFiles {
            if let ignoredSegment = firstIgnoredDirectory(in: entry.name) {
                skippedDirs.insert(ignoredSegment)
                continue
            }
            let baseName = (entry.name as NSString).lastPathComponent.lowercased()
            if ignoredFileNames.contains(baseName) { continue }
            let ext = (entry.name as NSString).pathExtension.lowercased()
            if binaryExtensions.contains(ext) {
                binaryCount += 1
                continue
            }
            keptFiles.append(entry)
        }

        let sortedForTree = keptFiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var sections: [String] = []
        sections.append("# 压缩包内容：\(fileName)")
        sections.append("")
        sections.append("## 目录树（共 \(keptFiles.count) 个可读文本/配置文件\(binaryCount > 0 ? "，已跳过 \(binaryCount) 个二进制/媒体文件" : "")）")
        if !skippedDirs.isEmpty {
            sections.append("- 已自动过滤目录：\(skippedDirs.sorted().joined(separator: "、"))")
        }
        sections.append("```")
        for entry in sortedForTree.prefix(500) {
            sections.append("\(entry.name) (\(formatSize(entry.uncompressedSize)))")
        }
        if sortedForTree.count > 500 {
            sections.append("... 其余 \(sortedForTree.count - 500) 个文件")
        }
        sections.append("```")

        var output = sections.joined(separator: "\n")
        var warnings: [String] = []

        // Sort by priority: README / manifests / configs first, then source code
        let prioritized = keptFiles.sorted { lhs, rhs in
            let p1 = priorityRank(lhs.name)
            let p2 = priorityRank(rhs.name)
            if p1 != p2 { return p1 < p2 }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        var unexpanded: [StreamZipReader.Entry] = []
        var expandedCount = 0

        for entry in prioritized {
            if entry.uncompressedSize > 512 * 1024 {
                unexpanded.append(entry)
                continue
            }
            guard output.count < maxCharacters else {
                unexpanded.append(entry)
                continue
            }
            guard let raw = try? reader.readEntry(entry, maxBytes: 512 * 1024),
                  let text = decodeReadableText(raw, path: entry.name) else {
                continue
            }
            let block = "\n\n### \(entry.name)\n```\n\(text)\n```"
            if output.count + block.count <= maxCharacters {
                output += block
                expandedCount += 1
            } else if expandedCount == 0 {
                let remaining = max(500, maxCharacters - output.count - 120)
                output += "\n\n### \(entry.name)\n```\n\(String(text.prefix(remaining)))\n...\n```"
                expandedCount += 1
            } else {
                unexpanded.append(entry)
            }
        }

        if !unexpanded.isEmpty {
            output += "\n\n## 未展开文件清单（共 \(unexpanded.count) 个，因字数预算限制未展开正文）\n"
            for item in unexpanded.prefix(100) {
                output += "- `\(item.name)` (\(formatSize(item.uncompressedSize)))\n"
            }
            if unexpanded.count > 100 {
                output += "- ... 其余 \(unexpanded.count - 100) 个\n"
            }
            warnings.append("压缩包已提取完整目录树与 \(expandedCount) 个核心文件，其余 \(unexpanded.count) 个文件因 10 万字预算仅保留路径清单。")
        }

        let cleanName = (fileName as NSString).deletingPathExtension
        return ImportedTextDocument(name: cleanName.isEmpty ? fileName : cleanName, text: output, warnings: warnings)
    }

    private static func firstIgnoredDirectory(in path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        for part in parts.dropLast() {
            let lower = part.lowercased()
            if ignoredDirectorySegments.contains(lower) {
                return String(part)
            }
        }
        return nil
    }

    private static func priorityRank(_ path: String) -> Int {
        let base = (path as NSString).lastPathComponent.lowercased()
        if base.hasPrefix("readme") { return 0 }
        if priorityConfigNames.contains(base) { return 1 }
        let ext = (path as NSString).pathExtension.lowercased()
        if ["yaml", "yml", "toml", "json", "xcconfig", "podspec"].contains(ext) { return 2 }
        return 3
    }

    private static func decodeReadableText(_ data: Data, path: String) -> String? {
        if data.isEmpty { return "" }
        if data.starts(with: Array("bplist00".utf8)),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let xmlData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
           let xml = String(data: xmlData, encoding: .utf8) {
            return xml
        }
        guard let decoded = BookText.decode(data) else { return nil }
        let normalized = decoded.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0.value != 9 && $0.value != 10 }) {
            return nil
        }
        return normalized
    }

    private static func formatSize(_ bytes: UInt64) -> String {
        if bytes >= 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        if bytes >= 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return "\(bytes) B"
    }
}
