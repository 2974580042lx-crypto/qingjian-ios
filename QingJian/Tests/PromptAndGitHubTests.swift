import XCTest
@testable import DeepSeekCore

final class PromptAndGitHubTests: XCTestCase {
    private var shanghai: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
    // 2026-10-17 22:05 in Shanghai, a Saturday.
    private var context: PromptVariables.Context {
        PromptVariables.Context(now: Date(timeIntervalSince1970: 1_792_245_900), userName: "小龙", modelName: "Flash", calendar: shanghai)
    }

    func testVariablesAreFilledAndUnknownBracesKept() {
        let text = "现在是{{时间}}，{{ 星期 }}，{{date}}。{{user}}在用{{模型}}。{{未知}} {{"
        XCTAssertEqual(PromptVariables.apply(text, context), "现在是22:05，星期六，2026年10月17日。小龙在用Flash。{{未知}} {{")
        XCTAssertEqual(PromptVariables.apply("没有变量", context), "没有变量")
        var anonymous = context
        anonymous.userName = "  "
        XCTAssertEqual(PromptVariables.apply("{{名字}}", anonymous), "我")
    }

    func testTimeNoteOnlyAfterALongGap() {
        let now = context.now
        XCTAssertNil(PromptVariables.elapsedNote(since: now.addingTimeInterval(-600), context: context))
        let late = PromptVariables.elapsedNote(since: now.addingTimeInterval(-9 * 3600), context: context)
        XCTAssertTrue(late?.contains("过去了 9 小时") == true)
        XCTAssertTrue(late?.contains("22:05") == true)
        XCTAssertTrue(PromptVariables.elapsedNote(since: nil, context: context)?.contains("现在是") == true)
        XCTAssertTrue(PromptVariables.currentTimeNote(context).contains("2026年10月17日 星期六 22:05"))
        XCTAssertEqual(PromptVariables.duration(3 * 86_400), " 3 天")
    }

    func testTimeNoteGoesBeforeTheNewestUserMessageOnly() {
        let messages = [ChatMessage(role: .user, content: "早"), ChatMessage(role: .assistant, content: "早安"),
                        ChatMessage(role: .user, content: "我回来了")]
        let request = ChatRequest(settings: AppSettings(), messages: messages).prefixingLastUserMessage("（提示）")
        XCTAssertEqual(request.messages.filter { $0.role == "user" }.map(\.content), ["早", "（提示）\n我回来了"])
    }

