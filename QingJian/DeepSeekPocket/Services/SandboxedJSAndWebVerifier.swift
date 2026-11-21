import Foundation
import WebKit

/// Isolated offscreen `WKWebView` sandbox (separate iOS `WebContent` XPC subprocess)
/// providing 5-second hard-kill JS computation and zero-network HTML/SVG self-checking.
/// If user/model JS enters an infinite `while(true){}` loop, tearing down the `WKWebView`
/// immediately kills the isolated subprocess with zero main-app freeze or leaked threads.
@MainActor
final class SandboxedJSAndWebVerifier {
    static let defaultTimeoutSeconds: TimeInterval = 5.0

    func run(_ action: SandboxAction) async -> SandboxExecutionReport {
        switch action {
        case .runJS(let code, let inputJSON):
            return await executeJavaScript(code: code, inputJSON: inputJSON, timeout: Self.defaultTimeoutSeconds)
        case .verifyHTML(let html):
            return await verifyHTML(html: html, timeout: Self.defaultTimeoutSeconds)
        }
    }

    private func executeJavaScript(code: String, inputJSON: String?, timeout: TimeInterval) async -> SandboxExecutionReport {
        let codeLiteral = Self.jsStringLiteral(code)
        let inputLiteral = Self.jsStringLiteral(inputJSON ?? "null")
        let harnessHTML = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval';">
        </head>
        <body>
        <script>
        (async function() {
          const logs = [];
          const errors = [];
          const origLog = console.log;
          const origErr = console.error;
          const origWarn = console.warn;
          const fmt = (args) => Array.from(args).map(a => {
            if (typeof a === 'string') return a;
            try { return JSON.stringify(a); } catch (_) { return String(a); }
          }).join(' ');
          console.log = function() { if (logs.length < 40) logs.push(fmt(arguments)); };
          console.warn = function() { if (logs.length < 40) logs.push('[warn] ' + fmt(arguments)); };
          console.error = function() { if (errors.length < 30) errors.push(fmt(arguments)); };
          window.onerror = function(msg, src, line, col) {
            errors.push(String(msg) + ' (line ' + line + ':' + col + ')');
          };
          window.addEventListener('unhandledrejection', function(ev) {
            errors.push('Unhandled rejection: ' + (ev.reason ? String(ev.reason) : 'unknown'));
          });

          // Block network primitives defensively on top of CSP
          try { window.fetch = () => { throw new Error('沙盒已禁用网络访问'); }; } catch (_) {}
          try { window.XMLHttpRequest = function() { throw new Error('沙盒已禁用网络访问'); }; } catch (_) {}

          let parsedInput = null;
          try {
            parsedInput = JSON.parse(\(inputLiteral));
          } catch (e) {
            errors.push('input_json 解析失败: ' + e.message);
          }

          let resultJSON = null;
          let ok = errors.length === 0;
          if (ok) {
            try {
              const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
              const fn = new AsyncFunction('input', \(codeLiteral));
              const value = await fn(parsedInput);
              if (value !== undefined) {
                try { resultJSON = JSON.stringify(value, null, 2); } catch (_) { resultJSON = String(value); }
              }
            } catch (err) {
              ok = false;
              errors.push(err && err.message ? String(err.message) : String(err));
            }
          }
          if (errors.length > 0) ok = false;
          window.webkit.messageHandlers.sermoSandbox.postMessage({
            ok: ok,
            resultJSON: resultJSON,
            logs: logs,
            errors: errors
          });
        })();
        </script>
        </body>
        </html>
        """
        return await runInIsolatedWebView(html: harnessHTML, timeout: timeout)
    }

    private func verifyHTML(html: String, timeout: TimeInterval) async -> SandboxExecutionReport {
        let staticIssues = SandboxTools.staticHTMLIssues(in: html)
        let probeScript = """
        <script>
        (function() {
          window.__sermoLogs = [];
          window.__sermoErrors = [];
          const fmt = (args) => Array.from(args).map(a => typeof a === 'string' ? a : String(a)).join(' ');
          console.log = function() { if (window.__sermoLogs.length < 30) window.__sermoLogs.push(fmt(arguments)); };
          console.error = function() { if (window.__sermoErrors.length < 30) window.__sermoErrors.push(fmt(arguments)); };
          window.onerror = function(msg, src, line, col) {
            window.__sermoErrors.push(String(msg) + ' (line ' + line + ':' + col + ')');
          };
          window.addEventListener('unhandledrejection', function(ev) {
            window.__sermoErrors.push('Unhandled rejection: ' + (ev.reason ? String(ev.reason) : 'unknown'));
          });
          window.addEventListener('load', function() {
            setTimeout(function() {
              const body = document.body;
              const textLen = body ? (body.innerText || '').trim().length : 0;
              const elCount = body ? body.querySelectorAll('*').length : 0;
              const scrollW = document.documentElement ? document.documentElement.scrollWidth : 0;
              const clientW = document.documentElement ? document.documentElement.clientWidth : 390;
              const overflow = scrollW > clientW + 12;
              const errs = window.__sermoErrors.slice();
              if (elCount === 0 && textLen === 0) {
                errs.push('页面渲染后正文与节点均为空。');
              }
              const summary = '节点数 ' + elCount + '，可见字数 ' + textLen + (overflow ? '，检测到横向溢出（scrollWidth=' + scrollW + ' > ' + clientW + '）' : '，移动端视口宽度适配正常');
              window.webkit.messageHandlers.sermoSandbox.postMessage({
                ok: errs.length === 0,
                logs: window.__sermoLogs,
                errors: errs,
                metricsSummary: summary
              });
            }, 120);
          });
        })();
        </script>
        """

        let wrapped = HTMLPreviewHelper.wrappedHTML(code: html, language: "html")
        let injected: String
        if let headRange = wrapped.range(of: "<head>", options: .caseInsensitive) {
            injected = wrapped.replacingCharacters(in: headRange, with: "<head>\n\(probeScript)\n")
        } else {
            injected = probeScript + "\n" + wrapped
        }

        var report = await runInIsolatedWebView(html: injected, timeout: timeout)
        if !staticIssues.isEmpty {
            report.errors = staticIssues + report.errors
            report.ok = false
        }
        return report
    }

    private func runInIsolatedWebView(html: String, timeout: TimeInterval) async -> SandboxExecutionReport {
        await withCheckedContinuation { continuation in
            let runner = IsolatedWebViewRunner(timeout: timeout) { report in
                continuation.resume(returning: report)
            }
            runner.start(html: html)
        }
    }

    private static func jsStringLiteral(_ raw: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [raw], options: []),
           let arr = String(data: data, encoding: .utf8),
           arr.count >= 2 {
            let inner = String(arr.dropFirst().dropLast())
            return inner
                .replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        }
        return "\"\""
    }
}

@MainActor
private final class IsolatedWebViewRunner: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var webView: WKWebView?
    private var watchdog: Task<Void, Never>?
    private var completion: ((SandboxExecutionReport) -> Void)?
    private let timeout: TimeInterval
    private var selfRetain: IsolatedWebViewRunner?

    init(timeout: TimeInterval, completion: @escaping (SandboxExecutionReport) -> Void) {
        self.timeout = timeout
        self.completion = completion
    }

    func start(html: String) {
        selfRetain = self
        let contentController = WKUserContentController()
        contentController.add(self, name: "sermoSandbox")

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController = contentController
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        view.navigationDelegate = self
        self.webView = view

        watchdog = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(1.0, self?.timeout ?? 5.0) * 1_000_000_000))
            } catch {
                return
            }
            self?.finish(with: SandboxExecutionReport(
                ok: false,
                timedOut: true,
                resultJSON: nil,
                logs: [],
                errors: ["脚本执行超过 \(Int(self?.timeout ?? 5)) 秒限制，已强制终止隔离进程。"],
                metricsSummary: nil
            ))
        }

        view.loadHTMLString(html, baseURL: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else {
            finish(with: SandboxExecutionReport(ok: false, errors: ["沙盒返回格式异常。"]))
            return
        }
        let ok = (body["ok"] as? Bool) ?? false
        let resultJSON = body["resultJSON"] as? String
        let logs = (body["logs"] as? [String]) ?? []
        let errors = (body["errors"] as? [String]) ?? []
        let metrics = body["metricsSummary"] as? String
        finish(with: SandboxExecutionReport(
            ok: ok,
            timedOut: false,
            resultJSON: resultJSON,
            logs: logs,
            errors: errors,
            metricsSummary: metrics
        ))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if let scheme = navigationAction.request.url?.scheme?.lowercased(),
           scheme == "http" || scheme == "https" || scheme == "file" {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(with: SandboxExecutionReport(ok: false, errors: ["页面加载失败：\(error.localizedDescription)"]))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(with: SandboxExecutionReport(ok: false, timedOut: true, errors: ["隔离沙盒进程内存超限或意外中止，已安全回收。"]))
    }

    private func finish(with report: SandboxExecutionReport) {
        guard let done = completion else { return }
        completion = nil
        watchdog?.cancel()
        watchdog = nil
        if let view = webView {
            view.stopLoading()
            view.navigationDelegate = nil
            view.configuration.userContentController.removeScriptMessageHandler(forName: "sermoSandbox")
            webView = nil
        }
        done(report)
        selfRetain = nil
    }
}
