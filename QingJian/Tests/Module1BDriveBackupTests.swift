import XCTest
import Foundation
@testable import DeepSeekCore

final class Module1BDriveBackupTests: XCTestCase {

    // MARK: - 1. Google Drive 20TB Multi-Version Direct Backup & SHA-256 Verification

    func testDriveFullBackupCreatesFolderUploadsMultiVersionNeverDeletesOldAndVerifiesSHA256() async throws {
        let server = MockDriveFullBackupServer()
        let client = DriveFullBackupClient { req in
            try await server.handle(req)
        }

        // Day 1 backup
        var proj1 = ChatProject(name: "宋代土地流转")
        proj1.memory = "- 重点核查清明集卷四"
        var thread1 = ChatThread(title: "第一天讨论")
        thread1.projectID = proj1.id
        thread1.messages = [ChatMessage(role: .user, content: "先理一下大纲")]
        let snap1 = AppSnapshot(settings: AppSettings(), threads: [thread1], activeThreadID: thread1.id, projects: [proj1])

        let payload1 = try UnifiedBackupCodec.capture(
            snapshot: snap1,
            learning: StudyMemoryArchive(version: 1, rows: []),
            preferences: ["sermo.interface.style": "paper", "qingjian.haptics": "true"],
            operationManual: OperationManualBook.defaultBook(),
            localProfile: BackupUserProfile(name: "小龙", handle: "xiaolong", avatar: Data([0xFF, 0xD8, 0xFF])),
            deliverablesManifest: ["doc-v1.md": Data("# 初稿".utf8)],
            imageSize: { _ in -1 },
            imageLoader: { _ in throw CocoaError(.fileNoSuchFile) }
        )
        let data1 = try UnifiedBackupCodec.encode(payload1)
        let session1 = StudyUploadSession(backupID: payload1.backupID.uuidString, sessionURL: nil, offset: 0)
        let uploaded1 = try await client.upload(
            data1,
            payload: payload1,
            deviceID: "iphone-16-pro",
            session: session1,
            persist: { _ in }
        )
        XCTAssertTrue(uploaded1.name.hasPrefix("Sermo完整备份-"))
        XCTAssertTrue(uploaded1.name.hasSuffix(".sermobackup"))

        // Day 2 backup with more threads -> MUST keep Day 1 backup intact (never auto-delete!)
        var thread2 = ChatThread(title: "第二天新增考证")
        thread2.messages = [ChatMessage(role: .user, content: "补充南宋官田")]
        var snap2 = snap1
        snap2.threads.append(thread2)
        var payload2 = try UnifiedBackupCodec.capture(
            snapshot: snap2,
            learning: StudyMemoryArchive(version: 1, rows: []),
            preferences: ["sermo.interface.style": "paper"],
            localProfile: BackupUserProfile(name: "小龙", handle: "xiaolong", avatar: nil),
            imageSize: { _ in -1 },
            imageLoader: { _ in throw CocoaError(.fileNoSuchFile) }
        )
        payload2.createdAt = Date(timeIntervalSinceNow: 86_400)
        let data2 = try UnifiedBackupCodec.encode(payload2)
        let session2 = StudyUploadSession(backupID: payload2.backupID.uuidString, sessionURL: nil, offset: 0)
        _ = try await client.upload(
            data2,
            payload: payload2,
            deviceID: "iphone-16-pro",
            session: session2,
            persist: { _ in }
        )

        let listed = try await client.listBackups()
        XCTAssertEqual(listed.count, 2, "20TB Google Drive policy must preserve all historical backups by default")
        XCTAssertEqual(listed.first?.backupID, payload2.backupID.uuidString)
        XCTAssertEqual(listed.last?.backupID, payload1.backupID.uuidString)

        // Download & verify Day 1 backup (simulating reinstall / new iPhone restore)
        let (_, decoded1) = try await client.download(uploaded1)
        XCTAssertEqual(decoded1.snapshot.threads.count, 1)
        XCTAssertEqual(decoded1.snapshot.projects?.first?.name, "宋代土地流转")
        XCTAssertEqual(decoded1.localProfile?.name, "小龙")
        XCTAssertEqual(decoded1.deliverablesManifest?["doc-v1.md"], Data("# 初稿".utf8))
        XCTAssertTrue(decoded1.booksMetadata.isEmpty)

        // Tamper 1 byte in cloud storage -> SHA-256 verification must reject restore
        await server.corruptFile(id: uploaded1.id)
        do {
            _ = try await client.download(uploaded1)
            XCTFail("Expected tampered cloud backup to fail SHA-256 check")
        } catch {}

        // Mark folder shared -> must reject with privacy conflict
        await server.markAllFoldersShared()
        do {
            _ = try await client.listBackups()
            XCTFail("Expected shared folder to pause/reject automatic cloud access")
        } catch {}
    }

