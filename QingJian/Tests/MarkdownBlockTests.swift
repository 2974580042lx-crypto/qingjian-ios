import XCTest
@testable import DeepSeekCore

final class MarkdownBlockTests: XCTestCase {
    func testListsHeadingsQuotesAndDividers() {
        let answer = """
        ## 读书方法
        先说结论：
        - **检视阅读**，先看目录
        - 读不懂就跳过
          这一行接着上一条
        1. 第一步
        2) 第二步
        3、第三步

        > 引用的一句话
        > 第二行

        ---
        普通段落，-5 度和 1.5 倍都不是列表。
        """
        let blocks = MarkdownBlock.parse(answer)
        XCTAssertEqual(blocks, [
            .heading("读书方法", level: 2),
            .paragraph("先说结论：", marks: 0),
            .list([
                .init(marker: "•", text: "**检视阅读**，先看目录", level: 0, marks: 1),
                .init(marker: "•", text: "读不懂就跳过\n这一行接着上一条", level: 0, marks: 0),
                .init(marker: "1.", text: "第一步", level: 0, marks: 0),
                .init(marker: "2.", text: "第二步", level: 0, marks: 0),
                .init(marker: "3.", text: "第三步", level: 0, marks: 0),
            ]),
            .quote("引用的一句话\n第二行", marks: 0),
            .divider,
            .paragraph("普通段落，-5 度和 1.5 倍都不是列表。", marks: 0),
        ])
    }

    func testNestedItemsAndCodeStayIntact() {
        let blocks = MarkdownBlock.parse("- 外层\n  - 内层\n\n```swift\nlet a = [1, 2]\n- 不是列表\n```")
        XCTAssertEqual(blocks.first, .list([.init(marker: "•", text: "外层", level: 0, marks: 0),
                                            .init(marker: "◦", text: "内层", level: 1, marks: 0)]))
        XCTAssertEqual(blocks.last, .code("swift\nlet a = [1, 2]\n- 不是列表\n"))
    }

    func testHighlightBudgetSpansAllBlocks() {
        let blocks = MarkdownBlock.parse("**一**\n\n- **二**\n- **三**\n\n> **四**")
        var marks: [Int] = []
        for block in blocks {
            switch block {
            case .paragraph(_, let m), .quote(_, let m): marks.append(m)
            case .list(let items): marks.append(contentsOf: items.map(\.marks))
            default: break
            }
        }
        XCTAssertEqual(marks, [1, 1, 0, 0])
    }

    func testBoldLineIsNotAListAndHashtagIsNotAHeading() {
        XCTAssertEqual(MarkdownBlock.parse("**粗体开头**的一句"), [.paragraph("**粗体开头**的一句", marks: 1)])
        XCTAssertEqual(MarkdownBlock.parse("#话题 不是标题"), [.paragraph("#话题 不是标题", marks: 0)])
    }
}

final class MarkdownTableTests: XCTestCase {
    func testPipeTablesBecomeTables() {
        let answer = """
        对比如下：
        | 方案 | 价格 | 备注 |
        |:---|:---:|---:|
        | **A** | 10 | 便宜 |
        | B | 20 |
        | C | 30 | 有 \\| 竖线 | 多余 |
        表后的文字
        """
        XCTAssertEqual(MarkdownBlock.parse(answer), [
            .paragraph("对比如下：", marks: 0),
            .table(header: ["方案", "价格", "备注"],
                   rows: [["**A**", "10", "便宜"], ["B", "20", ""], ["C", "30", "有 | 竖线"]],
                   alignments: [.leading, .center, .trailing]),
            .paragraph("表后的文字", marks: 0),
        ])
    }

    func testPipesWithoutASeparatorStayText() {
        XCTAssertEqual(MarkdownBlock.parse("a | b\n---"), [.paragraph("a | b", marks: 0), .divider])
        XCTAssertNil(MarkdownBlock.separator("| a | b |"))
        XCTAssertEqual(MarkdownBlock.separator("--- | :-:"), [.leading, .center])
    }
}
