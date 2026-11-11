import Foundation
import XCTest
@testable import DeepSeekCore

final class ContextAndEffortTests: XCTestCase {
    func testNewDefaultKeepsOneHundredRounds() {
        var messages: [ChatMessage] = []
        for index in 0..<110 {
            messages.append(ChatMessage(role: .user, content: "Question \(index)"))
            messages.append(ChatMessage(role: .assistant, content: "Answer \(index)"))
        }
        let request = ChatRequest(settings: AppSettings(), messages: messages)
        XCTAssertEqual(request.messages.count, 201)
        XCTAssertEqual(request.messages[1].content, "Question 10")
        XCTAssertEqual(request.messages.last?.content, "Answer 109")
    }

    func testLongContextRetainsRecentWholeMessagesAndSystemPrompt() {
        var settings = AppSettings(); settings.contextMessageLimit = 400
        let long = String(repeating: "字", count: 70000)
        let request = ChatRequest(settings: settings, messages: [
            ChatMessage(role: .user, content: long), ChatMessage(role: .assistant, content: long),
            ChatMessage(role: .user, content: "recent question"), ChatMessage(role: .assistant, content: long),
            ChatMessage(role: .user, content: "latest question")])
        XCTAssertEqual(request.messages[0].content, settings.systemPrompt)
        XCTAssertEqual(request.messages[1].content, "recent question")
        XCTAssertEqual(request.messages.last?.content, "latest question")
        XCTAssertEqual(request.messages[2].content, long)
        XCTAssertLessThanOrEqual(request.messages.reduce(0) { $0 + $1.content.utf8.count }, ChatRequest.contextByteBudget)
    }

    func testLegacyDefaultIsMigratedOnceAndManualChoiceRemains() {
        var legacy = AppSettings(); legacy.contextPolicyVersion = nil; legacy.contextMessageLimit = 40
        var upgraded = legacy.migratingDefaultContext()
        XCTAssertEqual(upgraded.contextMessageLimit, 200)
        upgraded.contextMessageLimit = 40
        XCTAssertEqual(upgraded.migratingDefaultContext().contextMessageLimit, 40)
        legacy.contextMessageLimit = 80
        XCTAssertEqual(legacy.migratingDefaultContext().contextMessageLimit, 80)
    }

    func testEveryEffortSelectionMapsDeterministicallyAndIsOmittedWhenDisabled() throws {
        for effort in ThinkingEffort.allCases {
            var settings = AppSettings(); settings.effort = effort
            let on = ChatRequest(settings: settings, messages: [ChatMessage(role: .user, content: "hello")])
            XCTAssertEqual(on.reasoningEffort, effort.rawValue)
            settings.thinkingEnabled = false
            let off = ChatRequest(settings: settings, messages: [ChatMessage(role: .user, content: "hello")])
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(off)) as? [String: Any])
            XCTAssertNil(json["reasoning_effort"])
        }
    }
}
