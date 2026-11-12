import XCTest
@testable import DeepSeekCore

final class OperationManualTests: XCTestCase {

    func testDefaultBookIsPersonaFriendlyAndComplete() {
        let book = OperationManualBook.defaultBook()
        XCTAssertEqual(book.chapters.count, 9)
        XCTAssertEqual(book.enabledCount, 9)
        XCTAssertFalse(book.hasUserChanges)

        let ids = Set(book.chapters.map(\.id))
        XCTAssertEqual(ids, [
            "study-resume",
            "study-english-words",
            "study-english-reading",
            "study-history-topic",
            "study-politics-practice",
            "study-memory-practice",
            "study-weekly-report",
            "tool-external",
            "app-backup-guide"
        ])

        let reading = try! XCTUnwrap(book.chapters.first { $0.id == "study-english-reading" })
        // Must allow free persona and natural conversational answering ("是不是应该选 A"), never robotic one-sentence policing.
        XCTAssertFalse(reading.content.contains("正文只用一句话邀请作答"))
        XCTAssertTrue(reading.content.contains("是不是应该选 A"))
        XCTAssertTrue(reading.content.contains("人设"))
    }

    func testNormalChatWithoutToolsInjectsZeroManualCharacters() {
        let book = OperationManualBook.defaultBook()
        let result = OperationManualTools.systemPromptNote(
            book: book,
            studySubject: nil,
            usesDrive: false,
            usesGitHub: false,
            usesWeb: false
        )
        XCTAssertNil(result)
    }

    func testScopeFilteringIsolatesSubjectsAndExternalTools() throws {
        let book = OperationManualBook.defaultBook()

        // 1. English project without external tools
        let engNote = try XCTUnwrap(OperationManualTools.systemPromptNote(
            book: book,
            studySubject: .english,
            usesDrive: false,
            usesGitHub: false,
            usesWeb: false
        ))
        XCTAssertTrue(engNote.includeTools)
        XCTAssertTrue(engNote.note.contains("[study-english-reading]"))
        XCTAssertTrue(engNote.note.contains("[study-english-words]"))
        XCTAssertTrue(engNote.note.contains("[study-resume]"))
        XCTAssertFalse(engNote.note.contains("[study-history-topic]"))
        XCTAssertFalse(engNote.note.contains("[study-politics-practice]"))
        XCTAssertFalse(engNote.note.contains("[tool-external]"))
        // Directory does NOT dump full chapter text upfront
        XCTAssertFalse(engNote.note.contains("<operation_manual"))

        // 2. History project
        let histNote = try XCTUnwrap(OperationManualTools.systemPromptNote(
            book: book,
            studySubject: .history,
            usesDrive: false,
            usesGitHub: false,
            usesWeb: false
        ))
        XCTAssertTrue(histNote.note.contains("[study-history-topic]"))
        XCTAssertFalse(histNote.note.contains("[study-english-reading]"))
        XCTAssertFalse(histNote.note.contains("[study-politics-practice]"))

        // 3. Coding / External-tool project (GitHub enabled, not a study project)
        let gitNote = try XCTUnwrap(OperationManualTools.systemPromptNote(
            book: book,
            studySubject: nil,
            usesDrive: false,
            usesGitHub: true,
            usesWeb: false
        ))
        XCTAssertTrue(gitNote.includeTools)
        XCTAssertTrue(gitNote.note.contains("[tool-external]"))
        XCTAssertTrue(gitNote.note.contains("[app-backup-guide]"))
        XCTAssertFalse(gitNote.note.contains("[study-resume]"))
    }

