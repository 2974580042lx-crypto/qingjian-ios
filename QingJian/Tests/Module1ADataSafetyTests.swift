import XCTest
import CoreFoundation
import Foundation
@testable import DeepSeekCore

final class Module1ADataSafetyTests: XCTestCase {

    // MARK: - Synthetic ZIP Helper

    private func makeZip(_ files: [(String, Data)]) -> Data {
        var archive = Data()
        var centralDirectory = Data()

        func appendU16(_ d: inout Data, _ v: UInt16) {
            d.append(UInt8(v & 0xFF))
            d.append(UInt8((v >> 8) & 0xFF))
        }
        func appendU32(_ d: inout Data, _ v: UInt32) {
            d.append(UInt8(v & 0xFF))
            d.append(UInt8((v >> 8) & 0xFF))
            d.append(UInt8((v >> 16) & 0xFF))
            d.append(UInt8((v >> 24) & 0xFF))
        }

        for (name, body) in files {
            let nameData = Data(name.utf8)
            let localOffset = UInt32(archive.count)

            appendU32(&archive, 0x04034B50)
            appendU16(&archive, 20)
            appendU16(&archive, 0x0800)
            appendU16(&archive, 0)
            appendU16(&archive, 0)
            appendU16(&archive, 0)
            appendU32(&archive, 0)
            appendU32(&archive, UInt32(body.count))
            appendU32(&archive, UInt32(body.count))
            appendU16(&archive, UInt16(nameData.count))
            appendU16(&archive, 0)
            archive.append(nameData)
            archive.append(body)

            appendU32(&centralDirectory, 0x02014B50)
            appendU16(&centralDirectory, 20)
            appendU16(&centralDirectory, 20)
            appendU16(&centralDirectory, 0x0800)
            appendU16(&centralDirectory, 0)
            appendU16(&centralDirectory, 0)
            appendU16(&centralDirectory, 0)
            appendU32(&centralDirectory, 0)
            appendU32(&centralDirectory, UInt32(body.count))
            appendU32(&centralDirectory, UInt32(body.count))
            appendU16(&centralDirectory, UInt16(nameData.count))
            appendU16(&centralDirectory, 0)
            appendU16(&centralDirectory, 0)
            appendU16(&centralDirectory, 0)
            appendU16(&centralDirectory, 0)
            appendU32(&centralDirectory, 0)
            appendU32(&centralDirectory, localOffset)
            centralDirectory.append(nameData)
        }

        let cdOffset = UInt32(archive.count)
        let cdSize = UInt32(centralDirectory.count)
        archive.append(centralDirectory)

        appendU32(&archive, 0x06054B50)
        appendU16(&archive, 0)
        appendU16(&archive, 0)
        appendU16(&archive, UInt16(files.count))
        appendU16(&archive, UInt16(files.count))
        appendU32(&archive, cdSize)
        appendU32(&archive, cdOffset)
        appendU16(&archive, 0)
        return archive
    }

    // MARK: - 1. Lossless /compact Slice & Application (#1, #3, #4)

    func testCompactPlanNeverDropsEarlyMessagesOrDuplicatesKeptTail() throws {
        // Case A: 12 settled messages -> summarize exact first 8, keep tail 4 untouched
        var medium = ChatThread(title: "宋史讨论")
        medium.messages = (1...12).map { i in
            ChatMessage(role: i.isMultiple(of: 2) ? .assistant : .user, content: "M-\(i)-CONTENT")
        }
        let mediumPlan = try ProjectMemory.prepareCompaction(thread: medium, project: nil)
        XCTAssertEqual(mediumPlan.compactedCount, 8)
        let mediumTranscript = mediumPlan.request.messages.last?.content ?? ""
        for i in 1...8 {
            XCTAssertTrue(mediumTranscript.contains("M-\(i)-CONTENT"), "Expected M-\(i) in summary input")
        }
        for i in 9...12 {
            XCTAssertFalse(mediumTranscript.contains("M-\(i)-CONTENT"), "Kept tail M-\(i) must not be duplicated in summary input")
        }

        // Case B: 120 settled messages -> summarize first 60, keep messages 61...120 verbatim (0 dropped!)
        var longThread = ChatThread(title: "清明集长对话")
        longThread.messages = (1...120).map { i in
            ChatMessage(role: i.isMultiple(of: 2) ? .assistant : .user, content: "LONG-\(i)-END")
        }
        let longPlan = try ProjectMemory.prepareCompaction(thread: longThread, project: nil)
        XCTAssertEqual(longPlan.compactedCount, 60)
        let longTranscript = longPlan.request.messages.last?.content ?? ""
        XCTAssertTrue(longTranscript.contains("LONG-1-END"), "First message must never be silently dropped")
        XCTAssertTrue(longTranscript.contains("LONG-60-END"))
        XCTAssertFalse(longTranscript.contains("LONG-61-END"))
        XCTAssertFalse(longTranscript.contains("LONG-120-END"))

        let compacted = ProjectMemory.buildCompactedThread(
            from: longThread,
            summary: "【核心意图与偏好】测试摘要",
            compactedCount: longPlan.compactedCount
        )
        XCTAssertEqual(compacted.parentThreadID, longThread.id)
        XCTAssertEqual(compacted.title, "清明集长对话")
        XCTAssertFalse(compacted.title.contains(" · 修改"))
        // 1 summary header + 60 untouched messages (61...120) = 61 messages
        XCTAssertEqual(compacted.messages.count, 61)
        XCTAssertEqual(compacted.messages[1].content, "LONG-61-END")
        XCTAssertEqual(compacted.messages.last?.content, "LONG-120-END")
    }

