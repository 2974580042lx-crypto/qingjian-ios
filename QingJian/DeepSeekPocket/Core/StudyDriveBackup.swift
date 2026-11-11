import Foundation

struct StudyDriveFile: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    var mimeType: String?
    var size: String?
    var createdTime: String?
    var modifiedTime: String?
    var sha256Checksum: String?
    var md5Checksum: String?
    var webViewLink: String?
    var parents: [String]?
    var appProperties: [String: String]?
    var ownedByMe: Bool?
    var shared: Bool?
    var driveId: String?
    var deviceID: String? { appProperties?["deviceID"] }
    var backupID: String? { appProperties?["backupID"] }
    var isPrivateOwned: Bool { ownedByMe == true && shared == false && driveId == nil }
}
struct StudyUploadSession: Codable, Sendable {
    let backupID: String
    var sessionURL: String?
    var offset: Int
}
struct StudyCloudState: Codable, Sendable {
    var enabled = true
    var acknowledgedIDs: Set<String> = []
    var lastVerifiedAt: Date?
    var lastFingerprint: String?
    var lastFileID: String?
    var lastFileURL: String?
    var dirty = true
    var pendingFingerprint: String?
    var pendingGeneration: Int?
    var upload: StudyUploadSession?
    var generation = 0
    var conflict = false
    var error: String?
    var lastOmittedImageCount: Int? = nil
    var lastCompleteFileURL: String? = nil
    mutating func changed() { generation += 1; dirty = true }
    func conflicts(with files: [StudyDriveFile], deviceID: String) -> Bool {
        files.contains { !acknowledgedIDs.contains($0.id) && $0.deviceID != deviceID }
    }
    mutating func verified(file: StudyDriveFile, fingerprint: String, generation captured: Int, files: [StudyDriveFile], now: Date = Date(), omittedImages: Int = 0) {
        if lastCompleteFileURL == nil && lastOmittedImageCount == nil { lastCompleteFileURL = lastFileURL }
        acknowledgedIDs = Set(files.map(\.id)); lastVerifiedAt = now; lastFingerprint = fingerprint
        lastFileID = file.id; lastFileURL = file.webViewLink
        lastOmittedImageCount = omittedImages
        if omittedImages == 0 { lastCompleteFileURL = file.webViewLink }
        upload = nil; pendingFingerprint = nil; pendingGeneration = nil; conflict = false; error = nil
        dirty = generation != captured
    }
}

