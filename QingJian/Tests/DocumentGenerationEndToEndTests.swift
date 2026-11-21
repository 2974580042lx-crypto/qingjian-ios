import XCTest
import Foundation
import PDFKit
@testable import DeepSeekCore

/// End-to-end verification tests for Part A: real DOCX / XLSX / PDF tool registration,
/// ChatGPT Subscription (`gpt-6.2-sol`) request payload & Responses SSE function_call decoding,
/// normal chat & project chat deliverable creation + v1 → v2 revision, and honest disabled-tool notices.
final class DocumentGenerationEndToEndTests: XCTestCase {

    func testNormalChatDocxRequestRoutesAndCompilesRealDownloadableFile() throws {
        let userPrompt = "生成一份名为《周一早操汇报稿.docx》的 Word 文档，包含标题和三段正文，直接交付可下载的真实文件。"

        // 1. Intent detection & turn-level enforcement directive
        let detected = DocumentDeliverableRouter.detectExplicitRequest(in: userPrompt)
        XCTAssertEqual(detected, .docx)
        let directive = DocumentDeliverableRouter.turnLevelDirective(for: .docx, isProjectChat: false, hasProjectDocs: false)
        XCTAssertTrue(directive.contains("document_create_docx"))
        XCTAssertTrue(directive.contains("严禁声称"))

        // 2. Verify ChatGPT Subscription (`gpt-6.2-sol`, High) request carries `document_create_docx` cleanly
        let settings = AppSettings()
        var chatReq = ChatRequest(
            settings: settings,
            messages: [ChatMessage(role: .user, content: userPrompt)],
            systemPrompt: settings.systemPrompt + "\n\n" + DocumentStudioTools.systemNote,
            includeReasoning: true
        ).withTools(DocumentStudioTools.specs + SandboxTools.specs)
        chatReq = chatReq.prefixingLastUserMessage(directive)

        let subReq = SubscriptionRequest(
            request: chatReq,
            model: "gpt-6.2-sol",
            effort: .high,
            summary: true,
            nativeWebSearch: true,
            nativeImageGeneration: false
        )
        let payloadData = try JSONEncoder().encode(subReq)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
        let tools = try XCTUnwrap(root["tools"] as? [[String: Any]])
        let fnNames = tools.compactMap { $0["name"] as? String }
        XCTAssertTrue(fnNames.contains("document_create_docx"))
        XCTAssertTrue(fnNames.contains("document_create_xlsx"))
        XCTAssertTrue(fnNames.contains("document_create_pdf"))
        let docxTool = try XCTUnwrap(tools.first { ($0["name"] as? String) == "document_create_docx" })
        XCTAssertEqual(docxTool["type"] as? String, "function")
        XCTAssertNil(docxTool["namespace"])

        // 3. Verify ResponsesStreamDecoder handles ALL SSE function_call argument variants (including `.arguments.done` & `output_item.done`)
        let argsJSON = #"{"title":"周一早操汇报稿.docx","markdown":"# 周一早操汇报稿\n\n第一段：本周一早晨全班按时到操场集合，队列整齐，精神面貌良好。\n\n第二段：本次早操重点完成了热身拉伸与八百米集体慢跑，全员达标。\n\n第三段：下一步将继续加强早起考勤与体能训练，保持稳定节奏。"}"#
        let escapedArgs = String(data: try JSONSerialization.data(withJSONObject: argsJSON, options: [.fragmentsAllowed]), encoding: .utf8)!
        let sse = """
        data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_doc_1","name":"document_create_docx","arguments":""}}

        data: {"type":"response.function_call_arguments.done","output_index":0,"arguments":\(escapedArgs)}

        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","call_id":"call_doc_1","name":"document_create_docx","arguments":\(escapedArgs)}}

        data: {"type":"response.completed","response":{"status":"completed"}}

        """
        var decoder = ResponsesStreamDecoder()
        var collector = ToolCallCollector()
        for byte in sse.utf8 {
            if let ev = try decoder.consume(byte) {
                collector.consume(ev.toolCalls)
            }
        }
        XCTAssertTrue(decoder.completed)
        XCTAssertEqual(collector.calls.count, 1)
        let call = try XCTUnwrap(collector.calls.first)
        XCTAssertEqual(call.name, "document_create_docx")

        // 4. Execute tool, persist to ProjectDeliverableStore, bind to messageID, and verify real OOXML content
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sermo-e2e-normal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = ProjectDeliverableStore(rootDirectory: tempDir)
        let threadID = UUID()
        let messageID = UUID()

        let result = try DocumentStudioTools.execute(call, projectID: nil, threadID: threadID, messageID: messageID, store: store)
        let created = try XCTUnwrap(result.created)
        XCTAssertEqual(created.format, .docx)
        XCTAssertEqual(created.fileName, "周一早操汇报稿.docx")
        XCTAssertEqual(created.messageID, messageID)
        XCTAssertEqual(store.deliverables(forMessage: messageID).map(\.id), [created.id])

        let binary = try store.readData(for: created.id)
        let extracted = try OfficeAndDocumentExtractor.extractDOCX(binary)
        XCTAssertTrue(extracted.contains("周一早操汇报稿"))
        XCTAssertTrue(extracted.contains("第一段"))
        XCTAssertTrue(extracted.contains("第二段"))
        XCTAssertTrue(extracted.contains("第三段"))
    }

