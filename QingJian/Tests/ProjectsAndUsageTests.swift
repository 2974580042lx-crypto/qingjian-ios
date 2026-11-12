import XCTest
@testable import DeepSeekCore

final class ProjectsAndUsageTests: XCTestCase {
    func testProjectPromptUsesOnlyItsInstructionsAndIncludedDocuments() throws {
        var project = ChatProject(name: "明史研读", instructions: "你是一位研究明史的老教授。")
        project.documents = [ProjectDocument(name: "大纲", text: "张居正改革"),
                             ProjectDocument(name: "草稿", text: "SECRET_DRAFT", isIncluded: false)]
        XCTAssertTrue(project.systemPrompt.hasPrefix("你是一位研究明史的老教授。"))
        XCTAssertTrue(project.systemPrompt.contains("《大纲》\n张居正改革"))
        XCTAssertFalse(project.systemPrompt.contains("SECRET_DRAFT"))
        XCTAssertEqual(ChatProject(name: "空项目").systemPrompt, "")

        let request = ChatRequest(settings: AppSettings(), messages: [ChatMessage(role: .user, content: "问")],
                                  systemPrompt: project.systemPrompt)
        XCTAssertEqual(request.messages.first?.role, "system")
        XCTAssertEqual(request.messages.first?.content, project.systemPrompt)
        XCTAssertFalse(request.messages.contains { $0.content == AppSettings.defaultPrompt })
        // An empty project prompt sends no system message rather than falling back to the global one.
        let bare = ChatRequest(settings: AppSettings(), messages: [ChatMessage(role: .user, content: "问")], systemPrompt: "")
        XCTAssertEqual(bare.messages.map(\.role), ["user"])
    }

    func testLongProjectDocumentsAreNotCutToTheSettingsLimit() {
        var project = ChatProject(name: "资料")
        project.documents = [ProjectDocument(name: "长文", text: String(repeating: "史", count: 60000))]
        let request = ChatRequest(settings: AppSettings(), messages: [ChatMessage(role: .user, content: "问")],
                                  systemPrompt: project.systemPrompt)
        XCTAssertGreaterThan(request.messages[0].content.count, 60000)
    }

    func testSuggestionsFollowTheProjectVoice() throws {
        var thread = ChatThread()
        thread.messages = [ChatMessage(role: .user, content: "问"), ChatMessage(role: .assistant, content: "答")]
        let request = try ReplySuggestions.request(for: thread, settings: AppSettings(), style: "PROJECT_VOICE")
        XCTAssertTrue(request.messages.last?.content.contains("PROJECT_VOICE") == true)
        XCTAssertFalse(request.messages.last?.content.contains(String(AppSettings.defaultPrompt.prefix(12))) == true)
    }

