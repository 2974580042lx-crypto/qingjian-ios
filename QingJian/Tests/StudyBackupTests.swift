import XCTest
@testable import DeepSeekCore

private enum BackupTestFailure: Error { case injected }
private struct BackupFixture {
    let snapshot: AppSnapshot
    let store: StudyMemoryStore
    let images: URL
    let photoName = "synthetic-politics-question.jpg"
    let photo: Data
    let english: StudyScope
    let history: StudyScope
    let politics: StudyScope
    init(root: URL, large: Bool = false) throws {
        store = try StudyMemoryStore(url: root.appendingPathComponent("source.sqlite"))
        images = root.appendingPathComponent("source-images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        photo = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/study-backup-question.jpg"))
        try photo.write(to: images.appendingPathComponent(photoName))
        try Data("synthetic-private-token-not-a-picture".utf8).write(to: images.appendingPathComponent("credentials.txt"))
        var projects: [ChatProject] = [], installed: [StudySubject] = []
        try StudyProjects.seed(projects: &projects, installed: &installed)
        for i in projects.indices { projects[i].instructions = "SYNTHETIC fixed instructions: preserve verbatim." }
        var et = ChatThread(), ht = ChatThread(), pt = ChatThread()
        et.projectID = StudySubject.english.projectID; ht.projectID = StudySubject.history.projectID; pt.projectID = StudySubject.politics.projectID
        english = .init(projectID: et.projectID!, threadID: et.id, subject: .english)
        history = .init(projectID: ht.projectID!, threadID: ht.id, subject: .history)
        politics = .init(projectID: pt.projectID!, threadID: pt.id, subject: .politics)
        func action(_ name: String, _ args: [String: Any]) throws -> StudyToolAction {
            try StudyToolAction(ToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: JSONSerialization.data(withJSONObject: args), as: UTF8.self)))
        }
        let opening = ChatMessage(role: .user, content: "开始合成词练习")
        let answer = ChatMessage(role: .user, content: "adapt我没记住", createdAt: Date().addingTimeInterval(1))
        et.messages = [opening, answer]
        try store.importWords(StudyWordPack.decode(Data(#"{"schema_version":"yanxi.private-import.v2-stage1","cards":[{"id":"synthetic-adapt","word":"adapt","translation_zh":"适应","unit_order":[{"collection":"required","unit":1,"position":1}]}]}"#.utf8)), projectID: english.projectID)
        let words = try store.startWords(scope: english, unitID: "required-1", count: 1, mode: .start, sourceMessageID: opening.id)
        _ = try store.gradeWord(.init(sessionID: words.session.id, expectedRevision: 1, wordID: "synthetic-adapt", rating: "again",
            source: .from(message: answer, scope: english, kind: .userStatement, quote: answer.content)), scope: english, operationID: "fixture-grade")
        let passage = StudyReadingPassage(id: "synthetic-reading", title: "合成Text4", year: 2026, textNumber: 4,
            paragraphs: ["A synthetic example uses adapt."], questions: [.init(id: "synthetic-36", number: 36, stem: "Which word appears?",
            options: ["adapt", "adopt", "absent", "another"], answer: 0, explanation: "Synthetic only", verification: "verified", source: "synthetic", sourceURL: nil)], source: "synthetic", sourceURL: nil, topic: "合成")
        try store.importReadings(.init(schema: "sermo.readings.v1", passages: [passage]), projectID: english.projectID)
        _ = try store.performReading(action("study_open_reading", ["passage_id":passage.id,"mode":"start"]), scope: english, message: opening)
        _ = try store.performReading(action("study_show_reading", ["kind":"question","number":36,"expected_revision":1]), scope: english, message: opening)
        let readAnswer = ChatMessage(role: .user, content: "第36题选A", createdAt: Date().addingTimeInterval(2)); et.messages.append(readAnswer)
        _ = try store.performReading(action("study_answer_reading", ["choice":"A","expected_revision":2,"evidence_quote":readAnswer.content]), scope: english, message: readAnswer)
        _ = try store.performReading(action("study_pause_reading", ["expected_revision":3]), scope: english, message: .init(role: .user, content: "暂停"))
        let hm = ChatMessage(role: .user, content: "合成历史专题，第一次学习")
        ht.messages = [hm]
        let temporary = StudyTemporaryMap(schema: "sermo.temporary-history-map.v1", id: "synthetic-map", status: "网络整理、待核",
            sources: [.init(id:"one",title:"合成来源1",url:"https://example.com/one",year:"synthetic",note:"not actual research"), .init(id:"two",title:"合成来源2",url:"https://example.com/two",year:"synthetic",note:"not actual research")],
            entries: [.init(id:"netmap:synthetic",title:"合成历史专题",block:"中国古代史",status:"网络整理、待核",sourceIDs:["one","two"],differences:["合成差异，保留待核"],relatedChapterIDs:[],relatedTermIDs:[])], differences: [])
        try store.importTemporaryHistoryMap(temporary, scope: history)
        try store.importStudyHistory(.init(schema:"sermo.history.v1",kind:"reference",source:"合成AI词条",verification:"未核",entries:[.init(id:"synthetic-ref",title:"合成词条",block:"中国古代史",text:"仅用于测试")]), scope: history, userConfirmedOutline: false)
        _ = try store.performLesson(action("study_start_topic", ["title":"合成历史专题","outline_id":"netmap:synthetic","mode":"start","phase":"first_pass","evidence_quote":hm.content]), scope: history, message: hm)
        let hs = try XCTUnwrap(store.studyTopicState(scope: history))
        _ = try store.performLesson(action("study_update_topic", ["expected_revision":hs.expected_revision,"session_revision":hs.session_revision,
            "phase":"first_pass","level":"studied_once","note":"合成薄弱点","pending_prompt":"合成待答问题","source_kind":"model_inference","evidence_quote":hm.content]), scope: history, message: hm)
        var pm = ChatMessage(role: .user, content: "合成纸质题选A错了，标准B"); pm.images = [photoName]; pt.messages = [pm]
        let practice: [String: Any] = ["area":"马原","kind":"single_choice","question":"合成照片题","answer":"A","outcome":"wrong","weak_point":"合成易混点","source_kind":"user_statement","evidence_quote":pm.content]
        _ = try store.performLesson(action("study_record_practice", practice), scope: politics, message: pm)
        _ = try store.weeklyReport(scope: politics, weeksAgo: 0, generate: true)
        let p = try XCTUnwrap(store.studyPractices(projectID: politics.projectID).first)
        let correction = ChatMessage(role: .user, content: "标准A，我答对了"); pt.messages.append(correction)
        var corrected = practice; corrected["record_id"] = p.reference; corrected["expected_revision"] = 1; corrected["outcome"] = "correct"; corrected["evidence_quote"] = correction.content
        _ = try store.performLesson(action("study_correct_practice", corrected), scope: politics, message: correction)
        _ = try store.weeklyReport(scope: politics, weeksAgo: 0, generate: true)
        let pending = ChatMessage(role: .user, content: "这条合成生词记忆待重试"); et.messages.append(pending)
        let committed = ChatMessage(role: .user, content: "保存一条合成易混记忆"); et.messages.append(committed)
        _ = try store.apply(.init(action: .remember, category: "生词", text: "合成易混记忆", source: .from(message: committed, scope: english, kind: .userStatement, quote: committed.content)), scope: english, operationID: "fixture-memory")
        try store.enqueue(.init(action: .remember, category: "生词", text: "合成待重试", source: .from(message: pending, scope: english, kind: .userStatement, quote: pending.content)), scope: english, operationID: "fixture-pending")
        if large { et.messages.append(.init(role: .user, content: String(repeating: "SYNTHETIC TRANSFER ONLY. ", count: 90_000))) }
        snapshot = .init(settings: AppSettings(), threads: [et, ht, pt], activeThreadID: et.id, projects: projects, installedStudySubjects: installed)
    }
    func payload() throws -> StudyBackupPayload {
        try StudyBackupCodec.capture(snapshot: snapshot, learning: store.exportAllStudyData(), deviceID: "synthetic-device-a") { name in
            try Data(contentsOf: images.appendingPathComponent(name))
        }
    }
}

final class StudyBackupTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sermo-backup-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if root.lastPathComponent.hasPrefix("sermo-backup-tests-") { try FileManager.default.removeItem(at: root) }
    }
    func testAllStudyDataImagesAndReportVersionsSurviveRestoreAndContinue() throws {
        let fixture = try BackupFixture(root: root)
        let original = try fixture.payload(), data = try StudyBackupCodec.encode(original), decoded = try StudyBackupCodec.decode(data)
        XCTAssertEqual(decoded.images.count, 1); XCTAssertEqual(decoded.images[0].data, fixture.photo)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic-private-token"))
        let kinds = Set(decoded.learning.rows.map(\.kind))
        for kind in ["memory","event","word_pack","word_progress","word_session","reading_passage","reading_session","reading_answer","topic","topic_session","practice","practice_event","weekly_report","pending","history_pack","temporary_map"] { XCTAssertTrue(kinds.contains(kind), kind) }
        XCTAssertEqual(decoded.learning.rows.filter { $0.kind == "weekly_report" }.count, 2)
        let target = try StudyMemoryStore(url: root.appendingPathComponent("restored.sqlite"))
        var normal = ChatThread(); normal.messages = [.init(role: .user, content: "unrelated normal chat")]
        var settings = AppSettings(); settings.systemPrompt = "keep current global settings"
        let current = AppSnapshot(settings: settings, threads: [normal], activeThreadID: normal.id, projects: [])
        var installed: AppSnapshot?
        let images = root.appendingPathComponent("restored-images"), recovery = root.appendingPathComponent("recovery")
        let outcome = try StudyRestoreEngine.restore(decoded, current: current, store: target, imagesDirectory: images, recoveryDirectory: recovery) { installed = $0 }
        XCTAssertEqual(installed?.settings.systemPrompt, settings.systemPrompt)
        XCTAssertTrue(outcome.snapshot.threads.contains { $0.id == normal.id })
        XCTAssertTrue(outcome.snapshot.projects!.allSatisfy { $0.instructions == "SYNTHETIC fixed instructions: preserve verbatim." })
        let restoredHash = try StudyCoding.hash(StudyCoding.encode(target.exportAllStudyData()))
        let sourceHash = try StudyCoding.hash(StudyCoding.encode(decoded.learning))
        XCTAssertEqual(restoredHash, sourceHash)
        let restoredPhoto = try Data(contentsOf: images.appendingPathComponent(fixture.photoName))
        XCTAssertEqual(restoredPhoto, fixture.photo)
        let dimensions = try StudyBackupCodec.validateImage(restoredPhoto)
        XCTAssertEqual(dimensions.width, 640); XCTAssertEqual(dimensions.height, 360)
        let photoMessage = outcome.snapshot.threads.first { $0.projectID == fixture.politics.projectID }!.messages.first!
        XCTAssertEqual(photoMessage.images, [fixture.photoName])
        XCTAssertEqual(try target.reviewInput(projectID: fixture.politics.projectID).practiceEvents.first(where: { $0.before == nil })?.after.source.attachmentIDs, [fixture.photoName])
        let before = try XCTUnwrap(target.readingState(scope: fixture.english))
        let readingID = try XCTUnwrap(target.readingSessions(projectID: fixture.english.projectID).first?.id)
        let call = try StudyToolAction(ToolCall(id: "resume", name: "study_open_reading", arguments: #"{"passage_id":"synthetic-reading","mode":"continue"}"#))
        _ = try target.performReading(call, scope: fixture.english, message: .init(role: .user, content: "继续"))
        XCTAssertTrue(before.paused); XCTAssertEqual(try target.readingState(scope: fixture.english)?.paused, false)
        XCTAssertEqual(try target.readingSessions(projectID: fixture.english.projectID).first?.id, readingID)
        XCTAssertEqual(try target.readingAnswers(projectID: fixture.english.projectID).count, 1)
        XCTAssertEqual(try target.wordProgress(projectID: fixture.english.projectID).first?.reviewCount, 1)
        XCTAssertEqual(try target.studyPractices(projectID: fixture.politics.projectID).first?.outcome, .correct)
        XCTAssertEqual(try target.studyTopics(projectID: fixture.history.projectID).first?.outlineID, "netmap:synthetic")
        XCTAssertEqual(try target.temporaryHistoryMap(projectID: fixture.history.projectID)?.entries[0].status, "网络整理、待核")
        XCTAssertTrue(try target.voiceReview(scope: fixture.history, instructions: "", zone: TimeZone(identifier: "Asia/Shanghai")!).contains("合成待答问题"))
        if let path = ProcessInfo.processInfo.environment["SERMO_STEP6_EVIDENCE_DIR"] {
            let evidence = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            try data.write(to: evidence.appendingPathComponent("synthetic-study-backup.json"))
            try fixture.photo.write(to: evidence.appendingPathComponent("original-question.jpg"))
            try restoredPhoto.write(to: evidence.appendingPathComponent("restored-question.jpg"))
            try outcome.snapshot.encoded().write(to: evidence.appendingPathComponent("restored-chat-snapshot.json"))
            try StudyCoding.encode(target.exportAllStudyData()).write(to: evidence.appendingPathComponent("after-resume-learning.json"))
            try FileManager.default.copyItem(at: root.appendingPathComponent("restored.sqlite"), to: evidence.appendingPathComponent("restored-learning.sqlite"))
        }
    }
    func testHistoryReferencedPhotoIsIncludedAfterOriginalChatImageRemoved() throws {
        let f = try BackupFixture(root: root)
        var snapshot = f.snapshot
        for t in snapshot.threads.indices { for m in snapshot.threads[t].messages.indices { snapshot.threads[t].messages[m].images = nil } }
        let backup = try StudyBackupCodec.capture(snapshot: snapshot, learning: f.store.exportAllStudyData(), deviceID: "synthetic") { _ in f.photo }
        XCTAssertEqual(backup.images.map(\.name), [f.photoName])
    }
    func testMissingImageChecksumDamageAndUnsafeNameAreRejected() throws {
        let f = try BackupFixture(root: root)
        XCTAssertThrowsError(try StudyBackupCodec.capture(snapshot: f.snapshot, learning: f.store.exportAllStudyData(), deviceID: "synthetic") { _ in throw BackupTestFailure.injected })
        let bytes = try StudyBackupCodec.encode(f.payload())
        var raw = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]; raw["sha256"] = "wrong"
        XCTAssertThrowsError(try StudyBackupCodec.decode(JSONSerialization.data(withJSONObject: raw)))
        XCTAssertFalse(StudyBackupCodec.safeImageName("../private.jpg")); XCTAssertFalse(StudyBackupCodec.safeImageName("C:\\private.jpg"))
        XCTAssertThrowsError(try StudyBackupCodec.validateImage(Data("not a picture".utf8)))
    }
    func testRestoreFailureRollsBackDataChatAndAddedImages() throws {
        let f = try BackupFixture(root: root), backup = try f.payload()
        let target = try StudyMemoryStore(url: root.appendingPathComponent("target.sqlite"))
        let current = AppSnapshot(settings: AppSettings(), threads: [ChatThread()], activeThreadID: nil, projects: [])
        let images = root.appendingPathComponent("target-images"), recovery = root.appendingPathComponent("rollback")
        var saved: AppSnapshot?
        XCTAssertThrowsError(try StudyRestoreEngine.restore(backup, current: current, store: target, imagesDirectory: images, recoveryDirectory: recovery, saveSnapshot: { saved = $0 }, checkpoint: { point in if point == "database" { throw BackupTestFailure.injected } }))
        XCTAssertTrue(try target.exportAllStudyData().rows.isEmpty)
        XCTAssertEqual(saved?.threads.first?.id, current.threads.first?.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: images.appendingPathComponent(f.photoName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.appendingPathComponent("restore-active.json").path))
    }
    func testInterruptedRestoreJournalIsRecoveredOnNextLaunch() throws {
        let f = try BackupFixture(root: root), backup = try f.payload()
        let target = try StudyMemoryStore(url: root.appendingPathComponent("target.sqlite"))
        try target.replaceStudyData(backup.learning, projectIDs: Set(backup.projectIDs))
        let current = AppSnapshot(settings: AppSettings(), threads: [ChatThread()], activeThreadID: nil, projects: [])
        let images = root.appendingPathComponent("crash-images"), recovery = root.appendingPathComponent("crash-journal")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        try f.photo.write(to: images.appendingPathComponent(f.photoName))
        let journal = StudyRestoreEngine.Journal(before: current, learning: .init(version: 1, rows: []), projectIDs: backup.projectIDs, addedImages: [f.photoName], previousImages: [], missingPreviousImages: [], committed: false)
        try StudyCoding.encode(journal).write(to: recovery.appendingPathComponent("restore-active.json"))
        var saved: AppSnapshot?
        XCTAssertTrue(try StudyRestoreEngine.recover(store: target, imagesDirectory: images, recoveryDirectory: recovery, saveSnapshot: { saved = $0 }))
        XCTAssertTrue(try target.exportAllStudyData().rows.isEmpty); XCTAssertNotNil(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: images.appendingPathComponent(f.photoName).path))
    }
    func testForeignChatCollisionDoesNotOverwriteAnything() throws {
        let f = try BackupFixture(root: root), backup = try f.payload()
        var collision = f.snapshot.threads[0]; collision.projectID = nil
        let current = AppSnapshot(settings: AppSettings(), threads: [collision], activeThreadID: collision.id, projects: [])
        XCTAssertThrowsError(try StudyBackupCodec.merge(backup, into: current, currentLearning: .init(version: 1, rows: [])))
    }
    func testTemporaryMapProgressSurvivesReimportAndSeparateOutlineImport() throws {
        let f = try BackupFixture(root: root)
        let before = try XCTUnwrap(f.store.studyTopics(projectID: f.history.projectID).first)
        let map = try XCTUnwrap(f.store.temporaryHistoryMap(projectID: f.history.projectID))
        try f.store.importTemporaryHistoryMap(map, scope: f.history)
        let changed = StudyTemporaryMap(schema: map.schema, id: map.id, status: map.status, sources: map.sources, entries: map.entries, differences: ["changed content"])
        XCTAssertThrowsError(try f.store.importTemporaryHistoryMap(changed, scope: f.history))
        try f.store.importStudyHistory(.init(schema:"sermo.history.v1",kind:"outline",source:"合成用户核对的另一版本",verification:"用户核对",entries:[.init(id:"new-separate-id",title:"另一版本条目",block:"中国古代史",text:"")]), scope: f.history, userConfirmedOutline: true)
        let after = try XCTUnwrap(f.store.studyTopics(projectID: f.history.projectID).first)
        XCTAssertEqual(before.id, after.id); XCTAssertEqual(before.revision, after.revision); XCTAssertEqual(before.level, after.level)
        XCTAssertEqual(try f.store.temporaryHistoryMap(projectID: f.history.projectID), map)
        XCTAssertNil(try f.store.temporaryHistoryMap(projectID: f.politics.projectID))
    }
    func testCloudStatePersistsPendingAndDetectsOtherDeviceWithoutLosingNewLocalChanges() throws {
        var state = StudyCloudState(); state.changed()
        state.upload = .init(backupID: "synthetic", sessionURL: "https://www.googleapis.com/upload/drive/v3/files?upload_id=synthetic", offset: 1024)
        state.pendingFingerprint = "old"; state.pendingGeneration = state.generation
        let restarted = try StudyCoding.decode(StudyCloudState.self, from: StudyCoding.encode(state))
        XCTAssertEqual(restarted.upload?.offset, 1024)
        let other = StudyDriveFile(id: "other", name: "backup", appProperties: ["deviceID":"other-device"])
        XCTAssertTrue(state.conflicts(with: [other], deviceID: "this-device"))
        state.acknowledgedIDs = [other.id]; XCTAssertFalse(state.conflicts(with: [other], deviceID: "this-device"))
        let generation = state.generation; state.changed()
        state.verified(file: other, fingerprint: "old", generation: generation, files: [other])
        XCTAssertTrue(state.dirty)
    }
    func testImageQuotaProducesExplicitRestorableFallbackWithoutDeletingOriginal() throws {
        let f = try BackupFixture(root: root)
        let backup = try StudyBackupCodec.captureResilient(snapshot: f.snapshot, learning: f.store.exportAllStudyData(), deviceID: "synthetic", imageBudgetBytes: 0,
            imageSize: { _ in f.photo.count }, imageLoader: { _ in f.photo })
        XCTAssertFalse(backup.isComplete); XCTAssertEqual(backup.version, 2)
        XCTAssertEqual(backup.omittedImages?.count, 1); XCTAssertTrue(backup.images.isEmpty)
        let (data, actual) = try StudyBackupCodec.encodeResilient(backup)
        let decoded = try StudyBackupCodec.decode(data)
        XCTAssertFalse(decoded.isComplete); XCTAssertEqual(actual.learning.rows.count, try f.store.exportAllStudyData().rows.count)
        let target = try StudyMemoryStore(url: root.appendingPathComponent("fallback.sqlite"))
        let result = try StudyRestoreEngine.restore(decoded, current: .init(settings: AppSettings(), threads: [], activeThreadID: nil, projects: []), store: target,
            imagesDirectory: f.images, recoveryDirectory: root.appendingPathComponent("fallback-recovery"), saveSnapshot: { _ in })
        XCTAssertEqual(result.snapshot.threads.count, f.snapshot.threads.count)
        XCTAssertEqual(try Data(contentsOf: f.images.appendingPathComponent(f.photoName)), f.photo)
        XCTAssertEqual(try target.studyPractices(projectID: f.politics.projectID).first?.outcome, .correct)
        if let path = ProcessInfo.processInfo.environment["SERMO_STEP7_EVIDENCE_DIR"] {
            let out = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try data.write(to: out.appendingPathComponent("synthetic-quota-fallback.json"))
            try StudyCoding.encode(target.exportAllStudyData()).write(to: out.appendingPathComponent("fallback-restored-records.json"))
        }
    }
    func testBackupCompressionKeepsDimensionsAndOriginalFile() throws {
        let f = try BackupFixture(root: root)
        let copy = try StudyBackupCodec.compressedCopy(f.photo)
        XCTAssertLessThanOrEqual(copy.count, f.photo.count)
        let size = try StudyBackupCodec.validateImage(copy)
        XCTAssertEqual(size.width, 640); XCTAssertEqual(size.height, 360)
        let backup = try StudyBackupCodec.captureResilient(snapshot: f.snapshot, learning: f.store.exportAllStudyData(), deviceID: "synthetic", imageBudgetBytes: f.photo.count,
            imageSize: { _ in f.photo.count }, imageLoader: { _ in f.photo })
        XCTAssertTrue(backup.isComplete)
        let target = try StudyMemoryStore(url: root.appendingPathComponent("compressed.sqlite"))
        _ = try StudyRestoreEngine.restore(backup, current: .init(settings: AppSettings(), threads: [], activeThreadID: nil, projects: []), store: target,
            imagesDirectory: f.images, recoveryDirectory: root.appendingPathComponent("compressed-recovery"), saveSnapshot: { _ in })
        XCTAssertEqual(try Data(contentsOf: f.images.appendingPathComponent(f.photoName)), f.photo)
    }
    func testCapacityWarningAndCompleteBackupPointerRemainHonest() throws {
        let f = try BackupFixture(root: root)
        let capacity = try StudyBackupCodec.imageCapacity(snapshot: f.snapshot, learning: f.store.exportAllStudyData()) { _ in StudyBackupCodec.imageWarningBytes }
        XCTAssertTrue(capacity.warning); XCTAssertEqual(capacity.count, 1)
        var state = StudyCloudState(); state.lastFileURL = "https://example.com/old-complete"
        let partial = StudyDriveFile(id: "partial", name: "records fallback", webViewLink: "https://example.com/partial")
        state.verified(file: partial, fingerprint: "p", generation: 0, files: [partial], omittedImages: 1)
        XCTAssertEqual(state.lastOmittedImageCount, 1)
        XCTAssertEqual(state.lastCompleteFileURL, "https://example.com/old-complete")
        XCTAssertEqual(state.lastFileURL, "https://example.com/partial")
    }
    func testUnavailablePhotoDoesNotPreventRecordRecoveryAndCannotMasqueradeAsV1FullBackup() throws {
        let f = try BackupFixture(root: root)
        let backup = try StudyBackupCodec.captureResilient(snapshot: f.snapshot, learning: f.store.exportAllStudyData(), deviceID: "synthetic",
            imageSize: { _ in throw BackupTestFailure.injected }, imageLoader: { _ in throw BackupTestFailure.injected })
        XCTAssertFalse(backup.isComplete); XCTAssertEqual(backup.omittedImages?.first?.reason, "unavailable")
        let bytes = try StudyBackupCodec.encode(backup)
        XCTAssertFalse(try StudyBackupCodec.decode(bytes).isComplete)
        let fake = StudyBackupPayload(version: 1, backupID: backup.backupID, deviceID: backup.deviceID, createdAt: backup.createdAt,
            projectIDs: backup.projectIDs, snapshot: backup.snapshot, learning: backup.learning, images: [], omittedImages: backup.omittedImages)
        XCTAssertThrowsError(try StudyBackupCodec.encode(fake))
    }
    func testDownloadedDriveFixtureUsesSameRestoreCode() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/drive-roundtrip.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("Real Drive readback fixture is added after the live cloud round trip.") }
        let payload = try StudyBackupCodec.decode(Data(contentsOf: file))
        let target = try StudyMemoryStore(url: root.appendingPathComponent("downloaded.sqlite"))
        let outcome = try StudyRestoreEngine.restore(payload, current: .init(settings: AppSettings(), threads: [], activeThreadID: nil, projects: []), store: target,
            imagesDirectory: root.appendingPathComponent("downloaded-images"), recoveryDirectory: root.appendingPathComponent("downloaded-recovery"), saveSnapshot: { _ in })
        XCTAssertEqual(outcome.snapshot.threads.count, payload.snapshot.threads.count)
        for image in payload.images {
            let bytes = try Data(contentsOf: root.appendingPathComponent("downloaded-images").appendingPathComponent(image.name))
            XCTAssertEqual(StudyCoding.hash(bytes), image.sha256); _ = try StudyBackupCodec.validateImage(bytes)
        }
        XCTAssertEqual(try target.exportAllStudyData().rows.count, payload.learning.rows.count)
        let project = try XCTUnwrap(payload.snapshot.projects?.first { $0.studySubject == .english })
        let session = try XCTUnwrap(target.readingSessions(projectID: project.id).first)
        let scope = StudyScope(projectID: project.id, threadID: session.threadID, subject: .english)
        let beforeAnswers = try target.readingAnswers(projectID: project.id).count
        let call = try StudyToolAction(ToolCall(id: "from-drive", name: "study_open_reading", arguments: #"{"passage_id":"synthetic-reading","mode":"continue"}"#))
        _ = try target.performReading(call, scope: scope, message: .init(role: .user, content: "从云盘恢复后继续"))
        let resumed = try XCTUnwrap(target.readingSessions(projectID: project.id).first)
        XCTAssertEqual(resumed.id, session.id); XCTAssertEqual(resumed.paragraph, session.paragraph)
        XCTAssertEqual(resumed.question, session.question); XCTAssertFalse(resumed.paused)
        XCTAssertEqual(try target.readingAnswers(projectID: project.id).count, beforeAnswers)
        if let path = ProcessInfo.processInfo.environment["SERMO_STEP6_EVIDENCE_DIR"] {
            let output = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let result: [String: Any] = ["downloaded_sha256":StudyCoding.hash(try Data(contentsOf: file)), "restored_rows":payload.learning.rows.count,
                "images":payload.images.count, "same_task_id":true, "same_waiting_question":true, "extra_answers":0, "resumed":true]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("real-drive-restore-verification.json"))
            for image in payload.images { try Data(contentsOf: root.appendingPathComponent("downloaded-images").appendingPathComponent(image.name)).write(to: output.appendingPathComponent("drive-restored-" + image.name)) }
            try StudyCoding.encode(target.exportAllStudyData()).write(to: output.appendingPathComponent("real-drive-after-resume.json"))
        }
    }
    func testResumableUploadUsesServerOffsetAndVerifiesDownloadedBytes() async throws {
        let f = try BackupFixture(root: root, large: true), p = try f.payload(), data = try StudyBackupCodec.encode(p)
        let server = BackupMockServer(data: data, payload: p, failFirstChunk: true)
        let client = StudyDriveBackupClient { request in try await server.handle(request) }
        let saved = UploadTestState(.init(backupID: p.backupID.uuidString, sessionURL: nil, offset: 0))
        do { _ = try await client.upload(data, payload: p, session: await saved.value) { await saved.set($0) }; XCTFail("injected disconnect must fail") }
        catch { }
        let afterFailure = await saved.value
        XCTAssertNotNil(afterFailure.sessionURL)
        let file = try await client.upload(data, payload: p, session: await saved.value) { await saved.set($0) }
        let downloaded = try await client.download(file)
        XCTAssertEqual(downloaded, data)
        let stats = await server.stats()
        XCTAssertEqual(stats.0, data.count); XCTAssertEqual(stats.1, 1); XCTAssertEqual(stats.2.filter { $0 == 0 }.count, 1)
    }

    func testUnifiedBackupCompressesVerifiesAndAutoDetectsLegacyFormats() throws {
        let fixture = try BackupFixture(root: root)
        let book = Book(title: "测试小说（仅档案不含正文）", characterCount: 120_000, chapterTitles: ["第一章", "第二章"], segments: [0..<2], notes: [nil])
        let persona = PersonaCard(name: "测试主角", detail: "性格沉稳")
        let unified = try UnifiedBackupCodec.capture(
            snapshot: fixture.snapshot,
            learning: fixture.store.exportAllStudyData(),
            booksMetadata: [book],
            personas: [persona],
            preferences: ["qingjian.profile.name": "小龙"],
            imageSize: { name in try fixture.images.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 },
            imageLoader: { name in try Data(contentsOf: fixture.images.appendingPathComponent(name)) }
        )
        let encoded = try UnifiedBackupCodec.encode(unified)
        XCTAssertTrue(encoded.starts(with: Data(UnifiedBackupCodec.magicPrefix.utf8)))
        let decodedPkg = try UnifiedBackupCodec.decodeAny(encoded)
        guard case .unified(let roundTrip) = decodedPkg else {
            return XCTFail("Expected .unified package")
        }
        XCTAssertEqual(roundTrip.snapshot.threads.count, fixture.snapshot.threads.count)
        XCTAssertEqual(roundTrip.learning.rows.count, unified.learning.rows.count)
        XCTAssertEqual(roundTrip.booksMetadata.map(\.title), ["测试小说（仅档案不含正文）"])
        XCTAssertEqual(roundTrip.personas.map(\.name), ["测试主角"])
        XCTAssertEqual(roundTrip.images.count, 1)
        XCTAssertEqual(roundTrip.preferences?["qingjian.profile.name"], "小龙")

        // Tamper with compressed payload bytes and verify SHA-256 rejection
        var tampered = encoded
        tampered[tampered.count - 1] ^= 0xFF
        XCTAssertThrowsError(try UnifiedBackupCodec.decode(tampered))

        // Verify decodeAny also recognizes legacy StudyBackupEnvelope and legacy AppSnapshot JSON
        let legacyStudyData = try StudyBackupCodec.encode(fixture.payload())
        if case .legacyStudy(let studyPkg) = try UnifiedBackupCodec.decodeAny(legacyStudyData) {
            XCTAssertEqual(studyPkg.images.count, 1)
        } else {
            XCTFail("Expected .legacyStudy package")
        }

        let legacyChatData = try fixture.snapshot.encoded()
        if case .legacyChat(let chatPkg) = try UnifiedBackupCodec.decodeAny(legacyChatData) {
            XCTAssertEqual(chatPkg.threads.count, fixture.snapshot.threads.count)
        } else {
            XCTFail("Expected .legacyChat package")
        }
    }
}

