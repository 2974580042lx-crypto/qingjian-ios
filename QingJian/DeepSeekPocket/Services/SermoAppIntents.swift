import AppIntents
import Foundation

/// Single-bundle Shortcuts / Share Sheet action requiring ZERO extra app extension target
/// or App Group entitlement — works reliably even on personally self-signed IPAs.
struct SendToSermoIntent: AppIntent {
    static var title: LocalizedStringResource = "发送到 Sermo"
    static var description = IntentDescription("将网页链接、摘录文字或笔记发送到 Sermo，打开后可选择放进当前对话或存入指定项目文献库。")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "标题", description: "可选：内容标题")
    var itemTitle: String?

    @Parameter(title: "文字内容", description: "可选：要发给 Sermo 或收藏的文字")
    var text: String?

    @Parameter(title: "网页链接", description: "可选：Safari 或其他 App 的网址")
    var url: URL?

    @Parameter(title: "目标项目名称", description: "可选：优先选中的项目名称")
    var projectName: String?

    static var parameterSummary: some ParameterSummary {
        Summary("将内容发送到 Sermo") {
            \.$itemTitle
            \.$text
            \.$url
            \.$projectName
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let cleanTitle = (itemTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanText = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanProject = (projectName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let item: ShareIntakeItem
        if let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            item = ShareIntakeItem(
                kind: .webLink,
                title: cleanTitle.isEmpty ? (url.host ?? url.absoluteString) : cleanTitle,
                bodyText: cleanText.isEmpty ? nil : cleanText,
                urlString: url.absoluteString,
                preferredProjectName: cleanProject.isEmpty ? nil : cleanProject
            )
        } else if !cleanText.isEmpty {
            let fallback = String(cleanText.prefix(28)).replacingOccurrences(of: "\n", with: " ")
            item = ShareIntakeItem(
                kind: .text,
                title: cleanTitle.isEmpty ? fallback : cleanTitle,
                bodyText: cleanText,
                preferredProjectName: cleanProject.isEmpty ? nil : cleanProject
            )
        } else {
            return .result(dialog: "没有收到可发送的文字或链接，已为你打开 Sermo。")
        }

        try ShareInboxQueue().enqueue(item)
        return .result(dialog: "已送入 Sermo，请在弹出卡片中选择放入对话或项目文献库。")
    }
}

struct SermoAppShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendToSermoIntent(),
            phrases: [
                "发送到 \(.applicationName)",
                "收藏到 \(.applicationName)",
                "用 \(.applicationName) 整理"
            ],
            shortTitle: "发送到 Sermo",
            systemImageName: "tray.and.arrow.down"
        )
    }
}
