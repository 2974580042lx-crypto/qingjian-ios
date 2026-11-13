import Foundation
import PDFKit
import UniformTypeIdentifiers

// A local text copy; the original file is not attached to requests or kept in the backup.
struct ImportedTextDocument: Sendable {
    let name: String
    let text: String
    let warnings: [String]
}

enum DeepSeekOCRProtocol {
    static let endpoint = URL(string: "https://api.deepseek.com/v1/tools/ocr")!

    static func multipartBody(data: Data, fileName: String, mimeType: String,
                              purpose: String = "text_recognition", boundary: String) -> Data {
        var body = Data()
        let safeFileName = fileName
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        func append(_ string: String) {
            body.append(Data(string.utf8))
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"purpose\"\r\n\r\n")
        append("\(purpose)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFileName)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    static func cleanOCRText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for (pattern, template) in [
            (#"<[｜|]box[｜|]>.*?<[｜|]/box[｜|]>"#, ""),
            (#"<[｜|]ref[｜|]>\s*(?:image|figure|pic|picture|插图|图片)\s*<[｜|]/ref[｜|]>"#, ""),
            (#"<[｜|]/?ref[｜|]>"#, ""),
            (#"<[｜|][^>\n]{1,40}[｜|]>"#, "")
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
            }
        }
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(_ data: Data) throws -> [Int: String] {
        guard data.count <= 32_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OCRError("OCR 返回的数据无法读取，请稍后重试。")
        }
        if let err = root["error"] as? [String: Any] {
            let msg = (err["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            throw OCRError(msg.isEmpty ? "OCR 识别未完成，请稍后重试。" : "OCR 识别失败：\(msg)")
        }
        if root["error"] != nil {
            throw OCRError("OCR 识别未完成，请稍后重试。")
        }
        guard let pages = root["pages"] as? [[String: Any]] else {
            throw OCRError("OCR 返回结果缺少页面内容。")
        }
        var output: [Int: String] = [:]
        for page in pages {
            guard let index = page["index"] as? Int,
                  let rawText = page["text"] as? String else { continue }
            output[index] = cleanOCRText(rawText)
        }
        return output
    }

    fileprivate struct OCRError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

final class DeepSeekOCRClient: @unchecked Sendable {
    func recognize(data: Data, fileName: String, mimeType: String,
                   purpose: String = "text_recognition", key: String) async throws -> [Int: String] {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            throw DeepSeekOCRProtocol.OCRError("未配置 DeepSeek API Key，无法执行 OCR 识别。")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 190
        config.urlCache = nil
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let boundary = "DeepSeekOCR-" + UUID().uuidString
        var request = URLRequest(url: DeepSeekOCRProtocol.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = DeepSeekOCRProtocol.multipartBody(
            data: data,
            fileName: fileName,
            mimeType: mimeType,
            purpose: purpose,
            boundary: boundary
        )
        try Task.checkCancellation()
        let (responseData, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw DeepSeekOCRProtocol.OCRError("OCR 服务没有返回有效响应。")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let root = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let err = root["error"] as? [String: Any],
               let msg = err["message"] as? String, !msg.isEmpty {
                throw DeepSeekOCRProtocol.OCRError("OCR 识别失败（HTTP \(http.statusCode)）：\(msg)")
            }
            throw DeepSeekOCRProtocol.OCRError("OCR 识别失败（HTTP \(http.statusCode)）。")
        }
        return try DeepSeekOCRProtocol.parse(responseData)
    }
}

enum DocumentTextImporter {
    static let maximumPDFBytes = 30 * 1024 * 1024
    static let maximumTextBytes = 2 * 1024 * 1024
    static let maximumPDFPages = 1000
    static var allowedContentTypes: [UTType] {
        [.pdf, .plainText, .text, .json, UTType(filenameExtension: "md") ?? .plainText]
    }

    static func load(_ url: URL, maxCharacters: Int = ChatProject.documentCharacterLimit,
                     apiKey: String = "") async throws -> ImportedTextDocument {
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated) {
            try await read(url, maxCharacters: maxCharacters, apiKey: apiKey)
        }
        return try await withTaskCancellationHandler(operation: {
            let document = try await work.value
            try Task.checkCancellation()
            return document
        }, onCancel: { work.cancel() })
    }

    private static func read(_ url: URL, maxCharacters: Int, apiKey: String) async throws -> ImportedTextDocument {
        guard maxCharacters > 0 else { throw ImportFailure("可导入字数不足，请先缩短当前内容。") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let ext = url.pathExtension.lowercased()
        let isPDF = ext == "pdf"
        let textExtensions: Set<String> = ["txt", "text", "md", "markdown", "csv", "tsv", "log", "json", "yaml", "yml", "xml", "html", "htm", "tex", "swift", "py", "js", "ts", "css", "sql"]
        guard isPDF || ext.isEmpty || textExtensions.contains(ext) else {
            throw ImportFailure("目前支持PDF和TXT、Markdown等纯文本资料，请把此格式先导出为PDF或TXT。")
        }
        let limit = isPDF ? maximumPDFBytes : maximumTextBytes
        var coordinatedError: NSError?
        var result: Result<Data, Error>?
        // File-provider URLs may still need to download. Coordinate off the main thread.
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatedError) { local in
            result = Result {
                let info = try local.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                guard info.isDirectory != true else { throw ImportFailure("请选择文件，不能导入文件夹。") }
                guard (info.fileSize ?? 0) <= limit else { throw oversized(isPDF) }
                let data = try Data(contentsOf: local, options: .mappedIfSafe)
                guard data.count <= limit else { throw oversized(isPDF) }
                return data
            }
        }
        if let coordinatedError { throw ImportFailure("文件未能读取，请确认云盘文件已下载：\(coordinatedError.localizedDescription)") }
        guard let result else { throw ImportFailure("没有读到文件内容，请从「文件」App下载后重试。") }
        let data = try result.get()
        try Task.checkCancellation()
        guard !data.isEmpty else { throw ImportFailure("这个文件是空的。") }
        let hasPDFHeader = data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
        if isPDF && !hasPDFHeader { throw ImportFailure("这个文件没有有效的PDF文件头，请确认已下载完整，且不是改了扩展名的其他文件。") }
        if !isPDF && hasPDFHeader { throw ImportFailure("文件内容实际是PDF，请使用.pdf扩展名后再导入。") }
        let originalName = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String((originalName.isEmpty ? "导入的资料" : originalName).prefix(200))
        var warnings: [String] = originalName.count > 200 ? ["资料名称超过200字，已缩短名称；正文未截断。"] : []
        if isPDF {
            let extracted = try await readPDF(data, name: name, maxCharacters: maxCharacters, apiKey: apiKey)
            warnings += extracted.warnings
            return ImportedTextDocument(name: name, text: extracted.text, warnings: warnings)
        }
        guard !data.starts(with: [0x50, 0x4B, 0x03, 0x04]), !data.starts(with: Array("{\\rtf".utf8)),
              let decoded = BookText.decode(data) else {
            throw ImportFailure("无法按文字读取此文件。支持PDF、TXT、Markdown及常见UTF-8、UTF-16、GB18030、Big5文字；请将其他文档先导出为PDF或TXT。")
        }
        let text = decoded.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0.value != 9 && $0.value != 10 }) else {
            throw ImportFailure("文件中包含无法作为正文读取的内容，请导出为UTF-8的TXT或Markdown后重试。")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportFailure("文件没有可导入的文字。") }
        guard text.count <= maxCharacters else { throw tooLong(maxCharacters) }
        let prefix = [UInt8](data.prefix(3))
        if String(data: data, encoding: .utf8) == nil,
           !prefix.starts(with: [0xFF, 0xFE]), !prefix.starts(with: [0xFE, 0xFF]) {
            warnings.append("已按常见中文旧编码读取，请打开资料核对文字。")
        }
        return ImportedTextDocument(name: name, text: text, warnings: warnings)
    }

    private static func readPDF(_ data: Data, name: String, maxCharacters: Int, apiKey: String) async throws -> (text: String, warnings: [String]) {
        guard let pdf = PDFDocument(data: data) else { throw ImportFailure("无法打开这个PDF，文件可能未下载完整或已经损坏。") }
        guard !pdf.isLocked else { throw ImportFailure("这个PDF需要密码。请先解锁并另存一份可打开的PDF，再导入。") }
        guard pdf.allowsCopying else { throw ImportFailure("这个PDF限制文字复制，无法提取正文；请使用允许提取文字的版本。") }
        guard pdf.pageCount > 0 else { throw ImportFailure("这个PDF没有页面。") }
        guard pdf.pageCount <= maximumPDFPages else { throw ImportFailure("PDF超过1000页，请先按所需章节拆分后导入。") }

        var pageTexts: [String?] = Array(repeating: nil, count: pdf.pageCount)
        var emptyPages: [Int] = []
        var textPages = 0
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: index) else { throw ImportFailure("PDF第\(index + 1)页未能读取，请重新导出PDF后重试。") }
            let pageText = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if pageText.isEmpty {
                emptyPages.append(index + 1)
            } else {
                textPages += 1
                pageTexts[index] = pageText
            }
        }

        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var warnings: [String] = []

        if textPages == 0 {
            guard !cleanKey.isEmpty else {
                throw ImportFailure("这个PDF没有可提取的文字，可能是扫描件。请先配置 DeepSeek API Key 开启自动 OCR，或先做文字识别后再导入。")
            }
            let ocrPages = try await DeepSeekOCRClient().recognize(
                data: data,
                fileName: "\(name).pdf",
                mimeType: "application/pdf",
                key: cleanKey
            )
            var recognized = 0
            emptyPages = []
            for index in 0..<pdf.pageCount {
                let text = (ocrPages[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    emptyPages.append(index + 1)
                } else {
                    recognized += 1
                    pageTexts[index] = text
                }
            }
            guard recognized > 0 else {
                throw ImportFailure("这个PDF没有识别出可读取的文字，可能全是空白页或图像过模糊。")
            }
            warnings.append("未检测到内置文字层，已通过 DeepSeek OCR 自动识别文字（\(recognized)/\(pdf.pageCount) 页）。")
        } else if emptyPages.count > textPages && !cleanKey.isEmpty {
            do {
                let ocrPages = try await DeepSeekOCRClient().recognize(
                    data: data,
                    fileName: "\(name).pdf",
                    mimeType: "application/pdf",
                    key: cleanKey
                )
                var filled = 0
                var remainingEmpty: [Int] = []
                for index in 0..<pdf.pageCount {
                    if let existing = pageTexts[index], !existing.isEmpty { continue }
                    let text = (ocrPages[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty {
                        remainingEmpty.append(index + 1)
                    } else {
                        pageTexts[index] = text
                        filled += 1
                    }
                }
                emptyPages = remainingEmpty
                if filled > 0 {
                    warnings.append("部分页面无内置文字层，已通过 DeepSeek OCR 补充识别 \(filled) 页。")
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
            }
        }

        let heading = "【PDF文字资料】\n以下页码为PDF文件中的物理页序，从1开始，不等同于书中印刷页码。文字提取可能改变多栏、表格及脚注的阅读顺序，请按页回到原文件核对。"
        var parts = [heading]
        var characterCount = heading.count
        for index in 0..<pdf.pageCount {
            let content = pageTexts[index] ?? "[本页没有可提取文字，可能是扫描页、图片或空白页。]"
            let section = "【PDF第\(index + 1)页】\n\(content)"
            characterCount += section.count + 2
            guard characterCount <= maxCharacters else { throw tooLong(maxCharacters) }
            parts.append(section)
        }
        if !emptyPages.isEmpty {
            warnings.append("共\(pdf.pageCount)页，其中\(emptyPages.count)页没有提取到文字，正文已按页标注；这份资料不是完整逐页转写。")
        }
        return (parts.joined(separator: "\n\n"), warnings)
    }

    private static func oversized(_ isPDF: Bool) -> ImportFailure {
        ImportFailure(isPDF ? "PDF超过30 MB，请压缩或拆分后导入。" : "文字文件超过2 MB，请按所需章节拆分后导入。")
    }
    private static func tooLong(_ limit: Int) -> ImportFailure {
        ImportFailure("提取内容超过可导入的\(limit.formatted())字，请拆分或缩短后重试；内容没有被截断。")
    }
    private struct ImportFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

// A text the project hands to the model with every request, switched on or off one by one.
struct ProjectDocument: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var text: String
    var isIncluded = true
}

struct ChatProject: Identifiable, Codable, Equatable, Sendable {
    // Included documents travel with every request, so their size is capped.
    static let documentCharacterLimit = 100_000
    var id = UUID()
    var name: String
    var instructions = ""
    var documents: [ProjectDocument] = []
    // Defaults applied when a new conversation starts inside the project.
    var model: DeepSeekModel?
    var thinkingEnabled: Bool?
    var effort: ThinkingEffort?
    var isLocked = false
    var createdAt = Date()
    // Optional: projects saved by 1.5.0 have no such key. Pinned projects fold out in the sidebar.
    var isPinned: Bool?
    var updatedAt = Date()
    // Added in 1.5.2, all optional so saved 1.5.x projects still load.
    var provider: AIProvider?
    var subscriptionModel: String?
    var subscriptionEffort: SubscriptionEffort?
    // Memory: points the project's model keeps across conversations. ChatGPT projects write it
    // automatically unless switched off; DeepSeek projects only once switched on (1.25), so
    // one-scene role-play projects never carry anything from one chat into the next.
    var autoMemory: Bool?
    var memory: String?
    var memoryUpdatedAt: Date?
    // Thread id → number of messages already folded into the memory.
    var memorizedCounts: [String: Int]?
    static let memoryCharacterLimit = 4000
    // Google Drive tools (1.5.8). Off unless switched on; DeepSeek projects only.
    var driveTools: Bool?
    // GitHub tools and noticing time passing (1.6.0), both off unless switched on.
    var githubTools: Bool?
    var timeAwareness: Bool?
    // The model's own web search and page reading.
    var webTools: Bool?
    var studySubject: StudySubject?
    // Pure role-play mode (1.37): keeps persona instructions, documents, memory, and time awareness,
    // while omitting external tools, built-in manual notes, and historical reasoning echo.
    var pureRoleplay: Bool?

    var service: AIProvider { provider ?? .deepSeek }
    var usesDriveTools: Bool { driveTools == true }
    var usesGitHubTools: Bool { githubTools == true }
    var usesWebTools: Bool { webTools == true }
    var isPureRoleplay: Bool { studySubject == nil && id != AppManual.projectID && pureRoleplay == true }
    var remembers: Bool { studySubject == nil && (service == .chatGPT ? autoMemory != false : autoMemory == true) }
    var includedCharacters: Int { documents.filter(\.isIncluded).reduce(0) { $0 + $1.text.count } }

    // Conversations in a project use only this, never the global prompt.
    var systemPrompt: String {
        composedPrompt(instructions: instructions)
    }

    /// Only user-authored instructions are templates; reference documents and
    /// saved memory must retain their literal braces (including the manual).
    func systemPrompt(resolving context: PromptVariables.Context, instructionsOverride: String? = nil) -> String {
        composedPrompt(instructions: PromptVariables.apply(instructionsOverride ?? instructions, context))
    }

    private func composedPrompt(instructions: String) -> String {
        var parts: [String] = []
        let clean = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { parts.append(clean) }
        let included = documents.filter { $0.isIncluded && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !included.isEmpty {
            parts.append("以下是这个项目的资料，回答时可以参考：")
            for document in included { parts.append("《\(document.name)》\n\(document.text)") }
        }
        if studySubject == nil, let memory = memory?.trimmingCharacters(in: .whitespacesAndNewlines), !memory.isEmpty {
            parts.append("以下是这个项目以往对话里记下的要点，回答时可以参考，不必复述：\n\(memory)")
        }
        return parts.joined(separator: "\n\n")
    }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              instructions.count <= 20000, documents.count <= 50,
              (memory ?? "").count <= Self.memoryCharacterLimit,
              Set(documents.map(\.id)).count == documents.count,
              documents.allSatisfy({ $0.name.count <= 200 && $0.text.count <= Self.documentCharacterLimit }),
              includedCharacters <= Self.documentCharacterLimit else {
            throw ChatError.invalidBackup("备份中有项目的名称、指令或资料不符合要求。")
        }
    }
}

// Markdown copy of one conversation, for sharing or handing to another tool.
enum ConversationExport {
    static func markdown(_ thread: ChatThread, userName: String) -> String {
        var lines = ["# \(thread.title)", "", thread.createdAt.formatted(date: .long, time: .shortened), ""]
        for message in thread.messages where !message.content.isEmpty {
            if let character = message.discussionCharacter {
                lines.append(message.role == .user ? "**\(userName) · 问\(character)**" : "**\(character) · 角色回答（依据原文演绎）**")
            } else {
                lines.append(message.role == .user ? "**\(userName)**" : "**Sermo**")
            }
            lines.append("")
            lines.append(message.content)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func fileName(for thread: ChatThread) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r")
        let base = thread.title.components(separatedBy: banned).joined().trimmingCharacters(in: .whitespaces)
        return String((base.isEmpty ? "对话" : base).prefix(40)) + ".md"
    }
}
