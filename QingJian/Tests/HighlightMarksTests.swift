import XCTest
@testable import DeepSeekCore

final class HighlightMarksTests: XCTestCase {
    private func parse(_ text: String) throws -> AttributedString {
        try AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    }

    func testFindsEachBoldPhraseInOrder() throws {
        let value = try parse("先读**目录**，再读**每章头尾**，最后**写一句话**。")
        let phrases = HighlightMarks.boldRanges(in: value).map { String(value[$0].characters) }
        XCTAssertEqual(phrases, ["目录", "每章头尾", "写一句话"])
    }

    func testMergesBoldSplitByItalicsIntoOneMark() throws {
        let value = try parse("这是**一段*很*重要的话**。")
        let phrases = HighlightMarks.boldRanges(in: value).map { String(value[$0].characters) }
        XCTAssertEqual(phrases, ["一段很重要的话"])
    }

    func testPlainTextHasNoMarks() throws {
        XCTAssertTrue(HighlightMarks.boldRanges(in: try parse("没有重点的一句话。")).isEmpty)
    }

    func testEstimatedCountIgnoresAnUnclosedPairWhileStreaming() {
        XCTAssertEqual(HighlightMarks.estimatedBoldCount("没有重点"), 0)
        XCTAssertEqual(HighlightMarks.estimatedBoldCount("一个**重点**"), 1)
        XCTAssertEqual(HighlightMarks.estimatedBoldCount("一个**重点**，还有**正在写"), 1)
        XCTAssertEqual(HighlightMarks.estimatedBoldCount("**一**和**二**"), 2)
        XCTAssertEqual(HighlightMarks.estimatedBoldCount("***粗斜体***"), 1)
    }

    func testBudgetIsSharedAcrossParagraphsInOrder() {
        XCTAssertEqual(HighlightMarks.budgets(forBoldCounts: [0, 1, 3, 2]), [0, 1, 1, 0])
        XCTAssertEqual(HighlightMarks.budgets(forBoldCounts: [5]), [2])
        XCTAssertEqual(HighlightMarks.budgets(forBoldCounts: [1, 1], limit: 0), [0, 0])
        XCTAssertEqual(HighlightMarks.budgets(forBoldCounts: []), [])
    }
}
