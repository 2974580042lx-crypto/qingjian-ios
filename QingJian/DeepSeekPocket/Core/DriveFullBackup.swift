import Foundation

struct BackupUserProfile: Codable, Equatable, Sendable {
    var name: String
    var handle: String
    var avatar: Data?
}

struct DriveFullBackupState: Codable, Equatable, Sendable {
    static let retryCooldownSeconds: TimeInterval = 600

    var enabled: Bool = true
    var lastSuccessAt: Date? = nil
    var lastAttemptAt: Date? = nil
    var lastFileID: String? = nil
    var lastFileName: String? = nil
    var lastFingerprint: String? = nil
    var lastError: String? = nil
    var pendingUpload: StudyUploadSession? = nil
    var pendingFingerprint: String? = nil

    func shouldRunAutomaticBackup(now: Date = Date(), hasRealData: Bool, calendar: Calendar = .current) -> Bool {
        guard enabled, hasRealData else { return false }
        if lastError != nil {
            if let attempt = lastAttemptAt, now.timeIntervalSince(attempt) < Self.retryCooldownSeconds {
                return false
            }
            return true
        }
        if let success = lastSuccessAt, calendar.isDate(success, inSameDayAs: now) {
            return false
        }
        return true
    }

    mutating func markSucceeded(fileID: String, fileName: String, fingerprint: String, now: Date = Date()) {
        lastSuccessAt = now
        lastAttemptAt = now
        lastFileID = fileID
        lastFileName = fileName
        lastFingerprint = fingerprint
        lastError = nil
        pendingUpload = nil
        pendingFingerprint = nil
    }

    mutating func markFailed(_ message: String, now: Date = Date()) {
        lastAttemptAt = now
        lastError = message
    }
}