    // MARK: - 2. Word (.docx) Footnotes, Endnotes & Track Changes (#25)

    func testDOCXExtractorPreservesAcademicFootnotesEndnotesAndStripsDeletedTrackChanges() throws {
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p>
              <w:r><w:t>宋代民间田宅典卖以投税印契之红契为凭</w:t></w:r>
              <w:r><w:footnoteReference w:id="1"/></w:r>
              <w:del><w:r><w:delText>这段是修订模式下已删除的废稿文字</w:delText></w:r></w:del>
              <w:r><w:t>，然白契涉讼亦须考究管业实情</w:t></w:r>
              <w:r><w:endnoteReference w:id="2"/></w:r>
              <w:r><w:t>。</w:t></w:r>
            </w:p>
          </w:body>
        </w:document>
        """
        let footnotesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:footnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>
          <w:footnote w:type="continuationSeparator" w:id="0"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>
          <w:footnote w:id="1">
            <w:p>
              <w:r><w:t>《名公书判清明集》卷四〈户婚门〉，中华书局本第 118 页。</w:t></w:r>
              <w:del><w:r><w:delText>旧误引页码</w:delText></w:r></w:del>
            </w:p>
          </w:footnote>
        </w:footnotes>
        """
        let endnotesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:endnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:endnote w:type="separator" w:id="0"><w:p/></w:endnote>
          <w:endnote w:id="2">
            <w:p><w:r><w:t>参见漆侠：《宋代经济史》（下册），第 742 页。</w:t></w:r></w:p>
          </w:endnote>
        </w:endnotes>
        """
        let docxData = makeZip([
            ("word/document.xml", Data(documentXML.utf8)),
            ("word/footnotes.xml", Data(footnotesXML.utf8)),
            ("word/endnotes.xml", Data(endnotesXML.utf8))
        ])

        let extracted = try OfficeAndDocumentExtractor.extractDOCX(docxData)
        XCTAssertFalse(extracted.contains("已删除的废稿文字"))
        XCTAssertFalse(extracted.contains("旧误引页码"))
        XCTAssertTrue(extracted.contains("红契为凭[注1]，然白契涉讼亦须考究管业实情[尾注2]。"))
        XCTAssertTrue(extracted.contains("## 脚注"))
        XCTAssertTrue(extracted.contains("[注1] 《名公书判清明集》卷四〈户婚门〉，中华书局本第 118 页。"))
        XCTAssertTrue(extracted.contains("## 尾注"))
        XCTAssertTrue(extracted.contains("[尾注2] 参见漆侠：《宋代经济史》（下册），第 742 页。"))

        // Verify streaming URL-based extraction produces identical result without full-archive Data load
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("thesis-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try docxData.write(to: tempURL)
        let streamed = try OfficeAndDocumentExtractor.extractDOCX(url: tempURL)
        XCTAssertEqual(streamed, extracted)
    }

    // MARK: - 3. UnifiedBackup Real Preferences, Bool Fidelity & Study Validation (#29)

    func testUnifiedBackupPreferencesRoundTripBoolsDoublesRealKeysAndStudyValidation() throws {
        let srcSuiteName = "sermo.test.prefs.src.\(UUID().uuidString)"
        let dstSuiteName = "sermo.test.prefs.dst.\(UUID().uuidString)"
        let srcDefaults = try XCTUnwrap(UserDefaults(suiteName: srcSuiteName))
        let dstDefaults = try XCTUnwrap(UserDefaults(suiteName: dstSuiteName))
        defer {
            srcDefaults.removePersistentDomain(forName: srcSuiteName)
            dstDefaults.removePersistentDomain(forName: dstSuiteName)
        }

        srcDefaults.set("paper", forKey: "sermo.interface.style")
        srcDefaults.set("light", forKey: "sermo.appearance.mode")
        srcDefaults.set("system", forKey: "qingjian.font.choice")
        srcDefaults.set(17.0, forKey: "qingjian.reading.size")
        srcDefaults.set(false, forKey: "qingjian.haptics")
        srcDefaults.set(true, forKey: "qingjian.speech.auto")
        srcDefaults.set("indigo", forKey: "sermo.personal.accent")
        srcDefaults.set("nativeChatGPT", forKey: "sermo.web.channel.chatGPT")
        srcDefaults.set("smart", forKey: "sermo.chat.layoutMode.default")

        let captured = UnifiedBackupCodec.collectPreferences(from: srcDefaults)
        XCTAssertEqual(captured["qingjian.haptics"], "false")
        XCTAssertEqual(captured["qingjian.speech.auto"], "true")
        XCTAssertEqual(captured["sermo.interface.style"], "paper")
        XCTAssertEqual(captured["sermo.appearance.mode"], "light")
        XCTAssertEqual(captured["qingjian.font.choice"], "system")
        XCTAssertEqual(captured["sermo.personal.accent"], "indigo")
        XCTAssertEqual(captured["sermo.web.channel.chatGPT"], "nativeChatGPT")

        UnifiedBackupCodec.applyPreferences(captured, to: dstDefaults)
        let rawHaptics = try XCTUnwrap(dstDefaults.object(forKey: "qingjian.haptics"))
        XCTAssertEqual(CFGetTypeID(rawHaptics as CFTypeRef), CFBooleanGetTypeID())
        XCTAssertEqual(dstDefaults.bool(forKey: "qingjian.haptics"), false)
        XCTAssertEqual(dstDefaults.bool(forKey: "qingjian.speech.auto"), true)
        XCTAssertEqual(dstDefaults.double(forKey: "qingjian.reading.size"), 17.0, accuracy: 0.001)
        XCTAssertEqual(dstDefaults.string(forKey: "sermo.interface.style"), "paper")

        // Corrupted learning row inside UnifiedBackupPayload must be rejected by validate()
        var studyProj = ChatProject(name: "考研历史")
        studyProj.studySubject = .history
        let snap = AppSnapshot(settings: AppSettings(), threads: [ChatThread()], activeThreadID: nil, projects: [studyProj])
        let badRow = StudyMemoryArchive.Row(projectID: studyProj.id, kind: "memory", id: "m1", payload: Data("not-json".utf8))
        let badPayload = UnifiedBackupPayload(
            snapshot: snap,
            learning: StudyMemoryArchive(version: 1, rows: [badRow]),
            images: []
        )
        XCTAssertThrowsError(try UnifiedBackupCodec.validate(badPayload))
    }

    // MARK: - 4. Symmetric Snapshot Limits, Non-Destructive Local Load & Manual/Zip Cap (#27)

    func testSnapshotSymmetricLimitsSoftLocalRecoveryAndManualZipGuards() throws {
        // 1. 6,000 threads round-trip through exported snapshot decode (previously capped at 5,000)
        let sixThousand = (0..<6000).map { i in ChatThread(title: "T\(i)") }
        let largeCountSnap = AppSnapshot(settings: AppSettings(), threads: sixThousand, activeThreadID: sixThousand.first?.id)
        let encodedLargeCount = try largeCountSnap.encoded(pretty: false, isLocalStore: false)
        let decodedLargeCount = try AppSnapshot.decode(encodedLargeCount)
        XCTAssertEqual(decodedLargeCount.threads.count, 6000)

        // 2. Local store soft recovery when a project accidentally exceeded 100,000 included characters
        var overProject = ChatProject(name: "论文资料超限恢复")
        overProject.documents = [
            ProjectDocument(name: "文献A", text: String(repeating: "甲", count: 60_000), isIncluded: true),
            ProjectDocument(name: "文献B", text: String(repeating: "乙", count: 60_000), isIncluded: true)
        ]
        let rawSnap = AppSnapshot(settings: AppSettings(), threads: [ChatThread(title: "宝贵旧对话")], activeThreadID: nil, projects: [overProject])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let rawBytes = try encoder.encode(rawSnap)
        let recovered = try AppSnapshot.decodeLocal(rawBytes)
        XCTAssertEqual(recovered.threads.first?.title, "宝贵旧对话")
        let recoveredDocs = try XCTUnwrap(recovered.projects?.first?.documents)
        XCTAssertEqual(recoveredDocs.count, 2, "Never delete user documents during soft recovery")
        XCTAssertEqual(recoveredDocs[0].text.count, 60_000)
        XCTAssertEqual(recoveredDocs[1].text.count, 60_000)
        XCTAssertLessThanOrEqual(recovered.projects?.first?.includedCharacters ?? 0, ChatProject.documentCharacterLimit)
        XCTAssertNoThrow(try recovered.validate(isLocalStore: true))

        // 3. AppManual.refreshed never pushes an existing project past documentCharacterLimit
        var manualProj = AppManual.newProject()
        manualProj.documents[0].text = "旧版简短说明"
        manualProj.documents.append(ProjectDocument(
            name: "用户附加长笔记",
            text: String(repeating: "笔", count: ChatProject.documentCharacterLimit - 100),
            isIncluded: true
        ))
        let refreshed = try XCTUnwrap(AppManual.refreshed(manualProj))
        XCTAssertNoThrow(try refreshed.validate())
        XCTAssertEqual(refreshed.documents.count, 2)

        // 4. ZipProjectExtractor strictly obeys maxCharacters even with long unexpanded trailer
        let manyFiles: [(String, Data)] = [
            ("README.md", Data(String(repeating: "R", count: 700).utf8))
        ] + (1...40).map { i in
            ("Sources/Module\(i)/VeryLongFileNameForBudgetCheck\(i).swift", Data(String(repeating: "x", count: 600).utf8))
        }
        let zipDoc = try ZipProjectExtractor.extract(data: makeZip(manyFiles), fileName: "Repo.zip", maxCharacters: 900)
        XCTAssertLessThanOrEqual(zipDoc.text.count, 900)
    }

    // MARK: - 5. OperationManualStore Never Overwrites Existing File on Error (#28)

    func testOperationManualStoreNeverOverwritesExistingFileOnDecodeError() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ManualNonDestructive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let url = tempDir.appendingPathComponent("operation-manual.json")
        let preciousRawBytes = Data("{\"corrupted_or_locked\": true".utf8)
        try preciousRawBytes.write(to: url)

        let store = OperationManualStore(url: url)
        let fallback = store.load()
        XCTAssertEqual(fallback.chapters.count, OperationManualBook.defaultBook().chapters.count)
        // Crucial: the file on disk must NOT be overwritten with factory defaults!
        XCTAssertEqual(try Data(contentsOf: url), preciousRawBytes)
    }

    // MARK: - 6. AppPersistence Shrink Guard, Pool Isolation, Timestamped Backups & Binary Bounds (#26, #31, #33)

    func testAppPersistenceShrinkGuardAllowShrinkAndSeparateBeforeShrinkPool() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PersistTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let persistence = try AppPersistence(baseDirectory: tempDir)
        var t1 = ChatThread(title: "对话1"); t1.messages = [ChatMessage(role: .user, content: "你好")]
        var t2 = ChatThread(title: "对话2"); t2.messages = [ChatMessage(role: .user, content: "世界")]
        let twoThreads = AppSnapshot(settings: AppSettings(), threads: [t1, t2], activeThreadID: t1.id)
        try persistence.save(twoThreads)

        // Accidental wipe of 2 non-empty threads -> 0 non-empty threads MUST be blocked when allowShrink == false!
        let wiped = AppSnapshot(settings: AppSettings(), threads: [ChatThread()], activeThreadID: nil)
        XCTAssertThrowsError(try persistence.save(wiped, allowShrink: false))

        // Verify before-shrink safety snapshot was created AND survives 6 manual-safety snapshots!
        for _ in 0..<6 {
            _ = try persistence.createSafetyCopy(prefix: "manual-safety", keep: 5)
        }
        let snapshots = persistence.safetySnapshots()
        XCTAssertTrue(snapshots.contains(where: { $0.name.hasPrefix("before-shrink-") }),
                      "before-shrink emergency snapshot must never be evicted by routine manual-safety copies")

        // Explicit user-confirmed delete (allowShrink: true) succeeds cleanly
        XCTAssertNoThrow(try persistence.save(wiped, allowShrink: true))
    }

    func testBackupFolderUsesTimestampedNamesWithoutOverwritingSameDay() {
        let morning = Date(timeIntervalSince1970: 1_795_100_000)
        let afternoon = Date(timeIntervalSince1970: 1_795_118_000)
        let name1 = BackupFolder.fileName(for: morning, ext: "sermobackup")
        let name2 = BackupFolder.fileName(for: afternoon, ext: "sermobackup")
        XCTAssertNotEqual(name1, name2, "Two backups on the same day must not overwrite each other")
        XCTAssertTrue(name2 > name1, "Lexicographical order must match chronological order")
    }

}
