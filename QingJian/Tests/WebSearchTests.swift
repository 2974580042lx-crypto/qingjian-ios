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
        let longQuery = String(repeating: "字", count: 500)
        let longOri = "背景前缀 " + String(repeating: "问", count: 200)
        let data = try WebSearchProtocol.body(query: longQuery, oriQuestion: longOri, count: 99, needContent: true)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sentQuery = try XCTUnwrap(body["query"] as? String)
        let sentOri = try XCTUnwrap(body["ori_question"] as? String)
        XCTAssertEqual(sentQuery.unicodeScalars.count, WebSearchProtocol.maxQueryScalars)
        XCTAssertLessThanOrEqual(sentOri.unicodeScalars.count, WebSearchProtocol.maxQueryScalars)
        XCTAssertTrue(sentOri.hasSuffix("问"))
        XCTAssertEqual(body["count"] as? Int, 50)
        XCTAssertEqual(body["need_content"] as? Bool, true)
    }

    func testIndependentSearchResultsParsingFiltersLowQualityAndPopulatesPages() throws {
        let payload = Data(#"""
        {
          "results": [
            {
              "rerank_score": 2.3,
              "title": "权威文档",
              "url": "https://example.com/good",
              "snippet": "简短摘要",
              "summary": "长摘要内容",
              "content": "完整正文内容",
              "site_name": "Example",
              "date": "2026-11-13T08:00:00+00:00"
            },
            {
              "rerank_score": 2.0,
              "title": "重复链接",
              "url": "https://example.com/good",
              "snippet": "重复",
              "summary": "重复"
            },
            {
              "rerank_score": 0.1,
              "title": "低质营销页",
              "url": "https://example.com/spam",
              "snippet": "低质"
            },
            {
              "rerank_score": 2.5,
              "title": "内网危险页",
              "url": "http://127.0.0.1/secret",
              "snippet": "危险"
            }
          ]
        }
        """#.utf8)
        let result = try WebSearchProtocol.parse(payload)
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.sources.first?.url, "https://example.com/good")
        XCTAssertEqual(result.sources.first?.snippet, "简短摘要")
        XCTAssertTrue(result.summary.contains("长摘要内容"))
        let page = try XCTUnwrap(result.pages["https://example.com/good"])
        XCTAssertTrue(page.contains("来源：Example · 2026-11-13"))
        XCTAssertTrue(page.contains("完整正文内容"))
        XCTAssertNil(result.pages["https://example.com/spam"])

        XCTAssertThrowsError(try WebSearchProtocol.parse(Data(#"{"results":[]}"#.utf8)))
        XCTAssertThrowsError(try WebSearchProtocol.parse(Data(#"{"error":{"message":"bad"}}"#.utf8)))
    }

    func testWebFetchProtocolRequestAndParsing() throws {
        XCTAssertThrowsError(try WebFetchProtocol.body(url: URL(string: "http://192.168.1.1/admin")!))
        let reqData = try WebFetchProtocol.body(url: URL(string: "https://example.com/post")!)
        let reqObj = try XCTUnwrap(JSONSerialization.jsonObject(with: reqData) as? [String: Any])
        XCTAssertEqual(reqObj["url"] as? String, "https://example.com/post")

        let content = String(repeating: "正", count: 60)
        let respData = Data(#"{"title":"测试标题","content":"\#(content)"}"#.utf8)
        let text = try WebFetchProtocol.parse(respData, limit: 40)
        XCTAssertTrue(text.hasPrefix("测试标题\n\n正"))
        XCTAssertTrue(text.hasSuffix("……"))

        let shortData = Data(#"{"title":"短","content":"太短了"}"#.utf8)
        XCTAssertThrowsError(try WebFetchProtocol.parse(shortData))
        XCTAssertThrowsError(try WebFetchProtocol.parse(Data(#"{"error":{"message":"forbidden"}}"#.utf8)))
    }

    func testDeepSeekOCRProtocolMultipartCleanAndParse() throws {
        let boundary = "TestBoundary123"
        let multipart = DeepSeekOCRProtocol.multipartBody(
            data: Data("PDFDATA".utf8),
            fileName: "scan\".pdf",
            mimeType: "application/pdf",
            boundary: boundary
        )
        let multipartText = try XCTUnwrap(String(data: multipart, encoding: .utf8))
        XCTAssertTrue(multipartText.contains("name=\"purpose\"\r\n\r\ntext_recognition"))
        XCTAssertTrue(multipartText.contains("name=\"file\"; filename=\"scan_.pdf\""))
        XCTAssertTrue(multipartText.contains("Content-Type: application/pdf"))
        XCTAssertTrue(multipartText.contains("PDFDATA"))

        let rawOCR = """
        <｜ref｜>第一章 导论<｜/ref｜><｜box｜>[[52, 40, 948, 96]]<｜/box｜>
        <｜ref｜>image<｜/ref｜><｜box｜>[[100, 200, 400, 500]]<｜/box｜>


        这是识别出来的正文。
        """
        let cleaned = DeepSeekOCRProtocol.cleanOCRText(rawOCR)
        XCTAssertEqual(cleaned, "第一章 导论\n\n这是识别出来的正文。")

        let heartbeatJSON = Data("""
        \n\n\n{"id":"ocr-1","pages":[
          {"index":0,"text":"<｜ref｜>标题<｜/ref｜><｜box｜>[[1,2,3,4]]<｜/box｜>\\n第一页正文"},
          {"index":1,"text":"第二页正文"}
        ]}
        """.utf8)
        let pages = try DeepSeekOCRProtocol.parse(heartbeatJSON)
        XCTAssertEqual(pages[0], "标题\n第一页正文")
        XCTAssertEqual(pages[1], "第二页正文")

        let embeddedError = Data(#"{"error":{"message":"OCR did not finish in time"}}"#.utf8)
        XCTAssertThrowsError(try DeepSeekOCRProtocol.parse(embeddedError))
    }

    func testDeepSeekVisionBridgeRequestAndResponseParsing() throws {
        XCTAssertThrowsError(try DeepSeekVisionBridge.requestBody(dataURLs: ["   "]))

        let bodyData = try DeepSeekVisionBridge.requestBody(
            dataURLs: ["data:image/jpeg;base64,abc"],
            userPrompt: "这里说的啥"
        )
        let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        XCTAssertEqual(json?["model"] as? String, "deepseek-flash")
        XCTAssertEqual(json?["stream"] as? Bool, false)
        let thinking = json?["thinking"] as? [String: Any]
        XCTAssertEqual(thinking?["type"] as? String, "disabled")

        let messages = json?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 1)
        XCTAssertEqual(messages?.first?["role"] as? String, "user")

        let parts = messages?.first?["content"] as? [[String: Any]]
        XCTAssertEqual(parts?.count, 2)
        XCTAssertEqual(parts?.first?["type"] as? String, "text")
        XCTAssertTrue((parts?.first?["text"] as? String ?? "").contains("这里说的啥"))
        XCTAssertEqual(parts?.last?["type"] as? String, "image_url")
        let imageObj = parts?.last?["image_url"] as? [String: Any]
        XCTAssertEqual(imageObj?["url"] as? String, "data:image/jpeg;base64,abc")

        let validResp = Data(#"""
        {"choices":[{"message":{"content":"  微信聊天截图：20:12 提醒补充参考文献。  "}}]}
        """#.utf8)
        XCTAssertEqual(try DeepSeekVisionBridge.parseResponse(validResp), "微信聊天截图：20:12 提醒补充参考文献。")

        let blankResp = Data(#"{"choices":[{"message":{"content":"   "}}]}"#.utf8)
        XCTAssertThrowsError(try DeepSeekVisionBridge.parseResponse(blankResp))

        let errResp = Data(#"{"error":{"message":"Model overloaded"}}"#.utf8)
        XCTAssertThrowsError(try DeepSeekVisionBridge.parseResponse(errResp))

        XCTAssertEqual(
            DeepSeekOCRProtocol.cleanOCRText("<|ref|>text<|/ref|><|det|>[[10,20,30,40]]<|/det|> 正文"),
            "正文"
        )
        XCTAssertEqual(
            DeepSeekOCRProtocol.cleanOCRText("<｜ref｜>第一章 导论<｜/ref｜><｜det｜>[[0,0,10,10]]<｜/det｜>"),
            "第一章 导论"
        )
    }
}