    func testManualSearchAndReadToolsExecuteCleanly() throws {
        let book = OperationManualBook.defaultBook()

        // Search in English scope
        let searchCall = ToolCall(id: "c1", name: "manual_search", arguments: #"{"query":"精读 阅读"}"#)
        let searchRes = try OperationManualTools.execute(
            searchCall,
            book: book,
            studySubject: .english,
            usesDrive: false,
            usesGitHub: false,
            usesWeb: false
        )
        XCTAssertEqual(searchRes.completedTitle, "已检索内置规范目录")
        XCTAssertTrue(searchRes.output.contains("[study-english-reading]"))
        XCTAssertFalse(searchRes.output.contains("[study-history-topic]"))

        // Read single chapter
        let readCall = ToolCall(id: "c2", name: "manual_read", arguments: #"{"chapter_ids":"study-english-reading"}"#)
        let readRes = try OperationManualTools.execute(
            readCall,
            book: book,
            studySubject: .english,
            usesDrive: false,
            usesGitHub: false,
            usesWeb: false
        )
        XCTAssertEqual(readRes.completedTitle, "已查阅规范：《英语：聊天式精读与做题》 v1")
        XCTAssertTrue(readRes.output.contains(#"<operation_manual id="study-english-reading""#))
        XCTAssertTrue(readRes.output.contains("study_answer_reading"))

        // Out-of-scope chapter cannot be read in English project
        let crossCall = ToolCall(id: "c3", name: "manual_read", arguments: #"{"chapter_ids":"study-history-topic"}"#)
        let crossRes = try OperationManualTools.execute(
            crossCall,
            book: book,
            studySubject: .english,
            usesDrive: false,
            usesGitHub: false,
            usesWeb: false
        )
        XCTAssertEqual(crossRes.completedTitle, "未找到对应规范章节")
        XCTAssertFalse(crossRes.output.contains("<operation_manual"))
    }

    func testStorePersistenceAndUpgradePreservesUserEditsAndCustomChapters() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualStoreTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("operation-manual.json")
        let store = OperationManualStore(url: fileURL)

        var book = store.load()
        XCTAssertEqual(book.chapters.count, 9)

        // 1. User modifies a built-in chapter
        var reading = try XCTUnwrap(book.chapters.first { $0.id == "study-english-reading" })
        reading.content += "\n补充：我的专属傲娇学长人设陪读备注。"
        try book.saveChapter(reading, creatingNew: false)

        // 2. User disables weekly report chapter
        XCTAssertTrue(book.setEnabled(false, chapterID: "study-weekly-report"))

        // 3. User adds a custom chapter
        let custom = OperationManualChapter(
            id: "my-custom-rule",
            title: "我的专属学习暗号",
            whenToRead: "用户发送暗号时查阅",
            content: "收到暗号先夸我一句再继续。",
            scope: .studyEnglish,
            isEnabled: true,
            version: 1,
            isCustom: true,
            isUserModified: true,
            updatedAt: Date()
        )
        try book.saveChapter(custom, creatingNew: true)
        try store.save(book)

        // Reload & simulate app upgrade merge
        let reloaded = store.load()
        XCTAssertEqual(reloaded.chapters.count, 10)
        let savedReading = try XCTUnwrap(reloaded.chapters.first { $0.id == "study-english-reading" })
        XCTAssertTrue(savedReading.isUserModified)
        XCTAssertEqual(savedReading.version, 2)
        XCTAssertTrue(savedReading.content.contains("专属傲娇学长"))

        let savedWeekly = try XCTUnwrap(reloaded.chapters.first { $0.id == "study-weekly-report" })
        XCTAssertFalse(savedWeekly.isEnabled)

        let savedCustom = try XCTUnwrap(reloaded.chapters.first { $0.id == "my-custom-rule" })
        XCTAssertTrue(savedCustom.isCustom)
        XCTAssertEqual(savedCustom.title, "我的专属学习暗号")
    }

    func testUnifiedBackupRoundTripsOperationManual() throws {
        var manual = OperationManualBook.defaultBook()
        var resume = try XCTUnwrap(manual.chapters.first { $0.id == "study-resume" })
        resume.content += "\n【用户个人补充条款】"
        try manual.saveChapter(resume, creatingNew: false)

        let custom = OperationManualChapter(
            id: "custom-backup-check",
            title: "随备份迁移的自建章节",
            whenToRead: "验证备份恢复时查阅",
            content: "自建章节完整保留。",
            scope: .custom,
            isEnabled: true,
            version: 1,
            isCustom: true,
            isUserModified: true,
            updatedAt: Date()
        )
        try manual.saveChapter(custom, creatingNew: true)

        let snap = AppSnapshot(
            settings: AppSettings(),
            threads: [ChatThread()],
            activeThreadID: nil,
            projects: [],
            usage: UsageLedger(),
            systemPromptPresets: [],
            installedStudySubjects: []
        )
        let payload = try UnifiedBackupCodec.capture(
            snapshot: snap,
            learning: StudyMemoryArchive(version: 1, rows: []),
            booksMetadata: [],
            personas: [],
            preferences: [:],
            operationManual: manual,
            imageSize: { _ in -1 },
            imageLoader: { _ in throw CocoaError(.fileNoSuchFile) }
        )
        let encoded = try UnifiedBackupCodec.encode(payload)
        let decodedPkg = try UnifiedBackupCodec.decodeAny(encoded)
        XCTAssertEqual(decodedPkg.manualChapterCount, 10)

        guard case .unified(let restoredPayload) = decodedPkg,
              let restoredManual = restoredPayload.operationManual else {
            return XCTFail("Expected unified backup payload with operationManual")
        }

        // Merge into a clean default book
        let merged = OperationManualBook.defaultBook().mergedFromBackup(restoredManual, mode: .merge)
        XCTAssertEqual(merged.chapters.count, 10)
        XCTAssertTrue(merged.chapters.first { $0.id == "study-resume" }?.content.contains("用户个人补充条款") == true)
        XCTAssertNotNil(merged.chapters.first { $0.id == "custom-backup-check" })
    }
}