    func testProjectChatDocxCreationSavesProjectDeliverableAndRevisesToV2InFollowUpThread() throws {
        let prompt = "根据当前项目的资料生成一份 Word 文档，保存为项目成果，并允许我在后续对话中继续修改。"
        XCTAssertEqual(DocumentDeliverableRouter.detectExplicitRequest(in: prompt), .docx)

        let rootDir = FileManager.default.temporaryDirectory.appendingPathComponent("sermo-e2e-proj-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let library = ProjectLibraryStore(rootDirectory: rootDir.appendingPathComponent("lib", isDirectory: true))
        let deliverables = ProjectDeliverableStore(rootDirectory: rootDir.appendingPathComponent("deliv", isDirectory: true))
        let projectID = UUID()

        _ = try library.ingestDocument(
            projectID: projectID,
            name: "名公书判清明集摘录",
            fileExtension: "pdf",
            text: "【PDF第118页】\n凡民典卖田宅，须凭牙保立契，投税印契者谓之红契；未经官司投税印押者谓之白契。"
        )

        // Thread 1: read library doc + generate v1 DOCX
        let thread1 = UUID()
        let msg1 = UUID()
        let searchCall = ToolCall(id: "c1", name: "project_search_docs", arguments: #"{"query":"红契"}"#)
        let searchOut = try ProjectLibraryTools.execute(searchCall, projectID: projectID, inlineDocuments: [], store: library)
        XCTAssertTrue(searchOut.contains("PDF第118页"))

        let createV1 = ToolCall(
            id: "c2",
            name: "document_create_docx",
            arguments: #"{"title":"宋代红白契考辨","content":"# 宋代红白契考辨\n\n据《名公书判清明集》载，民间典卖田宅投税印契者谓之红契[^1]。\n\n[^1]: 《名公书判清明集》卷四，第118页。"}"#
        )
        let res1 = try DocumentStudioTools.execute(createV1, projectID: projectID, threadID: thread1, messageID: msg1, store: deliverables)
        let v1 = try XCTUnwrap(res1.created)
        XCTAssertEqual(v1.version, 1)
        XCTAssertEqual(v1.projectID, projectID)
        XCTAssertEqual(v1.footnoteCount, 1)

        // Thread 2 (follow-up conversation in the same project): list -> read -> revise to v2
        let thread2 = UUID()
        let msg2 = UUID()
        let listCall = ToolCall(id: "c3", name: "document_list_deliverables", arguments: #"{"project_only":true}"#)
        let listOut = try DocumentStudioTools.execute(listCall, projectID: projectID, threadID: thread2, messageID: msg2, store: deliverables).output
        XCTAssertTrue(listOut.contains(v1.id.uuidString))

        let readCall = ToolCall(id: "c4", name: "document_read_deliverable", arguments: "{\"deliverable_id\":\"\(v1.id.uuidString)\"}")
        let readOut = try DocumentStudioTools.execute(readCall, projectID: projectID, threadID: thread2, messageID: msg2, store: deliverables).output
        XCTAssertTrue(readOut.contains("宋代红白契考辨"))

        let createV2 = ToolCall(
            id: "c5",
            name: "document_create_docx",
            arguments: "{\"title\":\"宋代红白契考辨\",\"markdown\":\"# 宋代红白契考辨（修订版）\\n\\n补充白契效力辨析：未经投税印押者为白契，官司原则上不予受理。\",\"base_deliverable_id\":\"\(v1.id.uuidString)\"}"
        )
        let res2 = try DocumentStudioTools.execute(createV2, projectID: projectID, threadID: thread2, messageID: msg2, store: deliverables)
        let v2 = try XCTUnwrap(res2.created)
        XCTAssertEqual(v2.version, 2)
        XCTAssertEqual(v2.groupID, v1.groupID)
        XCTAssertEqual(v2.fileName, "宋代红白契考辨-v2.docx")
        XCTAssertEqual(deliverables.versions(inGroup: v1.groupID).map(\.version), [2, 1])
        XCTAssertEqual(deliverables.latestDeliverablesByGroup(projectID: projectID, threadID: nil).map(\.id), [v2.id])
    }

    func testExcelNestedSheetsAndPdfToolExecutionRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sermo-e2e-xlsx-pdf-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectDeliverableStore(rootDirectory: dir)

        // Verify Excel works even when a model passes `sheets` as a nested JSON array instead of stringified `sheets_json`
        let xlsxCall = ToolCall(
            id: "x1",
            name: "document_create_xlsx",
            arguments: #"{"filename":"成绩统计表.xlsx","sheets":[{"name":"统计","headers":["姓名","分数"],"rows":[["张三","95"],["李四","88"]]}]}"#
        )
        let xlsxRes = try DocumentStudioTools.execute(xlsxCall, projectID: nil, threadID: UUID(), messageID: UUID(), store: store)
        let xlsxItem = try XCTUnwrap(xlsxRes.created)
        XCTAssertEqual(xlsxItem.format, .xlsx)
        let xlsxText = try OfficeAndDocumentExtractor.extractXLSX(try store.readData(for: xlsxItem.id))
        XCTAssertTrue(xlsxText.contains("张三"))
        XCTAssertTrue(xlsxText.contains("95"))

        // Verify PDF tool call produces valid PDFKit document
        let pdfCall = ToolCall(
            id: "p1",
            name: "document_create_pdf",
            arguments: #"{"title":"复习提纲","content":"# 313 历史学复习提纲\n\n第一部分：两税法与宋代土地制度。\n\n第二部分：明清一条鞭法与摊丁入亩。"}"#
        )
        let pdfRes = try DocumentStudioTools.execute(pdfCall, projectID: nil, threadID: UUID(), messageID: UUID(), store: store)
        let pdfItem = try XCTUnwrap(pdfRes.created)
        XCTAssertEqual(pdfItem.format, .pdf)
        let pdfDoc = try XCTUnwrap(PDFDocument(data: try store.readData(for: pdfItem.id)))
        XCTAssertGreaterThanOrEqual(pdfDoc.pageCount, 1)
        XCTAssertTrue((pdfDoc.page(at: 0)?.string ?? "").contains("复习提纲"))
    }

    func testResponsesDecoderHandlesDirectOutputItemDoneAndDisabledToolsHonestNotice() throws {
        // Direct function_call in output_item.done without prior output_item.added or delta
        let sse = """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","call_id":"call_direct","name":"document_create_pdf","namespace":"","arguments":"{\\"title\\":\\"简报\\",\\"markdown\\":\\"正文\\"}"}}

        data: {"type":"response.completed","response":{"status":"completed"}}

        """
        var decoder = ResponsesStreamDecoder()
        var collector = ToolCallCollector()
        for b in sse.utf8 {
            if let ev = try decoder.consume(b) { collector.consume(ev.toolCalls) }
        }
        XCTAssertEqual(collector.calls.count, 1)
        XCTAssertEqual(collector.calls.first?.name, "document_create_pdf")
        XCTAssertTrue(collector.calls.first?.arguments.contains("简报") == true)

        // Disabled tool honesty check & non-false-positive detection
        XCTAssertNil(DocumentDeliverableRouter.detectExplicitRequest(in: "什么是 docx 格式？"))
        XCTAssertEqual(DocumentDeliverableRouter.detectExplicitRequest(in: "帮我导出一个 Excel 表格汇总数据"), .xlsx)
        XCTAssertEqual(DocumentDeliverableRouter.detectExplicitRequest(in: "把这些整理成 PDF 文件给我下载"), .pdf)
        let rpNote = DocumentDeliverableRouter.toolsUnavailableSystemNote(for: .docx, reason: .pureRoleplay)
        XCTAssertTrue(rpNote.contains("纯角色扮演模式"))
        let chatOnlyNote = DocumentDeliverableRouter.toolsUnavailableSystemNote(for: .docx, reason: .chatOnlyPolicy)
        XCTAssertTrue(chatOnlyNote.contains("仅纯聊天"))
    }
}
