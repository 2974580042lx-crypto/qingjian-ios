import Foundation

/// On-device static analyzer for `.ipa` packages using `StreamZipReader`.
/// Produces a structured Markdown report covering size breakdown, `Info.plist`,
/// `embedded.mobileprovision` entitlements, Mach-O architectures/encryption/dylibs,
/// and bundle hygiene checks.
enum IPAAnalyzer {
    static let maximumReportCharacters = 95_000

    struct MachOSliceInfo: Sendable, Equatable {
        let architecture: String
        let isEncrypted: Bool
        let cryptID: UInt32
        let dylibs: [String]
    }

    static func analyze(url: URL) throws -> ImportedTextDocument {
        let reader = try StreamZipReader(url: url, maxArchiveBytes: StreamZipReader.maximumArchiveBytes)
        return try analyze(reader: reader, fileName: url.lastPathComponent)
    }

    static func analyze(data: Data, fileName: String = "App.ipa") throws -> ImportedTextDocument {
        let reader = try StreamZipReader(data: data, maxArchiveBytes: StreamZipReader.maximumArchiveBytes)
        return try analyze(reader: reader, fileName: fileName)
    }

    static func analyze(reader: StreamZipReader, fileName: String) throws -> ImportedTextDocument {
        let files = reader.entries.filter { !$0.isDirectory }
        guard !files.isEmpty else { throw ImportFailure("这个 IPA 压缩包里没有任何文件。") }

        let appPrefix = detectAppBundlePrefix(in: files)
        let infoEntry = appPrefix.flatMap { reader.entry(named: $0 + "Info.plist") }
            ?? files.first(where: { $0.name.hasPrefix("Payload/") && $0.name.hasSuffix(".app/Info.plist") })

        var infoDict: [String: Any] = [:]
        var infoSection = "_未找到 Info.plist_"
        if let infoEntry {
            do {
                let plistData = try reader.readEntry(infoEntry)
                if let parsed = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
                    infoDict = parsed
                    infoSection = formatInfoPlist(parsed)
                } else {
                    infoSection = "_Info.plist 顶层不是字典结构_"
                }
            } catch {
                infoSection = "_Info.plist 解析失败：\(error.localizedDescription)_"
            }
        }

        let executableName = infoDict["CFBundleExecutable"] as? String
        let displayName = (infoDict["CFBundleDisplayName"] as? String)
            ?? (infoDict["CFBundleName"] as? String)
            ?? fileName

        // 1. Size breakdown
        let sizeSection = formatSizeBreakdown(
            archiveSize: reader.archiveSize,
            files: files,
            appPrefix: appPrefix,
            executableName: executableName
        )

        // 2. Provisioning profile
        let provisionEntry = appPrefix.flatMap { reader.entry(named: $0 + "embedded.mobileprovision") }
            ?? files.first(where: { $0.name.hasSuffix("/embedded.mobileprovision") })
        let provisionSection = formatMobileProvision(provisionEntry, reader: reader)

        // 3. Mach-O analysis
        let machoSection = formatMachOAnalysis(
            files: files,
            reader: reader,
            appPrefix: appPrefix,
            executableName: executableName
        )

        // 4. Bundle hygiene
        let hygieneSection = formatHygieneCheck(files: files, appPrefix: appPrefix)

        var lines: [String] = []
        lines.append("# \(displayName) · IPA 静态体检报告")
        lines.append("")
        lines.append("- **原始文件**：`\(fileName)`")
        if let appPrefix { lines.append("- **App 目录**：`\(appPrefix)`") }
        lines.append("")
        lines.append("## 1. 包体与体积分布")
        lines.append(sizeSection)
        lines.append("")
        lines.append("## 2. Info.plist 关键配置")
        lines.append(infoSection)
        lines.append("")
        lines.append("## 3. 签名与权限（embedded.mobileprovision）")
        lines.append(provisionSection)
        lines.append("")
        lines.append("## 4. Mach-O 二进制与动态库依赖")
        lines.append(machoSection)
        if !hygieneSection.isEmpty {
            lines.append("")
            lines.append("## 5. 发布包资源清洁度提醒")
            lines.append(hygieneSection)
        }