    // MARK: - 2. Daily Schedule Rules & Strict Credential Exclusion

    func testDailyScheduleLogicAndZeroCredentialLeakage() throws {
        var state = DriveFullBackupState()
        let cal = Calendar(identifier: .gregorian)
        let morning = Date(timeIntervalSince1970: 1_795_219_200) // fixed timestamp
        let sameDayAfternoon = morning.addingTimeInterval(3 * 3600)
        let nextDay = morning.addingTimeInterval(25 * 3600)

        // Empty fresh install before restore should NOT auto-upload an empty shell
        XCTAssertFalse(state.shouldRunAutomaticBackup(now: morning, hasRealData: false, calendar: cal))

        // First launch of the day with real data -> runs
        XCTAssertTrue(state.shouldRunAutomaticBackup(now: morning, hasRealData: true, calendar: cal))

        // After success today -> does NOT run again automatically today, runs tomorrow
        state.markSucceeded(fileID: "f1", fileName: "Sermo完整备份.sermobackup", fingerprint: "abc", now: morning)
        XCTAssertFalse(state.shouldRunAutomaticBackup(now: sameDayAfternoon, hasRealData: true, calendar: cal))
        XCTAssertTrue(state.shouldRunAutomaticBackup(now: nextDay, hasRealData: true, calendar: cal))

        // After failure -> waits retry cooldown (10 min) then retries on foreground
        state.markFailed("网络连接中断", now: sameDayAfternoon)
        XCTAssertFalse(state.shouldRunAutomaticBackup(now: sameDayAfternoon.addingTimeInterval(120), hasRealData: true, calendar: cal))
        XCTAssertTrue(state.shouldRunAutomaticBackup(now: sameDayAfternoon.addingTimeInterval(660), hasRealData: true, calendar: cal))

        // Verify encoded backup never embeds secret tokens
        let snap = AppSnapshot(settings: AppSettings(), threads: [ChatThread(title: "日常")], activeThreadID: nil)
        let payload = try UnifiedBackupCodec.capture(
            snapshot: snap,
            learning: StudyMemoryArchive(version: 1, rows: []),
            preferences: ["sermo.interface.style": "paper"],
            imageSize: { _ in -1 },
            imageLoader: { _ in throw CocoaError(.fileNoSuchFile) }
        )
        let json = String(decoding: try StudyCoding.encode(payload), as: UTF8.self)
        XCTAssertFalse(json.contains("accessToken"))
        XCTAssertFalse(json.contains("refreshToken"))
        XCTAssertFalse(json.contains("apiKey"))
    }

    // MARK: - 3. StudyMemoryStore Nested Transactions & Empty BLOBs (#37)

