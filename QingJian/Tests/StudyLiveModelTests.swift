import XCTest
@testable import DeepSeekCore

/// Invoked explicitly by the manual macOS workflow. All material is synthetic.
final class StudyLiveModelTests: XCTestCase {
    @MainActor func testPart1LearnRecordAndExit() async throws {
        let (key, root) = try Self.configuration()
        let session = try LiveStudySession(key: key, root: root, phase: "part1", restoring: false)
        do {
            try await session.turn("请从 required-1 合成单元背一组两个词，一次只问一个。先出第一题，不要提前解释答案。", label: "01-start")
            let first = try XCTUnwrap(session.wordState().session)
            try session.require(first.position == 0 && first.currentWordID == "synthetic-adapt", "first word was not presented")
            try session.require(session.progressCount() == 0, "presentation incorrectly counted as learning")

            try await session.turn("我的答案是：adapt 表示采纳。我把 adapt 和 adopt 搞混了，这个词这次算没记住。请把这个易混点存进生词栏目。", label: "02-confusion-and-record")
            let after = try XCTUnwrap(session.wordState().session)
            try session.require(after.position == 1 && after.currentWordID == "synthetic-adopt", "answer did not advance exactly one word")
            try session.require(session.progressCount() == 1, "answer was not saved exactly once")
            let memories = try session.store.records(projectID: session.project.id)
            try session.require(memories.count == 1 && memories[0].text.lowercased().contains("adapt") && memories[0].text.lowercased().contains("adopt"), "confusion was not recorded")

            try await session.turn("今天先到这里，请暂停并保留当前还没回答的那个词。", label: "03-pause")
            let paused = try XCTUnwrap(session.wordState().session)
            try session.require(paused.paused && paused.position == 1, "pause did not preserve the waiting word")
            try session.saveExitState(memoryID: memories[0].id, sessionID: paused.id, waitingWordID: "synthetic-adopt")
            try session.finish(success: true)
        } catch {
            try session.finish(success: false, error: error)
            XCTFail("Live part 1 failed. See the redacted evidence artifact.")
        }
    }

    @MainActor func testPart2RestartResumeFindAndCorrect() async throws {
        let (key, root) = try Self.configuration()
        let session = try LiveStudySession(key: key, root: root, phase: "part2", restoring: true)
        do {
            let exit = try XCTUnwrap(session.exitState)
            try session.require(exit.processID != ProcessInfo.processInfo.processIdentifier, "restart must use a different Swift process")
            try await session.turn("继续刚才未完成的一轮，告诉我停在哪个词。先不要替我作答，也不要给当前词记分。", label: "04-restart-and-continue")
            let resumed = try XCTUnwrap(session.wordState().session)
            try session.require(resumed.id == exit.sessionID && resumed.currentWordID == exit.waitingWordID && !resumed.paused, "restart did not resume the saved session")
            try session.require(session.progressCount() == 1, "resuming incorrectly added an answer")

            session.openNewWindow()
            try await session.turn("我刚开了新窗口。找回这个项目之前保存的 adapt/adopt 易混记录，再接着上一个窗口没完成的背词任务。只问当前那一题，先别替我回答。", label: "05-new-window-recall")
            let moved = try XCTUnwrap(session.wordState().session)
            try session.require(moved.id == exit.sessionID && moved.threadID == session.thread.id && moved.currentWordID == exit.waitingWordID, "new window did not recover the saved task")
            try session.require(session.store.records(projectID: session.project.id).first?.id == exit.memoryID, "new window did not read the same project memory")

            try await session.turn("更正那条已有的易混记录：我容易混的是 affect 和 effect，adapt 和 adopt 已经能区分了。请更正原记录，别另建一条，当前背词题也先别记分。", label: "06-correct-memory")
            let memories = try session.store.records(projectID: session.project.id)
            try session.require(memories.count == 1 && memories[0].id == exit.memoryID && memories[0].revision == 2, "correction did not update the original record")
            try session.require(memories[0].text.lowercased().contains("affect") && memories[0].text.lowercased().contains("effect"), "corrected content missing")
            try session.require(session.store.events(projectID: session.project.id).count == 2, "memory revision history missing or duplicated")
            try session.require(session.progressCount() == 1, "memory correction incorrectly scored a word")
            try await session.turn("确认一下，周报是不是已经更新好了？", label: "07-weekly-state")
            try session.finish(success: true)
        } catch {
            try session.finish(success: false, error: error)
            XCTFail("Live part 2 failed. See the redacted evidence artifact.")
        }
    }

