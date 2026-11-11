import XCTest
@testable import DeepSeekCore

final class ReplySuggestionTests: XCTestCase {
    func testOneToThreeRepliesPreserveOrderAndRemoveDuplicates() throws {
        XCTAssertEqual(try ReplySuggestions.parse("{\"replies\":[\"  接着聊。  \",\"\",\"接着聊。\",\"我想问一句。\",\"我先听你说。\",\"第四条\"]}"),
                       ["接着聊。", "我想问一句。", "我先听你说。"])
        XCTAssertEqual(try ReplySuggestions.parse("{\"replies\":[\"只有一个自然回应。\"]}"), ["只有一个自然回应。"])
    }

    func testMalformedAndOverlongRepliesAreNotShown() throws {
        XCTAssertThrowsError(try ReplySuggestions.parse("这不是 JSON。"))
        XCTAssertThrowsError(try ReplySuggestions.parse("{\"replies\":[]}"))
        let data = try JSONEncoder().encode(["replies": [String(repeating: "长", count: 241)]])
        XCTAssertThrowsError(try ReplySuggestions.parse(String(decoding: data, as: UTF8.self)))
        XCTAssertEqual(try ReplySuggestions.parse("```json\n{\"replies\":[\"我想再听一听。\"]}\n```"), ["我想再听一听。"])
    }

    func testIncompleteStreamCannotPublishSuggestions() throws {
        var accumulator = ReplySuggestionAccumulator()
        accumulator.consume(StreamEvent(content: "{\"replies\":[\"继续聊。\"]}", finishReason: "stop"))
        XCTAssertThrowsError(try accumulator.result())
        accumulator.consume(StreamEvent(isDone: true))
        XCTAssertEqual(try accumulator.result(), ["继续聊。"])
        var truncated = ReplySuggestionAccumulator()
        truncated.consume(StreamEvent(content: "{\"replies\":[\"继续聊。\"]}", finishReason: "length", isDone: true))
        XCTAssertThrowsError(try truncated.result())
    }

    func testSuggestionRequestUsesOnlyBoundedCurrentThreadText() throws {
        var thread = ChatThread()
        thread.messages = [ChatMessage(role: .user, content: "这段对话的最初设定。")]
        for index in 0..<20 {
            thread.messages.append(ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "CURRENT_\(index) " + String(repeating: "字", count: 3500), reasoning: "HIDDEN_REASONING",
                images: ["PRIVATE_IMAGE.jpg"]))
        }
        let request = try ReplySuggestions.request(for: thread, settings: AppSettings())
        XCTAssertEqual(request.model, DeepSeekModel.pro.rawValue)
        XCTAssertEqual(request.thinking.type, "disabled")
        XCTAssertEqual(request.maxTokens, 1024)
        XCTAssertEqual(request.messages.count, 2)
        XCTAssertEqual(request.messages.last?.role, "user")
        let text = try XCTUnwrap(request.messages.last?.content)
        XCTAssertFalse(text.contains("HIDDEN_REASONING"))
        XCTAssertFalse(text.contains("PRIVATE_IMAGE.jpg"))
        XCTAssertTrue(request.messages.allSatisfy { $0.images.isEmpty })
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
        XCTAssertLessThanOrEqual(messages.count, 9)
        XCTAssertEqual(messages.first?["text"], "这段对话的最初设定。")
        XCTAssertTrue(messages.allSatisfy { ($0["text"]?.count ?? 0) <= 2000 })
    }

    func testStoppedAnswerDoesNotGenerateReplySuggestions() {
        var thread = ChatThread()
        thread.messages = [ChatMessage(role: .user, content: "你好。"), ChatMessage(role: .assistant, content: "未完成", state: .stopped)]
        XCTAssertThrowsError(try ReplySuggestions.request(for: thread, settings: AppSettings()))
    }

    func testOlderSettingsAndMessagesStillDecode() throws {
        var settings = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any])
        settings.removeValue(forKey: "replySuggestionsEnabled")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: settings))
        XCTAssertTrue(decoded.shouldSuggestReplies)
        let message = ChatMessage(role: .assistant, content: "旧版回答。")
        XCTAssertNil(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message)).replySuggestions)
    }

    func testSuggestionsSurviveBackupAndAreClearedWhenAnswerChanges() throws {
        let message = ChatMessage(role: .assistant, content: "原回答。",
            replySuggestions: ReplySuggestionBatch(replies: ["继续聊。"], usage: TokenUsage(promptTokens: 20, completionTokens: 10), createdAt: Date()))
        var thread = ChatThread(); thread.messages = [message]
        let snapshot = AppSnapshot(settings: AppSettings(), threads: [thread], activeThreadID: thread.id)
        let restored = try AppSnapshot.decode(snapshot.encoded())
        XCTAssertEqual(restored.threads[0].messages[0].replySuggestions?.replies, ["继续聊。"])
        let edited = try ConversationEditing.editedCopy(of: thread, messageID: message.id, text: "修改后的回答。")
        XCTAssertNil(edited.messages[0].replySuggestions)
    }
}