    func testGitHubWritesAlwaysLandOnSermoBranches() throws {
        func action(_ name: String, _ arguments: String) throws -> GitHubAction {
            try GitHubAction(ToolCall(id: "x", name: name, arguments: arguments))
        }
        let write = try action("github_write", #"{"repo":"me/app","path":"/Sources/A.swift","content":"let a = 1\n","branch":"fix-a","message":"修复"}"#)
        XCTAssertEqual(write, .write(repo: "me/app", path: "Sources/A.swift", content: "let a = 1\n", branch: "sermo/fix-a", message: "修复"))
        XCTAssertTrue(write.isWrite)
        XCTAssertEqual(try action("github_create_pr", #"{"repo":"me/app","branch":"sermo/fix-a","title":"t"}"#),
                       .pullRequest(repo: "me/app", branch: "sermo/fix-a", title: "t", body: ""))
        XCTAssertEqual(GitHubAction.workingBranch("main"), "sermo/main")
        XCTAssertFalse(try action("github_read", #"{"repo":"me/app","path":"README.md"}"#).isWrite)
        XCTAssertEqual(try action("github_list", #"{"repo":"me/app"}"#), .list(repo: "me/app", path: "", ref: nil))
    }

    func testGitHubArgumentsAreChecked() {
        func fails(_ name: String, _ arguments: String) {
            XCTAssertThrowsError(try GitHubAction(ToolCall(id: "x", name: name, arguments: arguments)), arguments)
        }
        fails("github_read", #"{"repo":"me/app","path":"../secrets"}"#)
        fails("github_read", #"{"repo":"me","path":"a"}"#)
        fails("github_read", #"{"repo":"me/app/extra","path":"a"}"#)
        fails("github_list", #"{"repo":"me/app","ref":"main..dev"}"#)
        fails("github_write", #"{"repo":"me/app","path":"a","content":"x","branch":"b"}"#)
        fails("github_merge", #"{"repo":"me/app"}"#)
    }

    func testLogDigestPicksErrorsAndTail() {
        let log = (1...50).map { "2026-10-17T10:00:00.1234567Z line \($0)" }.joined(separator: "\n")
            + "\n2026-10-17T10:00:01.1234567Z /x/ContentView.swift:12:3: error: cannot find 'foo' in scope"
        let digest = GitHubAction.logDigest(log, tail: 3)
        XCTAssertTrue(digest.contains("出错的行：\n/x/ContentView.swift:12:3: error: cannot find 'foo' in scope"))
        XCTAssertTrue(digest.hasSuffix("line 49\nline 50\n/x/ContentView.swift:12:3: error: cannot find 'foo' in scope"))
    }

    func testManualProjectKeepsUserInstructionsWhenRefreshed() throws {
        let fresh = AppManual.newProject()
        XCTAssertNoThrow(try fresh.validate())
        XCTAssertNil(AppManual.refreshed(fresh))
        var edited = fresh
        edited.instructions = "我自己的话"
        edited.documents[0].text = "旧版说明"
        let next = try XCTUnwrap(AppManual.refreshed(edited))
        XCTAssertEqual(next.instructions, "我自己的话")
        XCTAssertEqual(next.documents.first?.text, AppManual.document)
        XCTAssertTrue(AppManual.document.contains("GitHub"))
        XCTAssertFalse(fresh.usesDriveTools || fresh.usesGitHubTools || fresh.timeAwareness == true)
    }
}

final class WebPageTests: XCTestCase {
    func testExtractKeepsArticleTextAndDropsScripts() {
        let html = """
        <html><head><title>t</title><style>.a{}</style></head><body>
        <nav>首页 | 关于</nav>
        <article><h1>标题</h1><p>第一段&nbsp;内容，介绍&ldquo;检视阅读&rdquo;的做法，足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长足够长。</p>
        <script>alert('x')</script><p>第二段 &#26159; &#x597D; &amp; 结束</p></article>
        <footer>版权</footer></body></html>
        """
        let text = WebText.extract(html: html)
        XCTAssertTrue(text.contains("标题"))
        XCTAssertTrue(text.contains("“检视阅读”"))
        XCTAssertTrue(text.contains("第二段 是 好 & 结束"))
        XCTAssertFalse(text.contains("alert"))
        XCTAssertFalse(text.contains("首页"))
        XCTAssertFalse(text.contains("版权"))
        XCTAssertEqual(WebText.extract(html: "<p>" + String(repeating: "长", count: 100) + "</p>", limit: 10), String(repeating: "长", count: 10) + "……")
    }

    func testOnlyPublicWebAddressesAreFetched() {
        for good in ["https://example.com/a", "http://news.example.cn/x?y=1", "https://8.8.8.8/"] {
            XCTAssertTrue(WebText.isFetchable(URL(string: good)!), good)
        }
        for bad in ["file:///etc/passwd", "http://localhost:8080", "http://127.0.0.1", "http://192.168.1.1", "http://10.0.0.2",
                    "http://172.20.0.1", "http://169.254.1.1", "http://[::1]/", "https://user:pw@example.com", "ftp://example.com", "http://printer.local"] {
            XCTAssertFalse(WebText.isFetchable(URL(string: bad)!), bad)
        }
    }

    func testSearchKeepsTheSearchModelsSummaryAndPageText() throws {
        let body = Data(#"""
        {"content":[
          {"type":"text","text":"我来搜索。"},
          {"type":"web_search_tool_result","content":[{"type":"web_search_result","url":"https://example.com/a","title":"资料"}]},
          {"type":"text","text":"根据资料，答案是四十二。"}
        ]}
        """#.utf8)
        var result = try WebSearchProtocol.parse(body)
        XCTAssertEqual(result.summary, "我来搜索。根据资料，答案是四十二。")
        result.pages = ["https://example.com/a": "页面正文在这里"]
        XCTAssertTrue(result.context.contains("搜索时的总结：\n我来搜索。根据资料，答案是四十二。"))
        XCTAssertTrue(result.context.contains("正文节选：\n页面正文在这里"))
    }

    func testWebToolArguments() throws {
        XCTAssertEqual(try WebAction(ToolCall(id: "a", name: "web_search", arguments: #"{"query":" 天气 "}"#)), .search(query: "天气"))
        XCTAssertEqual(try WebAction(ToolCall(id: "a", name: "web_read", arguments: #"{"url":"https://example.com"}"#)), .read(url: "https://example.com"))
        XCTAssertThrowsError(try WebAction(ToolCall(id: "a", name: "web_read", arguments: #"{"url":"http://127.0.0.1/admin"}"#)))
        XCTAssertThrowsError(try WebAction(ToolCall(id: "a", name: "web_search", arguments: "{}")))
    }

    func testDecodesGBKPages() {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let data = "<meta charset=\"gbk\"><p>中文网页</p>".data(using: encoding)!
        XCTAssertTrue(WebText.decode(data, contentType: "text/html").contains("中文网页"))
    }

    func testExtractsURLsAndParsesGitHubRepoAndBlobTargets() {
        let prompt = "帮我看看这个仓库 https://github.com/xiaolong/qingjian-ios，还有这个文件 https://github.com/xiaolong/qingjian-ios/blob/main/README.md。"
        let urls = WebText.extractURLs(from: prompt)
        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://github.com/xiaolong/qingjian-ios",
            "https://github.com/xiaolong/qingjian-ios/blob/main/README.md"
        ])
        let repoTarget = WebText.parseGitHubURL(urls[0])
        XCTAssertEqual(repoTarget, WebText.GitHubTarget(owner: "xiaolong", repo: "qingjian-ios", ref: nil, path: nil, isBlob: false))
        let blobTarget = WebText.parseGitHubURL(urls[1])
        XCTAssertEqual(blobTarget, WebText.GitHubTarget(owner: "xiaolong", repo: "qingjian-ios", ref: "main", path: "README.md", isBlob: true))
        XCTAssertNil(WebText.parseGitHubURL(URL(string: "https://github.com/features/copilot")!))
    }
}