    func testStudyMemoryStoreSupportsNestedSavepointTransactionsAndZeroByteBlobs() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("StudyTxTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try StudyMemoryStore(url: tempDir.appendingPathComponent("learning.sqlite"))
        let projectID = UUID()

        try store.transaction {
            try store.write(["outer": "ok"], projectID: projectID, kind: "memory", id: "outer-1")
            // Nested transaction that succeeds
            try store.transaction {
                try store.write(["inner": "committed"], projectID: projectID, kind: "memory", id: "inner-1")
            }
            // Nested transaction that throws -> must only roll back inner savepoint, keeping outer-1 & inner-1!
            do {
                try store.transaction {
                    try store.write(["inner": "aborted"], projectID: projectID, kind: "memory", id: "inner-2")
                    throw StudyMemoryError.invalid("abort inner")
                }
            } catch {}
        }

        let outerVal = try store.read([String: String].self, projectID: projectID, kind: "memory", id: "outer-1")
        let innerCommitted = try store.read([String: String].self, projectID: projectID, kind: "memory", id: "inner-1")
        let innerAborted = try store.read([String: String].self, projectID: projectID, kind: "memory", id: "inner-2")
        XCTAssertEqual(outerVal?["outer"], "ok")
        XCTAssertEqual(innerCommitted?["inner"], "committed")
        XCTAssertNil(innerAborted)

        // Verify 0-byte BLOB in study_data does not throw StudyMemoryError.unavailable on export
        try store.replaceStudyData(
            StudyMemoryArchive(version: 1, rows: [
                .init(projectID: projectID, kind: "custom_empty", id: "e0", payload: Data())
            ]),
            projectIDs: [projectID],
            trustedRecovery: true
        )
        let exported = try store.exportAllStudyData()
        XCTAssertTrue(exported.rows.contains(where: { $0.id == "e0" && $0.payload.isEmpty }))
    }

    // MARK: - 4. Google Account Fallback (#38) & Recovery Dark-Storage Pruning (#34)

    func testGoogleBackupAccountFallbackAndRecoveryPruning() throws {
        let withEmail = GoogleCredentials(accessToken: "a", refreshToken: "rt-123", expiresAt: Date(), email: "  User@Example.com ", grantedDrive: true)
        XCTAssertEqual(withEmail.derivedBackupAccountID, "user@example.com")

        let withoutEmail = GoogleCredentials(accessToken: "a", refreshToken: "rt-no-email-token", expiresAt: Date(), email: nil, grantedDrive: true)
        let derived = withoutEmail.derivedBackupAccountID
        XCTAssertTrue(derived.hasPrefix("google-"))
        XCTAssertGreaterThan(derived.count, 12)
        XCTAssertEqual(derived, GoogleCredentials(accessToken: "b", refreshToken: "rt-no-email-token", expiresAt: Date(), email: "", grantedDrive: true).derivedBackupAccountID)

        // Verify StudyRestoreEngine.pruneRecoveryDirectory caps retained snapshots while preserving active journal
        let recDir = FileManager.default.temporaryDirectory.appendingPathComponent("RecPrune-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: recDir) }
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)

        let activeJournal = recDir.appendingPathComponent("restore-active.json")
        try Data("active".utf8).write(to: activeJournal)
        for i in 1...8 {
            let f = recDir.appendingPathComponent("before-restore-backup-\(i).json")
            try Data("snap-\(i)".utf8).write(to: f)
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: Double(i * 100))], ofItemAtPath: f.path)
        }
        StudyRestoreEngine.pruneRecoveryDirectory(recDir, keepPerPrefix: 4)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: recDir.path)
        XCTAssertTrue(remaining.contains("restore-active.json"))
        let backupsLeft = remaining.filter { $0.hasPrefix("before-restore-backup-") }
        XCTAssertEqual(backupsLeft.count, 4)
    }
}

// MARK: - Synthetic In-Memory Google Drive v3 Server

