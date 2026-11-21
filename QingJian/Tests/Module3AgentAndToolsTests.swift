import XCTest
import Foundation
@testable import DeepSeekCore

final class Module3AgentAndToolsTests: XCTestCase {

    func testToolCapabilityRegistryAndPermissionPolicies() {
        XCTAssertTrue(ToolCapabilityRegistry.supportsFunctionTools(provider: .deepSeek, colabToolsEnabled: false, compatibleToolsEnabled: true))
        XCTAssertTrue(ToolCapabilityRegistry.supportsFunctionTools(provider: .chatGPT, colabToolsEnabled: false, compatibleToolsEnabled: true))
        XCTAssertFalse(ToolCapabilityRegistry.supportsFunctionTools(provider: .colab, colabToolsEnabled: false, compatibleToolsEnabled: true))
        XCTAssertTrue(ToolCapabilityRegistry.supportsFunctionTools(provider: .colab, colabToolsEnabled: true, compatibleToolsEnabled: true))
        XCTAssertTrue(ToolCapabilityRegistry.supportsFunctionTools(provider: .compatible, colabToolsEnabled: false, compatibleToolsEnabled: true))

        // Issue #16: Compatible and Colab endpoints support direct vision regardless of DeepSeek's V4 Pro setting
        XCTAssertTrue(ToolCapabilityRegistry.supportsDirectVision(provider: .compatible, deepSeekModel: .pro))
        XCTAssertTrue(ToolCapabilityRegistry.supportsDirectVision(provider: .chatGPT, deepSeekModel: .pro))
        XCTAssertTrue(ToolCapabilityRegistry.supportsDirectVision(provider: .deepSeek, deepSeekModel: .flash))
        XCTAssertFalse(ToolCapabilityRegistry.supportsDirectVision(provider: .deepSeek, deepSeekModel: .pro))

        // Permission policy gating
        XCTAssertFalse(ToolCapabilityRegistry.shouldConfirmToolCall(name: "web_search", isIntrinsicWrite: false, policy: .auto))
        XCTAssertTrue(ToolCapabilityRegistry.shouldConfirmToolCall(name: "github_write", isIntrinsicWrite: true, policy: .auto))
        XCTAssertTrue(ToolCapabilityRegistry.shouldConfirmToolCall(name: "web_search", isIntrinsicWrite: false, policy: .alwaysAsk))
        XCTAssertFalse(ToolCapabilityRegistry.shouldConfirmToolCall(name: "manual_read", isIntrinsicWrite: false, policy: .alwaysAsk))

        // Research prompt detection
        XCTAssertFalse(ToolCapabilityRegistry.shouldUseAgentResearchPrompt(userText: "你好", explicitResearchMode: false, hasTools: true))
        XCTAssertTrue(ToolCapabilityRegistry.shouldUseAgentResearchPrompt(userText: "你好", explicitResearchMode: true, hasTools: true))
        XCTAssertTrue(ToolCapabilityRegistry.shouldUseAgentResearchPrompt(
            userText: "请先检索《名公书判清明集》里关于红契投税的三处判词，再对比漆侠先生的观点整理成核对清单。",
            explicitResearchMode: false,
            hasTools: true
        ))
    }

    func testProjectToolAccessAllowsCompatibleProviderAndRespectsChatOnlyPolicy() throws {
        var project = ChatProject(name: "代码审阅")
        project.githubTools = true
        project.webTools = true

        let compatAccess = ProjectToolAccess(
            project: project,
            provider: .compatible,
            colabTools: false,
            compatibleTools: true,
            permissionPolicy: .auto
        )
        XCTAssertNoThrow(try compatAccess.require("github_checks"))
        XCTAssertNoThrow(try compatAccess.require("web_read"))

        let chatOnlyAccess = ProjectToolAccess(
            project: project,
            provider: .compatible,
            colabTools: false,
            compatibleTools: true,
            permissionPolicy: .chatOnly
        )
        XCTAssertThrowsError(try chatOnlyAccess.require("github_checks"))
    }

