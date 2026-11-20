import SwiftUI
import UIKit
import WebKit

enum HTMLPreviewHelper {
    static func isPreviewable(language: String?, body: String) -> Bool {
        if let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
           lang == "HTML" || lang == "HTM" || lang == "SVG" {
            return true
        }
        let head = body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html") || head.hasPrefix("<svg")
    }

    static func wrappedHTML(code: String, language: String?) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("<html") || lower.contains("<!doctype") {
            return code
        }
        let isSVG = language?.uppercased() == "SVG" || lower.hasPrefix("<svg")
        let bodyStyle = isSVG
            ? "margin:0;padding:16px;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#F8F8F6;box-sizing:border-box;"
            : "margin:0;padding:16px;background:#F8F8F6;color:#1A1A18;font-family:-apple-system,BlinkMacSystemFont,sans-serif;box-sizing:border-box;"
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
        html, body { \(bodyStyle) }
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

@MainActor
struct HTMLPreviewSheet: View {
    let code: String
    let language: String?
    @Environment(\.dismiss) private var dismiss
    @State private var reloadToken = UUID()
    @State private var exportURL: URL?

    private var htmlString: String {
        HTMLPreviewHelper.wrappedHTML(code: code, language: language)
    }

    var body: some View {
        NavigationStack {
            HTMLWebView(html: htmlString, reloadToken: reloadToken)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("网页效果预览")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        ClaudeSheetCloseButton(label: "关闭") { dismiss() }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            reloadToken = UUID()
                        } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .regular))
                        }
                        .accessibilityLabel("重新加载预览")

                        Button {
                            exportHTML()
                        } label: {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .regular))
                        }
                        .accessibilityLabel("导出网页文件")
                    }
                }
        }
        .tint(Ink.ink)
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } }), onDismiss: cleanupExportFile) {
            if let url = exportURL {
                ShareSheet(items: [url])
            }
        }
    }

    private func exportHTML() {
        let filename = language?.uppercased() == "SVG" ? "Sermo矢量预览.svg" : "Sermo网页预览.html"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? Data(htmlString.utf8).write(to: url, options: .atomic)
        exportURL = url
    }

    private func cleanupExportFile() {
        guard let url = exportURL else { return }
        if url.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
            try? FileManager.default.removeItem(at: url)
        }
        exportURL = nil
    }
}

@MainActor
private struct HTMLWebView: UIViewRepresentable {
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
