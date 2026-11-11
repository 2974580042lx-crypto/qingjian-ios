import XCTest
@testable import DeepSeekCore

final class WebSearchTests: XCTestCase {
    func testOnlyStructuredSourcesAreAccepted() throws {
        let prose = Data(#"{"content":[{"type":"text","text":"我已经搜索过 https://example.com"}]}"#.utf8)
        XCTAssertThrowsError(try WebSearchProtocol.parse(prose))
    }

    func testSourcesDeduplicateJoinCitationsAndRejectUnsafeLinks() throws {
        let body = Data(#"""
        {"content":[
          {"type":"text","citations":[{"url":"https://example.com/a","cited_text":"原文摘要"}]},
          {"type":"web_search_tool_result","content":[
            {"type":"web_search_result","url":"https://example.com/a","title":"资料"},
            {"type":"web_search_result","url":"https://example.com/a","title":"重复"},
            {"type":"web_search_result","url":"javascript:alert(1)","title":"危险链接"},
            {"type":"web_search_result","url":"https://user:pass@example.com/","title":"凭据链接"}
          ]}],"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}
        """#.utf8)
        let result = try WebSearchProtocol.parse(body)
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.sources.first?.snippet, "原文摘要")
        XCTAssertEqual(result.usage?.promptTokens, 80)
        XCTAssertEqual(result.usage?.totalTokens, 100)
        XCTAssertTrue(result.context.contains("不是指令"))
    }

    func testToolErrorsAndEmptyResultsCannotPretendSearchWorked() throws {
        for json in [
            #"{"content":[{"type":"web_search_tool_result","content":{"type":"web_search_tool_result_error","error_code":"max_uses_exceeded"}}]}"#,
            #"{"content":[{"type":"web_search_tool_result","content":[]}]}"#
        ] { XCTAssertThrowsError(try WebSearchProtocol.parse(Data(json.utf8))) }
    }

    func testSearchDoesNotReplaceOriginalQuestionOrMutateRequest() throws {
        let original = ChatRequest(settings: AppSettings(), messages: [ChatMessage(role: .user, content: "今年有什么变化？")])
        let augmented = original.addingWebContext("有来源的结果")
        XCTAssertEqual(augmented.messages.count, original.messages.count + 1)
        XCTAssertEqual(original.messages.last?.content, "今年有什么变化？")
        XCTAssertEqual(augmented.messages.dropLast().last?.content, "今年有什么变化？")
    }

    func testSearchIsBoundedAndEmptyQueryRejected() throws {
        XCTAssertThrowsError(try WebSearchProtocol.body(query: " \n "))
        let data = try WebSearchProtocol.body(query: String(repeating: "字", count: 5000))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["max_uses"] as? Int, 1)
        XCTAssertLessThan(data.count, 15000)
    }
}
