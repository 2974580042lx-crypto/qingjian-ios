import SwiftUI
import UIKit
import WebKit

enum HTMLPreviewHelper {
    private static let titleRegex = try? NSRegularExpression(pattern: #"<title[^>]*>(.*?)</title>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let h1Regex = try? NSRegularExpression(pattern: #"<h1[^>]*>(.*?)</h1>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let tagStripRegex = try? NSRegularExpression(pattern: #"<[^>]+>"#, options: [])

    static func isPreviewable(language: String?, body: String) -> Bool {
        if let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
           lang == "HTML" || lang == "HTM" || lang == "SVG" {
            return true
        }
        let head = body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html") || head.hasPrefix("<svg")
    }

    private static func firstCleanMatch(_ regex: NSRegularExpression?, in text: String) -> String? {
        guard let regex else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              match.numberOfRanges >= 2,
              let innerRange = Range(match.range(at: 1), in: text) else { return nil }
        let inner = String(text[innerRange])
        let stripped: String
        if let strip = tagStripRegex {
            stripped = strip.stringByReplacingMatches(in: inner, options: [], range: NSRange(inner.startIndex..<inner.endIndex, in: inner), withTemplate: "")
        } else {
            stripped = inner
        }
        let clean = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(40))
    }

    static func extractTitle(code: String, language: String?) -> String {
        let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        if isPreviewable(language: language, body: code) {
            let headSlice = String(code.prefix(8192))
            if let title = firstCleanMatch(titleRegex, in: headSlice) { return title }
            if let h1 = firstCleanMatch(h1Regex, in: headSlice) { return h1 }
            return lang == "SVG" || code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("<svg")
                ? "矢量图形预览" : "交互网页预览"
        }
        if !lang.isEmpty { return "\(lang) 代码" }
        return "代码片段"
    }