    func testSnapshotsWithoutProjectsStillLoadAndProjectsRoundTrip() throws {
        let thread = ChatThread()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: AppSnapshot(settings: AppSettings(), threads: [thread], activeThreadID: thread.id).encoded()) as? [String: Any])
        json.removeValue(forKey: "projects"); json.removeValue(forKey: "usage")
        let old = try AppSnapshot.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.projects)
        XCTAssertNil(old.threads[0].projectID)

        let project = ChatProject(name: "日常")
        var member = ChatThread(); member.projectID = project.id
        var ledger = UsageLedger(); ledger.record(TokenUsage(promptTokens: 10, completionTokens: 5), model: .flash, at: Date())
        let restored = try AppSnapshot.decode(AppSnapshot(settings: AppSettings(), threads: [member], activeThreadID: member.id,
                                                          projects: [project], usage: ledger).encoded())
        XCTAssertEqual(restored.projects?.first?.name, "日常")
        XCTAssertEqual(restored.threads[0].projectID, project.id)
        XCTAssertEqual(restored.usage?.total.tokens, 15)
    }

    func testOversizedProjectIsRejected() {
        var project = ChatProject(name: "太长")
        project.documents = [ProjectDocument(name: "a", text: String(repeating: "字", count: 60000)),
                             ProjectDocument(name: "b", text: String(repeating: "字", count: 60000))]
        XCTAssertThrowsError(try project.validate())
        project.documents[1].isIncluded = false
        XCTAssertNoThrow(try project.validate())
    }

    func testLedgerCountsEveryPaidRequestPerDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 22)))
        var message = ChatMessage(role: .assistant, content: "答", createdAt: day, usage: TokenUsage(promptTokens: 100, completionTokens: 50), model: .pro)
        message.translationUsage = TokenUsage(promptTokens: 20, completionTokens: 10)
        message.replySuggestions = ReplySuggestionBatch(replies: ["好"], usage: TokenUsage(promptTokens: 8, completionTokens: 2), createdAt: day)
        var thread = ChatThread(); thread.messages = [message]
        let ledger = UsageLedger.rebuilt(from: [thread], calendar: calendar)
        let total = ledger.day(day, calendar: calendar)
        XCTAssertEqual(total.tokens, 190)
        XCTAssertEqual(total.requests, 3)
        XCTAssertEqual(total.proTokens, 150)
        XCTAssertEqual(total.flashTokens, 40)
        XCTAssertGreaterThan(total.cost, 0)
        XCTAssertEqual(ledger.days.keys.sorted(), ["2026-10-11"])
        XCTAssertEqual(ledger.favouriteModel, .pro)
    }

    func testImportedLedgerOnlyFillsMissingDaysAndStreakSkipsQuietToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 12)))
        func ago(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: today)! }
        var mine = UsageLedger()
        for offset in 1...3 { mine.record(TokenUsage(promptTokens: 10, completionTokens: 0), model: .flash, at: ago(offset), calendar: calendar) }
        XCTAssertEqual(mine.streak(endingAt: today, calendar: calendar), 3)
        var incoming = UsageLedger()
        incoming.record(TokenUsage(promptTokens: 999, completionTokens: 0), model: .flash, at: ago(1), calendar: calendar)
        incoming.record(TokenUsage(promptTokens: 40, completionTokens: 0), model: .flash, at: ago(10), calendar: calendar)
        mine.merge(missingDaysFrom: incoming)
        XCTAssertEqual(mine.day(ago(1), calendar: calendar).tokens, 10, "A day already on this phone is not counted twice.")
        XCTAssertEqual(mine.day(ago(10), calendar: calendar).tokens, 40)
        XCTAssertEqual(UsageLedger.level(0, peak: 100), 0)
        XCTAssertEqual(UsageLedger.level(10, peak: 100), 1)
        XCTAssertEqual(UsageLedger.level(100, peak: 100), 4)
    }

    func testMarkdownExportKeepsTheConversation() {
        var thread = ChatThread(); thread.title = "明/史:笔记"
        thread.messages = [ChatMessage(role: .user, content: "问题"), ChatMessage(role: .assistant, content: "回答")]
        let text = ConversationExport.markdown(thread, userName: "唐宋")
        XCTAssertTrue(text.hasPrefix("# 明/史:笔记"))
        XCTAssertTrue(text.contains("**唐宋**\n\n问题"))
        XCTAssertTrue(text.contains("**Sermo**\n\n回答"))
        XCTAssertEqual(ConversationExport.fileName(for: thread), "明史笔记.md")
    }

    func testProjectDesignerReadsWrappedJSONAndRejectsEmptyResults() throws {
        let answer = "好的：\n```json\n{\"name\":\" 313复习 \",\"instructions\":\"你是严格的阅卷老师。\",\"memory\":\"- 待补：目标院校\",\"autoMemory\":true,\"summary\":\"每天抽查\"}\n```"
        let draft = try ProjectDesigner.parse(answer)
        XCTAssertEqual(draft.name, "313复习")
        XCTAssertTrue(draft.autoMemory)
        XCTAssertFalse(draft.timeAwareness)
        XCTAssertTrue(draft.isValid)
        XCTAssertThrowsError(try ProjectDesigner.parse("{\"name\":\"空\"}"))
        XCTAssertThrowsError(try ProjectDesigner.parse("没有结果"))
        XCTAssertThrowsError(try ProjectDesigner.request("  ", base: nil))
        let request = try ProjectDesigner.request("健身教练", base: draft)
        XCTAssertNotNil(request)
    }

    func testPureRoleplaySnapshotRoundTripAndCleanChatRequestWithoutReasoningEcho() throws {
        var project = ChatProject(name: "夜谈角色", instructions: "你是直男哥哥，自然生活化地回弟弟的话。")
        project.pureRoleplay = true
        project.documents = [ProjectDocument(name: "人物设定", text: "怕痒，护短，爱嘴硬。")]
        var standalone = ChatThread(title: "单独角色扮演")
        standalone.pureRoleplay = true

        let restored = try AppSnapshot.decode(AppSnapshot(
            settings: AppSettings(),
            threads: [standalone],
            activeThreadID: standalone.id,
            projects: [project]
        ).encoded())
        XCTAssertEqual(restored.projects?.first?.pureRoleplay, true)
        XCTAssertEqual(restored.projects?.first?.isPureRoleplay, true)
        XCTAssertEqual(restored.threads.first?.pureRoleplay, true)

        let rpDraft = try ProjectDesigner.parse("{\"name\":\"小剧场\",\"instructions\":\"保持人设\",\"pureRoleplay\":true}")
        XCTAssertTrue(rpDraft.pureRoleplay)
        let defaultDraft = try ProjectDesigner.parse("{\"name\":\"助手\",\"instructions\":\"帮我查资料\"}")
        XCTAssertFalse(defaultDraft.pureRoleplay)

        var settings = AppSettings()
        settings.model = .pro
        settings.thinkingEnabled = true
        settings.effort = .max
        let history = [
            ChatMessage(role: .user, content: "哥，明天带我出去玩呗"),
            ChatMessage(role: .assistant, content: "行啊，几点起得来？", reasoning: "已思考 1 秒的简短摘要"),
            ChatMessage(role: .user, content: "九点我就到你楼下"),
        ]
        let built = ChatRequest(
            settings: settings,
            messages: history,
            systemPrompt: project.systemPrompt,
            includeReasoning: false
        ).withTools([])

        let data = try JSONEncoder().encode(built)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(payload["tools"])
        XCTAssertEqual(payload["reasoning_effort"] as? String, "max")
        XCTAssertEqual((payload["thinking"] as? [String: Any])?["type"] as? String, "enabled")
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertTrue((messages.first?["content"] as? String)?.contains("怕痒，护短，爱嘴硬。") == true)
        let assistantMessages = messages.filter { ($0["role"] as? String) == "assistant" }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertNil(assistantMessages.first?["reasoning_content"])
    }
}
