import XCTest
@testable import DeepSeekCore

final class StudyReadingTests: XCTestCase {
    private var folder: URL!
    private var store: StudyMemoryStore!
    private var scope: StudyScope!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("sermo-reading-" + UUID().uuidString)
        store = try StudyMemoryStore(url: folder.appendingPathComponent("study.sqlite"))
        scope = .init(projectID: StudySubject.english.projectID, threadID: UUID(), subject: .english)
        try store.importReadings(pack(), projectID: scope.projectID)
    }
    override func tearDownWithError() throws {
        store = nil
        if folder.lastPathComponent.hasPrefix("sermo-reading-") { try FileManager.default.removeItem(at: folder) }
    }
    private func pack(pending: Bool = false) -> StudyReadingPack {
        .init(schema: "sermo.readings.v1", passages: [.init(id: "synthetic-2026-text-4", title: "合成阅读 Text 4", year: 2026, textNumber: 4,
            paragraphs: ["Birds adapt to a changed climate. This is a synthetic passage.", "Only this second paragraph mentions gardens."],
            questions: [.init(id: "synthetic-q36", number: 36, stem: "What do birds do?", options: ["Adapt.", "Adopt pets.", "Fly to Mars.", "Build computers."],
                answer: 0, explanation: "Synthetic reference only.", verification: pending ? "pending" : "verified", source: "Synthetic reference", sourceURL: nil)],
            source: "Synthetic test material", sourceURL: nil, topic: "合成适应话题")])
    }
    private func action(_ name: String, _ args: [String: Any]) throws -> StudyToolAction {
        try StudyToolAction(ToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: JSONSerialization.data(withJSONObject: args), as: UTF8.self)))
    }
    private func message(_ text: String) -> ChatMessage { .init(role: .user, content: text, createdAt: Date().addingTimeInterval(2)) }
    @discardableResult private func open(_ msg: ChatMessage? = nil) throws -> StudyReadingResult {
        try store.performReading(action("study_open_reading", ["passage_id":"synthetic-2026-text-4", "mode":"start"]), scope: scope, message: msg ?? message("开始阅读"))
    }
    private func revision() throws -> Int { try XCTUnwrap(store.readingState(scope: scope)).revision }
    @discardableResult private func question(_ msg: ChatMessage) throws -> StudyReadingResult {
        try store.performReading(action("study_show_reading", ["kind":"question","number":36,"expected_revision":revision()]), scope: scope, message: msg)
    }
    func testImportValidationPartialMergeAndConflictRollback() throws {
        let data = try StudyCoding.encode(pack())
        XCTAssertEqual(try StudyReadingPack.decode(data).passages[0].questions[0].answer, 0)
        try open()
        let before = try revision()
        try store.importReadings(pack(), projectID: scope.projectID)
        XCTAssertEqual(try revision(), before)
        XCTAssertThrowsError(try store.importReadings(pack(pending: true), projectID: scope.projectID))
        XCTAssertEqual(try store.readingCatalog(projectID: scope.projectID).count, 1)
        let malformed = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"answer\":0", with: "\"answer\":8")
        XCTAssertThrowsError(try StudyReadingPack.decode(Data(malformed.utf8)))
    }
    func testRawExcerptIsExactAndContextContainsOnlyIndexAndCursor() throws {
        let result = try open()
        XCTAssertEqual(result.excerpts[0].text, pack().passages[0].paragraphs[0])
        let executor = StudyToolExecutor(store: store, scope: scope, documents: [])
        let context = try executor.context(query: "阅读")
        XCTAssertTrue(context.contains("synthetic-2026-text-4"))
        XCTAssertFalse(context.contains("Birds adapt"))
        XCTAssertFalse(context.contains("Only this second"))
        XCTAssertFalse(context.contains("Synthetic reference only"))
        XCTAssertEqual(try store.readingAnswers(projectID: scope.projectID).count, 0)
    }
    func testQuestionDoesNotLeakAnswerAndRequiresLaterUserReply() throws {
        try open()
        let shown = message("出题")
        let q = try question(shown)
        XCTAssertTrue(q.excerpts[0].text.contains("A. Adapt."))
        XCTAssertFalse(q.excerpts[0].text.contains("参考答案"))
        XCTAssertThrowsError(try store.performReading(action("study_answer_reading", ["choice":"A", "expected_revision":revision(), "evidence_quote":"出题"]), scope: scope, message: shown))
        XCTAssertEqual(try store.readingAnswers(projectID: scope.projectID).count, 0)
    }
    func testAnswerZeroAReplayAndCorrectionKeepSingleQuestion() throws {
        try open(); try question(message("出第36题"))
        let answer = message("我选B")
        let args: [String: Any] = ["choice":"B", "expected_revision":try revision(), "evidence_quote":answer.content]
        _ = try store.performReading(action("study_answer_reading", args), scope: scope, message: answer)
        _ = try store.performReading(action("study_answer_reading", args), scope: scope, message: answer)
        XCTAssertEqual(try store.readingAnswers(projectID: scope.projectID).count, 1)
        XCTAssertEqual(try store.readingAnswers(projectID: scope.projectID)[0].correct, false)
        let correction = message("更正，我实际选A")
        _ = try store.performReading(action("study_answer_reading", ["choice":"A","expected_revision":revision(),"evidence_quote":correction.content]), scope: scope, message: correction)
        let saved = try XCTUnwrap(store.readingAnswers(projectID: scope.projectID).first)
        XCTAssertEqual(saved.revision, 2); XCTAssertEqual(saved.correct, true)
        XCTAssertEqual(saved.referenceAnswer, "A")
        XCTAssertEqual(try store.readingEvents(projectID: scope.projectID).filter { $0.action == "study_answer_reading" }.count, 2)
        XCTAssertEqual(try store.readingState(scope: scope)?.question, 36)
    }
    func testReferenceRequiresAnswerOrExplicitSkipAndSkipIsNotScored() throws {
        try open(); try question(message("出题"))
        let request = message("直接看答案")
        XCTAssertThrowsError(try store.performReading(action("study_reading_reference", ["skip_without_answer":false,"expected_revision":revision(),"evidence_quote":request.content]), scope: scope, message: request))
        let result = try store.performReading(action("study_reading_reference", ["skip_without_answer":true,"expected_revision":revision(),"evidence_quote":request.content]), scope: scope, message: request)
        XCTAssertTrue(result.excerpts[0].text.contains("参考答案：A"))
        let answer = try XCTUnwrap(store.readingAnswers(projectID: scope.projectID).first)
        XCTAssertTrue(answer.skipped); XCTAssertNil(answer.correct); XCTAssertNil(answer.choice)
    }
    func testUnverifiedAnswerIsNeitherLeakedNorScored() throws {
        let another = StudyScope(projectID: UUID(), threadID: UUID(), subject: .english)
        try store.importReadings(pack(pending: true), projectID: another.projectID)
        scope = another; try open(); try question(message("出题"))
        let answer = message("选B")
        _ = try store.performReading(action("study_answer_reading", ["choice":"B","expected_revision":revision(),"evidence_quote":answer.content]), scope: scope, message: answer)
        XCTAssertNil(try store.readingAnswers(projectID: scope.projectID)[0].correct)
        let result = try store.performReading(action("study_reading_reference", ["skip_without_answer":false,"expected_revision":revision(),"evidence_quote":"看答案"]), scope: scope, message: message("看答案"))
        XCTAssertTrue(result.excerpts[0].text.contains("待核")); XCTAssertFalse(result.excerpts[0].text.contains("参考答案：A"))
    }
    func testInterruptionPauseReopenAndNewWindowResumePreserveQuestion() throws {
        try open(); try question(message("出题"))
        _ = try store.performReading(action("study_show_reading", ["kind":"paragraph","number":2,"expected_revision":revision()]), scope: scope, message: message("看看下一段"))
        XCTAssertEqual(try store.readingState(scope: scope)?.question, 36)
        _ = try store.performReading(action("study_pause_reading", ["expected_revision":revision()]), scope: scope, message: message("暂停"))
        let id = try XCTUnwrap(store.readingSessions(projectID: scope.projectID).first?.id)
        store = nil; store = try StudyMemoryStore(url: folder.appendingPathComponent("study.sqlite"))
        XCTAssertEqual(try store.readingState(scope: scope)?.paused, true)
        let other = StudyScope(projectID: scope.projectID, threadID: UUID(), subject: .english)
        XCTAssertNil(try store.readingState(scope: other))
        let resumed = try store.performReading(action("study_open_reading", ["passage_id":"","mode":"continue"]), scope: other, message: message("接上上个窗口"))
        XCTAssertEqual(resumed.state.paragraph, 2); XCTAssertEqual(resumed.state.question, 36); XCTAssertFalse(resumed.state.paused)
        XCTAssertEqual(try store.readingSessions(projectID: scope.projectID).first?.id, id)
        XCTAssertNil(try store.readingState(scope: scope))
        XCTAssertEqual(try store.readingAnswers(projectID: scope.projectID).count, 0)
    }
    func testProjectIsolationStaleRevisionAndForeignSourceAreRejected() throws {
        try open()
        let other = StudyScope(projectID: StudySubject.history.projectID, threadID: scope.threadID, subject: .history)
        XCTAssertTrue(try store.readingCatalog(projectID: other.projectID).isEmpty)
        XCTAssertNil(try store.readingState(scope: other))
        XCTAssertThrowsError(try store.performReading(action("study_pause_reading", ["expected_revision":999]), scope: scope, message: message("暂停")))
        XCTAssertThrowsError(try store.performReading(action("study_open_reading", ["passage_id":"synthetic-2026-text-4","mode":"start"]), scope: other, message: message("打开")))
    }
    func testCollectedWordRetainsOriginalSentenceAndVocabularyLinkWithoutScoring() throws {
        let wordData = Data(#"{"schema_version":"yanxi.private-import.v2-stage1","cards":[{"id":"synthetic-adapt","word":"adapt","translation_zh":"适应","unit_order":[{"collection":"required","unit":1,"position":1}]}]}"#.utf8)
        try store.importWords(StudyWordPack.decode(wordData), projectID: scope.projectID); try open()
        let executor = StudyToolExecutor(store: store, scope: scope, documents: [])
        let msg = message("帮我记一下adapt")
        let args: [String: Any] = ["word":"adapt","original_sentence":"Birds adapt to a changed climate.","expected_revision":try revision(),"evidence_quote":msg.content]
        _ = try executor.perform(action("study_collect_reading_word", args), sourceMessage: msg)
        _ = try executor.perform(action("study_collect_reading_word", args), sourceMessage: msg)
        let memories = try store.records(projectID: scope.projectID)
        XCTAssertEqual(memories.count, 1)
        XCTAssertEqual(memories[0].source.material?.linkedWordIDs, ["synthetic-adapt"])
        XCTAssertEqual(memories[0].source.material?.paragraph, 1)
        XCTAssertTrue(try store.wordProgress(projectID: scope.projectID).isEmpty)
        XCTAssertThrowsError(try store.readingWordReference(scope: scope, word: "adapt", originalSentence: "People adapt to winter.", expectedRevision: revision()))
        XCTAssertThrowsError(try store.readingWordReference(scope: scope, word: "apt", originalSentence: "Birds adapt to a changed climate.", expectedRevision: revision()))
        XCTAssertEqual(try store.readingState(scope: scope)?.paragraph, 1)
    }
    func testStoredSourceExcerptsSurviveSnapshotAndOldActivitiesRemainDecodable() throws {
        let result = try open()
        var activity = ToolActivity(id: "source", title: "资料", status: .done, kind: "study")
        activity.studyExcerpts = result.excerpts
        let data = try StudyCoding.encode(activity)
        XCTAssertEqual(try StudyCoding.decode(ToolActivity.self, from: data).studyExcerpts, result.excerpts)
        let old = Data(#"{"id":"old","title":"旧工具","status":"done"}"#.utf8)
        XCTAssertNil(try StudyCoding.decode(ToolActivity.self, from: old).studyExcerpts)
    }
    func testReadingSchemaRejectsUnknownFieldsAndNumericBoolean() throws {
        XCTAssertThrowsError(try action("study_open_reading", ["passage_id":"x","mode":"start","project_id":"foreign"]))
        let numeric = try action("study_reading_reference", ["skip_without_answer":1,"expected_revision":1,"evidence_quote":"看答案"])
        XCTAssertThrowsError(try numeric.boolean("skip_without_answer"))
    }
    func testCorrectionAfterReselectingAnAnsweredQuestionInSameUserTurn() throws {
        try open(); try question(message("出题"))
        let first = message("我选B")
        _ = try store.performReading(action("study_answer_reading", ["choice":"B","expected_revision":revision(),"evidence_quote":first.content]), scope: scope, message: first)
        let correction = message("刚才第36题改选A")
        try question(correction)
        _ = try store.performReading(action("study_answer_reading", ["choice":"A","expected_revision":revision(),"evidence_quote":correction.content]), scope: scope, message: correction)
        XCTAssertEqual(try store.readingAnswers(projectID: scope.projectID).count, 1)
        XCTAssertEqual(try store.readingAnswers(projectID: scope.projectID)[0].revision, 2)
    }
    func testAcceptanceScenarioWritesSyntheticStateEvidence() throws {
        let evidenceURL = ProcessInfo.processInfo.environment["SERMO_READING_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0) }
        var lines: [String] = []
        func capture(_ label: String) throws {
            let state = try store.readingState(scope: scope)
            lines.append(label + ": " + String(decoding: try StudyCoding.encode(state), as: UTF8.self))
            if let evidenceURL {
                try FileManager.default.createDirectory(at: evidenceURL, withIntermediateDirectories: true)
                try StudyCoding.encode(store.export(projectIDs: [scope.projectID])).write(to: evidenceURL.appendingPathComponent(label + ".json"))
                try FileManager.default.copyItem(at: folder.appendingPathComponent("study.sqlite"), to: evidenceURL.appendingPathComponent(label + ".sqlite"))
            }
        }
        try capture("00-before")
        try open(); try capture("01-paragraph-one")
        try question(message("来一道题")); try capture("02-waiting-question")
        let executor = StudyToolExecutor(store: store, scope: scope, documents: [])
        let note = message("adapt这个词不会，帮我记下来")
        _ = try executor.perform(action("study_collect_reading_word", ["word":"adapt","original_sentence":"Birds adapt to a changed climate.","expected_revision":revision(),"evidence_quote":note.content]), sourceMessage: note)
        XCTAssertEqual(try store.readingState(scope: scope)?.question, 36)
        try capture("03-interruption-and-word-source")
        _ = try store.performReading(action("study_pause_reading", ["expected_revision":revision()]), scope: scope, message: message("暂停"))
        try capture("04-pause-and-close")
        let sessionID = try XCTUnwrap(store.readingSessions(projectID: scope.projectID).first?.id)
        store = nil; store = try StudyMemoryStore(url: folder.appendingPathComponent("study.sqlite"))
        try capture("05-reopened")
        let oldScope = scope!
        scope = .init(projectID: oldScope.projectID, threadID: UUID(), subject: .english)
        _ = try store.performReading(action("study_open_reading", ["passage_id":"","mode":"continue"]), scope: scope, message: message("新窗口继续Text4"))
        XCTAssertEqual(try store.readingSessions(projectID: scope.projectID).first?.id, sessionID)
        XCTAssertEqual(try store.readingState(scope: scope)?.question, 36)
        XCTAssertEqual(try store.readingAnswers(projectID: scope.projectID).count, 0)
        XCTAssertNil(try store.readingState(scope: oldScope))
        try capture("06-new-window-same-task")
        let answer = message("我选A")
        _ = try store.performReading(action("study_answer_reading", ["choice":"A","expected_revision":revision(),"evidence_quote":answer.content]), scope: scope, message: answer)
        XCTAssertEqual(try store.readingAnswers(projectID: scope.projectID)[0].correct, true)
        try capture("07-answer-saved")
        let restoredWord = try XCTUnwrap(store.records(projectID: scope.projectID).first)
        XCTAssertEqual(restoredWord.source.material?.originalSentence, "Birds adapt to a changed climate.")
        if let evidenceURL { try Data(lines.joined(separator: "\n").utf8).write(to: evidenceURL.appendingPathComponent("scenario.txt")) }
    }
}
