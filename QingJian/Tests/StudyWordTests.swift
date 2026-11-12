import XCTest
import SQLite3
@testable import DeepSeekCore

final class StudyWordTests: XCTestCase {
    private var folder: URL!
    private var url: URL!
    private var store: StudyMemoryStore!
    private var scope: StudyScope!
    private let now = Date(timeIntervalSince1970: 1_794_384_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("sermo-word-tests-" + UUID().uuidString)
        url = folder.appendingPathComponent("learning.sqlite")
        store = try StudyMemoryStore(url: url)
        scope = StudyScope(projectID: StudySubject.english.projectID, threadID: UUID(), subject: .english)
        try store.importWords(pack(), projectID: scope.projectID)
    }
    override func tearDownWithError() throws {
        store = nil
        guard folder.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL,
              folder.lastPathComponent.hasPrefix("sermo-word-tests-") else { return }
        try FileManager.default.removeItem(at: folder)
    }
    private func pack() throws -> StudyWordPack {
        let text = #"{"schema_version":"yanxi.private-import.v2-stage1","cards":[{"id":"word-adopt","word":"adopt","translation_zh":"采纳，收养","meaning_status":"dictionary_draft_only","phonetic":null,"unit_order":[{"collection":"required","unit":1,"position":2},{"collection":"extra","unit":null,"position":1031}]},{"id":"word-adapt","word":"adapt","translation_zh":"适应，改编","core_meaning":"适应","phonetic_status":"verified","unit_order":[{"collection":"required","unit":1,"position":1}]},{"id":"word-effect","word":"effect","translation_zh":"效果","unit_order":[{"collection":"basic","unit":1,"position":1}]}]}"#
        return try StudyWordPack.decode(Data(text.utf8))
    }
    private func start(_ count: Int = 2, mode: StudyWordMode = .start) throws -> StudyWordSession {
        try store.startWords(scope: scope, unitID: "required-1", count: count, mode: mode, now: now).session
    }
    private func grade(_ session: StudyWordSession, rating: String = "good", messageID: UUID = UUID()) -> StudyWordGrade {
        StudyWordGrade(sessionID: session.id, expectedRevision: session.revision, wordID: session.currentWordID!, rating: rating,
            source: StudySource(kind: .userStatement, threadID: scope.threadID, messageID: messageID, text: "我记得，是适应", quote: "我记得，是适应", messageDate: now.addingTimeInterval(1)))
    }

    func testImportUsesUnitOrderAndDoesNotMarkDisplayedWordsLearned() throws {
        let session = try start()
        XCTAssertEqual(session.wordIDs, ["word-adapt", "word-adopt"])
        XCTAssertTrue(try store.wordProgress(projectID: scope.projectID).isEmpty)
        let first = try store.wordState(scope: scope)
        XCTAssertEqual(first.currentWord?.word, "adapt")
        XCTAssertNil(first.progress)
        XCTAssertEqual(try store.wordState(scope: scope).session, session, "Asking for context must not advance the lesson.")
    }

