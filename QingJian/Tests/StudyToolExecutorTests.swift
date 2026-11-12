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

    func testLockFreeToolsAcceptOmittedOptionalFieldsAndKeepIdleContextCompact() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sermo-free-exec-" + UUID().uuidString)
        defer { if folder.lastPathComponent.hasPrefix("sermo-free-exec-") { try? FileManager.default.removeItem(at: folder) } }
        let store = try StudyMemoryStore(url: folder.appendingPathComponent("test.sqlite"))
        let scope = StudyScope(projectID: StudySubject.english.projectID, threadID: UUID(), subject: .english)

        let wordJSON = #"{"schema_version":"yanxi.private-import.v2-stage1","cards":[{"id":"w-adapt","word":"adapt","translation_zh":"适应","unit_order":[{"collection":"required","unit":1,"position":1}]},{"id":"w-adopt","word":"adopt","translation_zh":"采纳","unit_order":[{"collection":"required","unit":1,"position":2}]}]}"#
        try store.importWords(StudyWordPack.decode(Data(wordJSON.utf8)), projectID: scope.projectID)

        let passage = StudyReadingPassage(
            id: "2024-text-1", title: "2024 Text 1", year: 2024, textNumber: 1,
            paragraphs: ["Paragraph one about sunshine and light.", "Paragraph two about growth."],
            questions: [.init(id: "q21", number: 21, stem: "What is discussed?", options: ["Light", "Rain", "Snow", "Wind"], answer: 0, explanation: "Light matches sunshine.", verification: "verified", source: "synthetic", sourceURL: nil)],
            source: "synthetic", sourceURL: nil, topic: "自然"
        )
        try store.importReadings(.init(schema: "sermo.readings.v1", passages: [passage]), projectID: scope.projectID)

        let executor = StudyToolExecutor(store: store, scope: scope, documents: [])
        let casualMsg = ChatMessage(role: .user, content: "哥哥早上好呀，抱抱")

        // 1. Casual chat does NOT dump reading catalog IDs into prompt context
        let idleContext = try executor.context(query: casualMsg.content)
        XCTAssertFalse(idleContext.contains("2024-text-1"))
        XCTAssertTrue(idleContext.contains("词库"))

        // 2. Lock-free batch draw with omitted count & unit_id
        let drawCall = ToolCall(id: "d1", name: "study_draw_words", arguments: #"{"mode":"shuffle"}"#)
        let drawOut = try executor.perform(StudyToolAction(drawCall), sourceMessage: casualMsg)
        XCTAssertTrue(drawOut.contains("adapt") && drawOut.contains("adopt"))

        // 3. Cross-turn lock-free grading without session_id, expected_revision, or evidence_quote
        let nextMsg = ChatMessage(role: .user, content: "可以打乱顺序背吗")
        let gradeCall = ToolCall(id: "g1", name: "study_grade_word", arguments: #"{"word":"adapt","rating":"good"}"#)
        _ = try executor.perform(StudyToolAction(gradeCall), sourceMessage: nextMsg)
        XCTAssertEqual(try store.wordPracticeSummary(projectID: scope.projectID).learnedWords, 1)

        // Another window in the same English project immediately sees today's discussed words in its context
        let secondWindowScope = StudyScope(projectID: scope.projectID, threadID: UUID(), subject: .english)
        let secondExecutor = StudyToolExecutor(store: store, scope: secondWindowScope, documents: [])
        let secondWindowContext = try secondExecutor.context(query: "今天我在不同窗口聊了哪些单词")
        XCTAssertTrue(secondWindowContext.contains("今日各窗口已聊单词：adapt(good)"))

        // 4. Lock-free study_remember & study_update_memory with omitted optional fields
        let remCall = ToolCall(id: "m1", name: "study_remember", arguments: #"{"text":"sunshine 答光线也算对"}"#)
        _ = try executor.perform(StudyToolAction(remCall), sourceMessage: nextMsg)
        let savedMem = try XCTUnwrap(store.records(projectID: scope.projectID).first)
        XCTAssertEqual(savedMem.category, "生词")

        let updCall = ToolCall(id: "m2", name: "study_update_memory", arguments: #"{"record_id":"\#(savedMem.toolReference)","text":"sunshine 光线/阳光都算掌握"}"#)
        _ = try executor.perform(StudyToolAction(updCall), sourceMessage: nextMsg)
        XCTAssertEqual(try store.records(projectID: scope.projectID).first?.text, "sunshine 光线/阳光都算掌握")

        // 5. Lock-free reading: read passage + question + answer without revision or quote locks
        let readPassageCall = ToolCall(id: "r1", name: "study_read_passage", arguments: #"{"passage_id":"2024-text-1","paragraph":1,"question":21}"#)
        let readPassageOut = try executor.perform(StudyToolAction(readPassageCall), sourceMessage: nextMsg)
        let decodedRead = try StudyCoding.decode(StudyReadingResult.self, from: Data(readPassageOut.utf8))
        XCTAssertEqual(decodedRead.excerpts.count, 2)

        let ansCall = ToolCall(id: "r2", name: "study_answer_reading", arguments: #"{"question":21,"choice":"A"}"#)
        _ = try executor.perform(StudyToolAction(ansCall), sourceMessage: nextMsg)
        XCTAssertEqual(try store.readingAnswers(projectID: scope.projectID).first?.correct, true)

        // 6. Lock-free history topic, practice & combined history search/read with omitted optional fields
        let histScope = StudyScope(projectID: StudySubject.history.projectID, threadID: UUID(), subject: .history)
        let histPack = StudyHistoryPack(
            schema: "sermo.history.v1", kind: "reference", source: "合成参考", verification: "测试",
            entries: [.init(id: "h-tang", title: "唐朝三省六部", block: "中国古代史", text: "中书门下尚书三省详细内容")]
        )
        try store.importStudyHistory(histPack, scope: histScope, userConfirmedOutline: false)
        let histExec = StudyToolExecutor(store: store, scope: histScope, documents: [])

        let topicCall = ToolCall(id: "h1", name: "study_save_topic", arguments: #"{"title":"隋唐中央官制","level":"studied_once"}"#)
        _ = try histExec.perform(StudyToolAction(topicCall), sourceMessage: nextMsg)
        XCTAssertEqual(try store.studyTopicState(scope: histScope)?.level, .studiedOnce)

        let pracCall = ToolCall(id: "h2", name: "study_save_practice", arguments: #"{"question":"口述三省职责","answer":"中书草拟门下审核尚书执行","outcome":"correct"}"#)
        _ = try histExec.perform(StudyToolAction(pracCall), sourceMessage: nextMsg)
        XCTAssertEqual(try store.studyPractices(projectID: histScope.projectID).count, 1)

        let histReadCall = ToolCall(id: "h3", name: "study_history_search", arguments: #"{"record_id":"h-tang"}"#)
        let histReadOut = try histExec.perform(StudyToolAction(histReadCall), sourceMessage: nextMsg)
        XCTAssertTrue(histReadOut.contains("中书门下尚书三省详细内容"))
    }
}