private actor UploadTestState {
    var value: StudyUploadSession
    init(_ value: StudyUploadSession) { self.value = value }
    func set(_ value: StudyUploadSession) { self.value = value }
}
private actor BackupMockServer {
    let data: Data
    let payload: StudyBackupPayload
    var received = Data()
    var failFirstChunk: Bool
    var initCount = 0
    var starts: [Int] = []
    init(data: Data, payload: StudyBackupPayload, failFirstChunk: Bool) { self.data = data; self.payload = payload; self.failFirstChunk = failFirstChunk }
    func stats() -> (Int, Int, [Int]) { (received.count, initCount, starts) }
    func handle(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url!, method = request.httpMethod ?? "GET"
        let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
        func response(_ status: Int, _ body: Data = Data(), _ headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
            (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
        let file: [String: Any] = ["id":"synthetic-backup", "name":"synthetic.json", "mimeType":"application/json", "size":String(data.count),
            "createdTime":"2026-11-11T00:00:00Z", "ownedByMe":true, "shared":false, "parents":["synthetic-folder"], "sha256Checksum":StudyCoding.hash(data),
            "appProperties":["sermoStudyBackup":"1","backupID":payload.backupID.uuidString,"deviceID":payload.deviceID,"sha256":StudyCoding.hash(data)]]
        if url.path.hasPrefix("/upload/") {
            if method == "POST" { initCount += 1; return response(200, Data(), ["Location":"https://www.googleapis.com/upload/drive/v3/files?upload_id=synthetic"]) }
            let range = request.value(forHTTPHeaderField: "Content-Range") ?? ""
            if range.hasPrefix("bytes */") {
                if received.count == data.count { return response(200, try JSONSerialization.data(withJSONObject: file)) }
                return response(308, Data(), received.isEmpty ? [:] : ["Range":"bytes=0-\(received.count - 1)"])
            }
            guard let start = Int(range.dropFirst(6).split(separator: "-")[0]), start == received.count, let body = request.httpBody else { throw BackupTestFailure.injected }
            starts.append(start); received.append(body)
            if failFirstChunk { failFirstChunk = false; throw BackupTestFailure.injected }
            if received.count == data.count { return response(200, try JSONSerialization.data(withJSONObject: file)) }
            return response(308, Data(), ["Range":"bytes=0-\(received.count - 1)"])
        }
        if url.path.hasSuffix("/synthetic-backup") {
            if query["alt"] == "media" { return response(200, received) }
            return response(200, try JSONSerialization.data(withJSONObject: file))
        }
        if query["q"]?.contains("sermoStudyRoot") == true {
            return response(200, try JSONSerialization.data(withJSONObject: ["files":[["id":"synthetic-folder","name":"synthetic folder","mimeType":"application/vnd.google-apps.folder","ownedByMe":true,"shared":false]]]))
        }
        return response(200, try JSONSerialization.data(withJSONObject: ["files": received.count == data.count ? [file] : []]))
    }
}
