import Foundation
import XCTest
@testable import DeepSeekCore

final class ConversationHistoryTests: XCTestCase {
    private func chain() -> [ChatThread] {
        var root = ChatThread(); root.title = "读书计划"; root.updatedAt = Date(timeIntervalSince1970: 1)
        var retry = root
        retry.id = UUID(); retry.parentThreadID = root.id; retry.title += " · 重试"
        retry.updatedAt = Date(timeIntervalSince1970: 2)
        var latest = retry
        latest.id = UUID(); latest.parentThreadID = retry.id; latest.title += " · 重试"
        latest.updatedAt = Date(timeIntervalSince1970: 3)
        return [root, retry, latest]
    }

    func testNestedLegacyRetriesProduceOneCleanSidebarRow() {
        let threads = chain()
        let visible = ConversationHistory.visibleThreads(threads, activeID: nil)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.id, threads[2].id)
        XCTAssertEqual(visible.first?.title, "读书计划")
        XCTAssertEqual(threads.count, 3, "Presentation must not destroy old backup data.")
        XCTAssertEqual(ConversationHistory.memberIDs(for: threads[2].id, in: threads), Set(threads.map(\.id)))
    }

    func testIndependentConversationsWithTheSameTitleStaySeparate() {
        let threads = chain()
        var independent = ChatThread(); independent.title = threads[0].title
        let visible = ConversationHistory.visibleThreads(threads + [independent], activeID: nil)
        XCTAssertEqual(visible.count, 2)
        XCTAssertTrue(visible.contains { $0.id == independent.id })
    }

    func testActiveBranchAndFamilyPinArePreserved() {
        var threads = chain(); threads[0].isPinned = true
        let visible = ConversationHistory.visibleThreads(threads, activeID: threads[1].id)
        XCTAssertEqual(visible.first?.id, threads[1].id)
        XCTAssertEqual(visible.first?.isPinned, true)
        XCTAssertEqual(visible.first?.title, "读书计划")
    }

    func testUserRenamedTitlesAreNotStripped() {
        var threads = chain(); threads[2].title = "我自己起的名字 · 重试"
        let visible = ConversationHistory.visibleThreads(threads, activeID: nil)
        XCTAssertEqual(visible.first?.title, "我自己起的名字 · 重试")
    }

    func testMissingParentsAndCyclesCannotCreateDuplicateRowsOrLoop() {
        var threads = chain()
        threads[0].parentThreadID = threads[2].id
        XCTAssertEqual(ConversationHistory.visibleThreads(threads, activeID: nil).count, 1)
        let missing = UUID()
        threads[0].parentThreadID = missing
        threads[1].parentThreadID = missing
        XCTAssertEqual(ConversationHistory.visibleThreads(threads, activeID: nil).count, 1)
    }
}