private actor MockDriveFullBackupServer {
    struct StoredItem {
        var meta: StudyDriveFile
        var data: Data
    }
    private var items: [String: StoredItem] = [:]
    private var sessions: [String: (meta: [String: Any], buffer: Data, expectedLength: Int)] = [:]
    private var counter = 0

    func corruptFile(id: String) {
        guard var item = items[id], !item.data.isEmpty else { return }
        item.data[item.data.count - 1] ^= 0xFF
        items[id] = item
    }

    func markAllFoldersShared() {
        for (k, var v) in items where v.meta.mimeType == "application/vnd.google-apps.folder" {
            v.meta.shared = true
            items[k] = v
        }
    }

    func handle(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        let method = request.httpMethod ?? "GET"
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        // 1. Resumable upload session creation (POST /upload/drive/v3/files?uploadType=resumable)
        if url.path == "/upload/drive/v3/files", method == "POST", queryItems["uploadType"] == "resumable" {
            let bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            let expectedLen = Int(request.value(forHTTPHeaderField: "X-Upload-Content-Length") ?? "0") ?? 0
            counter += 1
            let sid = "sess_\(counter)"
            sessions[sid] = (meta: bodyJSON, buffer: Data(), expectedLength: expectedLen)
            let sessionURL = "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=\(sid)"
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Location": sessionURL])!
            return (Data(), resp)
        }

        // 2. Resumable upload chunk PUT
        if url.path == "/upload/drive/v3/files", method == "PUT", let sid = queryItems["upload_id"], var session = sessions[sid] {
            let chunk = request.httpBody ?? Data()
            session.buffer.append(chunk)
            if session.buffer.count < session.expectedLength {
                sessions[sid] = session
                let range = "bytes=0-\(max(0, session.buffer.count - 1))"
                let resp = HTTPURLResponse(url: url, statusCode: 308, httpVersion: nil, headerFields: ["Range": range])!
                return (Data(), resp)
            }
            sessions.removeValue(forKey: sid)
            counter += 1
            let fid = "file_\(counter)"
            let sha = StudyCoding.hash(session.buffer)
            let file = StudyDriveFile(
                id: fid,
                name: session.meta["name"] as? String ?? "backup.sermobackup",
                mimeType: session.meta["mimeType"] as? String ?? "application/octet-stream",
                size: String(session.buffer.count),
                createdTime: String(format: "2026-11-21T06:00:%02dZ", counter),
                modifiedTime: String(format: "2026-11-21T06:00:%02dZ", counter),
                sha256Checksum: sha,
                md5Checksum: nil,
                webViewLink: "https://drive.google.com/file/d/\(fid)/view",
                parents: session.meta["parents"] as? [String],
                appProperties: session.meta["appProperties"] as? [String: String],
                ownedByMe: true,
                shared: false,
                driveId: nil
            )
            items[fid] = StoredItem(meta: file, data: session.buffer)
            let encoded = try JSONEncoder().encode(file)
            return (encoded, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        // 3. Create folder POST /drive/v3/files
        if url.path == "/drive/v3/files", method == "POST" {
            let bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            counter += 1
            let fid = "folder_\(counter)"
            let folder = StudyDriveFile(
                id: fid,
                name: bodyJSON["name"] as? String ?? "Sermo Backups",
                mimeType: bodyJSON["mimeType"] as? String ?? "application/vnd.google-apps.folder",
                size: nil,
                createdTime: "2026-11-21T06:00:00Z",
                modifiedTime: "2026-11-21T06:00:00Z",
                sha256Checksum: nil,
                md5Checksum: nil,
                webViewLink: nil,
                parents: bodyJSON["parents"] as? [String],
                appProperties: bodyJSON["appProperties"] as? [String: String],
                ownedByMe: true,
                shared: false,
                driveId: nil
            )
            items[fid] = StoredItem(meta: folder, data: Data())
            return (try JSONEncoder().encode(folder), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        // 4. List files GET /drive/v3/files?q=...
        if url.path == "/drive/v3/files", method == "GET" {
            let q = queryItems["q"] ?? ""
            let matched = items.values.map(\.meta).filter { meta in
                if q.contains("sermoFullBackupRoot") {
                    return meta.appProperties?["sermoFullBackupRoot"] == "1"
                }
                if q.contains("sermoFullBackup") {
                    return meta.appProperties?["sermoFullBackup"] == "1"
                }
                return false
            }.sorted { ($0.createdTime ?? "") > ($1.createdTime ?? "") }
            struct PageOut: Encodable { let files: [StudyDriveFile] }
            return (try JSONEncoder().encode(PageOut(files: matched)), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        // 5. File metadata or download GET /drive/v3/files/<id>
        if url.path.hasPrefix("/drive/v3/files/"), method == "GET" {
            let id = String(url.path.dropFirst("/drive/v3/files/".count))
            guard let stored = items[id] else {
                return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
            if queryItems["alt"] == "media" {
                return (stored.data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (try JSONEncoder().encode(stored.meta), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        return (Data(), HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!)
    }
}
