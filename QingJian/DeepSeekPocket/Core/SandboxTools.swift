import Foundation

enum SandboxAction: Equatable, Sendable {
    case runJS(code: String, inputJSON: String?)
    case verifyHTML(html: String)

    static let maxCodeCharacters = 120_000

    init(_ call: ToolCall) throws {
        let obj = try call.argumentObject()
        switch call.name {
        case "sandbox_run_js":
            let code = (obj["code"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else {
                throw ToolError.invalidArguments("sandbox_run_js 缺少要执行的 JavaScript 代码 code。")
            }
            guard code.count <= Self.maxCodeCharacters else {
                throw ToolError.invalidArguments("JavaScript 代码超过长度上限。")
            }
            let input = (obj["input_json"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            self = .runJS(code: code, inputJSON: input?.isEmpty == false ? input : nil)

        case "sandbox_verify_html":
            let html = (obj["html"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !html.isEmpty else {
                throw ToolError.invalidArguments("sandbox_verify_html 缺少要验证的 html 内容。")
            }
            guard html.count <= Self.maxCodeCharacters * 2 else {
                throw ToolError.invalidArguments("HTML 内容超过自检体积上限。")
            }
            self = .verifyHTML(html: html)

        default:
            throw ToolError.unknownTool(call.name)
        }
    }

    var activityTitle: String {
        switch self {
        case .runJS: return "在隔离沙盒中执行计算脚本"
        case .verifyHTML: return "在隔离沙盒中渲染自检 HTML 页面"
        }
    }
}

struct SandboxExecutionReport: Codable, Equatable, Sendable {
    var ok: Bool
    var timedOut: Bool = false
    var resultJSON: String?
    var logs: [String] = []
    var errors: [String] = []
    var metricsSummary: String?

    func formattedForModel() -> String {
        var parts: [String] = []
        if timedOut {
            parts.append("【执行超时已熔断】脚本运行超过 5 秒上限，隔离沙盒进程已安全销毁。请优化循环或缩小数据规模。")
        } else {
            parts.append(ok ? "【沙盒执行通过】" : "【沙盒检测到错误】")
        }
        if let resultJSON, !resultJSON.isEmpty {
            parts.append("返回值：\n\(String(resultJSON.prefix(8000)))")
        }
        if !logs.isEmpty {
            parts.append("控制台输出：\n" + logs.prefix(30).joined(separator: "\n"))
        }
        if !errors.isEmpty {
            parts.append("发现的问题：\n" + errors.prefix(20).map { "- \($0)" }.joined(separator: "\n"))
        }
        if let metricsSummary, !metricsSummary.isEmpty {
            parts.append("渲染检查：\(metricsSummary)")
        }
        return parts.joined(separator: "\n\n")
    }
}

enum SandboxTools {
    static let names: Set<String> = ["sandbox_run_js", "sandbox_verify_html"]

    static let specs: [ToolSpec] = [
        ToolSpec(
            name: "sandbox_run_js",
            description: "在完全断网、带 5 秒强熔断保护的本地 JavaScript 沙盒中执行精确数值计算、统计汇总、日期换算、JSON/CSV 数据处理或公式验算。脚本内可用 `input`（解析自 input_json）、`console.log(...)` 并通过 `return ...` 返回结果。",
            parameters: ToolSpec.object([
                ("code", "string", "JavaScript 函数体代码（可直接 return 计算结果）"),
                ("input_json", "string", "可选：JSON 字符串，传入后作为变量 input 供脚本读取")
            ], required: ["code"])
        ),
        ToolSpec(
            name: "sandbox_verify_html",
            description: "将即将交付给用户的 HTML/SVG 页面放入离屏安全沙盒加载并执行脚本自检，捕获 JS 运行报错、未捕获异常与空白渲染，便于交付前先修好。",
            parameters: ToolSpec.object([
                ("html", "string", "完整的 HTML 或 SVG 源码")
            ], required: ["html"])
        )
    ]

    static let systemNote = """
    你已配备隔离安全沙盒工具（sandbox_run_js / sandbox_verify_html）：涉及复杂数学计算、日期/字数统计、表格汇总校验时可调用 sandbox_run_js 精准验算；生成交互式 HTML/SVG 交付件前可调用 sandbox_verify_html 做零报错自检，若发现报错请先修复再交付。
    """

    /// Fast deterministic static HTML sanity checks usable on both macOS unit tests and iOS pre-check.
    static func staticHTMLIssues(in html: String) -> [String] {
        var issues: [String] = []
        let lower = html.lowercased()
        let openScripts = countMatches(pattern: #"<script\b[^>]*>"#, in: lower)
        let closeScripts = countMatches(pattern: #"</script\s*>"#, in: lower)
        if openScripts != closeScripts {
            issues.append("检测到未闭合的 <script> 标签（开标签 \(openScripts) 个，闭标签 \(closeScripts) 个）。")
        }
        let openStyles = countMatches(pattern: #"<style\b[^>]*>"#, in: lower)
        let closeStyles = countMatches(pattern: #"</style\s*>"#, in: lower)
        if openStyles != closeStyles {
            issues.append("检测到未闭合的 <style> 标签（开标签 \(openStyles) 个，闭标签 \(closeStyles) 个）。")
        }
        if html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("HTML 内容为空。")
        }
        return issues
    }

    private static func countMatches(pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return 0 }
        return regex.numberOfMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
    }
}
