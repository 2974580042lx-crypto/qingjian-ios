import Foundation

enum DeliverableFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case docx
    case xlsx
    case pdf
    case html
    case md
    case txt
    case csv

    var id: String { rawValue }

    var fileExtension: String { rawValue }

    var displayLabel: String {
        rawValue.uppercased()
    }

    var mimeType: String {
        switch self {
        case .docx: return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case .xlsx: return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case .pdf: return "application/pdf"
        case .html: return "text/html"
        case .md: return "text/markdown"
        case .txt: return "text/plain"
        case .csv: return "text/csv"
        }
    }
}

struct ProjectDeliverable: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let groupID: UUID
    let projectID: UUID?
    let threadID: UUID
    let messageID: UUID
    var title: String
    var fileName: String
    var format: DeliverableFormat
    var version: Int
    var summary: String
    var byteCount: Int
    var characterCount: Int
    var footnoteCount: Int
    var createdAt: Date
    var relativePath: String
    var sourcePreview: String

    /// Claude V3 restrained subtitle: e.g. "文件 · DOCX · v2" or "文件 · XLSX"
    var claudeSubtitle: String {
        var parts = ["文件 · \(format.displayLabel)"]
        if version > 1 {
            parts.append("v\(version)")
        }
        return parts.joined(separator: " · ")
    }

    var detailedMetaLine: String {
        var parts = ["文件 · \(format.displayLabel)", "v\(version)"]
        if footnoteCount > 0 { parts.append("\(footnoteCount) 条页下注") }
        if characterCount > 0 { parts.append("\(characterCount.formatted()) 字") }
        let kb = max(1, (byteCount + 512) / 1024)
        parts.append(kb >= 1024 ? String(format: "%.1f MB", Double(byteCount) / 1_048_576.0) : "\(kb) KB")
        return parts.joined(separator: " · ")
    }
}

/// Sidecar multi-version deliverable repository stored outside `conversations.json`
/// (`Application Support/QingJian/Deliverables/`). Never mutates `ChatMessage` schema and never overwrites source literature.
final class ProjectDeliverableStore: @unchecked Sendable {
    private let rootDirectory: URL
    private let lock = NSLock()
    private var items: [ProjectDeliverable] = []

    private struct ManifestFile: Codable {
        var version: Int = 1
        var items: [ProjectDeliverable]
    }

    init(rootDirectory: URL = ProjectDeliverableStore.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory
        loadManifest()
    }