/// This client receives authorization only from the caller. It never stores or
/// exports OAuth tokens. Tests use the same requests with a synthetic transport.
final class StudyDriveBackupClient: @unchecked Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private static let files = "https://www.googleapis.com/drive/v3/files"
    private static let uploads = "https://www.googleapis.com/upload/drive/v3/files"
    private static let fields = "id,name,mimeType,size,createdTime,modifiedTime,sha256Checksum,md5Checksum,webViewLink,parents,appProperties,ownedByMe,shared,driveId"
    init(transport: @escaping Transport) { self.transport = transport }
    static func validID(_ id: String) -> Bool { id.range(of: #"^[A-Za-z0-9_-]{1,200}$"#, options: .regularExpression) != nil }
    static func allowedURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "www.googleapis.com" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
            && (url.path.hasPrefix("/drive/v3/files") || url.path.hasPrefix("/upload/drive/v3/files"))
    }
    private static func url(_ base: String = files, id: String? = nil, query: [String: String]) throws -> URL {
        if let id, !validID(id) { throw StudyBackupError.invalid("云盘文件标识不正确。") }
        var c = URLComponents(string: base + (id.map { "/" + $0 } ?? ""))!
        c.queryItems = query.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        guard let url = c.url else { throw StudyBackupError.unavailable }; return url
    }
    private static func request(_ url: URL, method: String = "GET", json: [String: Any]? = nil) throws -> URLRequest {
        guard allowedURL(url) else { throw StudyBackupError.invalid("拒绝向非Google地址发送备份请求。") }
        var r = URLRequest(url: url); r.httpMethod = method; r.timeoutInterval = 120
        if let json { r.httpBody = try JSONSerialization.data(withJSONObject: json); r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type") }
        return r
    }
    private func success(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else { throw StudyBackupError.invalid("Google备份请求失败（HTTP \(response.statusCode)），待传文件保留。") }
        return data
    }
    private func list(query: String) async throws -> [StudyDriveFile] {
        struct Page: Decodable { let files: [StudyDriveFile]; let nextPageToken: String? }
        var files: [StudyDriveFile] = [], token: String?, seen = Set<String>()
        repeat {
            var q = ["q":query,"pageSize":"100","fields":"nextPageToken,files(\(Self.fields))","orderBy":"createdTime desc"]
            if let token { guard seen.insert(token).inserted else { throw StudyBackupError.invalid("云盘分页游标重复，未判定备份完成。") }; q["pageToken"] = token }
            let data = try await success(Self.request(Self.url(query: q)))
            let page = try JSONDecoder().decode(Page.self, from: data)
            files += page.files; token = page.nextPageToken
            guard files.count <= 10_000 else { throw StudyBackupError.invalid("云盘学习版本数量过多，请先手动整理；本次未截断列表。") }
        } while token != nil
        guard files.allSatisfy({ Self.validID($0.id) }) else { throw StudyBackupError.invalid("云盘返回无效文件标识。") }
        return files
    }
    func folders(create: Bool) async throws -> [StudyDriveFile] {
        var found = try await list(query: "'root' in parents and trashed = false and mimeType = 'application/vnd.google-apps.folder' and appProperties has { key='sermoStudyRoot' and value='1' }")
        guard found.allSatisfy(\.isPrivateOwned) else { throw StudyBackupError.conflict("学习备份目录已共享或不属于当前账号，自动备份已暂停。") }
        if found.isEmpty && create {
            let body: [String: Any] = ["name":"Sermo 学习备份", "mimeType":"application/vnd.google-apps.folder", "parents":["root"], "appProperties":["sermoStudyRoot":"1"]]
            let data = try await success(Self.request(Self.url(query: ["fields":Self.fields]), method: "POST", json: body))
            let file = try JSONDecoder().decode(StudyDriveFile.self, from: data)
            guard Self.validID(file.id), file.isPrivateOwned else { throw StudyBackupError.invalid("未能确认新建备份目录为私人目录。") }
            found = [file]
        }
        return found.sorted { ($0.createdTime ?? "", $0.id) < ($1.createdTime ?? "", $1.id) }
    }
    func listBackups() async throws -> [StudyDriveFile] {
        var files: [StudyDriveFile] = []
        for folder in try await folders(create: false) {
            files += try await list(query: "'\(folder.id)' in parents and trashed = false and appProperties has { key='sermoStudyBackup' and value='1' }")
        }
        guard files.allSatisfy(\.isPrivateOwned) else { throw StudyBackupError.conflict("有学习备份已被共享，自动同步暂停，请先核对云盘共享状态。") }
        return files.sorted { ($0.createdTime ?? "", $0.id) > ($1.createdTime ?? "", $1.id) }
    }
    func metadata(_ id: String) async throws -> StudyDriveFile {
        let data = try await success(Self.request(Self.url(id: id, query: ["fields":Self.fields])))
        return try JSONDecoder().decode(StudyDriveFile.self, from: data)
    }
    func download(_ file: StudyDriveFile) async throws -> Data {
        let meta = try await metadata(file.id)
        guard meta.isPrivateOwned, let size = meta.size.flatMap(Int.init), size > 0, size <= StudyBackupCodec.maximumBytes else {
            throw StudyBackupError.invalid("云盘备份大小或私有状态不正确。")
        }
        let data = try await success(Self.request(Self.url(id: file.id, query: ["alt":"media"])))
        guard data.count == size, meta.sha256Checksum.map({ $0.lowercased() == StudyCoding.hash(data) }) ?? true else { throw StudyBackupError.invalid("从云盘回读的备份校验不一致。") }
        let payload = try StudyBackupCodec.decode(data)
        guard meta.backupID == payload.backupID.uuidString, meta.deviceID == payload.deviceID,
              meta.appProperties?["sha256"] == StudyCoding.hash(data) else { throw StudyBackupError.invalid("云盘标记与备份内容不匹配，未恢复。") }
        return data
    }
    private static func nextOffset(_ response: HTTPURLResponse, total: Int) throws -> Int {
        guard let range = response.value(forHTTPHeaderField: "Range") else { return 0 }
        guard range.hasPrefix("bytes=0-"), let end = Int(range.dropFirst(8)), end >= 0, end < total else { throw StudyBackupError.invalid("云盘返回的续传位置不正确。") }
        return end + 1
    }
    func upload(_ data: Data, payload: StudyBackupPayload, session initial: StudyUploadSession,
                persist: @escaping @Sendable (StudyUploadSession) async throws -> Void) async throws -> StudyDriveFile {
        guard data.count <= StudyBackupCodec.maximumBytes, initial.backupID == payload.backupID.uuidString else { throw StudyBackupError.invalid("待传备份标识不匹配。") }
        let existing = try await listBackups()
        if let existing = existing.first(where: { $0.backupID == initial.backupID }) {
            guard existing.appProperties?["sha256"] == StudyCoding.hash(data) else { throw StudyBackupError.conflict("同一备份标识已有不同内容，未覆盖。") }
            return existing
        }
        var job = initial
        if let raw = job.sessionURL {
            guard let url = URL(string: raw), Self.allowedURL(url), url.path.hasPrefix("/upload/drive/v3/files") else { throw StudyBackupError.invalid("续传地址不安全，未发送凭据。") }
            var query = try Self.request(url, method: "PUT")
            query.setValue("bytes */\(data.count)", forHTTPHeaderField: "Content-Range"); query.setValue("0", forHTTPHeaderField: "Content-Length")
            let (body, response) = try await transport(query)
            if (200..<300).contains(response.statusCode) { return try JSONDecoder().decode(StudyDriveFile.self, from: body) }
            if response.statusCode == 308 { job.offset = try Self.nextOffset(response, total: data.count) }
            else if response.statusCode == 404 { job.sessionURL = nil; job.offset = 0 }
            else { throw StudyBackupError.invalid("续传状态查询失败（HTTP \(response.statusCode)）。") }
            try await persist(job)
        }
        if job.sessionURL == nil {
            guard let folder = try await folders(create: true).first else { throw StudyBackupError.unavailable }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
            let coverage = payload.isComplete ? "完整" : "记录保底-缺\(payload.omittedImages?.count ?? 0)图"
            let body: [String: Any] = ["name":"Sermo学习-\(coverage)-\(formatter.string(from: payload.createdAt))-\(payload.backupID.uuidString.prefix(8)).json", "mimeType":"application/json", "parents":[folder.id],
                "appProperties":["sermoStudyBackup":"1", "backupID":job.backupID, "deviceID":payload.deviceID, "sha256":StudyCoding.hash(data), "coverage":payload.isComplete ? "complete" : "records-fallback"]]
            var request = try Self.request(Self.url(Self.uploads, query: ["uploadType":"resumable","fields":Self.fields]), method: "POST", json: body)
            request.setValue("application/json", forHTTPHeaderField: "X-Upload-Content-Type"); request.setValue(String(data.count), forHTTPHeaderField: "X-Upload-Content-Length")
            let (_, response) = try await transport(request)
            guard (200..<300).contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location"),
                  let url = URL(string: location), Self.allowedURL(url), url.path.hasPrefix("/upload/drive/v3/files") else { throw StudyBackupError.invalid("无法建立安全的云盘续传会话。") }
            job.sessionURL = location; job.offset = 0; try await persist(job)
        }
        guard let url = job.sessionURL.flatMap(URL.init(string:)) else { throw StudyBackupError.unavailable }
        var iterations = 0
        while job.offset < data.count {
            try Task.checkCancellation(); iterations += 1
            guard iterations <= data.count / (1024 * 1024) + 3 else { throw StudyBackupError.invalid("云盘没有正常推进续传位置，待传任务保留。") }
            let end = min(job.offset + 1024 * 1024, data.count)
            var request = try Self.request(url, method: "PUT")
            request.httpBody = data.subdata(in: job.offset..<end)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(String(end - job.offset), forHTTPHeaderField: "Content-Length")
            request.setValue("bytes \(job.offset)-\(end - 1)/\(data.count)", forHTTPHeaderField: "Content-Range")
            let (body, response) = try await transport(request)
            if (200..<300).contains(response.statusCode) { return try JSONDecoder().decode(StudyDriveFile.self, from: body) }
            guard response.statusCode == 308 else { throw StudyBackupError.invalid("上传暂未完成（HTTP \(response.statusCode)），下次继续。") }
            let offset = try Self.nextOffset(response, total: data.count)
            guard offset > job.offset, offset <= end else { throw StudyBackupError.invalid("续传进度异常，未标记成功。") }
            job.offset = offset; try await persist(job)
        }
        throw StudyBackupError.invalid("尚未收到云盘完整上传确认，保留待传任务。")
    }
}
