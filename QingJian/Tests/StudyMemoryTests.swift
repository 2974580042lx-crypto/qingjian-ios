import XCTest
import SQLite3
@testable import DeepSeekCore

final class StudyMemoryTests: XCTestCase {
    private var directory: URL!
    private var url: URL!
    private var store: StudyMemoryStore!
    private var scope: StudyScope!
    private var message: ChatMessage!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("sermo-study-tests-" + UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent("learning.sqlite")
        store = try StudyMemoryStore(url: url)
        scope = StudyScope(projectID: StudySubject.english.projectID, threadID: UUID(), subject: .english)
        message = ChatMessage(role: .user, content: "我容易把 adapt 和 adopt 搞混，记下来。")
    }
    override func tearDownWithError() throws {
        store = nil
        guard directory.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL,
              directory.lastPathComponent.hasPrefix("sermo-study-tests-") else { return }
        try FileManager.default.removeItem(at: directory)
    }
    private func command(text: String = "容易混淆 adapt 与 adopt", record: StudyMemoryRecord? = nil) -> StudyMemoryCommand {
        let source = StudySource(kind: .userStatement, threadID: scope.threadID, messageID: message.id, text: message.content, quote: message.content)
        return StudyMemoryCommand(action: record == nil ? .remember : .correct, recordID: record?.id,
            expectedRevision: record?.revision, category: "生词", text: text, source: source)
    }

    func testSeedsAreEmptyAndDoNotOverwriteSameNamedUserProjects() throws {
        let own = ChatProject(name: "考研英语", instructions: "我的指令原文")
        var projects = [own], marks: [StudySubject] = []
        try StudyProjects.seed(projects: &projects, installed: &marks)
        XCTAssertEqual(projects.count, 4)
        XCTAssertEqual(projects[0], own)
        XCTAssertEqual(projects.filter { $0.studySubject != nil }.count, 3)
        for project in projects.dropFirst() {
            XCTAssertEqual(project.instructions, ""); XCTAssertNil(project.memory)
            XCTAssertTrue(project.documents.isEmpty)
            XCTAssertFalse(project.remembers, "Study projects use their separate ledger, not legacy whole-string memory replacement.")
        }
        XCTAssertEqual(projects[1].service, .deepSeek)
        XCTAssertEqual(projects[2].service, .chatGPT)
        XCTAssertEqual(projects[3].service, .chatGPT)
        projects[1].name = "英语伙伴"; projects[1].instructions = "用户的新指令"
        try StudyProjects.seed(projects: &projects, installed: &marks)
        XCTAssertEqual(projects.count, 4); XCTAssertEqual(projects[1].instructions, "用户的新指令")
        projects.removeAll { $0.studySubject == .politics }
        try StudyProjects.seed(projects: &projects, installed: &marks)
        XCTAssertFalse(projects.contains { $0.studySubject == .politics })
    }

    func testSaveCorrectReopenAndSourceHistory() throws {
        let first = try store.apply(command(), scope: scope, operationID: "first")
        message.content = "更正，我容易混淆 affect 和 effect。"
        let second = try store.apply(command(text: "容易混淆 affect 与 effect", record: first.event.after), scope: scope, operationID: "second")
        XCTAssertEqual(second.event.after.revision, 2)
        XCTAssertEqual(second.event.before, first.event.after)
        store = nil; store = try StudyMemoryStore(url: url)
        XCTAssertEqual(try store.records(projectID: scope.projectID), [second.event.after])
        XCTAssertEqual(try store.events(projectID: scope.projectID).count, 2)
        XCTAssertEqual(try store.records(projectID: scope.projectID)[0].source.text, message.content)
        XCTAssertTrue(try store.pending(projectID: scope.projectID).isEmpty)
    }

    func testRetriesHaveOneEventAndDifferentPayloadIsRejected() throws {
        let input = command()
        let first = try store.apply(input, scope: scope, operationID: "stable")
        XCTAssertEqual(try store.apply(input, scope: scope, operationID: "stable"), first)
        XCTAssertEqual(try store.events(projectID: scope.projectID).count, 1)
        XCTAssertThrowsError(try store.apply(command(text: "different"), scope: scope, operationID: "stable"))
        XCTAssertEqual(try store.records(projectID: scope.projectID)[0], first.event.after)
    }
    func testAddingSourceDateToAnOldOperationDoesNotCreateADuplicate() throws {
        var original = command()
        let first = try store.apply(original, scope: scope, operationID: "old-operation")
        original.source.messageDate = message.createdAt
        XCTAssertEqual(try store.apply(original, scope: scope, operationID: "old-operation"), first)
        XCTAssertEqual(try store.events(projectID: scope.projectID).count, 1)
    }