    func testAnswerAndPositionCommitTogetherAndRetryIsIdempotent() throws {
        let session = try start(); let input = grade(session)
        let first = try store.gradeWord(input, scope: scope, operationID: "answer-1", now: now)
        XCTAssertEqual(first.session.position, 1)
        XCTAssertEqual(first.event?.afterProgress.reviewCount, 1)
        XCTAssertEqual(try store.gradeWord(input, scope: scope, operationID: "answer-1", now: now).session, first.session)
        XCTAssertEqual(try store.wordProgress(projectID: scope.projectID).first?.reviewCount, 1)
        XCTAssertThrowsError(try store.gradeWord(grade(session, rating: "again"), scope: scope, operationID: "answer-1", now: now))
    }
    func testCannotGradeAQuestionBeforeTheUserHasAnsweredIt() throws {
        let session = try start()
        let early = StudyWordGrade(sessionID: session.id, expectedRevision: session.revision, wordID: session.currentWordID!, rating: "good",
            source: StudySource(kind: .userStatement, threadID: scope.threadID, messageID: UUID(), text: "开始背词", quote: "开始背词", messageDate: now.addingTimeInterval(-1)))
        XCTAssertThrowsError(try store.gradeWord(early, scope: scope, operationID: "premature", now: now))
        XCTAssertTrue(try store.wordProgress(projectID: scope.projectID).isEmpty)
        XCTAssertEqual(try store.wordState(scope: scope).session?.position, 0)
    }
    func testOpeningMessageCannotAlsoCountAsAnAnswerAndRetriesTolerateDatePrecision() throws {
        let openingID = UUID()
        let session = try store.startWords(scope: scope, unitID: "required-1", count: 2, mode: .start, sourceMessageID: openingID, now: now).session
        XCTAssertThrowsError(try store.gradeWord(grade(session, messageID: openingID), scope: scope, operationID: "opening", now: now))
        var answer = grade(session)
        answer.source.messageDate = now.addingTimeInterval(1.75)
        let committed = try store.gradeWord(answer, scope: scope, operationID: "answer", now: now)
        answer.source.messageDate = now.addingTimeInterval(1)
        XCTAssertEqual(try store.gradeWord(answer, scope: scope, operationID: "answer", now: now).session, committed.session)
        XCTAssertEqual(try store.wordProgress(projectID: scope.projectID).first?.reviewCount, 1)
    }

    func testRestartAndResumeKeepTheRemainingWord() throws {
        let session = try start()
        _ = try store.gradeWord(grade(session), scope: scope, operationID: "answer", now: now)
        store = nil; store = try StudyMemoryStore(url: url)
        let resumed = try store.startWords(scope: scope, unitID: "", count: 10, mode: .resume, now: now.addingTimeInterval(86400)).session
        XCTAssertEqual(resumed.id, session.id)
        XCTAssertEqual(resumed.position, 1)
        XCTAssertEqual(resumed.currentWordID, "word-adopt")
    }

    func testCrossWindowResumeTransfersOwnershipAndRejectsOldWindowWrite() throws {
        let session = try start(); let input = grade(session)
        let other = StudyScope(projectID: scope.projectID, threadID: UUID(), subject: .english)
        let resumed = try store.startWords(scope: other, unitID: "", count: 10, mode: .resume, now: now.addingTimeInterval(1)).session
        XCTAssertEqual(resumed.id, session.id); XCTAssertEqual(resumed.threadID, other.threadID)
        XCTAssertNil(try store.wordState(scope: scope).session)
        XCTAssertThrowsError(try store.gradeWord(input, scope: scope, operationID: "stale-window", now: now))
    }

    func testUndoRestoresFSRSStateAndQueue() throws {
        let session = try start()
        let answered = try store.gradeWord(grade(session, rating: "again"), scope: scope, operationID: "answer", now: now)
        XCTAssertEqual(answered.session.wordIDs.count, 3)
        let undone = try store.undoWord(scope: scope, sessionID: session.id, expectedRevision: answered.session.revision)
        XCTAssertEqual(undone.session.position, 0)
        XCTAssertEqual(undone.session.wordIDs, session.wordIDs)
        XCTAssertEqual(try store.wordProgress(projectID: scope.projectID).first?.reviewCount, 0)
        XCTAssertThrowsError(try store.undoWord(scope: scope, sessionID: session.id, expectedRevision: undone.session.revision))
    }
    func testAUserCorrectionCanUndoAndRegradeInTheSameTurn() throws {
        let session = try start()
        let answer = try store.gradeWord(grade(session, rating: "again"), scope: scope, operationID: "original", now: now)
        let correctionID = UUID()
        let restored = try store.undoWord(scope: scope, sessionID: session.id, expectedRevision: answer.session.revision)
        let corrected = try store.gradeWord(grade(restored.session, rating: "good", messageID: correctionID), scope: scope, operationID: "correction", now: now.addingTimeInterval(3))
        XCTAssertEqual(corrected.session.position, 1)
        XCTAssertEqual(corrected.event?.afterProgress.reviewCount, 1)
        XCTAssertEqual(corrected.event?.afterProgress.lastRating, "good")
    }

