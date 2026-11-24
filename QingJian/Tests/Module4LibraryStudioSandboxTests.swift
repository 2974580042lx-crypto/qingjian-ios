import XCTest
import Foundation
import PDFKit
@testable import DeepSeekCore

final class Module4LibraryStudioSandboxTests: XCTestCase {

    func testProjectLibrarySQLiteFTS5ChineseExactPhraseAndSectionRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sermo-lib-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProjectLibraryStore(rootDirectory: dir)
        let projectID = UUID()

        let docText = """
        【PDF第118页】
        卷四·户婚门·争业上：凡民典卖田宅，须凭牙保立契，投税印契者谓之红契；未经官司投税印押者谓之白契。白契虽有中人画字，官司不予受理。

        【PDF第312页】
        卷九·户婚门·先尽亲邻：宋律规定，凡典卖田宅，须先尽亲邻，次及典主。若未问亲邻而私自成交，亲邻于法定期限内可执价收赎。
        """

        let imported = try store.ingestDocument(
            projectID: projectID,
            name: "名公书判清明集（中华书局点校本）",
            fileExtension: "pdf",
            text: docText
        )
        XCTAssertEqual(imported.name, "名公书判清明集（中华书局点校本）")
        XCTAssertGreaterThanOrEqual(imported.chunkCount, 1)

        // Exact Chinese legal term search with page anchor
        let hits = try store.search(projectID: projectID, query: "先尽亲邻", documentNameFilter: nil, limit: 5)
        XCTAssertFalse(hits.isEmpty)
        let first = try XCTUnwrap(hits.first)
        XCTAssertTrue(first.excerpt.contains("先尽亲邻"))
        XCTAssertEqual(first.pageLabel, "PDF第312页")

        // Second phrase search
        let redHits = try store.search(projectID: projectID, query: "红契", documentNameFilter: nil, limit: 5)
        XCTAssertFalse(redHits.isEmpty)
        XCTAssertTrue(redHits.first?.excerpt.contains("投税印契者谓之红契") == true)
        XCTAssertEqual(redHits.first?.pageLabel, "PDF第118页")

        // Verbatim section read
        let section = try store.readSection(projectID: projectID, documentID: imported.id, chunkIndex: first.chunkIndex, window: 1)
        XCTAssertTrue(section.contains("先尽亲邻"))
        XCTAssertTrue(section.contains("PDF第312页"))

        // Deletion leaves empty index cleanly
        try store.deleteDocument(projectID: projectID, documentID: imported.id)
        let remaining = try store.listDocuments(projectID: projectID)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testProjectLibraryLargeCorpusAndToolDispatch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sermo-lib-large-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProjectLibraryStore(rootDirectory: dir)
        let projectID = UUID()

        // Build ~120,000-char corpus with a unique historical needle deep inside
        let fillerParagraph = "宋代乡村土地流转频繁，田宅典卖契约在东南诸路尤为发达，乡司税契册籍详载户名四至与亩数。\n"
        let repeated = String(repeating: fillerParagraph, count: 1400)
        let largeDoc = """
        ## 第一章 绪论
        \(repeated)
        ## 第七章 漆侠《宋代经济史》下册摘录
        【PDF第742页】
        漆侠指出：两宋时期“不抑兼并”政策下，官田私田化与土地商品化并进，红契投税制度成为国家掌控田赋的重要抓手。
        """

        let meta = try store.ingestDocument(
            projectID: projectID,
            name: "漆侠_宋代经济史_下册",
            fileExtension: "pdf",
            text: largeDoc
        )
        XCTAssertGreaterThan(meta.characterCount, 50_000)
        XCTAssertGreaterThan(meta.chunkCount, 40)

        let listCall = ToolCall(id: "c1", name: "project_list_docs", arguments: "{}")
        let listOut = try ProjectLibraryTools.execute(listCall, projectID: projectID, inlineDocuments: [], store: store)
        XCTAssertTrue(listOut.contains("漆侠_宋代经济史_下册"))

