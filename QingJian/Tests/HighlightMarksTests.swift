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

    func testParseInlineRescuesCJKBoldAdjacentToFullWidthPunctuationWhilePreservingCode() {
        let marne = HighlightMarks.parseInline("**1914年9月，第一次马恩河战役。**英法联军阻止了德军向巴黎方向的推进，迫使德军后撤。")
        XCTAssertFalse(String(marne.characters).contains("**"))
        XCTAssertEqual(
            HighlightMarks.boldRanges(in: marne).map { String(marne[$0].characters) },
            ["1914年9月，第一次马恩河战役。"]
        )

        let mixed = HighlightMarks.parseInline("在**“马恩河战役”**与**（第一次世界大战）**中，代码 `x ** 2 ** y` 保持原样。")
        XCTAssertEqual(
            HighlightMarks.boldRanges(in: mixed).map { String(mixed[$0].characters) },
            ["“马恩河战役”", "（第一次世界大战）"]
        )
        XCTAssertTrue(String(mixed.characters).contains("x ** 2 ** y"))
    }

    func testParseInlinePreservesMixedBoldItalicCodeAndPlainNumbers() {
        let sample = "1. **核心大脑（Carbon）**：*Same Carbon-level quality*，默认 `18pt` 与 1158 页。"
        let parsed = HighlightMarks.parseInline(sample)

        XCTAssertEqual(
            HighlightMarks.boldRanges(in: parsed).map { String(parsed[$0].characters) },
            ["核心大脑（Carbon）"]
        )

        var italicRuns: [String] = []
        var codeRuns: [String] = []
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            if run.inlinePresentationIntent?.contains(.emphasized) == true {
                italicRuns.append(text)
            }
            if run.inlinePresentationIntent?.contains(.code) == true {
                codeRuns.append(text)
            }
        }
        XCTAssertEqual(italicRuns, ["Same Carbon-level quality"])
        XCTAssertEqual(codeRuns, ["18pt"])
        XCTAssertTrue(String(parsed.characters).contains("1158"))
    }
}