    func testReimportKeepsProgressAndChangedSpellingIsRejected() throws {
        let session = try start()
        _ = try store.gradeWord(grade(session), scope: scope, operationID: "answer", now: now)
        try store.importWords(pack(), projectID: scope.projectID)
        XCTAssertEqual(try store.wordProgress(projectID: scope.projectID).first?.reviewCount, 1)
        let encoded = String(decoding: try JSONEncoder().encode(pack()), as: UTF8.self)
        let changed = try StudyWordPack.decode(Data(encoded.replacingOccurrences(of: "\"word\":\"adapt\"", with: "\"word\":\"different\"").utf8))
        XCTAssertThrowsError(try store.importWords(changed, projectID: scope.projectID))
    }
    func testPartialPackUpdateKeepsWordsInAnExistingSession() throws {
        let session = try start()
        let whole = try pack()
        let partial = StudyWordPack(schema: whole.schema, cards: [whole.cards[0]])
        XCTAssertEqual(try store.importWords(partial, projectID: scope.projectID), 3)
        XCTAssertEqual(try store.wordState(scope: scope).session?.id, session.id)
        XCTAssertEqual(try store.wordState(scope: scope).currentWord?.word, "adapt")
    }
    func testUndoneRatingCannotBeReplayedAndWeakWordsAreReadable() throws {
        let session = try start()
        let input = grade(session, rating: "again")
        let answer = try store.gradeWord(input, scope: scope, operationID: "answer", now: now)
        XCTAssertEqual(try store.wordState(scope: scope).recentUnfamiliar, ["adapt"])
        _ = try store.undoWord(scope: scope, sessionID: session.id, expectedRevision: answer.session.revision)
        XCTAssertThrowsError(try store.gradeWord(input, scope: scope, operationID: "answer", now: now))
    }

