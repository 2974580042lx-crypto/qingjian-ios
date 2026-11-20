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
            (#"<[｜|](?:box|det)[｜|]>.*?<[｜|]/(?:box|det)[｜|]>"#, ""),
            (#"<[｜|]ref[｜|]>\s*(?:image|figure|pic|picture|text|title|sub_title|table|table_caption|figure_caption|formula|header|footer|page_number|list|list_item|aside|footnote|插图|图片)\s*<[｜|]/ref[｜|]>"#, ""),
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

enum DeepSeekVisionBridge {
    static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!

    static func requestBody(dataURLs: [String], userPrompt: String = "") throws -> Data {
        let validURLs = dataURLs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !validURLs.isEmpty else {
            throw BridgeError("未找到可识别的图片数据。")
        }

        let promptHint = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseInstruction = """
        请完整、准确地提取并描述用户附带的图片内容（如有多张请按「附图 1」「附图 2」分别列出）：
        1. 逐字完整抄录图中所有可见文字（包括聊天记录、发送人/时间、标题、正文、按钮、数字、表格、注释或标签等），不要遗漏或改写关键信息。
        2. 简明说明图片的主要画面、界面结构、图表数据或场景细节。
        3. 仅陈述图中真实可见的内容；若有模糊不清处请如实说明，不要猜测或编造。
        """
        let fullInstruction = promptHint.isEmpty
            ? baseInstruction
            : baseInstruction + "\n\n用户提问重点：\(promptHint)"

        var contentParts: [[String: Any]] = [
            ["type": "text", "text": fullInstruction]
        ]
        for url in validURLs {
            contentParts.append([
                "type": "image_url",
                "image_url": ["url": url]
            ])
        }

        let payload: [String: Any] = [
            "model": "deepseek-flash",
            "messages": [
                [
                    "role": "user",
                    "content": contentParts
                ]
            ],
            "thinking": ["type": "disabled"],
            "max_tokens": 4096,
            "stream": false
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    static func parseResponse(_ data: Data) throws -> String {
        guard data.count <= 16_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError("图片理解服务返回的数据无法读取。")
        }
        if let err = root["error"] as? [String: Any] {
            let msg = (err["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            throw BridgeError(msg.isEmpty ? "图片理解请求失败，请稍后重试。" : "图片理解请求失败：\(msg)")
        }
        if root["error"] != nil {
            throw BridgeError("图片理解请求失败，请稍后重试。")
        }
        guard let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw BridgeError("图片理解服务返回缺少内容。")
        }

        let rawText: String
        if let str = message["content"] as? String {
            rawText = str
        } else if let parts = message["content"] as? [[String: Any]] {
            rawText = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            rawText = ""
        }

        let cleaned = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw BridgeError("图片理解服务未返回有效内容。")
        }
        return cleaned
    }

    static func describeImages(dataURLs: [String], userPrompt: String = "", key: String) async throws -> String {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            throw BridgeError("缺少 DeepSeek API Key。")
        }

        let body = try requestBody(dataURLs: dataURLs, userPrompt: userPrompt)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        request.timeoutInterval = 60

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 90
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if let _ = try? parseResponse(data) {
                // Unexpected non-2xx with valid content; fall through to parseResponse error/status check.
            } else {
                _ = try parseResponse(data) // Re-throws embedded API error message if present.
            }
            throw BridgeError("图片理解服务请求失败（HTTP \(http.statusCode)）。")
        }
        return try parseResponse(data)
    }

    private struct BridgeError: LocalizedError {
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

struct ImportFailure: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum DocumentTextImporter {
    static let maximumPDFBytes = 30 * 1024 * 1024
    static let maximumTextBytes = 15 * 1024 * 1024
    static let maximumZipBytes = ZipProjectExtractor.maximumZipBytes
    static let maximumIPABytes = StreamZipReader.maximumArchiveBytes
    static let maximumPDFPages = 1000
    static var allowedContentTypes: [UTType] {
        var types: [UTType] = [.data, .text, .sourceCode, .archive, .pdf, .plainText, .json, .xml, .rtf]
        let extraExts = ["ipa", "ips", "crash", "docx", "xlsx", "pptx", "epub", "md", "plist", "pbxproj", "xcconfig", "xcstrings", "yaml", "yml", "toml", "log"]
        for ext in extraExts {
            if let ut = UTType(filenameExtension: ext) { types.append(ut) }
        }
        return types
    }

    private static let developerAndTextExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "csv", "tsv", "log", "ips", "crash",
        "json", "jsonl", "yaml", "yml", "toml", "ini", "cfg", "conf", "env",
        "xml", "html", "htm", "css", "scss", "less", "tex", "svg",
        "plist", "entitlements", "pbxproj", "xcconfig", "strings", "xcstrings",
        "patch", "diff", "sql", "graphql", "proto",
        "swift", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "vue", "svelte",
        "go", "rs", "c", "cpp", "cc", "cxx", "h", "hpp", "m", "mm",
        "java", "kt", "kts", "cs", "rb", "php", "sh", "zsh", "bash", "ps1",
        "lua", "r", "dart", "ex", "exs", "hs", "ml", "zig"
    ]

    private static let extensionlessTextNames: Set<String> = [
        "dockerfile", "makefile", "podfile", "gemfile", "rakefile", "brewfile",
        "procfile", "readme", "license", "changelog", ".gitignore", ".gitattributes", ".editorconfig"
    ]

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
        let fileNameLower = url.lastPathComponent.lowercased()
        let isPDF = ext == "pdf"
        let isIPA = ext == "ipa"
        let isZIP = ext == "zip"
        let isOfficeOrEbook = ["docx", "xlsx", "pptx", "rtf", "epub"].contains(ext)
        let isSupportedText = ext.isEmpty || developerAndTextExtensions.contains(ext) || extensionlessTextNames.contains(fileNameLower)

        guard isPDF || isIPA || isZIP || isOfficeOrEbook || isSupportedText else {
            throw ImportFailure("暂不支持 .\(ext) 格式；支持代码/日志/配置、PDF、IPA、ZIP、Word/Excel/PPT、RTF 和 EPUB。")
        }

        let originalName = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String((originalName.isEmpty ? "导入的资料" : originalName).prefix(200))
        var warnings: [String] = originalName.count > 200 ? ["资料名称超过200字，已缩短名称；正文未截断。"] : []

        // Streaming path for .ipa and .zip so large archives never load completely into memory.
        if isIPA || isZIP {
            let limit = isIPA ? maximumIPABytes : maximumZipBytes
            var coordinatedError: NSError?
            var result: Result<ImportedTextDocument, Error>?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatedError) { local in
                result = Result {
                    let info = try local.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                    guard info.isDirectory != true else { throw ImportFailure("请选择文件，不能导入文件夹。") }
                    guard (info.fileSize ?? 0) <= limit else {
                        let mb = limit / (1024 * 1024)
                        throw ImportFailure(isIPA ? "IPA 超过 \(mb) MB 上限。" : "ZIP 超过 \(mb) MB 上限。")
                    }
                    if isIPA {
                        return try IPAAnalyzer.analyze(url: local)
                    } else {
                        return try ZipProjectExtractor.extract(url: local, maxCharacters: min(maxCharacters, ZipProjectExtractor.defaultCharacterBudget))
                    }
                }
            }
            if let coordinatedError { throw ImportFailure("文件未能读取，请确认云盘文件已下载：\(coordinatedError.localizedDescription)") }
            guard let result else { throw ImportFailure("没有读到文件内容，请从「文件」App下载后重试。") }
            var doc = try result.get()
            doc = ImportedTextDocument(name: doc.name, text: doc.text, warnings: warnings + doc.warnings)
            return doc
        }

        let isStreamableOOXML = (ext == "docx" || ext == "xlsx" || ext == "pptx")
        if isStreamableOOXML {
            var coordinatedError: NSError?
            var streamResult: Result<String, Error>?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatedError) { local in
                streamResult = Result {
                    let info = try local.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                    guard info.isDirectory != true else { throw ImportFailure("请选择文件，不能导入文件夹。") }
                    let size = info.fileSize ?? 0
                    guard size > 0 else { throw ImportFailure("这个文件是空的。") }
                    guard size <= maximumTextBytes else { throw oversized(false) }
                    switch ext {
                    case "docx": return try OfficeAndDocumentExtractor.extractDOCX(url: local)
                    case "xlsx": return try OfficeAndDocumentExtractor.extractXLSX(url: local)
                    case "pptx": return try OfficeAndDocumentExtractor.extractPPTX(url: local)
                    default: throw ImportFailure("不支持的文档格式。")
                    }
                }
            }
            if let coordinatedError { throw ImportFailure("文件未能读取，请确认云盘文件已下载：\(coordinatedError.localizedDescription)") }
            guard let streamResult else { throw ImportFailure("没有读到文件内容，请从「文件」App下载后重试。") }
            let extractedText = try streamResult.get()
            try Task.checkCancellation()
            let (finalText, truncWarning) = trimHeadTailIfNeeded(extractedText, maxCharacters: maxCharacters)
            if let truncWarning { warnings.append(truncWarning) }
            return ImportedTextDocument(name: name, text: finalText, warnings: warnings)
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

        if isOfficeOrEbook {
            let extractedText: String
            switch ext {
            case "docx": extractedText = try OfficeAndDocumentExtractor.extractDOCX(data)
            case "xlsx": extractedText = try OfficeAndDocumentExtractor.extractXLSX(data)
            case "pptx": extractedText = try OfficeAndDocumentExtractor.extractPPTX(data)
            case "rtf": extractedText = try OfficeAndDocumentExtractor.extractRTF(data)
            case "epub":
                let epub = try OfficeAndDocumentExtractor.extractEPUB(data)
                extractedText = epub.text
            default:
                throw ImportFailure("不支持的文档格式。")
            }
            let (finalText, truncWarning) = trimHeadTailIfNeeded(extractedText, maxCharacters: maxCharacters)
            if let truncWarning { warnings.append(truncWarning) }
            return ImportedTextDocument(name: name, text: finalText, warnings: warnings)
        }

        let hasPDFHeader = data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
        if isPDF && !hasPDFHeader { throw ImportFailure("这个文件没有有效的PDF文件头，请确认已下载完整，且不是改了扩展名的其他文件。") }
        if !isPDF && hasPDFHeader { throw ImportFailure("文件内容实际是PDF，请使用.pdf扩展名后再导入。") }
        if isPDF {
            let extracted = try await readPDF(data, name: name, maxCharacters: maxCharacters, apiKey: apiKey)
            warnings += extracted.warnings
            return ImportedTextDocument(name: name, text: extracted.text, warnings: warnings)
        }

        // Binary plist (.plist / .ips / .mobileprovision etc.)
        if data.starts(with: Array("bplist00".utf8)) {
            let xml = try OfficeAndDocumentExtractor.decodeBinaryPlist(data)
            let (finalText, truncWarning) = trimHeadTailIfNeeded(xml, maxCharacters: maxCharacters)
            if let truncWarning { warnings.append(truncWarning) }
            warnings.append("检测到二进制 plist，已自动转换为 XML 文本。")
            return ImportedTextDocument(name: name, text: finalText, warnings: warnings)
        }

        guard !data.starts(with: [0x50, 0x4B, 0x03, 0x04]), !data.starts(with: Array("{\\rtf".utf8)),
              let decoded = BookText.decode(data) else {
            throw ImportFailure("无法按文字读取此文件。支持代码、日志、PDF、IPA、ZIP、Office 文档及 UTF-8/UTF-16/GB18030/Big5 文字。")
        }
        let normalized = decoded.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0.value != 9 && $0.value != 10 }) else {
            throw ImportFailure("文件中包含无法作为正文读取的二进制控制字符，请检查文件格式。")
        }
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportFailure("文件没有可导入的文字。") }

        let (text, truncWarning) = trimHeadTailIfNeeded(normalized, maxCharacters: maxCharacters)
        if let truncWarning { warnings.append(truncWarning) }

        let prefix = [UInt8](data.prefix(3))
        if String(data: data, encoding: .utf8) == nil,
           !prefix.starts(with: [0xFF, 0xFE]), !prefix.starts(with: [0xFE, 0xFF]) {
            warnings.append("已按常见中文旧编码读取，请打开资料核对文字。")
        }
        return ImportedTextDocument(name: name, text: text, warnings: warnings)
    }

    private static func trimHeadTailIfNeeded(_ text: String, maxCharacters: Int) -> (String, String?) {
        guard text.count > maxCharacters else { return (text, nil) }
        let headCount = max(200, maxCharacters * 45 / 100)
        let tailCount = max(200, maxCharacters * 50 / 100)
        let omitted = text.count - headCount - tailCount
        let marker = "\n\n... [原文件共 \(text.count.formatted()) 字，已自动省略中间 \(omitted.formatted()) 字，保留头尾关键内容] ...\n\n"
        let trimmed = String(text.prefix(headCount)) + marker + String(text.suffix(tailCount))
        return (trimmed, "文件正文共 \(text.count.formatted()) 字，超过单份 \(maxCharacters.formatted()) 字上限，已自动保留头尾关键段。")
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
        ImportFailure(isPDF ? "PDF超过30 MB，请压缩或拆分后导入。" : "文件超过15 MB，请按所需章节拆分后导入。")
    }
    private static func tooLong(_ limit: Int) -> ImportFailure {
        ImportFailure("提取内容超过可导入的\(limit.formatted())字，请拆分或缩短后重试；内容没有被截断。")
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