    static func wrappedHTML(code: String, language: String?) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("<html") || lower.contains("<!doctype") {
            return code
        }
        let isSVG = language?.uppercased() == "SVG" || lower.hasPrefix("<svg")
        let layoutRule = isSVG
            ? "min-height:100vh;display:flex;align-items:center;justify-content:center;"
            : ""
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
        :root { color-scheme: light dark; }
        html, body { margin:0; padding:16px; background:#FAFAFA; color:#171717; font-family:-apple-system,BlinkMacSystemFont,sans-serif; box-sizing:border-box; \(layoutRule) }
        @media (prefers-color-scheme: dark) {
          html, body { background:#171717; color:#EDEDEB; }
        }
        svg { max-width: 100%; height: auto; display: block; }
        </style>
        </head>
        <body>
        \(trimmed)
        </body>
        </html>
        """
    }
}

enum ArtifactKind: Equatable {
    case web(code: String, language: String?, title: String)
    case code(code: String, language: String?, title: String)
    case document(markdown: String, title: String)

    var title: String {
        switch self {
        case .web(_, _, let t), .code(_, _, let t), .document(_, let t): return t
        }
    }

    var iconName: String {
        switch self {
        case .web: return "globe"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .document: return "doc.richtext"
        }
    }

    var rawText: String {
        switch self {
        case .web(let c, _, _), .code(let c, _, _): return c
        case .document(let md, _): return md
        }
    }

    var supportsDualMode: Bool {
        switch self {
        case .web, .document: return true
        case .code: return false
        }
    }
}

/// Sleek Claude Artifacts-style collapsed card rendered inside the chat transcript so long
/// HTML pages and code listings never flood vertical scroll space.
@MainActor
struct ArtifactCardView: View {
    let title: String
    let subtitle: String
    let iconName: String
    let actionHint: String
    let swiss: Bool
    let open: () -> Void

    var body: some View {
        Button {
            Haptic.tap()
            open()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Ink.ink2)
                    .frame(width: 38, height: 38)
                    .background(Ink.raised, in: RoundedRectangle(cornerRadius: swiss ? 0 : 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2.5) {
                    Text(title)
                        .font(TypeScale.ui(15, weight: .medium))
                        .foregroundStyle(Ink.ink)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(TypeScale.ui(12.5))
                        .foregroundStyle(Ink.ink3)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text(actionHint)
                        .font(TypeScale.ui(13, weight: .medium))
                        .foregroundStyle(Ink.ink2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Ink.ink3.opacity(0.75))
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(Ink.card, in: RoundedRectangle(cornerRadius: swiss ? 0 : 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: swiss ? 0 : 16, style: .continuous)
                    .stroke(swiss ? Ink.ink : Ink.line, lineWidth: swiss ? 1 : 0.7)
            )
            .contentShape(RoundedRectangle(cornerRadius: swiss ? 0 : 16, style: .continuous))
        }
        .buttonStyle(.pressFeedback)
    }
}

/// Full-screen Claude Artifacts viewer supporting live HTML/SVG preview + source toggle,
/// syntax-highlighted code inspection, and clean Markdown reading mode with export.
@MainActor
struct ArtifactPreviewSheet: View {
    let artifact: ArtifactKind
    @Environment(\.dismiss) private var dismiss
    @State private var mode: ViewMode
    @State private var reloadToken = UUID()
    @State private var copied = false
    @State private var exportURL: URL?

    enum ViewMode: String, CaseIterable, Identifiable {
        case preview = "预览"
        case source = "代码"
        var id: String { rawValue }
    }

    init(artifact: ArtifactKind) {
        self.artifact = artifact
        _mode = State(initialValue: artifact.supportsDualMode ? .preview : .source)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch artifact {
                case .web(let code, let language, _):
                    if mode == .preview {
                        HTMLWebView(html: HTMLPreviewHelper.wrappedHTML(code: code, language: language), reloadToken: reloadToken)
                            .ignoresSafeArea(edges: .bottom)
                    } else {
                        codeScrollView(code: code, language: language)
                    }
                case .code(let code, let language, _):
                    codeScrollView(code: code, language: language)
                case .document(let markdown, _):
                    if mode == .preview {
                        ScrollView {
                            MarkdownAnswer(content: markdown, style: InterfaceStyle.current, expandsWidth: true)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 18)
                        }
                        .background(Ink.paper.ignoresSafeArea())
                    } else {
                        codeScrollView(code: markdown, language: "markdown")
                    }
                }
            }
            .navigationTitle(artifact.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ClaudeSheetCloseButton(label: "关闭") { dismiss() }
                }
                if artifact.supportsDualMode {
                    ToolbarItem(placement: .principal) {
                        Picker("", selection: $mode) {
                            Text(isDocument ? "阅读" : "预览").tag(ViewMode.preview)
                            Text(isDocument ? "原文" : "代码").tag(ViewMode.source)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 140)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if case .web = artifact, mode == .preview {
                        Button { reloadToken = UUID() } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 14.5, weight: .regular))
                        }
                        .accessibilityLabel("重新加载预览")
                    }
                    Button { copyAll() } label: {
                        ClaudeActionGlyph(kind: copied ? .copied : .copy, size: 15.5)
                    }
                    .accessibilityLabel("复制全部")
                    Button { exportArtifact() } label: {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 14.5, weight: .regular))
                    }
                    .accessibilityLabel("导出文件")
                }
            }
        }
        .tint(Ink.ink)
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } }), onDismiss: cleanupExportFile) {
            if let url = exportURL { ShareSheet(items: [url]) }
        }
    }

    private var isDocument: Bool {
        if case .document = artifact { return true }
        return false
    }

    private func codeScrollView(code: String, language: String?) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(MarkdownAnswer.highlightedCode(code, language: language))
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Ink.paper.ignoresSafeArea())
    }

    private func copyAll() {
        UIPasteboard.general.string = artifact.rawText
        Haptic.tap()
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    private func exportArtifact() {
        let filename: String
        let content: String
        switch artifact {
        case .web(let code, let language, _):
            let isSVG = language?.uppercased() == "SVG"
            filename = isSVG ? "Sermo矢量图形.svg" : "Sermo网页预览.html"
            content = isSVG ? code : HTMLPreviewHelper.wrappedHTML(code: code, language: language)
        case .code(let code, let language, _):
            let ext = Self.fileExtension(for: language)
            filename = "Sermo代码.\(ext)"
            content = code
        case .document(let markdown, _):
            filename = "Sermo文稿.md"
            content = markdown
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? Data(content.utf8).write(to: url, options: .atomic)
        exportURL = url
    }

    private static func fileExtension(for language: String?) -> String {
        switch language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "swift": return "swift"
        case "python", "py": return "py"
        case "javascript", "js": return "js"
        case "typescript", "ts": return "ts"
        case "json": return "json"
        case "css": return "css"
        case "bash", "sh", "zsh": return "sh"
        case "markdown", "md": return "md"
        case "sql": return "sql"
        default: return "txt"
        }
    }

    private func cleanupExportFile() {
        guard let url = exportURL else { return }
        if url.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
            try? FileManager.default.removeItem(at: url)
        }
        exportURL = nil
    }
}

/// Backwards-compatible wrapper preserving callers expecting `HTMLPreviewSheet`.
@MainActor
struct HTMLPreviewSheet: View {
    let code: String
    let language: String?
    var body: some View {
        ArtifactPreviewSheet(artifact: .web(code: code, language: language, title: HTMLPreviewHelper.extractTitle(code: code, language: language)))
    }
}

/// Claude iOS-style bottom sheet listing web search sources cleanly with domain, title, and snippet.
@MainActor
struct WebSourcesSheet: View {
    let sources: [WebSource]
    let searchUsage: TokenUsage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                        if let url = URL(string: source.url) {
                            Link(destination: url) {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 6) {
                                        Text("\(index + 1)")
                                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(Ink.ink2)
                                            .frame(width: 18, height: 18)
                                            .background(Ink.raised, in: Circle())
                                        Text(url.host ?? source.url)
                                            .font(TypeScale.ui(12))
                                            .foregroundStyle(Ink.ink3)
                                            .lineLimit(1)
                                        Spacer()
                                        Image(systemName: "arrow.up.right")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(Ink.ink3.opacity(0.7))
                                    }
                                    Text(source.title)
                                        .font(TypeScale.ui(15, weight: .medium))
                                        .foregroundStyle(Ink.ink)
                                        .lineLimit(2)
                                    if !source.snippet.isEmpty {
                                        Text(source.snippet)
                                            .font(TypeScale.ui(13))
                                            .foregroundStyle(Ink.ink2)
                                            .lineLimit(3)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                .claudeCardRow()

                if let usage = searchUsage {
                    Section {
                        Text("本次搜索消耗 \(usage.totalTokens.formatted()) Tokens；实际扣费以服务商账单为准。")
                            .font(TypeScale.tiny)
                            .foregroundStyle(Ink.ink3)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .claudeGroupedListStyle()
            .navigationTitle("联网来源 · \(sources.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ClaudeSheetCloseButton(label: "完成") { dismiss() }
                }
            }
        }
        .tint(Ink.ink)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Ephemeral gallery for ChatGPT-generated images: displays high-res preview with one-tap
/// "Save to Photos" without storing into chat persistence or cloud backups.
@MainActor
struct GeneratedImagesGalleryView: View {
    let urls: [URL]
    let swiss: Bool
    @State private var fullScreenURL: URL?
    @State private var savedURLs: Set<URL> = []
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(urls, id: \.self) { url in
                if let uiImage = UIImage(contentsOfFile: url.path) {
                    ZStack(alignment: .bottomTrailing) {
                        Button { fullScreenURL = url } label: {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 360)
                                .clipShape(RoundedRectangle(cornerRadius: swiss ? 0 : 16, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: swiss ? 0 : 16, style: .continuous)
                                        .stroke(Ink.line, lineWidth: 0.6)
                                )
                        }
                        .buttonStyle(.plain)

                        Button {
                            saveImage(url)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: savedURLs.contains(url) ? "checkmark" : "square.and.arrow.down")
                                    .font(.system(size: 12, weight: .semibold))
                                Text(savedURLs.contains(url) ? "已存相册" : "存相册")
                                    .font(.system(size: 12.5, weight: .medium))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.62), in: Capsule())
                        }
                        .buttonStyle(.pressFeedback)
                        .padding(10)
                    }
                }
            }
            Text("临时预览 · 不写入聊天库也不占云盘空间，需要请点「存相册」")
                .font(TypeScale.tiny)
                .foregroundStyle(Ink.ink3)
        }
        .sheet(isPresented: Binding(get: { fullScreenURL != nil }, set: { if !$0 { fullScreenURL = nil } })) {
            if let url = fullScreenURL, let img = UIImage(contentsOfFile: url.path) {
                NavigationStack {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.ignoresSafeArea())
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("关闭") { fullScreenURL = nil }.foregroundStyle(.white)
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button(savedURLs.contains(url) ? "已存相册" : "保存到相册") { saveImage(url) }
                                    .foregroundStyle(.white)
                            }
                        }
                        .toolbarBackground(.hidden, for: .navigationBar)
                }
            }
        }
        .alert("未能保存到相册", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("知道了") { saveError = nil }
        } message: { Text(saveError ?? "") }
    }

    private func saveImage(_ url: URL) {
        Task {
            do {
                try await EphemeralGeneratedImageCache.saveToPhotos(url)
                Haptic.tap()
                savedURLs.insert(url)
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}

@MainActor
struct HTMLWebView: UIViewRepresentable {
    let html: String
    let reloadToken: UUID

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(Ink.paper)
        webView.scrollView.backgroundColor = UIColor(Ink.paper)
        webView.navigationDelegate = context.coordinator
        context.coordinator.lastHTML = html
        context.coordinator.lastToken = reloadToken
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html || context.coordinator.lastToken != reloadToken {
            context.coordinator.lastHTML = html
            context.coordinator.lastToken = reloadToken
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String = ""
        var lastToken: UUID = UUID()

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