    func testSubscriptionProtocolStatelessEncryptedReasoningAndUnnamespacedTools() throws {
        let spec = ToolSpec(
            name: "github_checks",
            description: "Check CI runs",
            parameters: ToolSpec.object([("repo", "string", "owner/repo"), ("branch", "string", "branch")], required: ["repo", "branch"])
        )
        var settings = AppSettings()
        settings.provider = .chatGPT
        let baseReq = ChatRequest(
            settings: settings,
            messages: [ChatMessage(role: .user, content: "检查 main 分支编译状态")]
        ).withTools([spec])

        let reasoningItem: JSONValue = .object([
            "type": .string("reasoning"),
            "id": .string("rs_123"),
            "encrypted_content": .string("enc_payload_abc")
        ])
        let call = ToolCall(id: "call_1", name: "github_checks", arguments: "{\"repo\":\"owner/repo\",\"branch\":\"main\"}")
        let multiTurnReq = baseReq.appending([
            .assistantCalls([call], content: "", reasoning: "", subscriptionItems: [reasoningItem]),
            .toolResult("all green", callID: "call_1")
        ])

        let subReq = SubscriptionRequest(request: multiTurnReq, model: "gpt-5.6-sol", effort: .high, summary: true)
        let encodedData = try JSONEncoder().encode(subReq)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedData) as? [String: Any])

        // Issue #14.1: Stateless store=false with reasoning items must request reasoning.encrypted_content
        let include = json["include"] as? [String]
        XCTAssertEqual(include, ["reasoning.encrypted_content"])

        // Issue #14.2: Function tools must not be wrapped in hardcoded "study" namespace
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["type"] as? String, "function")
        XCTAssertEqual(tools.first?["name"] as? String, "github_checks")
        XCTAssertNil(tools.first?["namespace"])

        let inputItems = try XCTUnwrap(json["input"] as? [[String: Any]])
        let fnCallItem = try XCTUnwrap(inputItems.first(where: { $0["type"] as? String == "function_call" }))
        XCTAssertNil(fnCallItem["namespace"], "Echoed function_call must not inject bogus 'study' namespace")

        // Issue #14.3: ResponsesStreamDecoder accepts unnamespaced function_call and avoids argument duplication
        var decoder = ResponsesStreamDecoder()
        let ssePayload = """
        data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_9","name":"web_read","arguments":"{\\"url\\":\\"https://example.com\\"}"}}

        data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\\"url\\":\\"https://example.com\\"}"}

        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","call_id":"call_9","name":"web_read","arguments":"{\\"url\\":\\"https://example.com\\"}"}}

        data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":100,"output_tokens":20}}}


        """
        var collector = ToolCallCollector()
        for byte in ssePayload.utf8 {
            if let ev = try decoder.consume(byte) {
                collector.consume(ev.toolCalls)
            }
        }
        if let tail = try decoder.finish() {
            collector.consume(tail.toolCalls)
        }
        XCTAssertEqual(collector.calls.count, 1)
        XCTAssertEqual(collector.calls.first?.name, "web_read")
        XCTAssertEqual(collector.calls.first?.arguments, "{\"url\":\"https://example.com\"}", "Initial arguments + delta must not concatenate into invalid doubled JSON")
    }

    func testGitHubChecksAllowsMainBranchWhileWritesEnforceSermoPrefix() throws {
        // Issue #20: github_checks is read-only and must allow inspecting "main"
        let checksCall = ToolCall(id: "c1", name: "github_checks", arguments: "{\"repo\":\"2974580042lx-crypto/qingjian-ios\",\"branch\":\"main\"}")
        let checksAction = try GitHubAction(checksCall)
        XCTAssertEqual(checksAction, .checks(repo: "2974580042lx-crypto/qingjian-ios", branch: "main"))

        // Writes and PRs must still strictly enforce sermo/ branch isolation
        let writeCall = ToolCall(id: "c2", name: "github_write", arguments: "{\"repo\":\"2974580042lx-crypto/qingjian-ios\",\"path\":\"README.md\",\"content\":\"hi\",\"branch\":\"main\",\"message\":\"update\"}")
        let writeAction = try GitHubAction(writeCall)
        if case .write(_, _, _, let branch, _) = writeAction {
            XCTAssertEqual(branch, "sermo/main")
        } else {
            XCTFail("Expected .write action")
        }
    }

    func testToolCallCollectorDeduplicatesRepeatedToolNameAndSSEErrorPassthrough() {
        // Issue #22: Some OpenAI-compatible servers repeat the full function name on every chunk
        var collector = ToolCallCollector()
        collector.consume([ToolCallDelta(index: 0, id: "call_1", name: "web_search", arguments: "{\"query\":")])
        collector.consume([ToolCallDelta(index: 0, id: nil, name: "web_search", arguments: "\"宋代红契\"}")])
        XCTAssertEqual(collector.calls.count, 1)
        XCTAssertEqual(collector.calls[0].name, "web_search")
        XCTAssertEqual(collector.calls[0].arguments, "{\"query\":\"宋代红契\"}")

        var sse = SSEDecoder()
        _ = try? sse.consume(line: "data: {\"error\":{\"message\":\"Upstream gateway rate limit\"}}")
        XCTAssertThrowsError(try sse.consume(line: "")) { err in
            XCTAssertTrue(err.localizedDescription.contains("Upstream gateway rate limit"))
            XCTAssertFalse(err.localizedDescription.contains("DeepSeek"))
        }
    }

    func testUsageLedgerExcludesCompatibleProviderFromRMBCost() {
        // Issue #19: Compatible endpoint usage must never be billed as DeepSeek RMB cost
        var ledger = UsageLedger()
        let usage = TokenUsage(promptTokens: 10_000, completionTokens: 5_000)
        ledger.record(usage, model: .pro, at: Date(), provider: .compatible)

        let total = ledger.total
        XCTAssertEqual(total.tokens, 15_000)
        XCTAssertEqual(total.compatibleTokens, 15_000)
        XCTAssertEqual(total.cost, 0.0, accuracy: 0.0001)
        XCTAssertEqual(total.proTokens, 0)
    }

    func testVisionDescriptionCachePersistsAcrossInstances() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sermo-vision-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("vision-cache.json")

        let cache1 = VisionDescriptionCache(fileURL: fileURL, maxEntries: 10)
        cache1.store(description: "附图1：清明集卷四第118页书影", for: "img_001.jpg")
        XCTAssertEqual(cache1.description(for: "img_001.jpg"), "附图1：清明集卷四第118页书影")

        let cache2 = VisionDescriptionCache(fileURL: fileURL, maxEntries: 10)
        XCTAssertEqual(cache2.description(for: "img_001.jpg"), "附图1：清明集卷四第118页书影")

        cache2.storeDescription("【用户附图内容】印章文字：罢归", for: ["img_a.jpg", "img_b.jpg"])
        XCTAssertEqual(cache2.cachedDescription(for: ["img_a.jpg", "img_b.jpg"]), "【用户附图内容】印章文字：罢归")

        // Verify multi-turn ChatRequest imageNoteResolver keeps earlier image notes for V4 Pro (#18)
        var turn1User = ChatMessage(role: .user, content: "帮我看下这两张封面", images: ["img_a.jpg", "img_b.jpg"])
        turn1User.state = .complete
        let turn1Assistant = ChatMessage(role: .assistant, content: "已看到封面。", state: .complete)
        let turn2User = ChatMessage(role: .user, content: "印章上写的两个字是什么？")
        var proSettings = AppSettings()
        proSettings.model = .pro
        let built = ChatRequest(
            settings: proSettings,
            messages: [turn1User, turn1Assistant, turn2User],
            imageLoader: nil,
            imageNoteResolver: { msg in cache2.cachedDescription(for: msg.images ?? []) }
        )
        let firstUserPayload = built.messages.first(where: { $0.role == "user" })?.content ?? ""
        XCTAssertTrue(firstUserPayload.contains("印章文字：罢归"))
        XCTAssertTrue(firstUserPayload.contains("帮我看下这两张封面"))
    }

    func testAgentRunRecordSummaryTimelineSynthesisAndPersistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sermo-agent-runs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("agent-runs.json")

        let threadID = UUID()
        let msgID = UUID()
        var record = AgentRunRecord(messageID: msgID, threadID: threadID, phase: .running)
        record.appendPlanningNote("先检索红白契判词，再核对中华书局页码。")
        record.upsertToolStep(id: "t1", kind: "web", title: "联网搜索：宋代红契投税", status: .done, detail: "命中 5 篇来源")
        record.appendSteeringNote("只保留卷四与卷九原句")
        record.upsertToolStep(id: "t2", kind: "drive", title: "读取云盘《开题报告初稿》", status: .running, detail: nil)

        XCTAssertTrue(record.isActive)
        XCTAssertTrue(record.summaryLine.contains("读取云盘《开题报告初稿》"))
        XCTAssertEqual(record.steeredNotes, ["只保留卷四与卷九原句"])

        record.upsertToolStep(id: "t2", kind: "drive", title: "读取云盘《开题报告初稿》", status: .done, detail: "读取 3,200 字")
        record.finish(phase: .completed)
        XCTAssertFalse(record.isActive)
        XCTAssertFalse(record.summaryLine.isEmpty)
        XCTAssertEqual(record.sheetHeaderTitle, "已完成 4 步工作")

        let runStore = AgentRunStore(fileURL: storeURL)
        runStore.save(record)
        let reloadedStore = AgentRunStore(fileURL: storeURL)
        let loaded = try XCTUnwrap(reloadedStore.record(for: msgID))
        XCTAssertEqual(loaded.steps.count, 4)
        XCTAssertEqual(loaded.steeredNotes, ["只保留卷四与卷九原句"])

        // Legacy synthesis hides silent completed manual_read steps
        var legacyMsg = ChatMessage(role: .assistant, content: "已完成核对。")
        legacyMsg.toolActivity = [
            ToolActivity(id: "m1", title: "已查阅内置规范", status: .done, detail: nil, kind: "manual"),
            ToolActivity(id: "w1", title: "联网搜索：两税法", status: .done, detail: "共 4 篇来源", kind: "web")
        ]
        let synth = try XCTUnwrap(AgentRunRecord.synthesized(from: legacyMsg, threadID: threadID, existing: nil))
        XCTAssertEqual(synth.steps.count, 1)
        XCTAssertEqual(synth.steps.first?.icon, .search)
    }
}
