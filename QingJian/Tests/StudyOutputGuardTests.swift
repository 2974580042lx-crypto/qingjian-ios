import XCTest
@testable import DeepSeekCore

final class StudyOutputGuardTests: XCTestCase {
    func testNegationsQuestionsPlansAndExamplesRemainVerbatim() {
        let allowed = [
            "周报尚未生成。", "我没有说已记入周报。", "我不能说“已记入周报”。",
            "不要声称已更新周报。", "并非已经完成周报。", "是否已经记入周报？",
            "周报已经生成了吗？", "如果已经生成周报，请先给我看一眼。",
            "已经学过的词可以加入下周周报。", "稍后我会把这些内容写入周报。",
            "例如“已记入周报”这句话，就应该避免。", "“已记入周报”是需要避免的表述。",
            "你说“已记入周报”是什么意思？", "已保存学习记录，待周报整理。",
            "已生成一份单词清单，周报暂时没有生成。", "adapt 表示适应，adopt 表示采纳。",
            "原文：编辑已经把结果写入周报。", "译文：我已记入周报。",
            "请翻译‘已记入周报’这句话。", "报社已经完成周报。"
        ]
        for text in allowed { XCTAssertEqual(StudyOutputGuard.checked(text), text, text) }
    }
    func testActualCompletionClaimsAreRejected() {
        let denied = ["已记入周报。", "已经把这个词写入本周周报了。", "周报已经更新。",
                      "本周总结已完成。", "记到周报里了。", "“已记入周报”。", "**已记入周报**。",
                      "已经将这个词记入周报。", "我已经把学会的词写入周报。"]
        for text in denied { XCTAssertTrue(StudyOutputGuard.checked(text).contains("尚未确认"), text) }
    }
    func testOnlyTheClaimClauseIsReplaced() {
        let result = StudyOutputGuard.checked("已保存学习记录，已记入周报，接下来我们复习 adapt。")
        XCTAssertTrue(result.hasPrefix("已保存学习记录，"))
        XCTAssertTrue(result.hasSuffix("接下来我们复习 adapt。"))
        XCTAssertFalse(result.contains("已记入周报"))
        XCTAssertFalse(StudyOutputGuard.checked("已记入周报，你要看吗？").contains("已记入周报"))
    }
    func testChunkBoundariesAndFinalPartialSentence() {
        var guarder = StudyOutputGuard()
        XCTAssertEqual(guarder.consume("已经把它记"), "")
        XCTAssertEqual(guarder.consume("入周报"), "")
        XCTAssertTrue(guarder.consume("", finish: true).contains("尚未确认"))
        var allowed = StudyOutputGuard()
        XCTAssertEqual(allowed.consume("已保存学习记录，待周报"), "")
        XCTAssertEqual(allowed.consume("整理。"), "已保存学习记录，待周报整理。")
    }
    func testWeeklyClaimsNeedScopedReceiptAndAreRevokedByChanges() throws {
        let project = UUID(), other = UUID(), now = Date()
        let report = StudyWeeklyReport(id: UUID(), projectID: project, start: now, end: now.addingTimeInterval(100), timeZoneID: "UTC", revision: 1, text: "合成周报", sourceDigest: "synthetic", sourceReferences: [], createdAt: now)
        let receipt = String(decoding: try StudyCoding.encode(StudyWeeklyResult(status: "generated", message: "已保存", report: report)), as: UTF8.self)
        var g = StudyOutputGuard()
        g.observeTool(name: "study_list_memory", result: receipt, projectID: project)
        XCTAssertTrue(g.consume("已记入周报。").contains("尚未确认"))
        g.observeTool(name: "study_weekly_report", result: receipt, projectID: other)
        XCTAssertTrue(g.consume("周报已经生成。").contains("尚未确认"))
        g.observeTool(name: "study_weekly_report", result: receipt, projectID: project)
        XCTAssertEqual(g.consume("周报已经生成。"), "周报已经生成。")
        g.observeTool(name: "study_list_memory", result: "[]", projectID: project)
        XCTAssertEqual(g.consume("周报已经生成。"), "周报已经生成。")
        g.observeTool(name: "study_correct_practice", result: "已更正", projectID: project)
        XCTAssertTrue(g.consume("周报已经更新。").contains("尚未确认"))
    }
}
