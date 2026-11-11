import XCTest
@testable import DeepSeekCore

// Ported from 研习, plus the Vox-only parts: picture input, thinking summaries,
// per-project service and memory, and data saved by 1.5.1.
final class SubscriptionTests: XCTestCase {
    private func tx() -> SubscriptionTransaction {
        SubscriptionTransaction(state: "one-time-state", nonce: "one-time-nonce", verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", redirectURI: "http://127.0.0.1:49321/auth/callback")
    }
    func testPKCEAndRegistrationNameSermo() throws {
        let t = tx()
        XCTAssertEqual(t.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let url = t.authorizationURL(endpoint: URL(string: "https://auth.openai.com/api/accounts/authorize")!, hostID: "urn:uuid:test-host", clientID: nil, idTokenHint: nil)
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(q.first(where: { $0.name == "agent_name_hint" })?.value, "Sermo")
        XCTAssertEqual(q.first(where: { $0.name == "client_id" })?.value, "dynamic_agent_client")
        XCTAssertEqual(q.first(where: { $0.name == "redirect_uri" })?.value, t.redirectURI)
        XCTAssertTrue(q.first(where: { $0.name == "scope" })?.value?.contains("chatgpt.tokens.use.direct") == true)
        XCTAssertFalse(url.absoluteString.contains(t.verifier))
    }
    func testCallbackRejectsForeignStateHostPathAndDuplicateFields() throws {
        let t = tx(), valid = t.redirectURI + "?code=synthetic&state=one-time-state&client_id=oaiapp_test"
        XCTAssertEqual(try t.validateCallback(URL(string: valid)!, savedClientID: nil).clientID, "oaiapp_test")
        for bad in [valid.replacingOccurrences(of: "127.0.0.1", with: "localhost"), valid.replacingOccurrences(of: "/auth/callback", with: "/callback"), valid.replacingOccurrences(of: "one-time-state", with: "wrong"), valid + "&state=one-time-state", valid + "&code=other", valid.replacingOccurrences(of: "oaiapp_test", with: "dynamic_agent_client")] {
            XCTAssertThrowsError(try t.validateCallback(URL(string: bad)!, savedClientID: nil))
        }
        XCTAssertThrowsError(try t.validateCallback(URL(string: valid)!, savedClientID: "oaiapp_other"))
    }
    func testResponsesPayloadHidesFailedHistoryAndAsksForSummary() throws {
        var settings = AppSettings(); settings.systemPrompt = "项目指令"
        let request = ChatRequest(settings: settings, messages: [ChatMessage(role: .user, content: "问题"), ChatMessage(role: .assistant, content: "失败的答案", state: .failed), ChatMessage(role: .user, content: "再问")])
        let data = try JSONEncoder().encode(SubscriptionRequest(request: request, model: "gpt-5.6-sol", summary: true))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "gpt-5.6-sol")
        XCTAssertEqual(root["store"] as? Bool, false); XCTAssertEqual(root["stream"] as? Bool, true)
        XCTAssertEqual(root["instructions"] as? String, "项目指令")
        XCTAssertNil(root["max_output_tokens"]); XCTAssertNil(root["max_tokens"])
        let reasoning = try XCTUnwrap(root["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["summary"] as? String, "auto"); XCTAssertNil(reasoning["effort"])
        let messages = try XCTUnwrap(root["input"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["content"]! }, ["问题", "再问"])
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SubscriptionRequest(request: request, model: "m"))) as? [String: Any]
        XCTAssertNil(plain?["reasoning"])
    }
    func testPicturesTravelAsInputImageBlocks() throws {
        let item = ResponsesInput(APIMessage(role: "user", content: "看图", images: ["data:image/jpeg;base64,AAAA"]))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        let blocks = try XCTUnwrap(root["content"] as? [[String: String]])
        XCTAssertEqual(blocks.map { $0["type"]! }, ["input_text", "input_image"])
        XCTAssertEqual(blocks[1]["image_url"], "data:image/jpeg;base64,AAAA")
    }
    func testCatalogUsesOnlyReturnedVisibleModels() throws {
        let data = Data(#"{"models":[{"slug":"gpt-5.6-sol","display_name":"GPT-5.6 Sol","visibility":"list"},{"slug":"gpt-6.1-sol","display_name":"GPT-6.1 Sol","visibility":"hidden"}]}"#.utf8)
        XCTAssertEqual(try SubscriptionModel.catalog(data).map(\.slug), ["gpt-5.6-sol"])
    }
    func testStreamParsesTextSummaryParagraphsAndUsage() throws {
        var parser = ResponsesStreamDecoder(); var text = "", thinking = ""; var finalEvent: StreamEvent?
        let source = "\u{FEFF}: keepalive\r\n\r\n"
            + "data: {\"type\":\"response.reasoning_summary_part.added\",\"summary_index\":0}\r\n\r\n"
            + "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"先想\"}\r\n\r\n"
            + "data: {\"type\":\"response.reasoning_summary_part.added\",\"summary_index\":1}\r\n\r\n"
            + "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"再想\"}\r\n\r\n"
            + "data: {\"type\":\"response.output_text.delta\",\"delta\":\"你好\"}\r\n\r\n"
            + "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":12,\"output_tokens\":3,\"input_tokens_details\":{\"cached_tokens\":2}}}}\r\n\r\n"
        for byte in source.utf8 { if let event = try parser.consume(byte) { text += event.content; thinking += event.reasoning; finalEvent = event } }
        XCTAssertEqual(text, "你好"); XCTAssertEqual(thinking, "先想\n\n再想"); XCTAssertTrue(parser.completed)
        XCTAssertEqual(finalEvent?.usage?.totalTokens, 15); XCTAssertEqual(finalEvent?.usage?.cachedTokens, 2)
        XCTAssertEqual(finalEvent?.finishReason, "stop")
    }
    func testDoneAndPartialTextDoNotPretendToBeComplete() throws {
        var parser = ResponsesStreamDecoder()
        for byte in "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\ndata: [DONE]\n\n".utf8 { _ = try parser.consume(byte) }
        _ = try parser.finish(); XCTAssertFalse(parser.completed)
    }
    func testLateQuotaFailureIsReportedAfterText() throws {
        var parser = ResponsesStreamDecoder()
        for byte in "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n".utf8 { _ = try parser.consume(byte) }
        XCTAssertThrowsError(try "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}\n\n".utf8.forEach { _ = try parser.consume($0) }) { error in
            XCTAssertTrue(error.localizedDescription.contains("额度"))
        }
        XCTAssertFalse(parser.completed)
    }
    func testDiscoveryRejectsOffOriginIdentityEndpoints() throws {
        let input = #"{"issuer":"https://auth.openai.com","authorization_endpoint":"https://auth.openai.com/api/accounts/authorize","token_endpoint":"https://evil.invalid/token","jwks_uri":"https://auth.openai.com/keys"}"#
        let config = try JSONDecoder().decode(SubscriptionDiscovery.self, from: Data(input.utf8))
        XCTAssertThrowsError(try config.validated())
    }
    func testTokenEnvelopeRequiresRotationAndExplicitScopes() throws {
        let valid = #"{"access_token":"synthetic-access","refresh_token":"synthetic-refresh","id_token":"synthetic-id","scope":"openid offline_access chatgpt.tokens.use.direct","token_type":"Bearer","expires_in":3600}"#
        XCTAssertTrue(try SubscriptionTokens.decode(Data(valid.utf8)).scopes.contains("chatgpt.tokens.use.direct"))
        let broken = valid.replacingOccurrences(of: "\"refresh_token\":\"synthetic-refresh\",", with: "")
        XCTAssertThrowsError(try SubscriptionTokens.decode(Data(broken.utf8)))
    }
    func testLoopbackRejectsUnrelatedRequestAndDeliversValidCallback() async throws {
        let listener = SubscriptionLoopback(state: "test-loopback-state")
        let url = try await listener.start()
        defer { listener.cancel() }
        XCTAssertEqual(url.host, "127.0.0.1")
        let invalid = URL(string: url.absoluteString + "?code=synthetic&state=wrong")!
        let (_, rejection) = try await URLSession.shared.data(from: invalid)
        XCTAssertEqual((rejection as? HTTPURLResponse)?.statusCode, 400)
        let valid = URL(string: url.absoluteString + "?code=synthetic&state=test-loopback-state&client_id=oaiapp_test")!
        let (_, accepted) = try await URLSession.shared.data(from: valid)
        XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
        let result = try await listener.result(); XCTAssertEqual(result, valid)
    }

    // MARK: Vox data

    func testDataFrom151StillDecodesWithDeepSeekDefaults() throws {
        let settings = #"{"model":"deepseek-flash","thinkingEnabled":true,"effort":"high","systemPrompt":"hello","maxOutputTokens":4096,"contextMessageLimit":200,"contextPolicyVersion":1}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(settings.utf8))
        XCTAssertEqual(decoded.selectedProvider, .deepSeek)
        XCTAssertEqual(decoded.subscriptionModel, SubscriptionModel.fallbackSlug)
        XCTAssertEqual(decoded.selectedSubscriptionEffort, .automatic)
        let project = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","name":"明史研读","instructions":"","documents":[],"isLocked":false,"createdAt":0,"updatedAt":0,"isPinned":true}"#
        let old = try JSONDecoder().decode(ChatProject.self, from: Data(project.utf8))
        XCTAssertEqual(old.service, .deepSeek); XCTAssertFalse(old.remembers); XCTAssertNil(old.memory)
    }
    func testOnlyChatGPTProjectsRememberAndMemoryJoinsThePrompt() throws {
        var project = ChatProject(name: "论文")
        XCTAssertFalse(project.remembers)
        project.provider = .chatGPT
        XCTAssertTrue(project.remembers)
        project.autoMemory = false
        XCTAssertFalse(project.remembers)
        // DeepSeek projects remember only once switched on.
        project.provider = .deepSeek
        XCTAssertFalse(project.remembers)
        project.autoMemory = true
        XCTAssertTrue(project.remembers)
        XCTAssertTrue(ProjectMemory.isExplicitCommand("记住：每天学到晚上十点"))
        XCTAssertTrue(ProjectMemory.isExplicitCommand("  忘掉刚才那条"))
        XCTAssertFalse(ProjectMemory.isExplicitCommand("我忘了昨天背到哪"))
        project.memory = "- 题目定在明代驿传"
        XCTAssertTrue(project.systemPrompt.contains("明代驿传"))
        project.memory = String(repeating: "长", count: ChatProject.memoryCharacterLimit + 1)
        XCTAssertThrowsError(try project.validate())
    }
    func testMemoryTakesOnlyNewSettledMessages() throws {
        var project = ChatProject(name: "论文"); project.provider = .chatGPT
        var thread = ChatThread(); thread.projectID = project.id
        thread.messages = [ChatMessage(role: .user, content: "一"), ChatMessage(role: .assistant, content: "二"),
                           ChatMessage(role: .user, content: "三"), ChatMessage(role: .assistant, content: "半截", state: .failed)]
        XCTAssertEqual(ProjectMemory.pending(thread, in: project).map(\.content), ["一", "二", "三"])
        project.memorizedCounts = [thread.id.uuidString: 2]
        XCTAssertEqual(ProjectMemory.pending(thread, in: project).map(\.content), ["三"])
        XCTAssertThrowsError(try ProjectMemory.request(project: project, thread: thread, new: ProjectMemory.pending(thread, in: project)))
        let request = try ProjectMemory.request(project: project, thread: thread, new: Array(thread.messages.prefix(2)))
        XCTAssertEqual(request.messages.first?.role, "system")
        XCTAssertTrue(request.messages.last?.content.contains("newMessages") == true)
    }
    func testMemoryResultIsCleanedAndCapped() throws {
        var accumulator = MemoryAccumulator()
        accumulator.consume(StreamEvent(content: "```\n- 一条\n```"))
        accumulator.consume(StreamEvent(finishReason: "stop", isDone: true))
        XCTAssertEqual(try accumulator.result(), "- 一条")
        var cut = MemoryAccumulator()
        cut.consume(StreamEvent(content: "- 一条"))
        XCTAssertThrowsError(try cut.result())
    }
    func testSubscriptionAnswersCountTokensButNoMoney() {
        var message = ChatMessage(role: .assistant, content: "答", usage: TokenUsage(promptTokens: 100, completionTokens: 50))
        message.provider = .chatGPT
        var thread = ChatThread(); thread.messages = [message]
        let ledger = UsageLedger.rebuilt(from: [thread])
        XCTAssertEqual(ledger.total.tokens, 150); XCTAssertEqual(ledger.total.cost, 0)
    }
}
