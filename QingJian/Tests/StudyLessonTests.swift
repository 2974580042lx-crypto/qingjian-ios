import XCTest
@testable import DeepSeekCore

final class StudyLessonTests: XCTestCase {
    private var folder: URL!
    private var store: StudyMemoryStore!
    private var history: StudyScope!
    private var politics: StudyScope!
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("sermo-step5-" + UUID().uuidString)
        store = try StudyMemoryStore(url: folder.appendingPathComponent("study.sqlite"))
        history = .init(projectID: StudySubject.history.projectID, threadID: UUID(), subject: .history)
        politics = .init(projectID: StudySubject.politics.projectID, threadID: UUID(), subject: .politics)
    }
    override func tearDownWithError() throws {
        store = nil
        if folder.lastPathComponent.hasPrefix("sermo-step5-") { try FileManager.default.removeItem(at: folder) }
    }
    private func action(_ name: String, _ args: [String: Any]) throws -> StudyToolAction {
        try StudyToolAction(ToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: JSONSerialization.data(withJSONObject: args), as: UTF8.self)))
    }
    @discardableResult private func start(_ scope: StudyScope, title: String = "合成历史专题") throws -> StudyLessonReceipt {
        let m = ChatMessage(role: .user, content: "第一次学习" + title)
        return try store.performLesson(action("study_start_topic", ["title":title,"outline_id":"","mode":"start","phase":"first_pass","evidence_quote":m.content]), scope: scope, message: m)
    }
    private func practiceArgs(message: ChatMessage, outcome: String = "wrong", source: String = "user_statement", area: String = "马原") -> [String: Any] {
        ["area":area,"kind":"single_choice","question":"合成题：区分概念甲与乙","answer":"A","outcome":outcome,
         "weak_point":"合成易混点","source_kind":source,"evidence_quote":message.content]
    }
    @discardableResult private func record(_ scope: StudyScope, message: ChatMessage, outcome: String = "wrong", source: String = "user_statement") throws -> StudyLessonReceipt {
        try store.performLesson(action("study_record_practice", practiceArgs(message: message, outcome: outcome, source: source,
            area: scope.subject == .history ? "中国古代史" : "马原")), scope: scope, message: message)
    }
    func testTopicPersistsAndNewWindowResumesSamePrompt() throws {
        try start(history)
        let current = try XCTUnwrap(store.studyTopicState(scope: history))
        let m = ChatMessage(role: .user, content: "只学了第一遍，我能说出两点，但容易忘第三点")
        let update = try action("study_update_topic", ["expected_revision":current.expected_revision,"session_revision":current.session_revision,
            "phase":"first_pass","level":"studied_once","note":"易忘第三点","pending_prompt":"请先说出两点提纲","source_kind":"user_statement","evidence_quote":m.content])
        _ = try store.performLesson(update, scope: history, message: m)
        let saved = try XCTUnwrap(store.studyTopicState(scope: history))
        _ = try store.performLesson(action("study_pause_topic", ["session_revision":saved.session_revision,"evidence_quote":"暂停"]), scope: history, message: .init(role: .user, content: "暂停"))
        store = nil; store = try StudyMemoryStore(url: folder.appendingPathComponent("study.sqlite"))
        let newScope = StudyScope(projectID: history.projectID, threadID: UUID(), subject: .history)
        let resumed = try store.performLesson(action("study_start_topic", ["title":"","outline_id":"","mode":"continue","phase":"unknown","evidence_quote":"继续"]), scope: newScope, message: .init(role: .user, content: "继续"))
        XCTAssertEqual(resumed.topic?.topic_id, current.topic_id)
        XCTAssertEqual(resumed.topic?.pendingPrompt, "请先说出两点提纲")
        XCTAssertEqual(resumed.topic?.phase, .firstPass)
        XCTAssertEqual(resumed.topic?.paused, false)
        XCTAssertNil(try store.studyTopicState(scope: history))
        XCTAssertNil(try store.studyTopicState(scope: politics))
    }
    func testContinueWithoutSavedTopicDoesNotInventOne() throws {
        XCTAssertThrowsError(try store.performLesson(action("study_start_topic", ["title":"不存在的专题","outline_id":"","mode":"continue","phase":"unknown","evidence_quote":"继续"]), scope: history, message: .init(role: .user, content: "继续")))
        XCTAssertTrue(try store.studyTopics(projectID: history.projectID).isEmpty)
    }
    func testStaleTopicRevisionAndPausedWritesAreRejected() throws {
        try start(history); let s = try XCTUnwrap(store.studyTopicState(scope: history))
        _ = try store.performLesson(action("study_pause_topic", ["session_revision":s.session_revision,"evidence_quote":"暂停"]), scope: history, message: .init(role: .user, content: "暂停"))
        XCTAssertThrowsError(try store.performLesson(action("study_update_topic", ["expected_revision":s.expected_revision,"session_revision":s.session_revision,
            "phase":"review","level":"can_outline","note":"不应写入","pending_prompt":"","source_kind":"model_inference","evidence_quote":"回答"]), scope: history, message: .init(role: .user, content: "回答")))
        XCTAssertEqual(try store.studyTopics(projectID: history.projectID).first?.level, .notStudied)
    }
    func testPracticeRetriesCorrectionsAndRemovalDoNotDuplicateQuestions() throws {
        let m = ChatMessage(role: .user, content: "合成题我选A，标准是B，这次错了")
        let a = try action("study_record_practice", practiceArgs(message: m))
        _ = try store.performLesson(a, scope: politics, message: m); _ = try store.performLesson(a, scope: politics, message: m)
        let p = try XCTUnwrap(store.studyPractices(projectID: politics.projectID).first)
        XCTAssertEqual(try store.studyPractices(projectID: politics.projectID).count, 1)
        let correction = ChatMessage(role: .user, content: "更正，标准答案是A，我答对了")
        var args = practiceArgs(message: correction, outcome: "correct"); args["record_id"] = p.reference; args["expected_revision"] = 1
        _ = try store.performLesson(action("study_correct_practice", args), scope: politics, message: correction)
        let corrected = try XCTUnwrap(store.studyPractices(projectID: politics.projectID).first)
        XCTAssertEqual(corrected.id, p.id); XCTAssertEqual(corrected.revision, 2); XCTAssertTrue(corrected.countsForAccuracy)
        _ = try store.performLesson(action("study_remove_practice", ["record_id":p.reference,"expected_revision":2,"evidence_quote":"删掉这条合成练习"]), scope: politics, message: .init(role: .user, content: "删掉这条合成练习"))
        XCTAssertTrue(try store.studyPractices(projectID: politics.projectID).isEmpty)
        XCTAssertEqual(try store.studyPractices(projectID: politics.projectID, includeDeleted: true).count, 1)
        XCTAssertEqual(try store.reviewInput(projectID: politics.projectID).practiceEvents.count, 3)
    }
    func testEditedSourceCannotReplayAnOldPracticeReceipt() throws {
        var m = ChatMessage(role: .user, content: "我选A，题干甲，标准B")
        let a = try action("study_record_practice", practiceArgs(message: m))
        _ = try store.performLesson(a, scope: politics, message: m)
        m.content += "，后来补充了不同题干"
        XCTAssertThrowsError(try store.performLesson(a, scope: politics, message: m))
        XCTAssertEqual(try store.studyPractices(projectID: politics.projectID).count, 1)
    }
    func testModelInferencesAndUnansweredQuestionsDoNotEnterAccuracy() throws {
        _ = try record(politics, message: .init(role: .user, content: "我选A，标准B，所以错了"))
        _ = try record(politics, message: .init(role: .user, content: "我选A，帮我看看"), outcome: "correct", source: "model_inference")
        let result = try store.weeklyReport(scope: politics, weeksAgo: 0, generate: true, zone: zone)
        XCTAssertTrue(result.report!.text.contains("用户确认的 1 题中，正确 0 题，0%"))
        XCTAssertTrue(result.report!.text.contains("模型整理摘要，原题待核"))
        let m = ChatMessage(role: .user, content: "还没作答")
        var args = practiceArgs(message: m); args["answer"] = ""
        XCTAssertThrowsError(try store.performLesson(action("study_record_practice", args), scope: politics, message: m))
    }
    func testImageOnlyEvidenceIsModelInferenceAndPreservesAttachmentReference() throws {
        var m = ChatMessage(role: .user, content: ""); m.images = ["synthetic-question.jpg"]
        let p = try record(politics, message: m, source: "model_inference")
        XCTAssertEqual(p.practice?.countsForAccuracy, false)
        XCTAssertEqual(try store.studyPractices(projectID: politics.projectID).first?.source.attachmentIDs, m.images)
        XCTAssertThrowsError(try record(politics, message: m, source: "user_statement"))
        let text = try store.voiceReview(scope: politics, instructions: "", zone: zone)
        XCTAssertTrue(text.contains("此文字导出没有携带原图"))
    }
    func testHistoryReferenceCannotSilentlyBecomeConfirmedOutline() throws {
        let entry = StudyHistoryPack.Entry(id: "synthetic-history", title: "合成条目", block: "中国古代史", text: "只用于测试")
        let reference = StudyHistoryPack(schema: "sermo.history.v1", kind: "reference", source: "合成AI参考", verification: "未核", entries: [entry])
        try store.importStudyHistory(reference, scope: history, userConfirmedOutline: false)
        XCTAssertNil(try store.studyHistoryPack(projectID: history.projectID, kind: "outline"))
        let outline = StudyHistoryPack(schema: "sermo.history.v1", kind: "outline", source: "合成用户大纲", verification: "用户核对", entries: [entry])
        XCTAssertThrowsError(try store.importStudyHistory(outline, scope: history, userConfirmedOutline: false))
        try store.importStudyHistory(outline, scope: history, userConfirmedOutline: true)
        XCTAssertThrowsError(try store.importStudyHistory(outline, scope: politics, userConfirmedOutline: true))
    }
    func testEmptyVoiceReviewIsCompleteAndDoesNotInventLearning() throws {
        let prompt = try store.voiceReview(scope: politics, instructions: "我的人格固定指令", zone: zone)
        XCTAssertTrue(prompt.contains("我的人格固定指令")); XCTAssertTrue(prompt.contains("没有这类练习记录"))
        XCTAssertTrue(prompt.contains("先给我思考和回答机会")); XCTAssertTrue(prompt.contains("没有保存的继续位置"))
        XCTAssertFalse(prompt.contains("今天已经学会"))
        XCTAssertTrue(try store.reviewInput(projectID: politics.projectID).memoryEvents.isEmpty)
    }
    func testVoiceReviewAndWeeklyReportKeepProjectsIsolated() throws {
        try start(history, title: "历史私有合成专题")
        _ = try record(politics, message: .init(role: .user, content: "政治合成题选A错了"))
        let h = try store.voiceReview(scope: history, instructions: "", zone: zone)
        let p = try store.voiceReview(scope: politics, instructions: "", zone: zone)
        XCTAssertFalse(p.contains("历史私有合成专题")); XCTAssertFalse(h.contains("政治合成题选A错了"))
        XCTAssertTrue(h.contains("第一遍学习"))
        XCTAssertEqual(try store.weeklyReport(scope: history, weeksAgo: 0, generate: false, zone: zone).status, "missing")
    }
    func testWeeklyReportInvalidatesAfterCorrectionAndKeepsOldSnapshot() throws {
        let m = ChatMessage(role: .user, content: "我选A，标准答案B")
        _ = try record(politics, message: m)
        let first = try store.weeklyReport(scope: politics, weeksAgo: 0, generate: true, zone: zone)
        XCTAssertEqual(first.status, "generated")
        let same = try store.weeklyReport(scope: politics, weeksAgo: 0, generate: true, zone: zone)
        XCTAssertEqual(first.report?.id, same.report?.id)
        let record = try XCTUnwrap(store.studyPractices(projectID: politics.projectID).first)
        let c = ChatMessage(role: .user, content: "更正，这题标准答案A，我做对了")
        var args = practiceArgs(message: c, outcome: "correct"); args["record_id"] = record.reference; args["expected_revision"] = 1
        _ = try store.performLesson(action("study_correct_practice", args), scope: politics, message: c)
        XCTAssertEqual(try store.weeklyReport(scope: politics, weeksAgo: 0, generate: false, zone: zone).status, "stale")
        let next = try store.weeklyReport(scope: politics, weeksAgo: 0, generate: true, zone: zone)
        XCTAssertEqual(next.report?.revision, 2); XCTAssertNotEqual(next.report?.id, first.report?.id)
        XCTAssertTrue(next.report!.text.contains("正确 1 题，100%"))
        XCTAssertTrue(first.report!.text.contains("正确 0 题，0%"))
        XCTAssertEqual(try store.export(projectIDs: [politics.projectID]).rows.filter { $0.kind == "weekly_report" }.count, 2)
    }
    func testLateSavedAndManualMemoryAreNotDescribedAsTodaysPractice() throws {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let old = ChatMessage(role: .user, content: "去年看过合成概念，今天只是补记", createdAt: yesterday)
        let source = StudySource.from(message: old, scope: politics, kind: .userStatement, quote: old.content)
        _ = try store.apply(.init(action: .remember, category: "易混点", text: "去年看过的合成概念", source: source), scope: politics, operationID: "late")
        let manual = StudySource(kind: .manual, threadID: politics.threadID, messageID: nil, text: "手动补记", quote: "手动补记")
        _ = try store.apply(.init(action: .remember, category: "错题", text: "手动补记旧错题", source: manual), scope: politics, operationID: "manual")
        let text = try store.voiceReview(scope: politics, instructions: "", zone: zone)
        XCTAssertTrue(text.contains("不等于本时段新学内容")); XCTAssertTrue(text.contains("学习日期未确认"))
        XCTAssertTrue(text.contains("本时段没有这类练习记录"))
        XCTAssertTrue(text.contains(StudyReviewText.stamp(yesterday, zone: zone)))
    }
    func testLocalDayBoundaryExcludesNextDayAndWeekStartsMonday() {
        let date = ISO8601DateFormatter().date(from: "2026-11-11T17:00:00Z")!
        let day = StudyReviewText.day(date, zone: zone)
        XCTAssertEqual(StudyReviewText.stamp(day.start, zone: zone), "2026-11-12 00:00")
        XCTAssertFalse(StudyReviewText.contains(day.end, day))
        XCTAssertEqual(StudyReviewText.stamp(StudyReviewText.week(date, weeksAgo: 0, zone: zone).start, zone: zone), "2026-11-09 00:00")
    }
    func testVoiceReviewUsesRelevantSubjectAndLimitsResumeChoicesWithoutDeletingScenes() throws {
        for i in 0..<5 {
            let scope = StudyScope(projectID: history.projectID, threadID: UUID(), subject: .history)
            try start(scope, title: "合成专题\(i)")
        }
        let text = try store.voiceReview(scope: history, instructions: "", zone: zone)
        XCTAssertFalse(text.contains("【实际背词与阅读作答】"))
        XCTAssertTrue(text.contains("更早现场仍保留"))
        let resume = text.components(separatedBy: "【可以从哪里继续").last!
        XCTAssertEqual(resume.components(separatedBy: "- 专题：").count - 1, 3)
        XCTAssertEqual(try store.reviewInput(projectID: history.projectID).topicSessions.count, 5)
    }
    func testSyntheticHistoryPoliticsAndReportsEvidence() throws {
        try start(history, title: "合成专题：概念甲与乙的关系")
        let s = try XCTUnwrap(store.studyTopicState(scope: history))
        let oral = ChatMessage(role: .user, content: "第一遍学，我能说出甲和乙两个方面，但联系还说不清")
        _ = try store.performLesson(action("study_update_topic", ["expected_revision":s.expected_revision,"session_revision":s.session_revision,
            "phase":"first_pass","level":"studied_once","note":"联系说不清，先理解框架","pending_prompt":"你能用自己的话说说甲和乙的联系吗？","source_kind":"user_statement","evidence_quote":oral.content]), scope: history, message: oral)
        _ = try store.performLesson(action("study_record_practice", ["area":"中国古代史","kind":"oral","question":"合成专题：说出甲乙的关系",
            "answer":oral.content,"outcome":"unknown","weak_point":"联系说不清","source_kind":"user_statement","evidence_quote":oral.content]), scope: history, message: oral)
        _ = try record(politics, message: .init(role: .user, content: "纸质合成题我选A，标准B，混淆甲乙，这题错了"))
        let h = try store.weeklyReport(scope: history, weeksAgo: 0, generate: true, zone: zone)
        let p = try store.weeklyReport(scope: politics, weeksAgo: 0, generate: true, zone: zone)
        let v = try store.voiceReview(scope: history, instructions: "合成人格指令：用简单的话讲。", zone: zone)
        XCTAssertTrue(h.report!.text.contains("第一遍学习")); XCTAssertTrue(v.contains("先给我思考和回答机会"))
        XCTAssertTrue(p.report!.text.contains("正确 0 题，0%"))
        if let path = ProcessInfo.processInfo.environment["SERMO_STEP5_EVIDENCE_DIR"] {
            let root = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try StudyCoding.encode(h).write(to: root.appendingPathComponent("history-weekly.json"))
            try StudyCoding.encode(p).write(to: root.appendingPathComponent("politics-weekly.json"))
            try Data(v.utf8).write(to: root.appendingPathComponent("voice-review.txt"))
            try StudyCoding.encode(store.export(projectIDs: [history.projectID, politics.projectID])).write(to: root.appendingPathComponent("synthetic-records.json"))
            try FileManager.default.copyItem(at: folder.appendingPathComponent("study.sqlite"), to: root.appendingPathComponent("synthetic-records.sqlite"))
        }
    }
}
