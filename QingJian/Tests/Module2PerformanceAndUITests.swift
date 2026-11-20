import XCTest
import Foundation
@testable import DeepSeekCore

final class Module2PerformanceAndUITests: XCTestCase {

    func testPendingDocumentDecodeDeterministicIDsAndEditableUserText() {
        let doc1 = PendingDocument(name: "清明集卷四", fileExtension: "docx", text: "交易必立红契，投税方为官凭。")
        let doc2 = PendingDocument(name: "页码核对表", fileExtension: "xlsx", text: "p.118\tp.312")
        let quoted = MessageQuoteCodec.encode(
            quote: QuotedMessage(author: "Sermo", excerpt: "先核对卷四原句"),
            userText: "请按这两个附件补充第三节页下注。"
        )
        let encoded = PendingDocumentCodec.encode(userText: quoted, documents: [doc1, doc2])

        let first = PendingDocumentCodec.decode(encoded)
        let second = PendingDocumentCodec.decode(encoded)
        XCTAssertEqual(first.attachments, second.attachments, "Repeated decodes must yield identical deterministic IDs for SwiftUI Equatable stability")
        XCTAssertEqual(first.attachments.count, 2)
        XCTAssertEqual(first.attachments[0].id, "0|清明集卷四|docx|\(doc1.characterCount)")

        let editable = PendingDocumentCodec.extractEditableUserText(encoded)
        XCTAssertEqual(editable, "请按这两个附件补充第三节页下注。")
        XCTAssertFalse(editable.contains("[[SERMO_FILE_START:"))
        XCTAssertFalse(editable.contains("[[SERMO_QUOTE_START:"))

        let replaced = PendingDocumentCodec.replaceEditableUserText(in: encoded, with: "请只保留中华书局点校本页码。")
        let redecoded = PendingDocumentCodec.decode(replaced)
        XCTAssertEqual(redecoded.attachments.count, 2)
        XCTAssertEqual(redecoded.attachments[0].text, doc1.text)
        let requoted = MessageQuoteCodec.decode(redecoded.userText)
        XCTAssertEqual(requoted.quote?.author, "Sermo")
        XCTAssertEqual(requoted.userText, "请只保留中华书局点校本页码。")
    }

    func testHighlightMarksDoubleBacktickCodeAndCachedInline() {
        let input = "命令 ``grep \"**重点**\"`` 会原样匹配，而这里的“**红白契**”才是加粗。"
        let parsed1 = HighlightMarks.parseInline(input)
        let parsed2 = HighlightMarks.parseInline(input)
        XCTAssertEqual(parsed1, parsed2)

        let plain = String(parsed1.characters)
        XCTAssertFalse(plain.contains("\u{E000}"), "No sentinel leak allowed")
        XCTAssertFalse(plain.contains("\u{E001}"), "No sentinel leak allowed")
        XCTAssertTrue(plain.contains("**重点**"), "Asterisks inside double-backtick code span must stay literal")

        let boldRanges = HighlightMarks.boldRanges(in: parsed1)
        XCTAssertEqual(boldRanges.count, 1)
        XCTAssertEqual(String(parsed1[boldRanges[0]].characters), "红白契")
    }

    func testUnpairedDollarFenceDoesNotSwallowTrailingParagraphs() {
        let paired = MarkdownBlock.parse("公式如下：\n\n$$a^2 + b^2 = c^2$$\n\n推导完毕。")
        XCTAssertEqual(paired.count, 3)
        if case .math(let eq) = paired[1] {
            XCTAssertEqual(eq, "a^2 + b^2 = c^2")
        } else {
            XCTFail("Expected paired $$ to parse as .math block")
        }

        let unpaired = MarkdownBlock.parse("预算大约 $$100 左右。\n\n下一段仍然是普通正文，不应变成斜体公式。")
        XCTAssertFalse(unpaired.contains {
            if case .math = $0 { return true }
            return false
        }, "Unpaired $$ must gracefully remain prose instead of swallowing trailing text into .math")
        XCTAssertEqual(unpaired.count, 2)
    }

    func testConversationExportStripsInternalTagsCleanly() {
        let doc = PendingDocument(name: "红白契史料", fileExtension: "txt", text: "原文内容")
        let withQuote = MessageQuoteCodec.encode(
            quote: QuotedMessage(author: "Sermo", excerpt: "上文提要"),
            userText: "帮我整理成表格"
        )
        let rawUserContent = PendingDocumentCodec.encode(userText: withQuote, documents: [doc])
        let thread = ChatThread(
            title: "宋代契约讨论",
            messages: [
                ChatMessage(role: .user, content: rawUserContent),
                ChatMessage(role: .assistant, content: "好的，已整理。")
            ]
        )
        let md = ConversationExport.markdown(thread, userName: "小龙")
        XCTAssertFalse(md.contains("[[SERMO_FILE_START:"))
        XCTAssertFalse(md.contains("[[SERMO_QUOTE_START:"))
        XCTAssertTrue(md.contains("> 引用 Sermo：上文提要"))
        XCTAssertTrue(md.contains("📎 附件：《红白契史料.txt》"))
        XCTAssertTrue(md.contains("帮我整理成表格"))
    }

    func testEstimateContextUsageUsesRealPromptTokensAndProviderCeiling() {
        var assistant = ChatMessage(role: .assistant, content: "一段简短回答")
        assistant.usage = TokenUsage(promptTokens: 12_000, completionTokens: 200, cachedTokens: 8_000)
        let messages = [
            ChatMessage(role: .user, content: "第一问"),
            assistant
        ]
        var colabSettings = AppSettings()
        colabSettings.provider = .colab
        let colabStats = ChatRequest.estimateContextUsage(settings: colabSettings, messages: messages)
        XCTAssertGreaterThanOrEqual(colabStats.estimatedTokens, 12_000)

        var dsSettings = AppSettings()
        dsSettings.provider = .deepSeek
        let dsStats = ChatRequest.estimateContextUsage(settings: dsSettings, messages: messages)
        XCTAssertGreaterThan(colabStats.ratio, dsStats.ratio, "16k Colab ceiling should report higher saturation than 64k DeepSeek ceiling for identical 12k prompt tokens")
    }
}