        let searchCall = ToolCall(id: "c2", name: "project_search_docs", arguments: "{\"query\":\"不抑兼并\"}")
        let searchOut = try ProjectLibraryTools.execute(searchCall, projectID: projectID, inlineDocuments: [], store: store)
        XCTAssertTrue(searchOut.contains("PDF第742页"))
        XCTAssertTrue(searchOut.contains("官田私田化"))
    }

    func testFilenameFilterPrecedesCandidateLimitAndWildcardIsLiteral() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectLibraryStore(rootDirectory: dir)
        let project = UUID()
        for i in 0..<12 {
            _ = try store.ingestDocument(projectID: project, name: "旧稿\(i)", fileExtension: "txt", text: "红契")
        }
        let target = try store.ingestDocument(projectID: project, name: "定稿", fileExtension: "txt", text: "红契及其使用说明")
        XCTAssertEqual(try store.search(projectID: project, query: "红契", documentNameFilter: "定稿", limit: 1).first?.documentID, target.id)
        XCTAssertTrue(try store.search(projectID: project, query: "%").isEmpty)
        XCTAssertThrowsError(try store.readSection(projectID: project, documentID: target.id, chunkIndex: Int.max))
    }

    func testDocxCompilerProducesValidOOXMLWithRealFootnotesAndRoundTrips() throws {
        let markdown = """
        # 第三节 宋代红白契争讼考辨

        宋代民间田宅交易须经官府投税印契方为有效[^1]。若仅有私约而未投税，涉讼时往往不被采信[^2]。

        | 契约类型 | 是否投税 | 法律效力 |
        | --- | --- | --- |
        | 红契 | 已投税印押 | 官司采信 |
        | 白契 | 未投税 | 原则上不受理 |

        [^1]: 《名公书判清明集》卷四《户婚门·争业上》，中华书局 1987 年版，第 118 页。
        [^2]: 漆侠：《宋代经济史》下册，中华书局版，第 742 页。
        """

        let spec = DocxDocumentSpec(
            title: "第三节 宋代红白契争讼考辨",
            markdown: markdown,
            useCircledNumbers: true,
            restartFootnotesPerPage: true
        )
        let compiled = try DocumentStudioCompiler.compileDOCX(spec)
        XCTAssertEqual(compiled.footnoteCount, 2)
        XCTAssertGreaterThan(compiled.data.count, 500)

        // Inspect OOXML structure directly via StreamZipReader
        let zip = try StreamZipReader(data: compiled.data)
        XCTAssertNotNil(zip.entry(named: "[Content_Types].xml"))
        XCTAssertNotNil(zip.entry(named: "word/document.xml"))
        XCTAssertNotNil(zip.entry(named: "word/footnotes.xml"))
        let settingsEntry = try XCTUnwrap(zip.entry(named: "word/settings.xml"))
        let settingsXML = String(decoding: try zip.readEntry(settingsEntry), as: UTF8.self)
        XCTAssertTrue(settingsXML.contains("decimalEnclosedCircle"))
        XCTAssertTrue(settingsXML.contains("eachPage"))

        // Round-trip through Sermo's own DOCX extractor
        let extracted = try OfficeAndDocumentExtractor.extractDOCX(compiled.data)
        XCTAssertTrue(extracted.contains("第三节 宋代红白契争讼考辨"))
        XCTAssertTrue(extracted.contains("[注1]"))
        XCTAssertTrue(extracted.contains("[注2]"))
        XCTAssertTrue(extracted.contains("中华书局 1987 年版，第 118 页"))
        XCTAssertTrue(extracted.contains("漆侠：《宋代经济史》下册"))
        XCTAssertTrue(extracted.contains("红契"))
    }

    func testXlsxCompilerProducesValidMultiSheetWorkbookAndRoundTrips() throws {
        let sheet1 = XlsxSheetSpec(
            name: "清明集判词核对",
            headers: ["编号", "卷次", "关键词", "页码"],
            rows: [
                ["1", "卷四", "红契 & 投税", "118"],
                ["2", "卷九", "先尽亲邻 <原句>", "312"]
            ]
        )
        let sheet2 = XlsxSheetSpec(
            name: "参考文献",
            headers: ["作者", "书名"],
            rows: [["漆侠", "宋代经济史"]]
        )

        let compiled = try DocumentStudioCompiler.compileXLSX(XlsxWorkbookSpec(sheets: [sheet1, sheet2]))
        XCTAssertGreaterThan(compiled.data.count, 500)

        let extracted = try OfficeAndDocumentExtractor.extractXLSX(compiled.data)
        XCTAssertTrue(extracted.contains("## 清明集判词核对"))
        XCTAssertTrue(extracted.contains("红契 & 投税"))
        XCTAssertTrue(extracted.contains("先尽亲邻 <原句>"))
        XCTAssertTrue(extracted.contains("312"))
        XCTAssertTrue(extracted.contains("## 参考文献"))
        XCTAssertTrue(extracted.contains("漆侠"))
    }

    func testPdfCompilerProducesValidMultiPageChineseVectorPDF() throws {
        let longBody = (1...45).map { idx in
            "第 \(idx) 段：宋代乡村社会的土地流转不仅体现在红白契的订立与投税，还深刻影响着宗族亲邻优先购买权与基层乡司治理结构。"
        }.joined(separator: "\n\n")
        let markdown = "# 宋代土地流转与乡村社会初稿\n\n\(longBody)"

        let pdfData = try DocumentStudioCompiler.compilePDF(title: "宋代土地流转与乡村社会初稿", markdown: markdown)
        XCTAssertGreaterThan(pdfData.count, 1000)
        XCTAssertTrue(pdfData.starts(with: Data("%PDF-".utf8)))

        let doc = try XCTUnwrap(PDFDocument(data: pdfData))
        XCTAssertGreaterThanOrEqual(doc.pageCount, 2, "Long document must paginate into multiple A4 pages")
        let fullText = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
        XCTAssertTrue(fullText.contains("宋代土地流转与乡村社会初稿"))
        XCTAssertTrue(fullText.contains("第 45 段"))
    }

    func testProjectDeliverableStoreVersioningAndBackupRoundTrip() throws {
        let rootA = FileManager.default.temporaryDirectory.appendingPathComponent("sermo-deliv-a-\(UUID().uuidString)", isDirectory: true)
        let rootB = FileManager.default.temporaryDirectory.appendingPathComponent("sermo-deliv-b-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }

        let storeA = ProjectDeliverableStore(rootDirectory: rootA)
        let projectID = UUID()
        let threadID = UUID()
        let msg1 = UUID()
        let msg2 = UUID()

        let v1 = try storeA.saveDeliverable(
            projectID: projectID,
            threadID: threadID,
            messageID: msg1,
            title: "第三节_宋代红白契争讼考辨",
            format: .docx,
            data: Data("v1-bytes".utf8),
            sourcePreview: "初稿正文 v1",
            summary: "初稿",
            footnoteCount: 4,
            baseDeliverableID: nil
        )
        XCTAssertEqual(v1.version, 1)

        let v2 = try storeA.saveDeliverable(
            projectID: projectID,
            threadID: threadID,
            messageID: msg2,
            title: "第三节_宋代红白契争讼考辨",
            format: .docx,
            data: Data("v2-bytes-updated".utf8),
            sourcePreview: "修订稿正文 v2",
            summary: "修订版",
            footnoteCount: 8,
            baseDeliverableID: v1.id
        )
        XCTAssertEqual(v2.version, 2)
        XCTAssertEqual(v2.groupID, v1.groupID)
        XCTAssertEqual(try storeA.readData(for: v1.id), Data("v1-bytes".utf8), "v1 must remain intact on disk")
        XCTAssertEqual(try storeA.readData(for: v2.id), Data("v2-bytes-updated".utf8))
        XCTAssertEqual(storeA.versions(inGroup: v1.groupID).map(\.version), [2, 1])

        // Backup export & restore into clean storeB
        let manifest = try storeA.exportBackupBundle()
        XCTAssertFalse(manifest.isEmpty)

        let storeB = ProjectDeliverableStore(rootDirectory: rootB)
        try storeB.restoreBackupBundle(manifest, mode: .replace)
        XCTAssertEqual(storeB.deliverables(forMessage: msg1).count, 1)
        XCTAssertEqual(storeB.deliverables(forMessage: msg2).count, 1)
        XCTAssertEqual(try storeB.readData(for: v2.id), Data("v2-bytes-updated".utf8))
    }

    func testSandboxToolsValidationAndStaticHTMLCheck() throws {
        let jsCall = ToolCall(id: "s1", name: "sandbox_run_js", arguments: "{\"code\":\"return 6 * 7;\"}")
        let jsAction = try SandboxAction(jsCall)
        if case .runJS(let code, _) = jsAction {
            XCTAssertEqual(code, "return 6 * 7;")
        } else {
            XCTFail("Expected .runJS")
        }

        let emptyCall = ToolCall(id: "s2", name: "sandbox_run_js", arguments: "{\"code\":\"   \"}")
        XCTAssertThrowsError(try SandboxAction(emptyCall))

        let brokenHTML = "<html><body><h1>标题</h1><script>const x = 1;</body></html>"
        let issues = SandboxTools.staticHTMLIssues(in: brokenHTML)
        XCTAssertFalse(issues.isEmpty, "Unclosed <script> tag must be caught by static HTML validator")

        let cleanHTML = "<!DOCTYPE html><html><head><title>测试页</title></head><body><h1>正常</h1><script>console.log(1);</script></body></html>"
        XCTAssertTrue(SandboxTools.staticHTMLIssues(in: cleanHTML).isEmpty)
    }
}