    static func defaultRootDirectory() -> URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("QingJian/Deliverables", isDirectory: true)
    }

    private var manifestURL: URL {
        rootDirectory.appendingPathComponent("manifest.json")
    }

    private var filesDirectory: URL {
        rootDirectory.appendingPathComponent("files", isDirectory: true)
    }

    func fileURL(for deliverable: ProjectDeliverable) -> URL {
        rootDirectory.appendingPathComponent(deliverable.relativePath)
    }

    func deliverable(by id: UUID) -> ProjectDeliverable? {
        lock.lock()
        defer { lock.unlock() }
        return items.first { $0.id == id }
    }

    func allDeliverables() -> [ProjectDeliverable] {
        lock.lock()
        defer { lock.unlock() }
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    func deliverables(forMessage messageID: UUID) -> [ProjectDeliverable] {
        lock.lock()
        defer { lock.unlock() }
        return items.filter { $0.messageID == messageID }.sorted { $0.createdAt < $1.createdAt }
    }

    func deliverables(forThread threadID: UUID) -> [ProjectDeliverable] {
        lock.lock()
        defer { lock.unlock() }
        return items.filter { $0.threadID == threadID }.sorted { $0.createdAt > $1.createdAt }
    }

    func deliverables(forProject projectID: UUID) -> [ProjectDeliverable] {
        lock.lock()
        defer { lock.unlock() }
        return items.filter { $0.projectID == projectID }.sorted { $0.createdAt > $1.createdAt }
    }

    func versions(inGroup groupID: UUID) -> [ProjectDeliverable] {
        lock.lock()
        defer { lock.unlock() }
        return items.filter { $0.groupID == groupID }.sorted { $0.version > $1.version }
    }

    func latestDeliverablesByGroup(projectID: UUID?, threadID: UUID?) -> [ProjectDeliverable] {
        lock.lock()
        let filtered: [ProjectDeliverable]
        if let projectID {
            filtered = items.filter { $0.projectID == projectID }
        } else if let threadID {
            filtered = items.filter { $0.threadID == threadID }
        } else {
            filtered = items
        }
        lock.unlock()

        var latestByGroup: [UUID: ProjectDeliverable] = [:]
        for item in filtered {
            if let existing = latestByGroup[item.groupID] {
                if item.version > existing.version || (item.version == existing.version && item.createdAt > existing.createdAt) {
                    latestByGroup[item.groupID] = item
                }
            } else {
                latestByGroup[item.groupID] = item
            }
        }
        return latestByGroup.values.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func saveDeliverable(
        projectID: UUID?,
        threadID: UUID,
        messageID: UUID,
        title: String,
        format: DeliverableFormat,
        data: Data,
        sourcePreview: String,
        summary: String,
        footnoteCount: Int = 0,
        baseDeliverableID: UUID? = nil
    ) throws -> ProjectDeliverable {
        guard !data.isEmpty else { throw DocumentStudioError.emptyContent }
        let cleanTitle = Self.sanitizeTitle(title)
        let id = UUID()
        let relativePath = "files/\(id.uuidString).\(format.fileExtension)"

        lock.lock()
        let matchedBase: ProjectDeliverable?
        if let baseID = baseDeliverableID, let found = items.first(where: { $0.id == baseID }) {
            matchedBase = found
        } else {
            matchedBase = items
                .filter { $0.format == format && $0.projectID == projectID && ($0.projectID != nil || $0.threadID == threadID) && $0.title == cleanTitle }
                .max(by: { $0.version < $1.version })
        }

        let groupID = matchedBase?.groupID ?? UUID()
        let existingVersions = items.filter { $0.groupID == groupID }.map(\.version)
        let nextVersion = (existingVersions.max() ?? 0) + 1
        let versionTag = nextVersion > 1 ? "-v\(nextVersion)" : ""
        let fileName = "\(cleanTitle)\(versionTag).\(format.fileExtension)"

        let record = ProjectDeliverable(
            id: id,
            groupID: groupID,
            projectID: projectID,
            threadID: threadID,
            messageID: messageID,
            title: cleanTitle,
            fileName: fileName,
            format: format,
            version: nextVersion,
            summary: String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)),
            byteCount: data.count,
            characterCount: sourcePreview.count,
            footnoteCount: footnoteCount,
            createdAt: Date(),
            relativePath: relativePath,
            sourcePreview: String(sourcePreview.prefix(24_000))
        )
        lock.unlock()

        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        let targetURL = fileURL(for: record)
        try data.write(to: targetURL, options: [.atomic])
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: targetURL.path
        )
        #endif

        lock.lock()
        items.append(record)
        let encodedManifest = encodeManifestLocked()
        lock.unlock()

        if let encodedManifest {
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            try encodedManifest.write(to: manifestURL, options: [.atomic])
        }
        return record
    }

    func readData(for deliverableID: UUID) throws -> Data {
        guard let item = deliverable(by: deliverableID) else {
            throw DocumentStudioError.invalidSpecification("未找到指定的成果文件。")
        }
        return try Data(contentsOf: fileURL(for: item))
    }

    func deleteDeliverable(_ deliverableID: UUID) {
        lock.lock()
        guard let idx = items.firstIndex(where: { $0.id == deliverableID }) else {
            lock.unlock()
            return
        }
        let removed = items.remove(at: idx)
        let encoded = encodeManifestLocked()
        lock.unlock()

        try? FileManager.default.removeItem(at: fileURL(for: removed))
        if let encoded {
            try? encoded.write(to: manifestURL, options: [.atomic])
        }
    }

    /// Exports manifest + deliverable files into a dictionary compatible with `UnifiedBackupPayload.deliverablesManifest`.
    func exportBackupBundle(maxTotalBytes: Int = 48 * 1024 * 1024) -> [String: Data] {
        lock.lock()
        let snapshotItems = items
        let manifestData = encodeManifestLocked()
        lock.unlock()

        guard !snapshotItems.isEmpty, let manifestData else { return [:] }
        var bundle: [String: Data] = ["manifest.json": manifestData]
        var used = manifestData.count
        for item in snapshotItems.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard let raw = try? Data(contentsOf: fileURL(for: item)),
                  used + raw.count <= maxTotalBytes else { continue }
            bundle[item.relativePath] = raw
            used += raw.count
        }
        return bundle
    }

    func restoreBackupBundle(_ bundle: [String: Data]?, mode: UnifiedRestoreMode) throws {
        guard let bundle, !bundle.isEmpty, let manifestData = bundle["manifest.json"] else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ManifestFile.self, from: manifestData)

        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        for item in decoded.items {
            guard item.relativePath.hasPrefix("files/"),
                  !item.relativePath.contains(".."),
                  let fileData = bundle[item.relativePath] else { continue }
            let target = fileURL(for: item)
            if mode == .replace || !FileManager.default.fileExists(atPath: target.path) {
                try fileData.write(to: target, options: [.atomic])
            }
        }

        lock.lock()
        if mode == .replace {
            items = decoded.items
        } else {
            let known = Set(items.map(\.id))
            for item in decoded.items where !known.contains(item.id) {
                items.append(item)
            }
        }
        let encoded = encodeManifestLocked()
        lock.unlock()

        if let encoded {
            try encoded.write(to: manifestURL, options: [.atomic])
        }
    }

    static func sanitizeTitle(_ raw: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r")
        var cleaned = raw.components(separatedBy: banned).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        for ext in [".docx", ".xlsx", ".pdf", ".html", ".md", ".txt", ".csv"] {
            if cleaned.lowercased().hasSuffix(ext) {
                cleaned = String(cleaned.dropLast(ext.count))
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Sermo交付文档" : String(cleaned.prefix(80))
    }

    private func encodeManifestLocked() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(ManifestFile(version: 1, items: items))
    }

    private func loadManifest() {
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(ManifestFile.self, from: data) else { return }
        lock.lock()
        items = decoded.items
        lock.unlock()
    }
}

