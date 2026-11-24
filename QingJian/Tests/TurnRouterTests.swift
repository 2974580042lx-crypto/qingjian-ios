import Foundation
import XCTest
@testable import DeepSeekCore

final class TurnRouterTests: XCTestCase {
    private func context(_ text: String, web: Bool = true, docs: Bool = false, chats: Bool = false) -> TurnRouter.Context {
        TurnRouter.Context(latest: text, webAllowed: web, hasDocs: docs, hasChats: chats)
    }

    func testShortEverydayLinesNeedNothing() {
        for line in ["好的", "哈哈哈", "晚安", "谢谢你"] {
            XCTAssertEqual(TurnRouter.localPlan(line, context: context(line)), .plain, line)
        }
    }

    func testShortQuestionsStillGoToTheRouter() {
        for line in ["天气怎样", "今天几号？", "查下汇率"] {
            XCTAssertNil(TurnRouter.localPlan(line, context: context(line)), line)
        }
    }

    func testFilesAndCodeKeepTheFullTools() {
        XCTAssertEqual(TurnRouter.localPlan("帮我把这些整理成 Excel 表格", context: context("")), .fullTools)
        XCTAssertEqual(TurnRouter.localPlan("把这段 Python 代码跑一下", context: context("")), .fullTools)
    }

    func testLinksAreReadWhenTheWebIsAllowed() {
        let text = "看看这个 https://example.com/a"
        let plan = TurnRouter.localPlan(text, context: context(text))
        XCTAssertEqual(plan?.web, true)
        XCTAssertEqual(plan?.tools, false)
        XCTAssertEqual(TurnRouter.localPlan(text, context: context(text, web: false)), .fullTools)
    }

    func testNamedRoutineAndProjectLookupSurviveFastPath() {
        var ctx = context("按周报来", docs: true)
        ctx.offersTools = false
        ctx.skills = [.init(name: "周报", hint: "周报模板")]
        XCTAssertNil(TurnRouter.localPlan(ctx.latest, context: ctx))
        XCTAssertNil(TurnRouter.localPlan("查一下项目文档", context: ctx))
    }

    func testLookingBackAsksTheRouterOnlyWhenThereAreChats() {
        let text = "我们上次说到哪了"
        XCTAssertNil(TurnRouter.localPlan(text, context: context(text, chats: true)))
    }

    func testParsesTheRoutersAnswerAndIgnoresWhatIsNotAllowed() {
        let reply = #"好的 {"web":true,"web_query":"今日 金价","docs_query":"第三章","chats_query":"旅行计划","skill":"周报","tools":false}"#
        var ctx = context("x", web: true, docs: true, chats: false)
        ctx.skills = [TurnRouter.SkillHint(name: "周报", hint: "写周报时")]
        let plan = TurnRouter.parse(reply, context: ctx)
        XCTAssertEqual(plan?.web, true)
        XCTAssertEqual(plan?.webQuery, "今日 金价")
        XCTAssertEqual(plan?.docsQuery, "第三章")
        XCTAssertNil(plan?.chatsQuery, "this project has no past chats to search")
        XCTAssertEqual(plan?.skill, "周报")
        XCTAssertEqual(plan?.tools, false)

        let noWeb = TurnRouter.parse(reply, context: context("x", web: false))
        XCTAssertEqual(noWeb?.web, false)
        XCTAssertNil(noWeb?.webQuery)
        XCTAssertNil(noWeb?.skill, "unknown routines are dropped")
    }

    func testUnreadableAnswerFallsBack() {
        XCTAssertNil(TurnRouter.parse("我觉得不需要", context: context("x")))
    }