        var report = lines.joined(separator: "\n")
        var warnings: [String] = []
        if report.count > maximumReportCharacters {
            report = String(report.prefix(maximumReportCharacters)) + "\n\n... [报告过长，已截断至 \(maximumReportCharacters) 字]"
            warnings.append("IPA 体检报告超过 \(maximumReportCharacters.formatted()) 字，已自动截断末尾部分。")
        }
        let cleanTitle = (fileName as NSString).deletingPathExtension
        return ImportedTextDocument(name: "\(cleanTitle).ipa-report", text: report, warnings: warnings)
    }

    // MARK: - Helpers

    private static func detectAppBundlePrefix(in files: [StreamZipReader.Entry]) -> String? {
        for entry in files where entry.name.hasPrefix("Payload/") {
            let parts = entry.name.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 2 && parts[1].hasSuffix(".app") {
                return "\(parts[0])/\(parts[1])/"
            }
        }
        return nil
    }

    private static func formatSizeBreakdown(
        archiveSize: UInt64,
        files: [StreamZipReader.Entry],
        appPrefix: String?,
        executableName: String?
    ) -> String {
        let totalUncompressed = files.reduce(UInt64(0)) { $0 &+ $1.uncompressedSize }
        let mainExecPath = (appPrefix ?? "") + (executableName ?? "")

        var mainExecBytes: UInt64 = 0
        var frameworksBytes: UInt64 = 0
        var pluginsBytes: UInt64 = 0
        var resourcesBytes: UInt64 = 0

        for file in files {
            let rel = appPrefix.flatMap { file.name.hasPrefix($0) ? String(file.name.dropFirst($0.count)) : nil } ?? file.name
            if !mainExecPath.isEmpty && file.name == mainExecPath {
                mainExecBytes &+= file.uncompressedSize
            } else if rel.hasPrefix("Frameworks/") {
                frameworksBytes &+= file.uncompressedSize
            } else if rel.hasPrefix("PlugIns/") || rel.hasPrefix("Extensions/") {
                pluginsBytes &+= file.uncompressedSize
            } else {
                resourcesBytes &+= file.uncompressedSize
            }
        }

        var out: [String] = []
        out.append("- 压缩包体积：**\(formatBytes(archiveSize))**（解压后总计 **\(formatBytes(totalUncompressed))**，共 \(files.count) 个文件）")
        out.append("- 主程序二进制：\(formatBytes(mainExecBytes))")
        out.append("- Frameworks 动态库/框架：\(formatBytes(frameworksBytes))")
        if pluginsBytes > 0 {
            out.append("- PlugIns / 扩展：\(formatBytes(pluginsBytes))")
        }
        out.append("- 资源与其余文件：\(formatBytes(resourcesBytes))")
        out.append("")
        out.append("### Top 25 最大文件")
        let top = files.sorted { $0.uncompressedSize > $1.uncompressedSize }.prefix(25)
        for (idx, item) in top.enumerated() {
            let rel = appPrefix.flatMap { item.name.hasPrefix($0) ? String(item.name.dropFirst($0.count)) : nil } ?? item.name
            out.append("\(idx + 1). `\(rel)` — \(formatBytes(item.uncompressedSize))（压缩后 \(formatBytes(item.compressedSize))）")
        }
        return out.joined(separator: "\n")
    }

    private static func formatInfoPlist(_ dict: [String: Any]) -> String {
        var out: [String] = []
        let simpleKeys: [(String, String)] = [
            ("CFBundleDisplayName", "显示名称"),
            ("CFBundleName", "Bundle 名称"),
            ("CFBundleIdentifier", "Bundle ID"),
            ("CFBundleShortVersionString", "版本号"),
            ("CFBundleVersion", "Build"),
            ("CFBundleExecutable", "主可执行文件"),
            ("MinimumOSVersion", "最低 iOS 版本"),
            ("DTPlatformVersion", "编译 SDK 版本"),
            ("DTXcodeBuild", "Xcode Build")
        ]
        for (key, label) in simpleKeys {
            if let val = dict[key] {
                out.append("- **\(label)**（`\(key)`）：`\(val)`")
            }
        }
        if let families = dict["UIDeviceFamily"] as? [Int] {
            let names = families.map { $0 == 1 ? "iPhone" : ($0 == 2 ? "iPad" : "Family(\($0))") }
            out.append("- **支持设备**：\(names.joined(separator: "、"))")
        }
        if let modes = dict["UIBackgroundModes"] as? [String], !modes.isEmpty {
            out.append("- **后台模式**：`\(modes.joined(separator: ", "))`")
        }
        if let schemes = dict["LSApplicationQueriesSchemes"] as? [String], !schemes.isEmpty {
            out.append("- **白名单 Schemes**：`\(schemes.prefix(30).joined(separator: ", "))`\(schemes.count > 30 ? "（共 \(schemes.count) 个）" : "")")
        }
        if let urlTypes = dict["CFBundleURLTypes"] as? [[String: Any]], !urlTypes.isEmpty {
            let allSchemes = urlTypes.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
            if !allSchemes.isEmpty {
                out.append("- **注册 URL Schemes**：`\(allSchemes.joined(separator: ", "))`")
            }
        }
        if let docTypes = dict["CFBundleDocumentTypes"] as? [[String: Any]], !docTypes.isEmpty {
            let names = docTypes.compactMap { $0["CFBundleTypeName"] as? String }
            out.append("- **声明支持文档类型**：\(names.joined(separator: "、"))")
        }
        let privacyKeys = dict.keys.filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") }.sorted()
        if !privacyKeys.isEmpty {
            out.append("")
            out.append("### 隐私权限说明")
            for key in privacyKeys {
                let desc = String(describing: dict[key] ?? "")
                out.append("- `\(key)`：\(desc)")
            }
        }
        return out.joined(separator: "\n")
    }

    private static func formatMobileProvision(_ entry: StreamZipReader.Entry?, reader: StreamZipReader) -> String {
        guard let entry else {
            return "- **未签名**：包内没有 `embedded.mobileprovision`（常见于 `unsigned.ipa` 或砸壳包）。"
        }
        do {
            let raw = try reader.readEntry(entry, maxBytes: 4 * 1024 * 1024)
            guard let plistData = extractEmbeddedPlist(from: raw),
                  let dict = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
                return "- 已检测到 `embedded.mobileprovision`（\(formatBytes(entry.uncompressedSize))），但未能提取内嵌 XML 权限表。"
            }
            var out: [String] = []
            if let name = dict["Name"] as? String { out.append("- **描述文件名称**：\(name)") }
            if let team = dict["TeamName"] as? String { out.append("- **Team 名称**：\(team)") }
            if let teamIDs = dict["TeamIdentifier"] as? [String], !teamIDs.isEmpty {
                out.append("- **Team ID**：`\(teamIDs.joined(separator: ", "))`")
            }
            if let appID = dict["AppIDName"] as? String { out.append("- **App ID**：\(appID)") }
            if let created = dict["CreationDate"] as? Date { out.append("- **签发时间**：\(isoDate(created))") }
            if let expires = dict["ExpirationDate"] as? Date { out.append("- **过期时间**：\(isoDate(expires))") }
            if let allDevices = dict["ProvisionsAllDevices"] as? Bool, allDevices {
                out.append("- **分发类型**：Enterprise（全设备）")
            } else if let devices = dict["ProvisionedDevices"] as? [String] {
                out.append("- **测试设备数**：\(devices.count) 台（Development / Ad-Hoc）")
            } else {
                out.append("- **分发类型**：App Store / 通用分发")
            }
            if let entitlements = dict["Entitlements"] as? [String: Any], !entitlements.isEmpty {
                out.append("")
                out.append("### Entitlements 权限")
                for key in entitlements.keys.sorted() {
                    out.append("- `\(key)` = `\(formatPlistValue(entitlements[key]))`")
                }
            }
            return out.joined(separator: "\n")
        } catch {
            return "- 读取 `embedded.mobileprovision` 失败：\(error.localizedDescription)"
        }
    }

    private static func extractEmbeddedPlist(from data: Data) -> Data? {
        let startToken = Data("<?xml".utf8)
        let altStartToken = Data("<plist".utf8)
        let endToken = Data("</plist>".utf8)
        let startRange = data.range(of: startToken) ?? data.range(of: altStartToken)
        guard let start = startRange?.lowerBound,
              let endRange = data.range(of: endToken, in: start..<data.endIndex) else {
            return nil
        }
        return data.subdata(in: start..<endRange.upperBound)
    }

    private static func formatMachOAnalysis(
        files: [StreamZipReader.Entry],
        reader: StreamZipReader,
        appPrefix: String?,
        executableName: String?
    ) -> String {
        var out: [String] = []
        let mainPath = appPrefix.flatMap { prefix in executableName.map { prefix + $0 } }
        if let mainPath, let mainEntry = reader.entry(named: mainPath) {
            out.append("### 主程序：`\(executableName ?? mainPath)`")
            do {
                let data = try reader.readEntry(mainEntry, maxBytes: 128 * 1024 * 1024)
                let slices = parseMachO(data)
                if slices.isEmpty {
                    out.append("- 未识别出有效 Mach-O 头。")
                } else {
                    for slice in slices {
                        let enc = slice.isEncrypted ? "**已加密（cryptid=\(slice.cryptID)，App Store 加密壳）**" : "未加密（cryptid=0）"
                        out.append("- 架构：`\(slice.architecture)` · 加密状态：\(enc)")
                        let appDylibs = slice.dylibs.filter { !$0.hasPrefix("/System/") && !$0.hasPrefix("/usr/lib/") }
                        let sysDylibs = slice.dylibs.filter { $0.hasPrefix("/System/") || $0.hasPrefix("/usr/lib/") }
                        if !appDylibs.isEmpty {
                            out.append("- 内嵌/三方动态库（\(appDylibs.count)）：")
                            for lib in appDylibs.prefix(40) { out.append("  - `\(lib)`") }
                            if appDylibs.count > 40 { out.append("  - ... 其余 \(appDylibs.count - 40) 个") }
                        }
                        out.append("- 链接系统框架/库：共 \(sysDylibs.count) 个")
                    }
                }
            } catch {
                out.append("- 主程序读取跳过：\(error.localizedDescription)")
            }
        } else {
            out.append("- 未定位到主程序可执行文件。")
        }

        // Scan embedded Frameworks
        let frameworkBinaries = files.filter { entry in
            guard let prefix = appPrefix, entry.name.hasPrefix(prefix + "Frameworks/") else { return false }
            let rel = String(entry.name.dropFirst((prefix + "Frameworks/").count))
            if rel.hasSuffix(".dylib") && !rel.contains("/") { return true }
            let parts = rel.split(separator: "/")
            if parts.count == 2 && parts[0].hasSuffix(".framework") {
                let fwName = String(parts[0].dropLast(".framework".count))
                return String(parts[1]) == fwName
            }
            return false
        }.sorted { $0.uncompressedSize > $1.uncompressedSize }

        if !frameworkBinaries.isEmpty {
            out.append("")
            out.append("### 内嵌 Frameworks / Dylibs（共 \(frameworkBinaries.count) 个）")
            for entry in frameworkBinaries.prefix(30) {
                let rel = appPrefix.map { String(entry.name.dropFirst($0.count)) } ?? entry.name
                if entry.uncompressedSize > UInt64(StreamZipReader.maximumEntryBytes) {
                    out.append("- `\(rel)`（\(formatBytes(entry.uncompressedSize))，超过单文件 32 MB 解析上限，跳过头解析）")
                    continue
                }
                if let data = try? reader.readEntry(entry), let first = parseMachO(data).first {
                    let enc = first.isEncrypted ? " · cryptid=\(first.cryptID)" : ""
                    out.append("- `\(rel)` — \(formatBytes(entry.uncompressedSize)) · `\(first.architecture)`\(enc)")
                } else {
                    out.append("- `\(rel)` — \(formatBytes(entry.uncompressedSize))")
                }
            }
        }
        return out.joined(separator: "\n")
    }

    static func parseMachO(_ data: Data) -> [MachOSliceInfo] {
        guard data.count >= 16 else { return [] }
        let magicBE = u32BE(data, 0)
        // Fat binary (0xCAFEBABE or 0xCAFEBABF)
        if magicBE == 0xCAFEBABE || magicBE == 0xCAFEBABF {
            let isFat64 = magicBE == 0xCAFEBABF
            let nfat = Int(u32BE(data, 4))
            guard nfat > 0, nfat <= 16 else { return [] }
            let archSize = isFat64 ? 32 : 20
            var slices: [MachOSliceInfo] = []
            for i in 0..<nfat {
                let entryOffset = 8 + i * archSize
                guard entryOffset + archSize <= data.count else { break }
                let rawOffset: UInt64 = isFat64 ? u64BE(data, entryOffset + 8) : UInt64(u32BE(data, entryOffset + 8))
                let rawSize: UInt64 = isFat64 ? u64BE(data, entryOffset + 16) : UInt64(u32BE(data, entryOffset + 12))
                let totalBytes = UInt64(data.count)
                guard rawOffset <= totalBytes, rawSize >= 28, rawSize <= totalBytes - rawOffset else { continue }
                let sliceOffset = Int(rawOffset)
                let sliceSize = Int(rawSize)
                let sliceData = data.subdata(in: (data.startIndex + sliceOffset)..<(data.startIndex + sliceOffset + sliceSize))
                if let parsed = parseSingleMachO(sliceData) {
                    slices.append(parsed)
                }
            }
            return slices
        }
        if let single = parseSingleMachO(data) {
            return [single]
        }
        return []
    }

    private static func parseSingleMachO(_ data: Data) -> MachOSliceInfo? {
        guard data.count >= 28 else { return nil }
        let magicLE = u32LE(data, 0)
        let is64: Bool
        let bigEndian: Bool
        switch magicLE {
        case 0xFEEDFACF: is64 = true; bigEndian = false
        case 0xCFFAEDFE: is64 = true; bigEndian = true
        case 0xFEEDFACE: is64 = false; bigEndian = false
        case 0xCEFAEDFE: is64 = false; bigEndian = true
        default: return nil
        }

        let headerSize = is64 ? 32 : 28
        guard data.count >= headerSize else { return nil }

        func read32(_ offset: Int) -> UInt32 {
            bigEndian ? u32BE(data, offset) : u32LE(data, offset)
        }

        let cputype = Int32(bitPattern: read32(4))
        let cpusubtype = Int32(bitPattern: read32(8))
        let ncmds = Int(read32(16))
        let sizeofcmds = Int(read32(20))

        let arch = cpuName(cputype: cputype, cpusubtype: cpusubtype)
        var isEncrypted = false
        var cryptID: UInt32 = 0
        var dylibs: [String] = []

        var cmdOffset = headerSize
        let cmdsEnd = min(data.count, headerSize + sizeofcmds)
        for _ in 0..<min(ncmds, 4096) {
            guard cmdOffset + 8 <= cmdsEnd else { break }
            let cmd = read32(cmdOffset)
            let cmdsize = Int(read32(cmdOffset + 4))
            guard cmdsize >= 8, cmdOffset + cmdsize <= cmdsEnd else { break }

            // LC_ENCRYPTION_INFO (0x21) or LC_ENCRYPTION_INFO_64 (0x2C)
            if (cmd == 0x21 || cmd == 0x2C) && cmdsize >= 20 {
                let cid = read32(cmdOffset + 16)
                cryptID = cid
                if cid != 0 { isEncrypted = true }
            }
            // LC_LOAD_DYLIB (0x0C), LC_LOAD_WEAK_DYLIB (0x80000018), LC_REEXPORT_DYLIB (0x8000001F), LC_LAZY_LOAD_DYLIB (0x20)
            if (cmd == 0x0C || cmd == 0x80000018 || cmd == 0x8000001F || cmd == 0x20) && cmdsize >= 24 {
                let strOffset = Int(read32(cmdOffset + 8))
                if strOffset >= 24 && strOffset < cmdsize {
                    let strSlice = data.subdata(in: (data.startIndex + cmdOffset + strOffset)..<(data.startIndex + cmdOffset + cmdsize))
                    if let nul = strSlice.firstIndex(of: 0) {
                        let nameBytes = strSlice.prefix(upTo: nul)
                        if let name = String(data: nameBytes, encoding: .utf8), !name.isEmpty {
                            dylibs.append(name)
                        }
                    } else if let name = String(data: strSlice, encoding: .utf8), !name.isEmpty {
                        dylibs.append(name)
                    }
                }
            }
            cmdOffset += cmdsize
        }

        return MachOSliceInfo(architecture: arch, isEncrypted: isEncrypted, cryptID: cryptID, dylibs: dylibs)
    }

    private static func cpuName(cputype: Int32, cpusubtype: Int32) -> String {
        switch cputype {
        case 0x0100000C: // CPU_TYPE_ARM64
            return (cpusubtype & 0x00FFFFFF) == 2 ? "arm64e" : "arm64"
        case 12: // CPU_TYPE_ARM
            return "armv7"
        case 0x01000007: // CPU_TYPE_X86_64
            return "x86_64"
        case 7: // CPU_TYPE_X86
            return "i386"
        default:
            return "cpu(\(cputype))"
        }
    }

    private static func formatHygieneCheck(files: [StreamZipReader.Entry], appPrefix: String?) -> String {
        var notes: [String] = []
        let suspiciousNames: Set<String> = ["agents.md", "claude.md", "readme.md", ".ds_store", ".env", "id_rsa"]
        for file in files {
            let rel = appPrefix.flatMap { file.name.hasPrefix($0) ? String(file.name.dropFirst($0.count)) : nil } ?? file.name
            let lowerName = (rel as NSString).lastPathComponent.lowercased()
            if suspiciousNames.contains(lowerName) || rel.contains("/.git/") || rel.hasPrefix(".git/") {
                notes.append("- 发现可疑/冗余发布文件：`\(rel)`（\(formatBytes(file.uncompressedSize))）")
            }
        }
        return notes.prefix(20).joined(separator: "\n")
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.2f MB", Double(bytes) / (1024 * 1024))
        }
        if bytes >= 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        }
        return "\(bytes) B"
    }

    private static func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }

    private static func formatPlistValue(_ value: Any?) -> String {
        switch value {
        case let b as Bool: return b ? "true" : "false"
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let arr as [Any]: return "[\(arr.map { formatPlistValue($0) }.joined(separator: ", "))]"
        default: return String(describing: value ?? "nil")
        }
    }

    private static func u32LE(_ data: Data, _ offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i]) | (UInt32(data[i + 1]) << 8) | (UInt32(data[i + 2]) << 16) | (UInt32(data[i + 3]) << 24)
    }

    private static func u32BE(_ data: Data, _ offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return (UInt32(data[i]) << 24) | (UInt32(data[i + 1]) << 16) | (UInt32(data[i + 2]) << 8) | UInt32(data[i + 3])
    }

    private static func u64BE(_ data: Data, _ offset: Int) -> UInt64 {
        (UInt64(u32BE(data, offset)) << 32) | UInt64(u32BE(data, offset + 4))
    }
}