/// Model-callable tools for generating real `.docx` / `.xlsx` / `.pdf` / `.html` / `.md` deliverables
/// and listing/reading prior deliverable versions across conversations.
enum DocumentStudioTools {
    static let names: Set<String> = [
        "document_create_docx",
        "document_create_xlsx",
        "document_create_pdf",
        "document_create_file",
        "document_list_deliverables",
        "document_read_deliverable"
    ]

    static let specs: [ToolSpec] = [
        ToolSpec(
            name: "document_create_docx",
            description: "生成标准可编辑的 Word (.docx) 文档，支持标题层级、表格与真正的页面底部脚注（Markdown 使用 [^1] 与文末 [^1]: 注释内容，自动写入 word/footnotes.xml）。修改旧文件时传 base_deliverable_id 自动升版本号（v1 → v2）。",
            parameters: ToolSpec.object([
                ("title", "string", "文档名称（不含 .docx 后缀，如 第三节_宋代红白契争讼考辨）"),
                ("markdown", "string", "完整 Markdown 正文，可含 # 标题、表格、[^1] 脚注标记与 [^1]: 脚注定义"),
                ("use_circled_footnotes", "boolean", "可选：是否采用圆圈序号 ①②③（默认 true）"),
                ("restart_footnotes_per_page", "boolean", "可选：脚注是否每页重新编号（默认 true）"),
                ("summary", "string", "可选：一句话说明本版生成或修订要点"),
                ("base_deliverable_id", "string", "可选：若基于已有成果修改，传入其 deliverable_id 自动递增版本号")
            ], required: ["title", "markdown"])
        ),
        ToolSpec(
            name: "document_create_xlsx",
            description: "生成标准多工作表 Excel (.xlsx) 表格，支持中文表头、自动列宽、冻结首行与数字格式。",
            parameters: ToolSpec.object([
                ("title", "string", "表格名称（不含 .xlsx 后缀）"),
                ("sheets_json", "string", "JSON 数组字符串，例如 [{\"name\":\"核对表\",\"headers\":[\"卷次\",\"页码\"],\"rows\":[[\"卷四\",\"118\"]]}]"),
                ("summary", "string", "可选：一句话说明表格内容"),
                ("base_deliverable_id", "string", "可选：若基于已有表格修订，传入其 deliverable_id 自动升版本")
            ], required: ["title", "sheets_json"])
        ),
        ToolSpec(
            name: "document_create_pdf",
            description: "生成排版清晰的 A4 中文矢量 PDF 文档（自动分页并带页眉页码），适合阅读、提交与分享。",
            parameters: ToolSpec.object([
                ("title", "string", "PDF 标题（不含 .pdf 后缀）"),
                ("markdown", "string", "完整 Markdown 正文"),
                ("summary", "string", "可选：一句话说明本版内容"),
                ("base_deliverable_id", "string", "可选：若基于已有 PDF 修订，传入其 deliverable_id 自动升版本")
            ], required: ["title", "markdown"])
        ),
        ToolSpec(
            name: "document_create_file",
            description: "生成可预览与导出的 HTML、Markdown、CSV 或 TXT 文件成果并保存版本记录。",
            parameters: ToolSpec.object([
                ("title", "string", "文件名称（不含后缀）"),
                ("format", "string", "格式：html / md / csv / txt"),
                ("content", "string", "完整文件内容"),
                ("summary", "string", "可选：一句话说明文件用途"),
                ("base_deliverable_id", "string", "可选：修订已有文件时传入 deliverable_id")
            ], required: ["title", "format", "content"])
        ),
        ToolSpec(
            name: "document_list_deliverables",
            description: "列出当前项目或当前对话已生成的文件成果及历史版本，便于跨对话继续修改或引用。",
            parameters: ToolSpec.object([
                ("project_only", "boolean", "可选：true 列出当前项目全部成果，false 仅列当前对话（默认 true）")
            ], required: [])
        ),
        ToolSpec(
            name: "document_read_deliverable",
            description: "读取已生成文件成果的正文源稿摘要，以便在其基础上修改并生成新版本（v2 / v3）。",
            parameters: ToolSpec.object([
                ("deliverable_id", "string", "document_list_deliverables 返回的 deliverable_id")
            ], required: ["deliverable_id"])
        )
    ]

