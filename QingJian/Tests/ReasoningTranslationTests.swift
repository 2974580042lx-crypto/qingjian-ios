import Foundation
import XCTest
@testable import DeepSeekCore

final class ReasoningTranslationTests: XCTestCase {
    func testTranslationUsesOnlyCompletedReasoningWithThinkingDisabled() throws {
        let message = ChatMessage(role: .assistant, content: "Private final answer", reasoning: "Consider one small step.")
        let request = try ReasoningTranslation.request(for: message)
        XCTAssertEqual(request.messages.count, 2)
        XCTAssertEqual(request.messages[0].role, "system")
        XCTAssertEqual(request.messages[1], APIMessage(role: "user", content: message.reasoning))
        XCTAssertFalse(request.messages.contains { $0.content.contains(message.content) })
        XCTAssertEqual(request.thinking.type, "disabled")
        XCTAssertNil(request.reasoningEffort)
        XCTAssertEqual(request.model, DeepSeekModel.flash.rawValue)
    }

    func testIncompleteOrMissingReasoningCannotStartTranslation() {
        XCTAssertThrowsError(try ReasoningTranslation.request(for: ChatMessage(role: .assistant, reasoning: "not done", state: .streaming)))
        XCTAssertThrowsError(try ReasoningTranslation.request(for: ChatMessage(role: .assistant, reasoning: " \n ")))
        XCTAssertThrowsError(try ReasoningTranslation.request(for: ChatMessage(role: .user, reasoning: "unexpected")))
    }

    func testOverlongSourceIsRejectedWithoutSilentTruncation() {
        XCTAssertThrowsError(try ReasoningTranslation.request(for: ChatMessage(role: .assistant, reasoning: String(repeating: "a", count: 100001))))
    }

    func testTranslationPublishesOnlyAfterDoneAndPreservesUsage() throws {
        var buffer = TranslationAccumulator()
        buffer.consume(StreamEvent(content: "考虑"))
        buffer.consume(StreamEvent(content: "一个小改变。", finishReason: "stop"))
        XCTAssertThrowsError(try buffer.result())
        let usage = TokenUsage(promptTokens: 20, completionTokens: 8)
        buffer.consume(StreamEvent(usage: usage))
        buffer.consume(StreamEvent(isDone: true))
        XCTAssertEqual(try buffer.result(), "考虑一个小改变。")
        XCTAssertEqual(buffer.usage, usage)
    }

    func testTruncationAndEmptyResponsesNeverBecomeCachedTranslations() {
        for reason in ["length", "content_filter", "aborted"] {
            var buffer = TranslationAccumulator()
            buffer.consume(StreamEvent(content: "不完整", finishReason: reason, isDone: true))
            XCTAssertThrowsError(try buffer.result())
        }
        var empty = TranslationAccumulator()
        empty.consume(StreamEvent(finishReason: "stop", isDone: true))
        XCTAssertThrowsError(try empty.result())
    }

    func testCachedTranslationSurvivesBackupWithoutEnteringChatPayload() throws {
        var thread = ChatThread()
        thread.messages = [ChatMessage(role: .user, content: "question"),
            ChatMessage(role: .assistant, content: "answer", reasoning: "English original", reasoningTranslation: "中文译文", translationUsage: TokenUsage(promptTokens: 4, completionTokens: 5))]
        let snapshot = AppSnapshot(settings: AppSettings(), threads: [thread], activeThreadID: thread.id)
        let restored = try AppSnapshot.decode(snapshot.encoded())
        XCTAssertEqual(restored.threads[0].messages[1].reasoningTranslation, "中文译文")
        XCTAssertEqual(restored.threads[0].messages[1].translationUsage?.totalTokens, 9)
        let payload = ChatRequest(settings: AppSettings(), messages: restored.threads[0].messages)
        XCTAssertFalse(payload.messages.contains { $0.content.contains("中文译文") || $0.content.contains("English original") })
    }

    func testOldRecordWithoutTranslationFieldsLoads() throws {
        var thread = ChatThread()
        thread.messages = [ChatMessage(role: .assistant, content: "old answer", reasoning: "old reasoning")]
        let snapshot = AppSnapshot(settings: AppSettings(), threads: [thread], activeThreadID: thread.id)
        let restored = try AppSnapshot.decode(snapshot.encoded())
        XCTAssertNil(restored.threads[0].messages[0].reasoningTranslation)
        XCTAssertNil(restored.threads[0].messages[0].translationUsage)
        XCTAssertEqual(restored.threads[0].messages[0].reasoning, "old reasoning")
    }

    func testEditClearsOnlyEditedTranslationAndPreservesEarlierUsage() throws {
        var thread = ChatThread()
        thread.messages = [ChatMessage(role: .user, content: "first"),
            ChatMessage(role: .assistant, content: "answer", reasoning: "original", reasoningTranslation: "译文", translationUsage: TokenUsage(promptTokens: 10, completionTokens: 5)),
            ChatMessage(role: .user, content: "follow up")]
        let edited = try ConversationEditing.editedCopy(of: thread, messageID: thread.messages[1].id, text: "new answer")
        XCTAssertNil(edited.messages[1].reasoningTranslation)
        XCTAssertNil(edited.messages[1].translationUsage)
        XCTAssertEqual(thread.messages[1].reasoningTranslation, "译文")
        let laterEdit = try ConversationEditing.editedCopy(of: thread, messageID: thread.messages[2].id, text: "new follow up")
        XCTAssertEqual(laterEdit.messages[1].reasoningTranslation, "译文")
        XCTAssertEqual(laterEdit.messages[1].translationUsage?.totalTokens, 15)
    }
}
