import Foundation

enum DeliverableToolsUnavailableReason: Equatable, Sendable {
    case pureRoleplay
    case chatOnlyPolicy
    case providerToolsDisabled(AIProvider)

    var honestUserGuidance: String {
        switch self {
        case .pureRoleplay:
            return "当前对话已开启「纯角色扮演模式」，系统已屏蔽所有文件生成与外部工具。请点对话右上角「⋯」（或项目主页「⋯ → 编辑详情」）关闭「纯角色扮演模式」后再让我生成可下载文件。"
        case .chatOnlyPolicy:
            return "当前对话的工具权限设为「仅纯聊天」，暂时无法调用文件生成工具。请点输入框左下角「+ → 权限」切回「自动」后再试。"
        case .providerToolsDisabled(let provider):
            return "当前「\(provider.title)」通道在设置中关闭了工具调用功能，无法生成真实附件。请到「设置」中开启该通道的工具支持，或切换到 ChatGPT 订阅 / DeepSeek。"
        }
    }
}

/// Deterministic intent router and turn-level directive generator for real deliverable creation
/// (`.docx`, `.xlsx`, `.pdf`). Counters LLM pre-training refusals ("无法发送 .docx 附件") and
/// drives automatic corrective retry in `AppStore.runToolLoop` when a model forgets to call the tool.
enum DocumentDeliverableRouter {
    private static let creationVerbs: [String] = [
        "生成", "创建", "导出", "输出", "交付", "制作", "写一份", "做一份", "出一份",
        "整理成", "整理为", "保存为", "存为", "存成", "转换成", "转为", "转成",
        "给我一份", "给我一个", "发我一份", "发给我", "帮我写", "帮我做", "帮我出",
        "改一版", "修订", "继续修改", "重新生成", "直接下载", "可下载",
        "create", "generate", "export", "build", "make a", "save as", "deliver"
    ]

    private static let purelyExplanatoryGuards: [String] = [
        "什么是", "什么意思", "怎么打开", "如何打开", "打不开", "怎么转", "如何把", "教程", "区别是什么"
    ]

    /// Detects when the user's message explicitly requests creating/delivering a real `.docx`, `.xlsx`, or `.pdf` file.
    static func detectExplicitRequest(in rawUserText: String) -> DeliverableFormat? {
        let docFree = PendingDocumentCodec.extractEditableUserText(rawUserText)
        let quoteFree = MessageQuoteCodec.decode(docFree).userText
        let text = quoteFree.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let lower = text.lowercased()
        let hasVerb = creationVerbs.contains { lower.contains($0) }
        guard hasVerb else { return nil }

        // Avoid firing on pure how-to / conceptual questions unless a concrete filename or delivery request is present.
        let hasExplicitFilename = lower.contains(".docx") || lower.contains(".xlsx") || lower.contains(".pdf")
            || lower.contains("可下载") || lower.contains("真实文件") || lower.contains("项目成果")
        if !hasExplicitFilename && purelyExplanatoryGuards.contains(where: { lower.contains($0) }) {
            return nil
        }

        // Order: explicit extension first, then format keywords
        if lower.contains(".docx") || lower.contains("docx") || lower.contains("word文档")
            || lower.contains("word 文档") || lower.contains("word文件") || lower.contains("word 文件")
            || (lower.contains("word") && (lower.contains("生成") || lower.contains("导出") || lower.contains("交付") || lower.contains("下载") || lower.contains("写一份") || lower.contains("做一份") || lower.contains("保存为"))) {
            return .docx
        }
        if lower.contains(".xlsx") || lower.contains("xlsx") || lower.contains("excel")
            || lower.contains("电子表格") || lower.contains("表格文件") {
            return .xlsx
        }
        if lower.contains(".pdf") || (lower.contains("pdf") && (lower.contains("生成") || lower.contains("导出") || lower.contains("交付") || lower.contains("下载") || lower.contains("制作") || lower.contains("整理成") || lower.contains("保存为") || lower.contains("输出") || lower.contains("写一份") || lower.contains("做一份"))) {
            return .pdf
        }
        return nil
    }

