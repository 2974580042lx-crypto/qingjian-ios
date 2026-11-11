import XCTest
@testable import DeepSeekCore

final class ProtocolTests: XCTestCase {
    func testChineseContentAndReasoningAreSeparate() throws {
        var decoder = SSEDecoder()
        XCTAssertNil(try decoder.consume(line: #"data: {"choices":[{"delta":{"content":"答案","reasoning_content":"先想一想"}}]}"#))
        let event = try XCTUnwrap(decoder.consume(line: ""))
        XCTAssertEqual(event.content, "答案")
        XCTAssertEqual(event.reasoning, "先想一想")
    }
    func testCommentsCRLFAndDone() throws {
        var decoder = SSEDecoder()
        XCTAssertNil(try decoder.consume(line: ": keep-alive\r"))
        XCTAssertNil(try decoder.consume(line: "\r"))
        XCTAssertNil(try decoder.consume(line: "data: [DONE]\r"))
        XCTAssertTrue(try XCTUnwrap(decoder.consume(line: "\r")).isDone)
    }
    func testUsageOnTheFinalContentChunk() throws {
        var decoder = SSEDecoder()
        _ = try decoder.consume(line: #"data: {"choices":[{"delta":{"content":""},"finish_reason":"stop"}],"usage":{"prompt_tokens":17,"completion_tokens":9,"prompt_cache_hit_tokens":4}}"#)
        let event = try XCTUnwrap(decoder.consume(line: ""))
        XCTAssertEqual(event.finishReason, "stop")
        XCTAssertEqual(event.usage, TokenUsage(promptTokens: 17, completionTokens: 9, cachedTokens: 4))
    }
    func testOptionalUsageOnlyChunkAndCachedTokenFallback() throws {
        var decoder = SSEDecoder()
        _ = try decoder.consume(line: #"data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":20,"prompt_tokens_details":{"cached_tokens":80}}}"#)
        let event = try XCTUnwrap(decoder.consume(line: ""))
        XCTAssertEqual(event.content, "")
        XCTAssertEqual(event.usage?.cachedTokens, 80)
    }
    func testMultilineEventAndTrailingFlush() throws {
        var decoder = SSEDecoder()
        _ = try decoder.consume(line: #"data: {"choices": ["#)
        _ = try decoder.consume(line: #"data: {"delta":{"content":"hello"}}]}"#)
        XCTAssertEqual(try decoder.flush()?.content, "hello")
        XCTAssertNil(try decoder.flush())
    }
    func testMalformedAndErrorEventsAreNotSilentlyIgnored() throws {
        var malformed = SSEDecoder()
        _ = try malformed.consume(line: "data: this is not JSON")
        XCTAssertThrowsError(try malformed.consume(line: ""))
        var serverError = SSEDecoder()
        _ = try serverError.consume(line: #"data: {"error":{"message":"server busy"}}"#)
        XCTAssertThrowsError(try serverError.consume(line: ""))
    }
    func testThinkingDisabledRequestDoesNotSendConflictingEffort() throws {
        var settings = AppSettings()
        settings.thinkingEnabled = false
        let request = ChatRequest(settings: settings, messages: [ChatMessage(role: .user, content: "hello")])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertNil(json["reasoning_effort"])
        XCTAssertEqual((json["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertEqual(json["model"] as? String, "deepseek-flash")
        XCTAssertEqual(json["stream"] as? Bool, true)
    }
    func testIncompleteAnswersAndReasoningAreExcludedFromFutureContext() throws {
        let messages = [
            ChatMessage(role: .user, content: "第一问"),
            ChatMessage(role: .assistant, content: "完整回答", reasoning: "不回传这个"),
            ChatMessage(role: .user, content: "第二问"),
            ChatMessage(role: .assistant, content: "不完整回答", state: .stopped),
            ChatMessage(role: .user, content: "继续")
        ]
        let request = ChatRequest(settings: AppSettings(), messages: messages)
        XCTAssertEqual(request.messages.map(\.content).suffix(4), ["第一问", "完整回答", "第二问", "继续"])
        let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertFalse(encoded.contains("reasoning_content"))
        XCTAssertFalse(encoded.contains("不完整回答"))
    }
    func testTruncatedHistoryStartsWithUserAfterSystemPrompt() {
        var settings = AppSettings()
        settings.contextMessageLimit = 2
        let messages = [
            ChatMessage(role: .user, content: "旧问题"),
            ChatMessage(role: .assistant, content: "旧回答"),
            ChatMessage(role: .user, content: "新问题")
        ]
        let request = ChatRequest(settings: settings, messages: messages)
        XCTAssertEqual(request.messages.map(\.role), ["system", "user"])
        XCTAssertEqual(request.messages.last?.content, "新问题")
    }
    func testBackupRoundTripContainsNoAPIKeyField() throws {
        let fixedDate = Date(timeIntervalSince1970: 1700000000)
        var thread = ChatThread()
        thread.createdAt = fixedDate
        thread.updatedAt = fixedDate
        thread.messages = [ChatMessage(role: .user, content: "备份正文", createdAt: fixedDate),
                           ChatMessage(role: .assistant, content: "回答", createdAt: fixedDate,
                                       usage: TokenUsage(promptTokens: 10, completionTokens: 20))]
        let snapshot = AppSnapshot(settings: AppSettings(), threads: [thread], activeThreadID: thread.id)
        let data = try snapshot.encoded()
        let restored = try AppSnapshot.decode(data)
        XCTAssertEqual(restored.threads, snapshot.threads)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("apiKey"))
        XCTAssertFalse(text.contains("api_key"))
        XCTAssertFalse(text.contains("Authorization"))
    }
    func testUnknownVersionAndDuplicateIDsAreRejected() throws {
        let thread = ChatThread()
        var future = AppSnapshot(settings: AppSettings(), threads: [thread], activeThreadID: thread.id)
        future.version = 99
        XCTAssertThrowsError(try future.validate())
        let duplicate = AppSnapshot(settings: AppSettings(), threads: [thread, thread], activeThreadID: thread.id)
        XCTAssertThrowsError(try duplicate.validate())
        var duplicateMessages = thread
        let message = ChatMessage(role: .user, content: "重复编号")
        duplicateMessages.messages = [message, message]
        XCTAssertThrowsError(try AppSnapshot(settings: AppSettings(), threads: [duplicateMessages], activeThreadID: thread.id).validate())
    }
    func testSettingsAreBoundedOnImport() {
        var settings = AppSettings()
        settings.maxOutputTokens = -1
        settings.contextMessageLimit = 1000000
        settings.systemPrompt = String(repeating: "字", count: 20001)
        let validated = settings.validated()
        XCTAssertEqual(validated.maxOutputTokens, 1024)
        XCTAssertEqual(validated.contextMessageLimit, 400)
        XCTAssertEqual(validated.systemPrompt.count, 20000)
    }
}