    func testRouterRequestIsSmallAndWithoutThinking() throws {
        var ctx = context("最近有什么新闻", docs: true)
        ctx.recent = [TurnRouter.Line(role: "用户", text: String(repeating: "长", count: 2000))]
        let request = TurnRouter.request(ctx)
        XCTAssertEqual(request.model, DeepSeekModel.flash.rawValue)
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertTrue(json.contains(#""type":"disabled""#))
        XCTAssertNil(request.tools)
        XCTAssertLessThan(request.messages.last?.content.count ?? 0, 2000)
    }

    func testHelpersFallBackWhenDeepSeekCannotPay() {
        XCTAssertEqual(AuxiliaryRouting.order(policy: nil, chatProvider: .chatGPT), [.deepSeek, .chatGPT])
        XCTAssertEqual(AuxiliaryRouting.order(policy: .chatGPT, chatProvider: .deepSeek), [.chatGPT, .deepSeek])
        XCTAssertEqual(AuxiliaryRouting.order(policy: .follow, chatProvider: .chatGPT), [.chatGPT, .deepSeek])
        XCTAssertTrue(AuxiliaryRouting.shouldTryNextService(after: ChatError.insufficientBalance))
        XCTAssertTrue(AuxiliaryRouting.shouldTryNextService(after: ChatError.missingKey))
        XCTAssertFalse(AuxiliaryRouting.shouldTryNextService(after: ChatError.incompleteStream))
        XCTAssertFalse(AuxiliaryRouting.shouldTryNextService(after: CancellationError()))
    }

    func testOlderPolicyValuesStillDecode() throws {
        let follow = try JSONDecoder().decode(AuxiliaryProviderPolicy.self, from: Data(#""follow""#.utf8))
        let deepSeek = try JSONDecoder().decode(AuxiliaryProviderPolicy.self, from: Data(#""deepSeek""#.utf8))
        XCTAssertEqual(follow, .follow)
        XCTAssertEqual(deepSeek, .deepSeek)
        XCTAssertTrue(AppSettings().routesTurns)
        XCTAssertTrue(AppSettings().offersCompaction)
    }

    func testCompactionIsOfferedOnlyForLongChats() {
        XCTAssertFalse(AuxiliaryRouting.isLongEnoughToCompact(estimatedTokens: 20_000, messageCount: 30, messageLimit: 200))
        XCTAssertTrue(AuxiliaryRouting.isLongEnoughToCompact(estimatedTokens: 61_000, messageCount: 30, messageLimit: 200))
        XCTAssertTrue(AuxiliaryRouting.isLongEnoughToCompact(estimatedTokens: 1_000, messageCount: 160, messageLimit: 200))
    }
}

final class CacheFriendlyWindowTests: XCTestCase {
    func testWindowStartMovesInStepsNotEveryTurn() {
        var starts: [Int] = []
        for count in 201...260 {
            starts.append(ChatRequest.windowStart(sizes: Array(repeating: 20, count: count), messageLimit: 200, byteBudget: 500_000))
        }
        XCTAssertEqual(Set(starts), [50, 100], "a quarter of the limit at a time")
        XCTAssertTrue(starts.allSatisfy { $0 % 50 == 0 })
    }

    func testByteBudgetCutsAtStableCheckpoints() {
        var sizes: [Int] = []
        var previous: Int?
        var changes = 0
        for index in 0..<400 {
            sizes.append(8_000 + (index % 7) * 1_000)
            let start = ChatRequest.windowStart(sizes: sizes, messageLimit: 400, byteBudget: 509_000)
            XCTAssertLessThanOrEqual(sizes.dropFirst(start).reduce(0, +), 509_000)
            if let previous, previous != start { changes += 1 }
            previous = start
        }
        XCTAssertLessThan(changes, 40, "the start moves about every quarter budget, not with every message")
    }

    func testSmallHistoriesAreLeftAlone() {
        XCTAssertEqual(ChatRequest.windowStart(sizes: [10, 10, 10], messageLimit: 200, byteBudget: 1000), 0)
        XCTAssertEqual(ChatRequest.windowStart(sizes: [10], messageLimit: 1, byteBudget: 1), 0)
    }
}