    @MainActor func testReadingPart1ReadInterruptReturnAndPause() async throws {
        let (key, root) = try Self.configuration()
        let s = try LiveStudySession(key: key, root: root, phase: "reading-part1", restoring: false, reading: true)
        do {
            try await s.turn("开始合成的2026年Text4，先把第一段给我看。先不出题、不讲答案，我想自己读一下。", label: "r01-read-paragraph")
            let opened = try XCTUnwrap(s.store.readingState(scope: s.scope))
            try s.require(opened.paragraph == 1 && opened.question == nil, "did not open first paragraph only")
            try s.require(s.lastExcerpts().contains { $0.text == LiveStudySession.readingParagraph }, "original paragraph not returned by client tool")
            try s.require(s.store.readingAnswers(projectID: s.project.id).isEmpty, "reading paragraph was scored")

            try await s.turn("这一段读完了，把第36题给我，先不要解释选项或告诉我答案。", label: "r02-present-question")
            try s.require(s.store.readingState(scope: s.scope)?.question == 36, "waiting question missing")
            try s.require(s.lastExcerpts().contains { $0.text.hasPrefix(LiveStudySession.readingQuestion) }, "question was not shown from source")

            try await s.turn("先插一句，段落里的resilient是什么意思？只解释这个词，不用记生词，别推进阅读，也先别替我选答案。", label: "r03-interrupt-for-word")
            let interrupted = try XCTUnwrap(s.store.readingState(scope: s.scope))
            try s.require(interrupted.paragraph == 1 && interrupted.question == 36, "word explanation moved reading position")
            try s.require(s.store.readingAnswers(projectID: s.project.id).isEmpty && s.progressCount() == 0, "word explanation was counted as an answer")
            try s.require(s.store.records(projectID: s.project.id).isEmpty, "word explanation saved unwanted memory")

            try await s.turn("这个词懂了，回到刚才那道待答题，原样给我看一遍，先别讲答案。", label: "r04-return-to-question")
            try s.require(s.store.readingState(scope: s.scope)?.question == 36, "did not return to the waiting question")
            try s.require(s.lastExcerpts().contains { $0.text.hasPrefix(LiveStudySession.readingQuestion) }, "return did not read the original question")
            try s.require(s.store.readingAnswers(projectID: s.project.id).isEmpty, "return counted as an answer")

            try await s.turn("先暂停，保留这道还没答的题。下次我会在新窗口接着来。", label: "r05-pause")
            let paused = try XCTUnwrap(s.store.readingSessions(projectID: s.project.id).first)
            try s.require(paused.paused && paused.paragraph == 1 && paused.question == 36, "pause did not preserve reading position")
            try s.saveExitState(sessionID: paused.id)
            try s.finish(success: true)
        } catch {
            try s.finish(success: false, error: error)
            XCTFail("Live reading part 1 failed. See the redacted evidence artifact.")
        }
    }
    @MainActor func testReadingPart2NewWindowResumeAndAnswer() async throws {
        let (key, root) = try Self.configuration()
        let s = try LiveStudySession(key: key, root: root, phase: "reading-part2", restoring: true, reading: true)
        do {
            let exit = try XCTUnwrap(s.exitState)
            try s.require(exit.processID != ProcessInfo.processInfo.processIdentifier, "reading restart must be a new Swift process")
            s.openNewWindow()
            try await s.turn("我换了一个新窗口，继续上次没做完的Text4阅读，回到停下的段落和那道待答题，不要替我答。", label: "r06-new-window-resume")
            let resumed = try XCTUnwrap(s.store.readingSessions(projectID: s.project.id).first)
            try s.require(resumed.id == exit.sessionID && resumed.threadID == s.thread.id && resumed.paragraph == 1 && resumed.question == 36 && !resumed.paused, "new window did not resume the same reading task")
            try s.require(s.store.readingAnswers(projectID: s.project.id).isEmpty, "resume added an answer")
            try s.require(s.lastExcerpts().contains { $0.text.hasPrefix(LiveStudySession.readingQuestion) }, "resume did not display the saved question")

            try await s.turn("这道题我选A，因为傍晚浇水能减少因热量造成的水分损失。请记下我的作答，再告诉我对不对。", label: "r07-answer")
            let answers = try s.store.readingAnswers(projectID: s.project.id)
            try s.require(answers.count == 1 && answers[0].sessionID == exit.sessionID && answers[0].question == 36 && answers[0].choice == "A" && answers[0].correct == true && !answers[0].skipped, "actual answer was not saved exactly once on the original task")
            try s.require(answers[0].source.threadID == s.thread.id && answers[0].source.text.contains("我选A"), "answer lost its real source")
            try s.require(s.progressCount() == 0, "reading answer incorrectly changed vocabulary scores")
            try s.finish(success: true)
        } catch {
            try s.finish(success: false, error: error)
            XCTFail("Live reading part 2 failed. See the redacted evidence artifact.")
        }
    }
    @MainActor func testLessonsPart1HistoryFirstPassAndPause() async throws {
        let (key, root) = try Self.configuration()
        let s = try LiveStudySession(key: key, root: root, phase: "lessons-part1", restoring: false, subject: .history)
        do {
            try await s.turn("只用这段合成材料：甲负责提出方案，乙负责复核方案，两者合作完成决策。开始‘甲乙分工与配合’这个合成历史专题，这是第一遍。一次问一个小问题，不补充真实史实。", label: "h01-first-pass")
            let first = try XCTUnwrap(s.store.studyTopicState(scope: s.scope))
            try s.require(first.phase == .firstPass, "history first-pass phase was not saved")
            try await s.turn("我的口述：甲提出方案，乙复核方案。但我还说不清两者怎么配合。进度请记成学过一遍，不能记成能口述完整提纲。请保存‘配合关系说不清’这个薄弱点，下次先问我两者如何配合。", label: "h02-oral-and-weak-point")
            let saved = try XCTUnwrap(s.store.studyTopicState(scope: s.scope))
            let memories = try s.store.records(projectID: s.project.id)
            try s.require(saved.phase == .firstPass && saved.level == .studiedOnce, "history progress was overstated or missing")
            try s.require((saved.note + memories.map(\.text).joined()).contains("配合"), "weak point was not saved")
            try s.require(!saved.pendingPrompt.isEmpty && saved.pendingPrompt.contains("配合"), "next oral question was not preserved")
            try await s.turn("现在暂停这个专题，保留薄弱点和下次待回答的问题，我之后换个窗口继续。", label: "h03-pause")
            let input = try s.store.reviewInput(projectID: s.project.id)
            let current = try XCTUnwrap(input.topicSessions.first(where: { $0.threadID == s.thread.id }))
            try s.require(current.paused && current.pendingPrompt.contains("配合"), "history pause lost the pending question")
            try s.saveExitState(sessionID: current.id)
            try s.finish(success: true)
        } catch {
            try s.finish(success: false, error: error)
            XCTFail("Live lessons part 1 failed. See the redacted evidence artifact.")
        }
    }
    @MainActor func testLessonsPart2ResumePoliticsCorrectAndStaleReport() async throws {
        let (key, root) = try Self.configuration()
        let s = try LiveStudySession(key: key, root: root, phase: "lessons-part2", restoring: true, subject: .history)
        do {
            let exit = try XCTUnwrap(s.exitState)
            try s.require(exit.processID != ProcessInfo.processInfo.processIdentifier, "lessons restart must be a new Swift process")
            let historyID = s.project.id
            s.openNewWindow()
            try await s.turn("我换窗口了，继续上次合成历史专题，从保存的薄弱点接着问，先不要替我口述答案。", label: "h04-new-window-resume")
            let historyInput = try s.store.reviewInput(projectID: historyID)
            let resumed = try XCTUnwrap(historyInput.topicSessions.first(where: { $0.threadID == s.thread.id }))
            try s.require(resumed.id == exit.sessionID && !resumed.paused && resumed.pendingPrompt.contains("配合"), "new window did not resume the saved history task")

            s.openProject(.politics)
            try await s.turn("记录一道我在纸上做的合成政治单选题，归到马原。题目：按本题合成材料，甲和乙有什么关系？A共同完成任务，B互不相关。我实际选了A，手头暂记的标准答案是B，这题先记为答错；薄弱点是甲乙关系易混。这不是考试真题，不要补出真实理论。", label: "p01-paper-question-wrong")
            let first = try s.store.studyPractices(projectID: s.project.id)
            try s.require(first.count == 1 && first[0].answer.contains("A") && first[0].outcome == .wrong && first[0].countsForAccuracy, "paper answer was not recorded as user-reported wrong")
            let recordID = first[0].id
            try await s.turn("请只按这条实际记录生成一次本项目本周周报。", label: "p02-generate-weekly")
            let generated = try s.store.weeklyReport(scope: s.scope, weeksAgo: 0, generate: false)
            let reportID = try XCTUnwrap(generated.report?.id)
            try s.require(generated.status == "current" && generated.report?.revision == 1, "weekly report was not actually generated")
            try await s.turn("更正刚才那道原记录：我重新核对了纸质答案，这道合成题标准答案其实是A，所以我答对了。只更正原题，不要新增题目，先不要重新生成周报。", label: "p03-correct-original")
            let corrected = try s.store.studyPractices(projectID: s.project.id)
            try s.require(corrected.count == 1 && corrected[0].id == recordID && corrected[0].revision == 2 && corrected[0].outcome == .correct, "correction did not update the original practice exactly once")
            try await s.turn("现在只检查刚才那份周报是不是需要更新，不要重新生成它。", label: "p04-check-stale-report")
            let stale = try s.store.weeklyReport(scope: s.scope, weeksAgo: 0, generate: false)
            try s.require(stale.status == "stale" && stale.report?.id == reportID && stale.report?.revision == 1, "old weekly report was not retained as stale")
            try s.require(s.lastCalls().contains { $0.name == "study_weekly_report" && (try? $0.argumentObject()["mode"] as? String) == "read" }, "model did not read the actual report status")
            try s.require(s.store.export(projectIDs: [s.project.id]).rows.filter { $0.kind == "weekly_report" }.count == 1, "the test generated extra report versions")
            try s.require(s.store.studyTopics(projectID: s.project.id).isEmpty && !s.store.studyTopics(projectID: historyID).isEmpty, "history and politics data were mixed")
            try s.finish(success: true)
        } catch {
            try s.finish(success: false, error: error)
            XCTFail("Live lessons part 2 failed. See the redacted evidence artifact.")
        }
    }
    private static func configuration() throws -> (String, URL) {
        let env = ProcessInfo.processInfo.environment
        guard env["SERMO_RUN_LIVE"] == "1" else { throw XCTSkip("Live model tests run only from the manual opt-in workflow.") }
        guard let key = env["SERMO_STUDY_LIVE_DEEPSEEK_KEY"], !key.isEmpty,
              let root = env["SERMO_LIVE_EVIDENCE_DIR"], root.hasPrefix("/") else {
            throw LiveStudyFailure.failed("Missing required live-test Secret or output directory.")
        }
        return (key, URL(fileURLWithPath: root, isDirectory: true))
    }
}