    static let systemNote = """
    你已配备本地文档生成工作台工具（document_create_docx / document_create_xlsx / document_create_pdf / document_create_file / document_list_deliverables / document_read_deliverable）。当用户要求输出可下载的 Word、Excel、PDF、HTML 或 Markdown 成果文件，或修改此前已生成的交付文件时，请直接调用对应工具生成真实文件（生成的成果会自动以单列文件行展示在回复上方，无需在聊天正文里重复粘贴整份文件全文，只需简洁交代要点与修改处即可）。
    """

    static func activityTitle(for call: ToolCall) -> String {
        let obj = (try? call.argumentObject()) ?? [:]
        let title = (obj["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch call.name {
        case "document_create_docx":
            return title.isEmpty ? "生成 Word 文档" : "生成《\(title).docx》"
        case "document_create_xlsx":
            return title.isEmpty ? "生成 Excel 表格" : "生成《\(title).xlsx》"
        case "document_create_pdf":
            return title.isEmpty ? "生成 PDF 文档" : "生成《\(title).pdf》"
        case "document_create_file":
            let fmt = (obj["format"] as? String ?? "txt").lowercased()
            return title.isEmpty ? "生成文件成果" : "生成《\(title).\(fmt)》"
        case "document_list_deliverables":
            return "查看项目成果文件列表"
        case "document_read_deliverable":
            return "读取已有成果文件原稿"
        default:
            return "处理文档成果"
        }
    }

    static func execute(
        _ call: ToolCall,
        projectID: UUID?,
        threadID: UUID,
        messageID: UUID,
        store: ProjectDeliverableStore
    ) throws -> (output: String, created: ProjectDeliverable?) {
        let obj = try call.argumentObject()
        let baseID = (obj["base_deliverable_id"] as? String).flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        switch call.name {
        case "document_create_docx":
            let title = (obj["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let markdown = (obj["markdown"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !markdown.isEmpty else {
                throw ToolError.invalidArguments("生成 Word 文档需要 title 和 markdown。")
            }
            let circled = (obj["use_circled_footnotes"] as? Bool) ?? true
            let restart = (obj["restart_footnotes_per_page"] as? Bool) ?? true
            let summary = (obj["summary"] as? String) ?? "Word 交付稿"
            let compiled = try DocumentStudioCompiler.compileDOCX(DocxDocumentSpec(
                title: title,
                markdown: markdown,
                useCircledNumbers: circled,
                restartFootnotesPerPage: restart
            ))
            let saved = try store.saveDeliverable(
                projectID: projectID,
                threadID: threadID,
                messageID: messageID,
                title: title,
                format: .docx,
                data: compiled.data,
                sourcePreview: markdown,
                summary: summary,
                footnoteCount: compiled.footnoteCount,
                baseDeliverableID: baseID
            )
            return (
                "已成功生成 Word 文件《\(saved.fileName)》（deliverable_id: \(saved.id.uuidString)，版本 v\(saved.version)，\(saved.characterCount) 字，含 \(saved.footnoteCount) 条真实 Word 页下注，大小 \(saved.byteCount) 字节）。文件已自动附在聊天成果区。",
                saved
            )

        case "document_create_xlsx":
            let title = (obj["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let sheetsRaw = (obj["sheets_json"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !sheetsRaw.isEmpty, let sheetsData = sheetsRaw.data(using: .utf8) else {
                throw ToolError.invalidArguments("生成 Excel 表格需要 title 和有效的 sheets_json。")
            }
            let sheets: [XlsxSheetSpec]
            if let direct = try? JSONDecoder().decode([XlsxSheetSpec].self, from: sheetsData) {
                sheets = direct
            } else if let wrapped = try? JSONDecoder().decode(XlsxWorkbookSpec.self, from: sheetsData) {
                sheets = wrapped.sheets
            } else {
                throw ToolError.invalidArguments("sheets_json 格式无效，请传入包含 name、headers、rows 的 JSON 数组。")
            }
            let summary = (obj["summary"] as? String) ?? "Excel 数据表"
            let compiled = try DocumentStudioCompiler.compileXLSX(XlsxWorkbookSpec(sheets: sheets))
            let preview = sheets.map { s in
                "## \(s.name)\n" + ([s.headers] + s.rows).map { $0.joined(separator: "\t") }.joined(separator: "\n")
            }.joined(separator: "\n\n")
            let saved = try store.saveDeliverable(
                projectID: projectID,
                threadID: threadID,
                messageID: messageID,
                title: title,
                format: .xlsx,
                data: compiled.data,
                sourcePreview: preview,
                summary: summary,
                footnoteCount: 0,
                baseDeliverableID: baseID
            )
            return (
                "已成功生成 Excel 文件《\(saved.fileName)》（deliverable_id: \(saved.id.uuidString)，版本 v\(saved.version)，共 \(compiled.sheetCount) 张工作表、\(compiled.rowCount) 行，大小 \(saved.byteCount) 字节）。文件已自动附在聊天成果区。",
                saved
            )

        case "document_create_pdf":
            let title = (obj["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let markdown = (obj["markdown"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !markdown.isEmpty else {
                throw ToolError.invalidArguments("生成 PDF 需要 title 和 markdown。")
            }
            let summary = (obj["summary"] as? String) ?? "PDF 排版文档"
            let pdfData = try DocumentStudioCompiler.compilePDF(title: title, markdown: markdown)
            let saved = try store.saveDeliverable(
                projectID: projectID,
                threadID: threadID,
                messageID: messageID,
                title: title,
                format: .pdf,
                data: pdfData,
                sourcePreview: markdown,
                summary: summary,
                footnoteCount: 0,
                baseDeliverableID: baseID
            )
            return (
                "已成功生成中文 PDF 文件《\(saved.fileName)》（deliverable_id: \(saved.id.uuidString)，版本 v\(saved.version)，大小 \(saved.byteCount) 字节）。文件已自动附在聊天成果区。",
                saved
            )

        case "document_create_file":
            let title = (obj["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let rawFmt = (obj["format"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let content = (obj["content"] as? String ?? "")
            guard !title.isEmpty, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError.invalidArguments("生成文件需要 title 和非空 content。")
            }
            let format: DeliverableFormat
            switch rawFmt {
            case "html", "htm": format = .html
            case "md", "markdown": format = .md
            case "csv": format = .csv
            default: format = .txt
            }
            let summary = (obj["summary"] as? String) ?? "\(format.displayLabel) 文件"
            let saved = try store.saveDeliverable(
                projectID: projectID,
                threadID: threadID,
                messageID: messageID,
                title: title,
                format: format,
                data: Data(content.utf8),
                sourcePreview: content,
                summary: summary,
                footnoteCount: 0,
                baseDeliverableID: baseID
            )
            return (
                "已成功生成文件《\(saved.fileName)》（deliverable_id: \(saved.id.uuidString)，版本 v\(saved.version)，大小 \(saved.byteCount) 字节）。文件已自动附在聊天成果区。",
                saved
            )

        case "document_list_deliverables":
            let projectOnly = (obj["project_only"] as? Bool) ?? true
            let list = projectOnly && projectID != nil
                ? store.deliverables(forProject: projectID!)
                : store.deliverables(forThread: threadID)
            guard !list.isEmpty else {
                return ("当前还没有已生成的文件成果。", nil)
            }
            let lines = list.prefix(30).map { item in
                "- 《\(item.fileName)》| deliverable_id: \(item.id.uuidString) | \(item.detailedMetaLine)"
            }
            return ("已生成的文件成果（共 \(list.count) 份）：\n" + lines.joined(separator: "\n"), nil)

        case "document_read_deliverable":
            let idStr = (obj["deliverable_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = UUID(uuidString: idStr), let item = store.deliverable(by: id) else {
                throw ToolError.invalidArguments("未找到指定的 deliverable_id。")
            }
            return (
                "《\(item.fileName)》（\(item.detailedMetaLine)）原稿内容：\n\n\(item.sourcePreview)",
                nil
            )

        default:
            throw ToolError.unknownTool(call.name)
        }
    }
}
