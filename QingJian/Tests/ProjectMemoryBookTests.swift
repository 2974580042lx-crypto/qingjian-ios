import Foundation
import XCTest
@testable import DeepSeekCore

final class ProjectMemoryBookTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    func testOldTextBecomesEntriesAndTheOriginalIsKept() {
        var project = ChatProject(name: "论文")
        project.memory = "- 题目定在明代驿传\n\n• 导师姓王\n- 题目定在明代驿传"
        XCTAssertTrue(project.migrateMemoryIfNeeded())
        XCTAssertEqual(project.memoryItems?.map(\.text), ["题目定在明代驿传", "导师姓王"])
        XCTAssertEqual(project.memoryLegacyText, "- 题目定在明代驿传\n\n• 导师姓王\n- 题目定在明代驿传")
        XCTAssertEqual(project.memory, "- 题目定在明代驿传\n- 导师姓王")
        XCTAssertFalse(project.migrateMemoryIfNeeded(), "only once")
        XCTAssertNoThrow(try project.validate())
    }

    func testEditingAsTextKeepsUnchangedEntries() {
        let items = ProjectMemoryBook.migrate("- 甲\n- 乙\n- 丙", now: now)
        let result = ProjectMemoryBook.reconcile(items, with: "- 甲\n- 丙\n- 丁", byUser: true, now: now)
        XCTAssertEqual(result.items.map(\.text), ["甲", "丙", "丁"])
        XCTAssertEqual(result.items[0].id, items[0].id)
        XCTAssertEqual(result.items[1].id, items[2].id)
        XCTAssertEqual(result.changes.map(\.kind), [.add, .delete])
        XCTAssertEqual(Set(result.changes.map(\.batchID)).count, 1)
    }

    func testOpsAddUpdateDeleteAndSkipDuplicates() {
        let items = ProjectMemoryBook.migrate("- 用纸本记笔记\n- 住在杭州", now: now)
        let thread = UUID()
        let result = ProjectMemoryBook.apply([
            .add(text: "养了一只柴犬", quote: "我家柴犬", expires: nil),
            .add(text: "住在杭州", quote: nil, expires: nil),
            .update(id: items[0].id, text: "改用 iPad 记笔记（之前用纸本）", quote: "现在都用 iPad 了", expires: nil),
            .delete(id: items[1].id)
        ], to: items, threadID: thread, now: now)
        XCTAssertEqual(result.items.map(\.text), ["改用 iPad 记笔记（之前用纸本）", "住在杭州", "养了一只柴犬"].filter { $0 != "住在杭州" })
        XCTAssertEqual(result.changes.map(\.kind), [.add, .update, .delete])
        XCTAssertEqual(result.items.last?.sourceThreadID, thread)
        XCTAssertEqual(result.items.last?.sourceQuote, "我家柴犬")
    }

    func testUndoPutsAWholeUpdateBack() throws {
        let items = ProjectMemoryBook.migrate("- 甲\n- 乙", now: now)
        let update = ProjectMemoryBook.apply([.add(text: "丙", quote: nil, expires: nil), .delete(id: items[0].id),
                                              .update(id: items[1].id, text: "乙二", quote: nil, expires: nil)],
                                             to: items, threadID: nil, now: now)
        let batch = try XCTUnwrap(update.changes.first?.batchID)
        let undone = try XCTUnwrap(ProjectMemoryBook.undo(batch: batch, items: update.items, log: update.changes, now: now))
        XCTAssertEqual(Set(undone.items.map(\.text)), ["甲", "乙"])
        XCTAssertTrue(undone.changes.allSatisfy(\.byUser))
    }

    func testUndoLeavesEntriesEditedAgainAlone() throws {
        let items = ProjectMemoryBook.migrate("- 甲", now: now)
        let first = ProjectMemoryBook.apply([.update(id: items[0].id, text: "甲二", quote: nil, expires: nil)], to: items, threadID: nil, now: now)
        let second = ProjectMemoryBook.apply([.update(id: items[0].id, text: "甲三", quote: nil, expires: nil)], to: first.items, threadID: nil, now: now)
        let batch = try XCTUnwrap(first.changes.first?.batchID)
        XCTAssertNil(ProjectMemoryBook.undo(batch: batch, items: second.items, log: first.changes + second.changes, now: now))
    }

    func testSmallMemoryGoesWholeLargeMemoryOnlyPinnedAndRelevant() {
        var small = ProjectMemoryBook.migrate("- 喜欢简短的回答\n- 在准备考研", now: now)
        XCTAssertEqual(ProjectMemoryBook.select(small, query: "随便", now: now).always.count, 2)

        var lines = (0..<40).map { "- 第\($0)条关于写作习惯的长期偏好记录，写得长一些以便超过预算的限制" }
        lines.append("- 五月计划去杭州旅行")
        var large = ProjectMemoryBook.migrate(lines.joined(separator: "\n"), now: now)
        large[0].pinned = true
        let pick = ProjectMemoryBook.select(large, query: "杭州旅行住哪里好", now: now)
        XCTAssertEqual(pick.always.map(\.id), [large[0].id])
        XCTAssertTrue(pick.relevant.contains { $0.text == "五月计划去杭州旅行" })
        XCTAssertEqual(pick.relevant.count, 1)

        small[1].expiresAt = now.addingTimeInterval(-60)
        XCTAssertEqual(ProjectMemoryBook.select(small, query: "", now: now).always.map(\.text), ["喜欢简短的回答"],
                       "an entry past its end date is no longer used")
    }

    func testWriterSeesShortIdsAndPrivacyRule() throws {
        var project = ChatProject(name: "日常")
        let items = ProjectMemoryBook.migrate("- 甲", now: now)
        var thread = ChatThread()
        thread.messages = [ChatMessage(role: .user, content: "记住我对花生过敏"), ChatMessage(role: .assistant, content: "好的")]
        let built = try ProjectMemoryBook.request(project: project, items: items, thread: thread, new: thread.messages, now: now)
        XCTAssertEqual(built.ids["m1"], items[0].id)
        let body = built.request.messages.last?.content ?? ""
        XCTAssertTrue(body.contains(#""id":"m1""#))
        XCTAssertTrue(built.request.messages.first?.content.contains("也照样记") ?? false)
        project.memoryKeepsPrivate = false
        let strict = try ProjectMemoryBook.request(project: project, items: items, thread: thread, new: thread.messages, now: now)
        XCTAssertTrue(strict.request.messages.first?.content.contains("一律不记") ?? false)
    }

    func testParsesOpsAndDropsUnknownIds() throws {
        let known = UUID()
        let ops = try ProjectMemoryBook.parseOps("""
        {"ops":[{"op":"add","text":"在准备考研","quote":"我在准备考研","expires":"2026-12-20"},
                {"op":"update","id":"m1","text":"甲二"},
                {"op":"update","id":"m9","text":"不存在"},
                {"op":"delete","id":"m1"},
                {"op":"noop"}]}
        """, ids: ["m1": known])
        XCTAssertEqual(ops.count, 3)
        if case let .add(text, quote, expires) = ops[0] {
            XCTAssertEqual(text, "在准备考研")
            XCTAssertEqual(quote, "我在准备考研")
            XCTAssertNotNil(expires)
        } else { XCTFail("first op should add") }
        XCTAssertEqual(ops[2], .delete(id: known))
        XCTAssertThrowsError(try ProjectMemoryBook.parseOps("没有 JSON", ids: [:]))
        XCTAssertEqual(try ProjectMemoryBook.parseOps(#"{"ops":[]}"#, ids: [:]), [])
    }

    func testSystemPromptUsesTheChosenMemoryPart() {
        var project = ChatProject(name: "日常")
        project.memory = "- 整段旧记忆"
        let context = PromptVariables.Context(now: now, userName: "小龙", modelName: "Flash")
        XCTAssertTrue(project.systemPrompt(resolving: context).contains("整段旧记忆"))
        let chosen = project.systemPrompt(resolving: context, memoryBlock: ProjectMemoryBook.alwaysBlock(ProjectMemoryBook.migrate("- 置顶的一条")))
        XCTAssertTrue(chosen.contains("置顶的一条"))
        XCTAssertFalse(chosen.contains("整段旧记忆"))
        XCTAssertFalse(project.systemPrompt(resolving: context, memoryBlock: nil).contains("记下的要点"))
    }
}