private enum LiveStudyFailure: Error { case failed(String) }

@MainActor private final class LiveStudySession {
    struct ExitState: Codable {
        let snapshot: AppSnapshot
        let memoryID: UUID?
        let sessionID: UUID
        let waitingWordID: String?
        let processID: Int32
        let requests: Int
        let tokens: Int
    }
    struct DatabaseState: Encodable {
        let memories: [StudyMemoryRecord]
        let memoryEvents: [StudyMemoryEvent]
        let progress: [StudyWordProgress]
        let currentWindow: StudyWordState
        let readingSessions: [StudyReadingSession]
        let readingAnswers: [StudyReadingAnswer]
        let readingEvents: [StudyReadingEvent]
        let lessons: StudyReviewInput
        let weekly: StudyWeeklyResult
        let archive: StudyMemoryArchive
    }
    struct Round: Encodable {
        let request: JSONValue
        let modelText: String
        let visibleText: String
        let calls: [ToolCall]
        let receipts: [String]
        let usage: TokenUsage?
    }
    struct Turn: Encodable {
        let label: String
        let userMessage: ChatMessage
        let threadID: UUID
        let before: DatabaseState
        var rounds: [Round] = []
        var after: DatabaseState?
        var error: String?
    }
    struct Report: Encodable {
        let phase: String
        let processID: Int32
        let model = "deepseek-flash"
        let data = "Synthetic vocabulary, synthetic reading and synthetic user messages only"
        let implementation = "Shared Swift StudyToolExecutor, StudyMemoryStore, DeepSeekClient and client request settings"
        var status = "running"
        var requests = 0
        var tokens = 0
        var turns: [Turn] = []
        var error: String?
    }
    final class Buffer {
        var content = ""
        var visible = ""
        var collector = ToolCallCollector()
        var usage: TokenUsage?
        var guarder = StudyOutputGuard()
        func consume(_ event: StreamEvent) {
            content += event.content
            visible += guarder.consume(event.content, finish: event.isDone || event.finishReason != nil)
            collector.consume(event.toolCalls)
            if let usage = event.usage { self.usage = usage }
        }
    }
    let store: StudyMemoryStore
    var project: ChatProject
    let root: URL
    let phase: String
    let key: String
    let databaseURL: URL
    var settings: AppSettings
    var threads: [ChatThread]
    var activeIndex = 0
    var report: Report
    var exitState: ExitState?
    var outputGuard = StudyOutputGuard()
    var thread: ChatThread { threads[activeIndex] }
    var scope: StudyScope { StudyScope(projectID: project.id, threadID: thread.id, subject: project.studySubject ?? .english) }
    static let readingParagraph = "In a school garden, students collect rainwater in a covered tank. They water the plants in the evening, when less water is lost to heat. The garden stays resilient during dry weeks."
    static let readingQuestion = "Why do the students water plants in the evening?"

