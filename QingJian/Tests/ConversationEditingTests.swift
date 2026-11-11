import Foundation
import XCTest
@testable import DeepSeekCore

final class ConversationEditingTests: XCTestCase {
    func testResendingReplacesFollowingContentWithoutChangingThreadIdentity() throws {
        var original = ChatThread()
        original.messages = [ChatMessage(role: .user, content: "三天计划"),
                             ChatMessage(role: .assistant, content: "原回答"),
                             ChatMessage(role: .user, content: "再详细一点")]
        let edited = try ConversationEditing.editedCopy(of: original, messageID: original.messages[0].id, text: "两天计划", resend: true)
        XCTAssertEqual(original.messages.count, 3)
        XCTAssertEqual(original.messages[0].content, "三天计划")
        XCTAssertEqual(edited.messages.map(\.content), ["两天计划"])
        XCTAssertNil(edited.parentThreadID)
        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.messages[0].id, original.messages[0].id)
    }

    func testAssistantEditIsSavedWithoutInventedUsageOrReasoning() throws {
        var original = ChatThread()
        original.messages = [ChatMessage(role: .user, content: "你好"),
            ChatMessage(role: .assistant, content: "原文", reasoning: "原始推理", usage: TokenUsage(promptTokens: 3, completionTokens: 4), isBookmarked: true)]
        let edited = try ConversationEditing.editedCopy(of: original, messageID: original.messages[1].id, text: "修改的正文")
        XCTAssertEqual(edited.messages.last?.role, .assistant)
        XCTAssertEqual(edited.messages.last?.content, "修改的正文")
        XCTAssertEqual(edited.messages.last?.reasoning, "")
        XCTAssertNil(edited.messages.last?.usage)
        XCTAssertEqual(edited.messages.last?.isBookmarked, original.messages.last?.isBookmarked)
        XCTAssertEqual(original.messages.last?.content, "原文")
    }

    func testRetryReusesThreadIdentityAndBuildsTheSameUserContext() throws {
        var original = ChatThread()
        original.messages = [ChatMessage(role: .user, content: "问题"), ChatMessage(role: .assistant, content: "好答案")]
        let retry = try ConversationEditing.retryCopy(of: original)
        XCTAssertEqual(original.messages.last?.content, "好答案")
        XCTAssertEqual(retry.id, original.id)
        XCTAssertEqual(retry.title, original.title)
        XCTAssertEqual(retry.messages.map(\.content), ["问题"])
        XCTAssertEqual(ChatRequest(settings: AppSettings(), messages: retry.messages).messages.last?.content, "问题")
    }

    func testPlainEditKeepsLaterMessagesAndThreadMetadata() throws {
        var original = ChatThread()
        original.title = "我的标题"; original.isPinned = true; original.draft = "未发出的草稿"
        original.messages = [ChatMessage(role: .user, content: "旧问题"),
            ChatMessage(role: .assistant, content: "旧回答"), ChatMessage(role: .user, content: "后续问题")]
        let result = try ConversationEditing.editedCopy(of: original, messageID: original.messages[0].id, text: "改字")
        XCTAssertEqual(result.messages.map(\.content), ["改字", "旧回答", "后续问题"])
        XCTAssertEqual(result.messages.map(\.id), original.messages.map(\.id))
        XCTAssertEqual(result.id, original.id)
        XCTAssertEqual(result.title, original.title)
        XCTAssertEqual(result.createdAt, original.createdAt)
        XCTAssertEqual(result.draft, original.draft)
        XCTAssertEqual(result.isPinned, original.isPinned)
    }

    func testRepeatedRetriesDoNotAccumulateNamesOrLoseEarlierUsage() throws {
        var thread = ChatThread(); thread.title = "日常聊天"
        thread.messages = [ChatMessage(role: .user, content: "第一问"),
            ChatMessage(role: .assistant, content: "第一答", usage: TokenUsage(promptTokens: 10, completionTokens: 20)),
            ChatMessage(role: .user, content: "第二问"), ChatMessage(role: .assistant, content: "旧回答")]
        let id = thread.id, messageID = thread.messages[0].id
        for _ in 0..<5 {
            thread = try ConversationEditing.retryCopy(of: thread)
            thread.messages.append(ChatMessage(role: .assistant, content: "新回答"))
        }
        XCTAssertEqual(thread.id, id)
        XCTAssertEqual(thread.title, "日常聊天")
        XCTAssertEqual(thread.messages.count, 4)
        XCTAssertEqual(thread.messages[0].id, messageID)
        XCTAssertEqual(thread.messages[1].usage?.totalTokens, 30)
    }

    func testLegacyBackupWithoutNewOptionalFieldsStillLoads() throws {
        var original = ChatThread()
        original.messages = [ChatMessage(role: .user, content: "旧记录")]
        let data = try AppSnapshot(settings: AppSettings(), threads: [original], activeThreadID: original.id).encoded()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var threads = try XCTUnwrap(object["threads"] as? [[String: Any]])
        threads[0].removeValue(forKey: "draft")
        threads[0].removeValue(forKey: "isPinned")
        threads[0].removeValue(forKey: "parentThreadID")
        object["threads"] = threads
        let restored = try AppSnapshot.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.threads[0].messages[0].content, "旧记录")
        XCTAssertNil(restored.threads[0].draft)
        XCTAssertNil(restored.threads[0].messages[0].isBookmarked)
    }
}
