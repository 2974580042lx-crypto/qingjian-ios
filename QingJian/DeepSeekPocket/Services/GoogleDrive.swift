import Foundation
import Combine
import Security
import AuthenticationServices
import UIKit

private enum GoogleKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.xiaolong.qingjian.google.drive",
         kSecAttrAccount as String: "local-account"]
    }
    static func read() throws -> GoogleCredentials? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw GoogleAuthError.storage(status) }
        return try? JSONDecoder().decode(GoogleCredentials.self, from: data)
    }
    static func save(_ credentials: GoogleCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw GoogleAuthError.storage(added) }
        } else if status != errSecSuccess { throw GoogleAuthError.storage(status) }
    }
    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

enum DriveError: LocalizedError {
    case http(Int, String?), unsupported(String), tooLarge, invalidResponse
    var errorDescription: String? {
        switch self {
        case .http(let code, let message): return "谷歌云盘返回错误（HTTP \(code)）" + (message.map { "：\($0)" } ?? "。")
        case .unsupported(let detail): return detail
        case .tooLarge: return "文件太大，超过 5 MB，暂不读取。"
        case .invalidResponse: return "谷歌云盘返回的数据无法读取。"
        }
    }
}

// Google sign-in and the Drive calls behind the drive_ tools. Tokens stay in
// the Keychain on this phone and never go into chat backups or to the model.
@MainActor
final class GoogleDriveStore: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var connected = false
    @Published private(set) var accountLabel = "尚未登录"
    @Published private(set) var signingIn = false
    // Set when a token can no longer be refreshed (Google ends test-mode sign-ins after about a week).
    @Published private(set) var needsSignIn = false
    @Published var issue: String?
    private var credentials: GoogleCredentials?
    private var webSession: ASWebAuthenticationSession?
    private let refresh = GoogleRefreshTask()
    private let preview = ProcessInfo.processInfo.arguments.contains("--ui-preview")
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()
    private static let files = "https://www.googleapis.com/drive/v3/files"
    private static let uploads = "https://www.googleapis.com/upload/drive/v3/files"
    private static let fileFields = "id,name,mimeType,modifiedTime,size,parents"
    private static let downloadLimit = 5_000_000

    override init() {
        super.init()
        guard !preview else { return }
        do { credentials = try GoogleKeychain.read() }
        catch { issue = error.localizedDescription }
        publish()
    }

    private func publish() {
        connected = credentials != nil
        accountLabel = credentials.map { $0.email ?? "已登录谷歌账号" } ?? "尚未登录"
    }

    // MARK: Sign-in

    func signIn() {
        guard !signingIn else { return }
        guard !preview else { issue = "界面测试模式不连接真实账号。"; return }
        signingIn = true
        issue = nil
        Task {
            defer { self.signingIn = false; self.webSession = nil }
            do {
                let state = try Self.random(), verifier = try Self.random()
                let callback = try await self.authorize(GoogleOAuth.authorizationURL(state: state, verifier: verifier))
                let code = try GoogleOAuth.code(from: callback, state: state)
                let response = try await self.tokenRequest(GoogleOAuth.exchangeBody(code: code, verifier: verifier))
                guard let refresh = response.refreshToken, !refresh.isEmpty else { throw GoogleAuthError.noRefreshToken }
                guard response.scope.map(GoogleCredentials.hasDrive) ?? true else { throw GoogleAuthError.driveNotGranted }
                let next = GoogleCredentials(accessToken: response.accessToken, refreshToken: refresh,
                                             expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn ?? 3600)),
                                             email: GoogleOAuth.email(fromIDToken: response.idToken), grantedDrive: true)
                try GoogleKeychain.save(next)
                // Reauthentication replaces the session just like signing out:
                // cancel and detach the previous refresh before accepting it.
                self.refresh.invalidate()
                self.credentials = next
                self.needsSignIn = false
                self.publish()
            } catch GoogleAuthError.cancelled {
                // Closing the sheet is not an error worth showing.
            } catch {
                self.issue = error.localizedDescription
            }
        }
    }

    func cancelSignIn() { webSession?.cancel() }

    func signOut() {
        if let token = credentials?.refreshToken {
            // Best effort: also withdraw the grant on Google's side.
            var request = URLRequest(url: GoogleOAuth.revokeEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = GoogleOAuth.form(["token": token])
            let session = self.session
            Task.detached { _ = try? await session.data(for: request) }
        }
        refresh.invalidate()
        GoogleKeychain.delete()
        credentials = nil
        needsSignIn = false
        issue = nil
        publish()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? UIWindow()
    }

    private func authorize(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(GoogleOAuth.callbackScheme)) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let failure = error as? ASWebAuthenticationSessionError, failure.code == .canceledLogin {
                    continuation.resume(throwing: GoogleAuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? GoogleAuthError.invalidCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.webSession = session
            if !session.start() { continuation.resume(throwing: GoogleAuthError.cancelled) }
        }
    }

    private func tokenRequest(_ body: Data) async throws -> GoogleTokenResponse {
        var request = URLRequest(url: GoogleOAuth.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DriveError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            if code == "invalid_grant" { throw GoogleAuthError.signInRequired }
            throw GoogleAuthError.service(code ?? "HTTP \(http.statusCode)")
        }
        guard let decoded = try? JSONDecoder().decode(GoogleTokenResponse.self, from: data) else { throw DriveError.invalidResponse }
        return decoded
    }

    private func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = credentials else { needsSignIn = true; throw GoogleAuthError.signInRequired }
        if !forceRefresh && current.isFresh { return current.accessToken }
        return try await refresh.value { started in
            do {
                let response = try await self.tokenRequest(GoogleOAuth.refreshBody(refreshToken: current.refreshToken))
                // Signed out (or in again) while this was in flight: drop the result.
                guard self.refresh.generation == started, self.credentials != nil else { throw GoogleAuthError.signInRequired }
                let next = current.updated(with: response)
                // Keep using the new token this session even if the Keychain write fails.
                try? GoogleKeychain.save(next)
                self.credentials = next
                return next.accessToken
            } catch GoogleAuthError.signInRequired {
                if self.refresh.generation == started { self.expire() }
                throw GoogleAuthError.signInRequired
            }
        }
    }

    private func expire() {
        GoogleKeychain.delete()
        credentials = nil
        needsSignIn = true
        publish()
    }
    var backupAccountID: String? { credentials?.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    func studyBackupClient() throws -> StudyDriveBackupClient {
        guard let account = backupAccountID, !account.isEmpty else { throw GoogleAuthError.signInRequired }
        return StudyDriveBackupClient { [weak self] request in
            guard let self else { throw GoogleAuthError.signInRequired }
            return try await self.sendStudyBackup(request, account: account)
        }
    }
    private func sendStudyBackup(_ input: URLRequest, account: String) async throws -> (Data, HTTPURLResponse) {
        guard backupAccountID == account, let url = input.url, StudyDriveBackupClient.allowedURL(url) else { throw GoogleAuthError.signInRequired }
        var token = try await accessToken()
        for attempt in 0..<2 {
            guard backupAccountID == account else { throw CancellationError() }
            var request = input; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard backupAccountID == account, let http = response as? HTTPURLResponse else { throw CancellationError() }
            if http.statusCode == 401 && attempt == 0 { token = try await accessToken(forceRefresh: true); continue }
            if http.statusCode == 401 { expire(); throw GoogleAuthError.signInRequired }
            return (data, http)
        }
        throw GoogleAuthError.signInRequired
    }

    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw GoogleAuthError.invalidCallback }
        return Data(bytes).base64URL
    }

    // MARK: Drive calls

    /// Sends an authorised request; on 401 refreshes the token once and retries.
    private func send(_ make: (String) throws -> URLRequest) async throws -> Data {
        var token = try await accessToken()
        for attempt in 0..<2 {
            let request = try make(token)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw DriveError.invalidResponse }
            if (200..<300).contains(http.statusCode) { return data }
            if http.statusCode == 401 && attempt == 0 {
                token = try await accessToken(forceRefresh: true)
                continue
            }
            if http.statusCode == 401 { if credentials != nil { expire() }; throw GoogleAuthError.signInRequired }
            let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            let message = error?["message"] as? String
            if http.statusCode == 403, message?.lowercased().contains("insufficient") == true { throw GoogleAuthError.driveNotGranted }
            throw DriveError.http(http.statusCode, message.map { String($0.prefix(200)) })
        }
        throw DriveError.invalidResponse
    }

    private static func url(_ base: String, path: String = "", _ query: [String: String] = [:]) throws -> URL {
        guard var components = URLComponents(string: base + path) else { throw DriveError.invalidResponse }
        var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "supportsAllDrives", value: "true"))
        components.queryItems = items
        // "+" in a query value is read as a space by Google; encode it explicitly.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw DriveError.invalidResponse }
        return url
    }

    private static func request(_ url: URL, token: String, method: String = "GET", json: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return request
    }

    private struct Page: Decodable { let files: [DriveFile]; let nextPageToken: String? }
    private func decodePage(_ data: Data) throws -> Page {
        guard let page = try? JSONDecoder().decode(Page.self, from: data) else { throw DriveError.invalidResponse }
        return page
    }
    private func decodeFiles(_ data: Data) throws -> [DriveFile] { try decodePage(data).files }

    /// A folder's files, page by page, up to `limit`; `more` is true when some were left out.
    private func children(of folderID: String, limit: Int = 200) async throws -> (files: [DriveFile], more: Bool) {
        var files: [DriveFile] = []
        var token: String?
        repeat {
            var query = ["q": DriveAction.childrenQuery(folderID), "pageSize": "100", "orderBy": "folder,name",
                         "fields": "nextPageToken,files(\(Self.fileFields))", "includeItemsFromAllDrives": "true"]
            if let token { query["pageToken"] = token }
            let url = try Self.url(Self.files, query)
            let page = try decodePage(try await send { try Self.request(url, token: $0) })
            files.append(contentsOf: page.files)
            token = page.nextPageToken
        } while token != nil && files.count < limit
        return (Array(files.prefix(limit)), token != nil || files.count > limit)
    }

    func readColabEndpoint() async throws -> Data {
        guard connected else { throw GoogleAuthError.signInRequired }
        let account = accountLabel
        func files(_ query: String) async throws -> [DriveFile] {
            let data = try await send { token in
                try Self.request(Self.url("https://www.googleapis.com/drive/v3/files", path: "", ["q": query,
                    "fields": "files(id,name,mimeType)", "pageSize": "100"]), token: token)
            }
            return try decodeFiles(data)
        }
        let folders = try await files("'root' in parents and name = 'EasyColab' and mimeType = 'application/vnd.google-apps.folder' and trashed = false")
        guard folders.count == 1, let folder = folders.first else {
            throw ColabError.configuration("请在 Google Drive 根目录保留一个 EasyColab 文件夹。")
        }
        let endpoints = try await files("'\(folder.id)' in parents and name = 'endpoint.json' and trashed = false")
        guard endpoints.count == 1, let endpoint = endpoints.first else {
            throw ColabError.configuration("没有找到唯一的 /EasyColab/endpoint.json，请先在电脑端更新地址。")
        }
        let data = try await send { token in
            try Self.request(Self.url(Self.files, path: "/\(endpoint.id)",
                ["alt": "media"]), token: token)
        }
        guard account == accountLabel else { throw CancellationError() }
        guard data.count <= 65536 else { throw ColabError.configuration("endpoint.json 文件过大，请重新生成。") }
        return data
    }

    func metadata(_ fileID: String) async throws -> DriveFile {
        let url = try Self.url(Self.files, path: "/\(fileID)", ["fields": Self.fileFields])
        let data = try await send { try Self.request(url, token: $0) }
        guard let file = try? JSONDecoder().decode(DriveFile.self, from: data) else { throw DriveError.invalidResponse }
        return file
    }

    /// Runs one tool action and returns the text handed back to the model.
    func perform(_ action: DriveAction) async throws -> String {
        switch action {
        case .search(let query, let limit):
            let url = try Self.url(Self.files, ["q": DriveAction.searchQuery(query), "pageSize": String(limit),
                                                "fields": "files(\(Self.fileFields))", "includeItemsFromAllDrives": "true"])
            let files = try decodeFiles(try await send { try Self.request(url, token: $0) })
            return DriveFormat.list(files, emptyMessage: "没有找到包含「\(query)」的文件。")
        case .list(let folderID):
            let result = try await children(of: folderID)
            let text = DriveFormat.list(result.files, emptyMessage: "这个文件夹是空的。")
            return result.more ? text + "\n\n（文件夹里超过 \(result.files.count) 项，只列出了前 \(result.files.count) 项；要找具体文件请用 drive_search。）" : text
        case .read(let fileID):
            let file = try await metadata(fileID)
            guard let plan = file.readPlan else {
                throw DriveError.unsupported("《\(file.name)》是\(file.kind)，暂时读不了文字内容。")
            }
            if let size = file.size.flatMap(Int.init), size > Self.downloadLimit { throw DriveError.tooLarge }
            let url = try plan.export.map { try Self.url(Self.files, path: "/\(fileID)/export", ["mimeType": $0]) }
                ?? Self.url(Self.files, path: "/\(fileID)", ["alt": "media"])
            let data = try await send { try Self.request(url, token: $0) }
            guard data.count <= Self.downloadLimit * 2 else { throw DriveError.tooLarge }
            return DriveFormat.fileContent(String(decoding: data, as: UTF8.self), name: file.name)
        case .create(let name, let content, let folderID, let googleDoc):
            var info: [String: Any] = ["name": name,
                                       "mimeType": googleDoc ? "application/vnd.google-apps.document" : Self.textMIME(for: name)]
            if let folderID { info["parents"] = [folderID] }
            let url = try Self.url(Self.uploads, ["uploadType": "multipart", "fields": Self.fileFields])
            let boundary = "sermo-\(UUID().uuidString)"
            let body = try Self.multipart(metadata: info, content: content, contentType: "text/plain; charset=UTF-8", boundary: boundary)
            let data = try await send { token in
                var request = try Self.request(url, token: token, method: "POST")
                request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
                return request
            }
            let file = try? JSONDecoder().decode(DriveFile.self, from: data)
            return "已新建《\(file?.name ?? name)》（\(file?.kind ?? "文件")） id: \(file?.id ?? "未知")"
        case .update(let fileID, let content):
            let file = try await metadata(fileID)
            guard file.canRewrite else {
                throw DriveError.unsupported("《\(file.name)》是\(file.kind)，不能整体改写。可以新建一份文件代替。")
            }
            let url = try Self.url(Self.uploads, path: "/\(fileID)", ["uploadType": "media", "fields": Self.fileFields])
            _ = try await send { token in
                var request = try Self.request(url, token: token, method: "PATCH")
                request.setValue("\(file.mimeType); charset=UTF-8", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(content.utf8)
                return request
            }
            return "已改写《\(file.name)》，共 \(content.count) 字。"
        case .createFolder(let name, let folderID):
            var json: [String: Any] = ["name": name, "mimeType": "application/vnd.google-apps.folder"]
            if let folderID { json["parents"] = [folderID] }
            let url = try Self.url(Self.files, ["fields": Self.fileFields])
            let data = try await send { try Self.request(url, token: $0, method: "POST", json: json) }
            let file = try? JSONDecoder().decode(DriveFile.self, from: data)
            return "已新建文件夹《\(file?.name ?? name)》 id: \(file?.id ?? "未知")"
        case .move(let fileID, let newName, let folderID):
            let file = try await metadata(fileID)
            var query = ["fields": Self.fileFields]
            if let folderID {
                query["addParents"] = folderID
                let old = (file.parents ?? []).filter { $0 != folderID }
                if !old.isEmpty { query["removeParents"] = old.joined(separator: ",") }
            }
            let url = try Self.url(Self.files, path: "/\(fileID)", query)
            var json: [String: Any] = [:]
            if let newName { json["name"] = newName }
            _ = try await send { try Self.request(url, token: $0, method: "PATCH", json: json) }
            var done: [String] = []
            if let newName { done.append("改名为《\(newName)》") }
            if folderID != nil { done.append("移到了指定文件夹") }
            return "《\(file.name)》已" + done.joined(separator: "，") + "。"
        case .trash(let fileID):
            let file = try await metadata(fileID)
            let url = try Self.url(Self.files, path: "/\(fileID)", ["fields": "id,trashed"])
            _ = try await send { try Self.request(url, token: $0, method: "PATCH", json: ["trashed": true]) }
            return "《\(file.name)》已移到回收站，30 天内可在谷歌云盘里恢复。"
        }
    }

    private static func textMIME(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "md", "markdown": return "text/markdown"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "html", "htm": return "text/html"
        default: return "text/plain"
        }
    }

    private static func multipart(metadata: [String: Any], content: String, contentType: String, boundary: String) throws -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(try JSONSerialization.data(withJSONObject: metadata))
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        body.append(Data(content.utf8))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
