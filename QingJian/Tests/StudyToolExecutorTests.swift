import XCTest
@testable import DeepSeekCore

final class StudyToolExecutorTests: XCTestCase {
    func testSharedExecutorReadsWritesAndCorrectsWithTheClientScope() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sermo-executor-" + UUID().uuidString)
        defer { if directory.lastPathComponent.hasPrefix("sermo-executor-") { try? FileManager.default.removeItem(at: directory) } }
        let store = try StudyMemoryStore(url: directory.appendingPathComponent("memory.sqlite"))
        let scope = StudyScope(projectID: StudySubject.english.projectID, threadID: UUID(), subject: .english)
        let document = ProjectDocument(name: "合成资料", text: "Synthetic vocabulary exercise")
        let executor = StudyToolExecutor(store: store, scope: scope, documents: [document])
        func action(_ name: String, _ arguments: [String: Any]) throws -> StudyToolAction {
            try StudyToolAction(ToolCall(id: UUID().uuidString, name: name,
                arguments: String(decoding: JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)))
        }
        let read = try executor.perform(action("study_read_material", ["document_id":document.id.uuidString]),
            sourceMessage: ChatMessage(role: .user, content: "读资料"))
        XCTAssertTrue(read.contains(document.text))
        let message = ChatMessage(role: .user, content: "我混淆 adapt 和 adopt，请记录")
        let save = try action("study_remember", ["category":"生词","text":"混淆 adapt/adopt","source_kind":"user_statement","evidence_quote":message.content])
        _ = try executor.perform(save, sourceMessage: message)
        _ = try executor.perform(save, sourceMessage: message)
        let first = try XCTUnwrap(store.records(projectID: scope.projectID).first)
        XCTAssertEqual(try store.events(projectID: scope.projectID).count, 1)
        let correction = ChatMessage(role: .user, content: "更正，实际是 affect 和 effect")
        _ = try executor.perform(action("study_correct", ["record_id":first.toolReference,"expected_revision":1,"category":"生词",
            "text":"混淆 affect/effect","source_kind":"user_statement","evidence_quote":correction.content]), sourceMessage: correction)
        XCTAssertEqual(try store.records(projectID: scope.projectID).first?.revision, 2)
        XCTAssertTrue(try executor.context(query: "affect").contains("affect/effect"))
        XCTAssertThrowsError(try executor.perform(save, sourceMessage: ChatMessage(role: .assistant, content: message.content)))
    }
    func testCurrentReferencesAreBoundByTheSharedExecutor() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sermo-current-" + UUID().uuidString)
        defer { if folder.lastPathComponent.hasPrefix("sermo-current-") { try? FileManager.default.removeItem(at: folder) } }
        let store = try StudyMemoryStore(url: folder.appendingPathComponent("test.sqlite"))
        let scope = StudyScope(projectID: StudySubject.english.projectID, threadID: UUID(), subject: .english)
        let data = Data(#"{"schema_version":"yanxi.private-import.v2-stage1","cards":[{"id":"sample-adapt","word":"adapt","translation_zh":"适应","unit_order":[{"collection":"required","unit":1,"position":1}]}]}"#.utf8)
        try store.importWords(StudyWordPack.decode(data), projectID: scope.projectID)
        let executor = StudyToolExecutor(store: store, scope: scope, documents: [])
        let opening = ChatMessage(role: .user, content: "开始背词")
        let start = ToolCall(id: "start", name: "study_start_words", arguments: #"{"unit_id":"required-1","count":1,"mode":"start"}"#)
        _ = try executor.perform(StudyToolAction(start), sourceMessage: opening)
        let session = try XCTUnwrap(store.wordState(scope: scope).session)
        let context = try executor.context(query: "adapt")
        XCTAssertFalse(context.contains(session.id.uuidString))
        let answer = ChatMessage(role: .user, content: "我记得，是适应", createdAt: Date().addingTimeInterval(1))
        let call = ToolCall(id: "grade", name: "study_grade_word", arguments: #"{"session_id":"current","expected_revision":1,"word_id":"current","rating":"good","evidence_quote":"我记得，是适应"}"#)
        _ = try executor.perform(StudyToolAction(call), sourceMessage: answer)
        XCTAssertEqual(try store.wordProgress(projectID: scope.projectID).first?.reviewCount, 1)
        let otherScope = StudyScope(projectID: scope.projectID, threadID: UUID(), subject: .english)
        let other = StudyToolExecutor(store: store, scope: otherScope, documents: [])
        XCTAssertThrowsError(try other.perform(StudyToolAction(call), sourceMessage: answer))
    }
}
