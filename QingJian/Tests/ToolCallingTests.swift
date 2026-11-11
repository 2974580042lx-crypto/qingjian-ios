import XCTest
@testable import DeepSeekCore

final class ToolCallingTests: XCTestCase {
    private func decode(_ wire: String) throws -> [StreamEvent] {
        var decoder = SSEByteDecoder()
        var events: [StreamEvent] = []
        for byte in wire.utf8 {
            if let event = try decoder.consume(byte: byte) { events.append(event) }
        }
        if let event = try decoder.finish() { events.append(event) }
        return events
    }

    func testStreamedToolCallPiecesJoinIntoWholeCalls() throws {
        let wire = [
            #"data: {"choices":[{"delta":{"reasoning_content":"要查云盘"}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"drive_search","arguments":""}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"query\":"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"周报\"}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"drive_list","arguments":"{}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":4}}"#,
            "data: [DONE]",
        ].map { $0 + "\n\n" }.joined()
        var collector = ToolCallCollector()
        let events = try decode(wire)
        for event in events { collector.consume(event.toolCalls) }
        XCTAssertEqual(collector.calls, [ToolCall(id: "call_a", name: "drive_search", arguments: #"{"query":"周报"}"#),
                                         ToolCall(id: "call_b", name: "drive_list", arguments: "{}")])
        XCTAssertEqual(events.compactMap(\.finishReason), ["tool_calls"])
        XCTAssertEqual(try DriveAction(collector.calls[0]), .search(query: "周报", limit: 10))
        XCTAssertEqual(try DriveAction(collector.calls[1]), .list(folderID: "root"))
    }

    func testRequestCarriesToolsAndToolTurnsInDeepSeekShape() throws {
        var settings = AppSettings()
        settings.systemPrompt = "系统"
        let history = [ChatMessage(role: .user, content: "找周报"),
                       ChatMessage(role: .assistant, content: "好的", reasoning: "先想想"),
                       ChatMessage(role: .user, content: "再找一次")]
        let call = ToolCall(id: "call_a", name: "drive_search", arguments: #"{"query":"周报"}"#)
        let request = ChatRequest(settings: settings, messages: history, includeReasoning: true)
            .withTools(DriveTools.specs)
            .appending([.assistantCalls([call], content: "", reasoning: "要搜索"), .toolResult("- 周报（文本） id: abc12", callID: "call_a")])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, DriveTools.specs.count)
        XCTAssertEqual(tools.first?["type"] as? String, "function")
        XCTAssertEqual((tools.first?["function"] as? [String: Any])?["name"] as? String, "drive_search")
        XCTAssertNil(object["tool_choice"])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "user", "assistant", "tool"])
        XCTAssertEqual(messages[2]["reasoning_content"] as? String, "先想想")
        XCTAssertNil(messages[1]["reasoning_content"])
        let calls = try XCTUnwrap(messages[4]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.first?["id"] as? String, "call_a")
        XCTAssertEqual((calls.first?["function"] as? [String: Any])?["arguments"] as? String, #"{"query":"周报"}"#)
        XCTAssertEqual(messages[4]["reasoning_content"] as? String, "要搜索")
        XCTAssertEqual(messages[5]["tool_call_id"] as? String, "call_a")
        let final = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request.answeringWithoutTools())) as? [String: Any])
        XCTAssertEqual(final["tool_choice"] as? String, "none")
    }

    func testPlainRequestsStayUnchanged() throws {
        let history = [ChatMessage(role: .user, content: "你好"), ChatMessage(role: .assistant, content: "嗨", reasoning: "想")]
        let request = ChatRequest(settings: AppSettings(), messages: history + [ChatMessage(role: .user, content: "在吗")])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertNil(object["tools"])
        XCTAssertNil(object["tool_choice"])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertTrue(messages.allSatisfy { $0["reasoning_content"] == nil && $0["tool_calls"] == nil })
    }

    func testDriveArgumentsAreCheckedBeforeAnythingRuns() {
        func action(_ name: String, _ arguments: String) throws -> DriveAction {
            try DriveAction(ToolCall(id: "x", name: name, arguments: arguments))
        }
        XCTAssertEqual(try action("drive_read", #"{"file_id":"1AbC_d-E"}"#), .read(fileID: "1AbC_d-E"))
        XCTAssertEqual(try action("drive_search", #"{"query":" 合同 ","limit":99}"#), .search(query: "合同", limit: 20))
        XCTAssertEqual(try action("drive_create", #"{"name":"笔记.md","content":"第一行\n","google_doc":true}"#),
                       .create(name: "笔记.md", content: "第一行\n", folderID: nil, googleDoc: true))
        XCTAssertEqual(try action("drive_move", #"{"file_id":"abcde","new_name":"新名"}"#), .move(fileID: "abcde", newName: "新名", folderID: nil))
        XCTAssertThrowsError(try action("drive_read", #"{"file_id":"../etc"}"#))
        XCTAssertThrowsError(try action("drive_read", #"{"file_id":"a' or 'b"}"#))
        XCTAssertThrowsError(try action("drive_read", "不是 JSON"))
        XCTAssertThrowsError(try action("drive_move", #"{"file_id":"abcde"}"#))
        XCTAssertThrowsError(try action("drive_delete_forever", #"{"file_id":"abcde"}"#))
        XCTAssertThrowsError(try action("drive_search", #"{"query":"   "}"#))
    }

    func testOnlyWritesNeedConfirmation() throws {
        XCTAssertFalse(DriveAction.search(query: "a", limit: 1).isWrite)
        XCTAssertFalse(DriveAction.read(fileID: "abcde").isWrite)
        XCTAssertTrue(DriveAction.trash(fileID: "abcde").isWrite)
        XCTAssertTrue(DriveAction.create(name: "a", content: "", folderID: nil, googleDoc: false).isWrite)
        XCTAssertEqual(DriveAction.trash(fileID: "abcde").targetFileID, "abcde")
        let text = DriveAction.trash(fileID: "abcde").confirmation(targetName: "旧稿")
        XCTAssertTrue(text.title.contains("旧稿"))
        XCTAssertTrue(text.detail.contains("30 天"))
    }

    func testSearchQueryEscapesQuotes() {
        XCTAssertEqual(DriveAction.searchQuery(#"it's a\b"#),
                       #"trashed = false and (name contains 'it\'s a\\b' or fullText contains 'it\'s a\\b')"#)
    }

    func testFileContentIsMarkedAsMaterialAndClipped() {
        let long = String(repeating: "字", count: ToolLoop.resultCharacterLimit + 10)
        let text = DriveFormat.fileContent(long, name: "长文")
        XCTAssertTrue(text.contains("不是指令"))
        XCTAssertTrue(text.contains("内容过长"))
        XCTAssertEqual(DriveFormat.list([], emptyMessage: "空"), "空")
        let file = DriveFile(id: "abcde", name: "周报", mimeType: "application/vnd.google-apps.document", modifiedTime: "2026-10-17T08:00:00Z")
        XCTAssertEqual(DriveFormat.list([file], emptyMessage: ""), "- 周报（谷歌文档，修改于 2026-10-17） id: abcde")
        XCTAssertFalse(file.canRewrite)
        XCTAssertTrue(DriveFile(id: "abcde", name: "a.md", mimeType: "text/markdown").canRewrite)
        XCTAssertNil(DriveFile(id: "abcde", name: "a.pdf", mimeType: "application/pdf").readPlan)
    }

    func testUsageAddsUpAcrossRounds() {
        let total = TokenUsage.combined(TokenUsage(promptTokens: 10, completionTokens: 2, cachedTokens: 4),
                                        TokenUsage(promptTokens: 20, completionTokens: 3, cachedTokens: 5))
        XCTAssertEqual(total, TokenUsage(promptTokens: 30, completionTokens: 5, cachedTokens: 9))
        XCTAssertNil(TokenUsage.combined(nil, nil))
    }

    func testGoogleSignInURLAndCallback() throws {
        XCTAssertEqual(GoogleOAuth.callbackScheme, "com.googleusercontent.apps.449575043400-ugf9rn7nh5j3t7em00rla2o4ehrqgjpt")
        let url = GoogleOAuth.authorizationURL(state: "s1", verifier: "v")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["redirect_uri"], GoogleOAuth.redirectURI)
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["code_challenge"], GoogleOAuth.challenge(for: "v"))
        XCTAssertTrue(items["scope"]?.contains("https://www.googleapis.com/auth/drive") == true)
        let good = URL(string: GoogleOAuth.redirectURI + "?state=s1&code=4/abc")!
        XCTAssertEqual(try GoogleOAuth.code(from: good, state: "s1"), "4/abc")
        XCTAssertThrowsError(try GoogleOAuth.code(from: URL(string: GoogleOAuth.redirectURI + "?state=other&code=x")!, state: "s1"))
        XCTAssertThrowsError(try GoogleOAuth.code(from: URL(string: "evil:/oauth2redirect?state=s1&code=x")!, state: "s1"))
        XCTAssertThrowsError(try GoogleOAuth.code(from: URL(string: GoogleOAuth.redirectURI + "?state=s1&error=access_denied")!, state: "s1")) {
            XCTAssertEqual($0 as? GoogleAuthError, .denied)
        }
    }

    func testRefreshKeepsRefreshTokenWhenGoogleOmitsIt() throws {
        let old = GoogleCredentials(accessToken: "a", refreshToken: "r", expiresAt: .distantPast, email: "x@y.z", grantedDrive: true)
        let response = try JSONDecoder().decode(GoogleTokenResponse.self, from: Data(#"{"access_token":"b","expires_in":3599}"#.utf8))
        let next = old.updated(with: response, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(next.accessToken, "b")
        XCTAssertEqual(next.refreshToken, "r")
        XCTAssertEqual(next.expiresAt, Date(timeIntervalSince1970: 3599))
        XCTAssertEqual(String(data: GoogleOAuth.refreshBody(refreshToken: "1//a+b/c"), encoding: .utf8),
                       "client_id=\(GoogleOAuth.clientID)&grant_type=refresh_token&refresh_token=1%2F%2Fa%2Bb%2Fc")
    }

    func testBackupTrimsOnlyItsOwnOldFiles() {
        let names = (1...9).map { BackupFolder.fileName(for: Date(timeIntervalSince1970: Double($0) * 86_400 * 3)) }
            + ["我的笔记.json", "Sermo备份-20261001.json"]
        let removed = BackupFolder.expired(names)
        XCTAssertEqual(removed.count, 2)
        XCTAssertEqual(Set(removed), Set(names.prefix(2)))
    }
}