    func testFailedGradeRollsBackBothQueueAndProgress() throws {
        let session = try start()
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK); defer { sqlite3_close(db) }
        let sql = "CREATE TRIGGER fail_word BEFORE INSERT ON study_data WHEN NEW.kind='word_event' BEGIN SELECT RAISE(ABORT,'test failure'); END"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try store.gradeWord(grade(session), scope: scope, operationID: "fail", now: now))
        XCTAssertTrue(try store.wordProgress(projectID: scope.projectID).isEmpty)
        XCTAssertEqual(try store.wordState(scope: scope).session, session)
    }

    func testDueReviewAndExplicitExtraPractice() throws {
        let session = try start(1)
        _ = try store.gradeWord(grade(session), scope: scope, operationID: "answer", now: now)
        let progress = try XCTUnwrap(store.wordProgress(projectID: scope.projectID).first)
        let other = StudyScope(projectID: scope.projectID, threadID: UUID(), subject: .english)
        let due = try store.startWords(scope: other, unitID: "required-1", count: 1, mode: .review, now: progress.due.addingTimeInterval(1))
        XCTAssertEqual(due.session.currentWordID, "word-adapt")
        let practice = try store.startWords(scope: scope, unitID: "required-1", count: 1, mode: .practice, now: now)
        XCTAssertEqual(practice.session.currentWordID, "word-adapt")
    }

    func testFuzzyUnitIDAndWordPracticeSummaryTrackRealTimeProgress() throws {
        // Fuzzy unit ID like "Unit 1" or "random" resolves cleanly without throwing "找不到这个单元"
        let fuzzySession = try store.startWords(scope: scope, unitID: "Unit 1", count: 2, mode: .start, now: now).session
        XCTAssertEqual(fuzzySession.unitID, "required-1")
        XCTAssertEqual(fuzzySession.currentWordID, "word-adapt")

        _ = try store.gradeWord(grade(fuzzySession, rating: "good"), scope: scope, operationID: "fuzzy-grade-1", now: now)
        let summary = try store.wordPracticeSummary(projectID: scope.projectID, now: now.addingTimeInterval(10))
        XCTAssertEqual(summary.totalWords, 3)
        XCTAssertEqual(summary.learnedWords, 1)
        XCTAssertEqual(summary.recentWords.first?.word.word, "adapt")
        XCTAssertEqual(summary.recentWords.first?.lastRating, "good")
    }

    func testOtherProjectCannotReadWordsOrProgress() throws {
        let session = try start(); _ = try store.gradeWord(grade(session), scope: scope, operationID: "answer", now: now)
        let other = StudyScope(projectID: StudySubject.history.projectID, threadID: UUID(), subject: .history)
        XCTAssertNil(try store.wordPack(projectID: other.projectID))
        XCTAssertTrue(try store.wordProgress(projectID: other.projectID).isEmpty)
        XCTAssertThrowsError(try store.startWords(scope: other, unitID: "", count: 10, mode: .start, now: now))
    }

    func testArchiveKeepsInstructionsAndLearningRecordsRecoverable() throws {
        var project = ChatProject(name: "英语伙伴", instructions: "用户固定指令")
        project.id = scope.projectID; project.studySubject = .english
        let session = try start(); _ = try store.gradeWord(grade(session), scope: scope, operationID: "answer", now: now)
        try store.archiveProject(project, keptThreadIDs: [scope.threadID])
        store = nil; store = try StudyMemoryStore(url: url)
        let archived = try XCTUnwrap(store.archivedProjects().first)
        XCTAssertEqual(archived.project.instructions, "用户固定指令")
        XCTAssertEqual(archived.keptThreadIDs, [scope.threadID])
        XCTAssertEqual(try store.wordProgress(projectID: project.id).count, 1)
        try store.finishRestoringProject(project.id)
        XCTAssertTrue(try store.archivedProjects().isEmpty)
        XCTAssertEqual(try store.wordPack(projectID: project.id)?.cards.count, 3)
    }

    func testFalseWeeklyClaimsAreHeldAcrossStreamChunks() {
        var guarder = StudyOutputGuard()
        XCTAssertEqual(guarder.consume("我已经把这对词记"), "")
        let result = guarder.consume("入本周周报了。")
        XCTAssertFalse(result.contains("已经把")); XCTAssertTrue(result.contains("尚未确认"))
        XCTAssertEqual(guarder.consume("已保存学习记录，待周报整理。"), "已保存学习记录，待周报整理。")
        XCTAssertEqual(StudyOutputGuard.checked("我不能说“已记入周报”。"), "我不能说“已记入周报”。")
        XCTAssertTrue(StudyOutputGuard.checked("本周总结已更新。" ).contains("尚未确认"))
    }

    func testSubscriptionToolSSEAndOpaqueContinuationEncoding() throws {
        let events: [[String: Any]] = [
            ["type":"response.output_item.added","output_index":1,"item":["type":"function_call","call_id":"call_1","name":"study_word_state","namespace":"study","arguments":""]],
            ["type":"response.function_call_arguments.delta","output_index":1,"delta":"{}"],
            ["type":"response.output_item.done","output_index":0,"item":["type":"reasoning","id":"reason_1","summary":[],"encrypted_content":"synthetic-opaque"]],
            ["type":"response.completed","response":["status":"completed"]]
        ]
        var parser = ResponsesStreamDecoder(), collector = ToolCallCollector(), continuation: [JSONValue] = []
        for object in events {
            let packet = "data: " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n\n"
            for byte in packet.utf8 { if let event = try parser.consume(byte) { collector.consume(event.toolCalls); continuation += event.subscriptionItems } }
        }
        XCTAssertTrue(parser.completed); XCTAssertEqual(collector.calls.first?.arguments, "{}")
        var request = ChatRequest(settings: AppSettings(), messages: [ChatMessage(role: .user, content: "继续")]).withTools(StudyWordTools.specs)
        request = request.appending([.assistantCalls(collector.calls, content: "", reasoning: "", subscriptionItems: continuation), .toolResult("已读取", callID: "call_1")])
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SubscriptionRequest(request: request, model: "test-model"))) as! [String: Any]
        let tools = payload["tools"] as! [[String: Any]]; XCTAssertEqual(tools[0]["type"] as? String, "namespace")
        let input = payload["input"] as! [[String: Any]]
        XCTAssertTrue(input.contains { $0["encrypted_content"] as? String == "synthetic-opaque" })
        XCTAssertTrue(input.contains { $0["type"] as? String == "function_call" && $0["namespace"] as? String == "study" })
        XCTAssertTrue(input.contains { $0["type"] as? String == "function_call_output" && $0["call_id"] as? String == "call_1" })
    }
}