    static func toolName(for format: DeliverableFormat) -> String {
        switch format {
        case .docx: return "document_create_docx"
        case .xlsx: return "document_create_xlsx"
        case .pdf: return "document_create_pdf"
        case .html, .md, .txt, .csv: return "document_create_file"
        }
    }

    /// Authoritative turn-level instruction prefixed right beside the user's prompt (request-only, never stored).
    static func turnLevelDirective(for format: DeliverableFormat, isProjectChat: Bool, hasProjectDocs: Bool) -> String {
        let tool = toolName(for: format)
        let ext = format.fileExtension
        let formatRule: String
        switch format {
        case .docx:
            formatRule = "请直接调用 `document_create_docx(title: \"...\", markdown: \"...\")` 生成真实可下载的 `.docx` Word 文件（支持标题、正文、表格与 `[^1]` 真实 Word 页下注）。"
        case .xlsx:
            formatRule = "请直接调用 `document_create_xlsx(title: \"...\", sheets_json: \"[...]\")` 生成真实可下载的多工作表 `.xlsx` Excel 文件。"
        case .pdf:
            formatRule = "请直接调用 `document_create_pdf(title: \"...\", markdown: \"...\")` 生成真实可下载的中文排版 `.pdf` 文件。"
        default:
            formatRule = "请直接调用 `document_create_file(title: \"...\", format: \"\(ext)\", content: \"...\")` 生成真实可下载的文件。"
        }

        let projectNote: String
        if isProjectChat {
            let docsStep = hasProjectDocs
                ? "若本轮需要引用当前项目的资料，请先用 `project_list_docs` / `project_search_docs`（或项目上下文已附资料）核对内容，再调用 `\(tool)`。"
                : ""
            projectNote = "\(docsStep)调用 `\(tool)` 后，Sermo 会自动把真实 `.\(ext)` 文件归档到「项目成果」并支持后续对话继续迭代 v1 → v2。"
        } else {
            projectNote = "调用 `\(tool)` 后，Sermo 会直接在回复上方渲染可点击预览、分享与导出的真实 `.\(ext)` 附件卡片。"
        }

        return """
        【Sermo 本地文件编译引擎已就绪 · 必选动作】
        本客户端已挂载真实的本地文件生成工具 `\(tool)`，完全支持向用户直接交付可下载的 `.\(ext)` 真实附件。
        \(formatRule)
        \(projectNote)
        硬性禁止：
        1. 严禁声称「当前聊天无法发送可下载的 .\(ext) 附件」或「本环境不支持导出文件」。
        2. 严禁只输出 HTML 预览代码块或纯文字来冒充 `.\(ext)` 文件，也严禁让用户自己复制到 Word/Excel。
        3. 收到工具成功回执后，只需在正文中用简明中文交代文档要点即可，不必重复粘贴整篇长文。
        """
    }

    /// Corrective nudge used inside `runToolLoop` if the model still skipped calling the real tool on Round 0.
    static func correctiveRetryDirective(for format: DeliverableFormat) -> String {
        let tool = toolName(for: format)
        let ext = format.fileExtension
        return """
        【系统纠偏：尚未调用真实文件工具】
        你刚才的回复没有调用 `\(tool)`，也没有生成任何 `.\(ext)` 文件。请不要输出 HTML 预览，也不要告诉用户无法发送附件或让用户自己复制。
        请**立刻调用 `\(tool)` 工具**（传入规范的 `title` 与完整内容参数），等待工具返回成功回执后再给用户一句简明的交付说明。
        """
    }

    static func toolsUnavailableSystemNote(for format: DeliverableFormat, reason: DeliverableToolsUnavailableReason) -> String {
        """
        【能力边界如实告知】
        用户请求生成可下载的 `.\(format.fileExtension)` 真实文件，但本对话当前未开启工具调用。原因：\(reason.honestUserGuidance)
        请如实向用户转达上述具体原因和开启路径，切勿虚构或假装已经生成了文件。
        """
    }
}