    func testOtherProjectsCannotReadOrCorrect() throws {
        let first = try store.apply(command(), scope: scope, operationID: "first")
        for subject in [StudySubject.history, .politics] {
            let other = StudyScope(projectID: subject.projectID, threadID: scope.threadID, subject: subject)
            var change = command(record: first.event.after); change.category = subject.categories[0]
            XCTAssertTrue(try store.records(projectID: other.projectID).isEmpty)
            XCTAssertThrowsError(try store.apply(change, scope: other, operationID: "cross-project"))
            XCTAssertFalse(try store.context(scope: other, query: "adapt").contains("容易混淆"))
        }
    }

    func testTwoConnectionsRejectStaleUpdates() throws {
        let first = try store.apply(command(), scope: scope, operationID: "first")
        let other = try StudyMemoryStore(url: url)
        let second = try other.apply(command(text: "新的记录", record: first.event.after), scope: scope, operationID: "other")
        XCTAssertThrowsError(try store.apply(command(text: "旧窗口的修改", record: first.event.after), scope: scope, operationID: "stale"))
        XCTAssertEqual(try store.records(projectID: scope.projectID), [second.event.after])
        XCTAssertEqual(try store.pending(projectID: scope.projectID).first?.id, "stale")
    }

    func testFailedTransactionLeavesPendingButNoMemoryOrSuccessEvent() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = "CREATE TRIGGER force_failure BEFORE INSERT ON study_data WHEN NEW.kind='event' BEGIN SELECT RAISE(ABORT,'test failure'); END"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let input = command()
        XCTAssertThrowsError(try store.apply(input, scope: scope, operationID: "retry"))
        XCTAssertTrue(try store.records(projectID: scope.projectID).isEmpty)
        XCTAssertTrue(try store.events(projectID: scope.projectID).isEmpty)
        XCTAssertEqual(try store.pending(projectID: scope.projectID).count, 1)
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER force_failure", nil, nil, nil), SQLITE_OK)
        let result = try store.apply(input, scope: scope, operationID: "retry")
        XCTAssertEqual(result.event.after.revision, 1)
        XCTAssertTrue(try store.pending(projectID: scope.projectID).isEmpty)
    }

    func testUndoKeepsHistory() throws {
        let first = try store.apply(command(), scope: scope, operationID: "first")
        let correction = try store.apply(command(text: "纠正内容", record: first.event.after), scope: scope, operationID: "correct")
        let undone = try store.undo(projectID: scope.projectID, eventID: correction.event.id, expectedRevision: 2)
        XCTAssertEqual(undone.event.after.text, first.event.after.text)
        XCTAssertEqual(undone.event.after.revision, 3)
        XCTAssertEqual(try store.events(projectID: scope.projectID).count, 3)
        XCTAssertThrowsError(try store.undo(projectID: scope.projectID, eventID: correction.event.id, expectedRevision: 2))
    }

    func testForgetAndUndoRestoreTheRecord() throws {
        let first = try store.apply(command(), scope: scope, operationID: "first")
        var deletion = command(record: first.event.after); deletion.action = .forget
        let result = try store.apply(deletion, scope: scope, operationID: "delete")
        XCTAssertTrue(try store.records(projectID: scope.projectID).isEmpty)
        XCTAssertEqual(try store.records(projectID: scope.projectID, includeDeleted: true).count, 1)
        _ = try store.undo(projectID: scope.projectID, eventID: result.event.id, expectedRevision: 2)
        XCTAssertEqual(try store.records(projectID: scope.projectID)[0].text, first.event.after.text)
    }

    func testSourceAndScopeValidation() throws {
        var invalid = command()
        invalid.source = StudySource(kind: .userStatement, threadID: scope.threadID, messageID: message.id, text: "原话", quote: "伪造引用")
        XCTAssertThrowsError(try store.apply(invalid, scope: scope, operationID: "bad-source"))
        let other = StudyScope(projectID: scope.projectID, threadID: UUID(), subject: .english)
        XCTAssertThrowsError(try store.apply(command(), scope: other, operationID: "bad-thread"))
        XCTAssertTrue(try store.events(projectID: scope.projectID).isEmpty)
    }

    func testRebindSessionsMovesActiveStudySessionsOnRetryOrVersionSwitch() throws {
        try store.importWords(StudyWordPack.decode(Data(#"{"schema_version":"yanxi.private-import.v2-stage1","cards":[{"id":"w1","word":"adapt","translation_zh":"适应","unit_order":[{"collection":"required","unit":1,"position":1}]}]}"#.utf8)), projectID: scope.projectID)
        _ = try store.startWords(scope: scope, unitID: "required-1", count: 1, mode: .start, sourceMessageID: message.id)
        XCTAssertNotNil(try store.wordState(scope: scope).session)

        let retryThreadID = UUID()
        let retryScope = StudyScope(projectID: scope.projectID, threadID: retryThreadID, subject: .english)
        try store.rebindSessions(from: [scope.threadID], to: retryThreadID, projectID: scope.projectID)
        XCTAssertNotNil(try store.wordState(scope: retryScope).session)
        XCTAssertEqual(try store.wordState(scope: retryScope).currentWord?.word, "adapt")
    }

    func testAppSideMemoryReadIsIdenticalAfterSavedModelSwitches() throws {
        _ = try store.apply(command(), scope: scope, operationID: "first")
        var project = ChatProject(name: "考研英语", instructions: "我的固定人格原文")
        project.id = scope.projectID; project.studySubject = .english
        var thread = ChatThread(); thread.id = scope.threadID; thread.projectID = project.id
        thread.messages = [message]
        let originalInstructions = project.instructions
        let baseline = try store.context(scope: scope, query: "adapt")
        for provider in AIProvider.allCases {
            var selection = ChatModelSelection(settings: AppSettings(), project: project)
            selection.provider = provider; thread.modelSelection = selection
            let snapshot = AppSnapshot(settings: AppSettings(), threads: [thread], activeThreadID: thread.id, projects: [project])
            let restored = try AppSnapshot.decode(snapshot.encoded())
            let restoredScope = StudyScope(projectID: try XCTUnwrap(restored.threads[0].projectID), threadID: restored.threads[0].id,
                subject: try XCTUnwrap(restored.projects?[0].studySubject))
            XCTAssertEqual(try store.context(scope: restoredScope, query: "adapt"), baseline)
            XCTAssertEqual(restored.projects?[0].instructions, originalInstructions)
            XCTAssertEqual(restored.threads[0].modelSelection?.provider, provider)
        }
    }

    func testProjectDefaultsOnlySelectNewConversationsAndLegacyMigrationUsesBackupSettings() throws {
        var backupSettings = AppSettings(); backupSettings.model = .pro
        var project = ChatProject(name: "历史"); project.provider = .chatGPT; project.subscriptionModel = "backup-model"
        var first = ChatThread(); first.projectID = project.id
        var threads = [first]
        ChatModelSelection.migrate(&threads, projects: [project], settings: backupSettings)
        XCTAssertEqual(threads[0].modelSelection?.subscriptionModel, "backup-model")
        XCTAssertEqual(threads[0].modelSelection?.model, .pro)
        project.provider = .deepSeek; project.model = .flash
        ChatModelSelection.migrate(&threads, projects: [project], settings: AppSettings())
        XCTAssertEqual(threads[0].modelSelection?.provider, .chatGPT)
        XCTAssertEqual(ChatModelSelection(settings: AppSettings(), project: project).provider, .deepSeek)
        threads[0].modelSelection?.provider = .colab
        XCTAssertEqual(project.provider, .deepSeek)
    }

    func testExportContainsHistoryAndPendingOperationsAndFiltersProjects() throws {
        _ = try store.apply(command(), scope: scope, operationID: "first")
        try store.enqueue(command(text: "待处理内容"), scope: scope, operationID: "pending")
        let archive = try store.export(projectIDs: [scope.projectID])
        let restored = try StudyCoding.decode(StudyMemoryArchive.self, from: StudyCoding.encode(archive))
        XCTAssertEqual(restored.version, 1)
        XCTAssertTrue(restored.rows.allSatisfy { $0.projectID == scope.projectID })
        XCTAssertEqual(Set(restored.rows.map(\.kind)), ["memory", "event", "operation", "pending"])
        XCTAssertTrue(try store.export(projectIDs: [StudySubject.history.projectID]).rows.isEmpty)
    }

    func testToolRejectsScopeOverrideDuplicateKeysAndInvalidRevision() throws {
        let text = "{\"category\":\"生词\",\"text\":\"学习记录\",\"source_kind\":\"user_statement\",\"evidence_quote\":\"原话\"}"
        XCTAssertNoThrow(try StudyToolAction(ToolCall(id: "test", name: "study_remember", arguments: text)))
        let bad = text.dropLast() + ",\"project_id\":\"other\"}"
        XCTAssertThrowsError(try StudyToolAction(ToolCall(id: "test", name: "study_remember", arguments: String(bad))))
        XCTAssertThrowsError(try StudyToolAction(ToolCall(id: "test", name: "study_list_memory", arguments: "{\"query\":\"a\",\"query\":\"b\"}")))
        let invalidRevision = String(text.dropLast()) + ",\"record_id\":\"\(UUID().uuidString)\",\"expected_revision\":true}"
        let action = try StudyToolAction(ToolCall(id: "test", name: "study_correct", arguments: invalidRevision))
        XCTAssertThrowsError(try action.command(scope: scope, message: message))
    }
}