    init(key: String, root: URL, phase: String, restoring: Bool, reading: Bool = false, subject: StudySubject = .english) throws {
        self.key = key; self.root = root; self.phase = phase
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = root.appendingPathComponent("synthetic-learning.sqlite")
        store = try StudyMemoryStore(url: databaseURL)
        report = Report(phase: phase, processID: ProcessInfo.processInfo.processIdentifier)
        if restoring {
            let saved = try StudyCoding.decode(ExitState.self, from: Data(contentsOf: root.appendingPathComponent("exit-state.json")))
            exitState = saved; settings = saved.snapshot.settings; threads = saved.snapshot.threads
            project = try XCTUnwrap(saved.snapshot.projects?.first)
            activeIndex = threads.firstIndex { $0.id == saved.snapshot.activeThreadID } ?? 0
            report.requests = saved.requests; report.tokens = saved.tokens
        } else {
            var config = AppSettings(); config.model = .flash; config.thinkingEnabled = false; config.maxOutputTokens = 1024
            settings = config
            var p = ChatProject(name: "合成" + subject.title + "验收"); p.id = subject.projectID; p.studySubject = subject
            p.provider = .deepSeek; p.autoMemory = true; project = p
            var t = ChatThread(); t.projectID = p.id; t.modelSelection = ChatModelSelection(settings: config, project: p); threads = [t]
            let fixture = #"{"schema_version":"yanxi.private-import.v2-stage1","cards":[{"id":"synthetic-adapt","word":"adapt","translation_zh":"适应，改编（合成验收词条）","unit_order":[{"collection":"required","unit":1,"position":1}]},{"id":"synthetic-adopt","word":"adopt","translation_zh":"采纳，收养（合成验收词条）","unit_order":[{"collection":"required","unit":1,"position":2}]}]}"#
            if subject == .english { try store.importWords(StudyWordPack.decode(Data(fixture.utf8)), projectID: p.id) }
            if reading {
                let passage = StudyReadingPassage(id: "synthetic-2026-text-4", title: "2026年合成英语阅读 Text4", year: 2026, textNumber: 4,
                    paragraphs: [Self.readingParagraph, "The students also keep a notebook to compare how much water each plant needs."],
                    questions: [.init(id: "synthetic-q36", number: 36, stem: Self.readingQuestion,
                        options: ["To reduce water lost to heat.", "To keep the tank empty.", "To stop plants growing.", "To avoid collecting rainwater."],
                        answer: 0, explanation: "Synthetic reference: evening watering reduces heat-related water loss.", verification: "verified", source: "Synthetic test reference", sourceURL: nil)],
                    source: "Synthetic test material, not an exam paper", sourceURL: nil, topic: "合成校园花园节水")
                try store.importReadings(.init(schema: "sermo.readings.v1", passages: [passage]), projectID: p.id)
            }
        }
    }
    func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw LiveStudyFailure.failed(message) }
    }
    func wordState() throws -> StudyWordState { try store.wordState(scope: scope) }
    func progressCount() throws -> Int { try store.wordProgress(projectID: project.id).reduce(0) { $0 + $1.reviewCount } }
    private func state() throws -> DatabaseState {
        try DatabaseState(memories: store.records(projectID: project.id), memoryEvents: store.events(projectID: project.id),
                          progress: store.wordProgress(projectID: project.id), currentWindow: wordState(),
                          readingSessions: store.readingSessions(projectID: project.id), readingAnswers: store.readingAnswers(projectID: project.id),
                          readingEvents: store.readingEvents(projectID: project.id), lessons: store.reviewInput(projectID: project.id),
                          weekly: store.weeklyReport(scope: scope, weeksAgo: 0, generate: false), archive: store.export(projectIDs: [project.id]))
    }
    private func write<T: Encodable>(_ value: T, name: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let safe = String(decoding: try encoder.encode(value), as: UTF8.self).replacingOccurrences(of: key, with: "[REDACTED]")
        try Data(safe.utf8).write(to: root.appendingPathComponent(name), options: .atomic)
    }
    private func copyDatabase(_ name: String) throws {
        let target = root.appendingPathComponent(name + ".sqlite")
        guard !FileManager.default.fileExists(atPath: target.path) else { throw LiveStudyFailure.failed("Evidence file already exists") }
        try FileManager.default.copyItem(at: databaseURL, to: target)
    }
    func turn(_ text: String, label: String) async throws {
        let message = ChatMessage(role: .user, content: text)
        threads[activeIndex].messages.append(message)
        let executor = StudyToolExecutor(store: store, scope: scope, documents: project.documents)
        let config = (thread.modelSelection ?? ChatModelSelection(settings: settings, project: project)).applying(to: settings)
        let englishNotes = scope.subject == .english ? [StudyWordTools.note, StudyReadingTools.note] : []
        let prompt = try ([project.systemPrompt, executor.context(query: text), StudyTools.note, StudyLessonTools.note] + englishNotes).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let englishTools = scope.subject == .english ? StudyWordTools.specs + StudyReadingTools.specs : []
        var request = ChatRequest(settings: config, messages: thread.messages, systemPrompt: prompt).withTools(StudyTools.specs + englishTools + StudyLessonTools.specs(for: scope.subject))
        outputGuard = StudyOutputGuard()
        report.turns.append(Turn(label: label, userMessage: message, threadID: thread.id, before: try state()))
        let index = report.turns.count - 1
        try copyDatabase(label + "-before")
        try write(report, name: phase + "-conversation.json")
        var answer = ""
        do {
            for round in 0..<ToolLoop.maxRounds {
                guard report.requests < 24, report.tokens < 150_000 else { throw LiveStudyFailure.failed("Live request budget reached") }
                if round == ToolLoop.maxRounds - 1 { request = request.answeringWithoutTools() }
                report.requests += 1
                let buffer = Buffer()
                buffer.guarder = outputGuard
                try await DeepSeekClient(requestTimeout: 45, resourceTimeout: 90).stream(request: request, key: key) { event in buffer.consume(event) }
                outputGuard = buffer.guarder
                if let usage = buffer.usage { report.tokens += usage.totalTokens }
                answer += buffer.visible
                let calls = buffer.collector.calls
                var receipts: [String] = []
                if !calls.isEmpty {
                    for call in calls {
                        do {
                            let result = try executor.perform(StudyToolAction(call), sourceMessage: message)
                            receipts.append(result)
                            outputGuard.observeTool(name: call.name, result: result, projectID: project.id)
                        }
                        catch { receipts.append("应用操作未完成：" + error.localizedDescription) }
                    }
                }
                let body = try StudyCoding.decode(JSONValue.self, from: JSONEncoder().encode(request))
                report.turns[index].rounds.append(Round(request: body, modelText: buffer.content, visibleText: buffer.visible, calls: calls, receipts: receipts, usage: buffer.usage))
                try write(report, name: phase + "-conversation.json")
                if calls.isEmpty { break }
                guard round < ToolLoop.maxRounds - 1 else { throw LiveStudyFailure.failed("Tool loop exhausted") }
                request = request.appending([.assistantCalls(calls, content: buffer.content, reasoning: "")])
                for (call, receipt) in zip(calls, receipts) { request = request.appending([.toolResult(receipt, callID: call.id)]) }
            }
            try require(!answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "No final answer")
            threads[activeIndex].messages.append(ChatMessage(role: .assistant, content: answer))
            report.turns[index].after = try state()
            try copyDatabase(label + "-after")
            try write(report, name: phase + "-conversation.json")
        } catch {
            report.turns[index].error = String(describing: error)
            report.turns[index].after = try? state()
            try write(report, name: phase + "-conversation.json")
            throw error
        }
    }
    func lastExcerpts() -> [StudyReadingExcerpt] {
        (report.turns.last?.rounds ?? []).flatMap(\.receipts).flatMap { receipt in
            (try? StudyCoding.decode(StudyReadingResult.self, from: Data(receipt.utf8)))?.excerpts ?? []
        }
    }
    func lastCalls() -> [ToolCall] { (report.turns.last?.rounds ?? []).flatMap(\.calls) }
    func saveExitState(memoryID: UUID? = nil, sessionID: UUID, waitingWordID: String? = nil) throws {
        let snapshot = AppSnapshot(settings: settings, threads: threads, activeThreadID: thread.id, projects: [project])
        // Use the client's snapshot round-trip, including its persisted date precision.
        let persisted = try AppSnapshot.decode(snapshot.encoded())
        let state = ExitState(snapshot: persisted, memoryID: memoryID, sessionID: sessionID, waitingWordID: waitingWordID,
                              processID: ProcessInfo.processInfo.processIdentifier, requests: report.requests, tokens: report.tokens)
        try write(state, name: "exit-state.json")
    }
    func openNewWindow() {
        var next = ChatThread(); next.projectID = project.id
        next.modelSelection = ChatModelSelection(settings: settings, project: project)
        threads.append(next); activeIndex = threads.count - 1
    }
    func openProject(_ subject: StudySubject) {
        var next = ChatProject(name: "合成" + subject.title + "验收")
        next.id = subject.projectID; next.studySubject = subject; next.provider = .deepSeek; next.autoMemory = true
        project = next; openNewWindow()
    }
    func finish(success: Bool, error: Error? = nil) throws {
        report.status = success ? "passed" : "failed"
        report.error = error.map { String(describing: $0) }
        try write(report, name: phase + "-conversation.json")
        try write(try state(), name: phase + "-final-database.json")
    }
}