/// Direct full-backup client for Google Drive (`/Sermo Backups/`).
/// Uses OAuth Bearer injection from the caller, never stores credentials in backups,
/// verifies SHA-256 end-to-end, and preserves all historical backups by default (20TB policy).
final class DriveFullBackupClient: @unchecked Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let folderName = "Sermo Backups"
    static let maximumArchiveBytes = UnifiedBackupCodec.maximumUncompressedBytes + 1024

    private let transport: Transport
    private static let filesEndpoint = "https://www.googleapis.com/drive/v3/files"
    private static let uploadsEndpoint = "https://www.googleapis.com/upload/drive/v3/files"
    private static let fields = "id,name,mimeType,size,createdTime,modifiedTime,sha256Checksum,md5Checksum,webViewLink,parents,appProperties,ownedByMe,shared,driveId"

    init(transport: @escaping Transport) {
        self.transport = transport
    }

    private static func makeURL(_ base: String = filesEndpoint, id: String? = nil, query: [String: String]) throws -> URL {
        if let id, !StudyDriveBackupClient.validID(id) {
            throw ChatError.invalidBackup("云盘备份文件标识不正确。")
        }
        guard var comps = URLComponents(string: base + (id.map { "/" + $0 } ?? "")) else {
            throw ChatError.invalidBackup("无法构造云盘请求地址。")
        }
        comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url, StudyDriveBackupClient.allowedURL(url) else {
            throw ChatError.invalidBackup("拒绝向非 Google Drive 官方地址发送请求。")
        }
        return url
    }

    private static func makeRequest(_ url: URL, method: String = "GET", json: [String: Any]? = nil) throws -> URLRequest {
        guard StudyDriveBackupClient.allowedURL(url) else {
            throw ChatError.invalidBackup("拒绝向非 Google Drive 官方地址发送请求。")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 120
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func sendSuccess(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }
                .flatMap { $0["message"] as? String }
            throw ChatError.server("Google 云盘备份请求失败（HTTP \(response.statusCode)）" + (detail.map { "：\($0)" } ?? "。"))
        }
        return data
    }

    private func queryFiles(_ query: String) async throws -> [StudyDriveFile] {
        struct Page: Decodable { let files: [StudyDriveFile]; let nextPageToken: String? }
        var all: [StudyDriveFile] = []
        var pageToken: String?
        var seenTokens = Set<String>()
        repeat {
            var q: [String: String] = [
                "q": query,
                "pageSize": "100",
                "fields": "nextPageToken,files(\(Self.fields))",
                "orderBy": "createdTime desc"
            ]
            if let pageToken {
                guard seenTokens.insert(pageToken).inserted else {
                    throw ChatError.invalidBackup("云盘分页游标异常重复。")
                }
                q["pageToken"] = pageToken
            }
            let data = try await sendSuccess(Self.makeRequest(Self.makeURL(query: q)))
            let page = try JSONDecoder().decode(Page.self, from: data)
            all.append(contentsOf: page.files)
            pageToken = page.nextPageToken
            guard all.count <= 20_000 else {
                throw ChatError.invalidBackup("云盘历史备份数量超过单次读取上限。")
            }
        } while pageToken != nil
        guard all.allSatisfy({ StudyDriveBackupClient.validID($0.id) }) else {
            throw ChatError.invalidBackup("云盘返回了无效的文件标识。")
        }
        return all
    }

    func folders(create: Bool) async throws -> [StudyDriveFile] {
        var found = try await queryFiles("'root' in parents and trashed = false and mimeType = 'application/vnd.google-apps.folder' and appProperties has { key='sermoFullBackupRoot' and value='1' }")
        guard found.allSatisfy(\.isPrivateOwned) else {
            throw ChatError.invalidBackup("「\(Self.folderName)」目录处于共享状态或不属于当前账号，为保护隐私已暂停自动备份，请先在 Google 云盘关闭该目录共享。")
        }
        if found.isEmpty && create {
            let body: [String: Any] = [
                "name": Self.folderName,
                "mimeType": "application/vnd.google-apps.folder",
                "parents": ["root"],
                "appProperties": ["sermoFullBackupRoot": "1"]
            ]
            let data = try await sendSuccess(Self.makeRequest(Self.makeURL(query: ["fields": Self.fields]), method: "POST", json: body))
            let created = try JSONDecoder().decode(StudyDriveFile.self, from: data)
            guard StudyDriveBackupClient.validID(created.id), created.isPrivateOwned else {
                throw ChatError.invalidBackup("未能确认新建的 Google 云盘备份目录为私有目录。")
            }
            found = [created]
        }
        return found.sorted { ($0.createdTime ?? "", $0.id) < ($1.createdTime ?? "", $1.id) }
    }

    func listBackups() async throws -> [StudyDriveFile] {
        var files: [StudyDriveFile] = []
        for folder in try await folders(create: false) {
            let batch = try await queryFiles("'\(folder.id)' in parents and trashed = false and appProperties has { key='sermoFullBackup' and value='1' }")
            files.append(contentsOf: batch)
        }
        guard files.allSatisfy(\.isPrivateOwned) else {
            throw ChatError.invalidBackup("检测到云盘中有备份文件被开启了共享，为保护隐私已停止自动读取，请先检查共享权限。")
        }
        return files.sorted { ($0.createdTime ?? "", $0.id) > ($1.createdTime ?? "", $1.id) }
    }

    func metadata(_ id: String) async throws -> StudyDriveFile {
        let data = try await sendSuccess(Self.makeRequest(Self.makeURL(id: id, query: ["fields": Self.fields])))
        return try JSONDecoder().decode(StudyDriveFile.self, from: data)
    }

    func download(_ file: StudyDriveFile) async throws -> (Data, UnifiedBackupPayload) {
        let meta = try await metadata(file.id)
        guard meta.isPrivateOwned,
              let size = meta.size.flatMap(Int.init),
              size > 0,
              size <= Self.maximumArchiveBytes else {
            throw ChatError.invalidBackup("云盘备份文件体积或私有权限状态异常，未执行恢复。")
        }
        let data = try await sendSuccess(Self.makeRequest(Self.makeURL(id: file.id, query: ["alt": "media"])))
        let actualSHA = StudyCoding.hash(data)
        guard data.count == size else {
            throw ChatError.invalidBackup("下载的备份字节数不完整，请检查网络后重试。")
        }
        if let remoteSHA = meta.sha256Checksum?.lowercased(), !remoteSHA.isEmpty {
            guard remoteSHA == actualSHA else {
                throw ChatError.invalidBackup("云盘文件 SHA-256 校验不一致，文件可能已损坏。")
            }
        }
        if let propSHA = meta.appProperties?["sha256"]?.lowercased(), !propSHA.isEmpty {
            guard propSHA == actualSHA else {
                throw ChatError.invalidBackup("云盘记录摘要与文件内容不一致，已拒绝恢复。")
            }
        }
        let payload = try UnifiedBackupCodec.decode(data)
        if let expectedID = meta.backupID, !expectedID.isEmpty {
            guard expectedID == payload.backupID.uuidString else {
                throw ChatError.invalidBackup("云盘备份标识与包内标识不一致，已拒绝恢复。")
            }
        }
        return (data, payload)
    }

    private static func nextOffset(_ response: HTTPURLResponse, total: Int) throws -> Int {
        guard let range = response.value(forHTTPHeaderField: "Range") else { return 0 }
        guard range.hasPrefix("bytes=0-"),
              let end = Int(range.dropFirst(8)),
              end >= 0,
              end < total else {
            throw ChatError.invalidBackup("云盘返回的断点续传偏移不正确。")
        }
        return end + 1
    }

    /// Uploads a new versioned `.sermobackup` archive to `/Sermo Backups/` without deleting any prior backup.
    func upload(
        _ data: Data,
        payload: UnifiedBackupPayload,
        deviceID: String,
        session initial: StudyUploadSession,
        persist: @escaping @Sendable (StudyUploadSession) async throws -> Void
    ) async throws -> StudyDriveFile {
        guard !data.isEmpty,
              data.count <= Self.maximumArchiveBytes,
              initial.backupID == payload.backupID.uuidString else {
            throw ChatError.invalidBackup("待上传备份包校验未通过。")
        }
        let dataSHA = StudyCoding.hash(data)
        let existing = try await listBackups()
        if let hit = existing.first(where: { $0.backupID == initial.backupID }) {
            guard hit.appProperties?["sha256"] == dataSHA else {
                throw ChatError.invalidBackup("云盘已存在同编号但内容不同的备份文件，未覆盖。")
            }
            return hit
        }

        var job = initial
        if let rawURL = job.sessionURL {
            guard let url = URL(string: rawURL),
                  StudyDriveBackupClient.allowedURL(url),
                  url.path.hasPrefix("/upload/drive/v3/files") else {
                throw ChatError.invalidBackup("云盘续传地址校验不安全，已中止。")
            }
            var probe = try Self.makeRequest(url, method: "PUT")
            probe.setValue("bytes */\(data.count)", forHTTPHeaderField: "Content-Range")
            probe.setValue("0", forHTTPHeaderField: "Content-Length")
            let (body, response) = try await transport(probe)
            if (200..<300).contains(response.statusCode) {
                return try verifyUploaded(JSONDecoder().decode(StudyDriveFile.self, from: body), expectedBytes: data.count, expectedSHA: dataSHA)
            }
            if response.statusCode == 308 {
                job.offset = try Self.nextOffset(response, total: data.count)
            } else if response.statusCode == 404 || response.statusCode == 410 {
                job.sessionURL = nil
                job.offset = 0
            } else {
                throw ChatError.server("查询云盘续传进度失败（HTTP \(response.statusCode)）。")
            }
            try await persist(job)
        }

        if job.sessionURL == nil {
            guard let folder = try await folders(create: true).first else {
                throw ChatError.invalidBackup("无法访问 Google 云盘备份目录。")
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let suffix = payload.isComplete ? "" : "-缺\(payload.omittedImages?.count ?? 0)图"
            let fileName = "Sermo完整备份-\(formatter.string(from: payload.createdAt))\(suffix)-\(payload.backupID.uuidString.prefix(6)).sermobackup"
            let metadataBody: [String: Any] = [
                "name": fileName,
                "mimeType": "application/octet-stream",
                "parents": [folder.id],
                "appProperties": [
                    "sermoFullBackup": "1",
                    "backupID": job.backupID,
                    "deviceID": String(deviceID.prefix(80)),
                    "sha256": dataSHA,
                    "threads": String(payload.snapshot.threads.count),
                    "projects": String((payload.snapshot.projects ?? []).count),
                    "complete": payload.isComplete ? "1" : "0"
                ]
            ]
            var initReq = try Self.makeRequest(
                Self.makeURL(Self.uploadsEndpoint, query: ["uploadType": "resumable", "fields": Self.fields]),
                method: "POST",
                json: metadataBody
            )
            initReq.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
            initReq.setValue(String(data.count), forHTTPHeaderField: "X-Upload-Content-Length")
            let (_, response) = try await transport(initReq)
            guard (200..<300).contains(response.statusCode),
                  let location = response.value(forHTTPHeaderField: "Location"),
                  let sessionURL = URL(string: location),
                  StudyDriveBackupClient.allowedURL(sessionURL),
                  sessionURL.path.hasPrefix("/upload/drive/v3/files") else {
                throw ChatError.server("未能建立安全的 Google 云盘上传会话。")
            }
            job.sessionURL = location
            job.offset = 0
            try await persist(job)
        }

        guard let uploadURL = job.sessionURL.flatMap(URL.init(string:)) else {
            throw ChatError.invalidBackup("缺少有效的上传会话地址。")
        }
        let chunkSize = 1024 * 1024
        var iterations = 0
        let maxIterations = data.count / chunkSize + 4
        while job.offset < data.count {
            try Task.checkCancellation()
            iterations += 1
            guard iterations <= maxIterations else {
                throw ChatError.server("云盘上传进度未正常推进，待传进度已保留，稍后自动重试。")
            }
            let end = min(job.offset + chunkSize, data.count)
            var putReq = try Self.makeRequest(uploadURL, method: "PUT")
            putReq.httpBody = data.subdata(in: job.offset..<end)
            putReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            putReq.setValue(String(end - job.offset), forHTTPHeaderField: "Content-Length")
            putReq.setValue("bytes \(job.offset)-\(end - 1)/\(data.count)", forHTTPHeaderField: "Content-Range")
            let (body, response) = try await transport(putReq)
            if (200..<300).contains(response.statusCode) {
                let uploaded = try JSONDecoder().decode(StudyDriveFile.self, from: body)
                return try verifyUploaded(uploaded, expectedBytes: data.count, expectedSHA: dataSHA)
            }
            guard response.statusCode == 308 else {
                throw ChatError.server("云盘上传暂未完成（HTTP \(response.statusCode)），下次联网后继续。")
            }
            let next = try Self.nextOffset(response, total: data.count)
            guard next > job.offset, next <= end else {
                throw ChatError.invalidBackup("云盘分块上传确认范围异常。")
            }
            job.offset = next
            try await persist(job)
        }
        throw ChatError.server("尚未收到云盘最终上传确认，待传任务已保留。")
    }

    /// Manual-only trash helper: moves a user-selected historical backup to Google Drive Trash (30-day recoverable).
    /// Never called automatically.
    func moveBackupToTrash(fileID: String) async throws {
        _ = try await sendSuccess(Self.makeRequest(
            Self.makeURL(id: fileID, query: ["fields": "id"]),
            method: "PATCH",
            json: ["trashed": true]
        ))
    }

    private func verifyUploaded(_ file: StudyDriveFile, expectedBytes: Int, expectedSHA: String) throws -> StudyDriveFile {
        guard StudyDriveBackupClient.validID(file.id), file.isPrivateOwned else {
            throw ChatError.invalidBackup("上传后的云盘文件权限状态异常。")
        }
        if let size = file.size.flatMap(Int.init) {
            guard size == expectedBytes else {
                throw ChatError.invalidBackup("云盘返回的文件大小与本机上传不一致。")
            }
        }
        if let remoteSHA = file.sha256Checksum?.lowercased(), !remoteSHA.isEmpty {
            guard remoteSHA == expectedSHA else {
                throw ChatError.invalidBackup("云盘返回的 SHA-256 与本机备份不一致。")
            }
        }
        return file
    }
}
