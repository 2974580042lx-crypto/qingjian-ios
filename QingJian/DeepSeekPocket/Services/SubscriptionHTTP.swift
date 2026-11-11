import Foundation

struct SubscriptionDiscovery: Decodable, Sendable {
    let issuer: String
    let authorization_endpoint: URL
    let token_endpoint: URL
    let jwks_uri: URL
    let revocation_endpoint: URL?
    func validated() throws -> Self {
        guard issuer == "https://auth.openai.com" else { throw SubscriptionError.invalidIdentity }
        for url in [authorization_endpoint, token_endpoint, jwks_uri] + [revocation_endpoint].compactMap({ $0 }) {
            guard url.scheme == "https", url.host == "auth.openai.com", url.port == nil || url.port == 443,
                  url.user == nil, url.password == nil, url.fragment == nil else { throw SubscriptionError.invalidIdentity }
        }
        return self
    }
}

struct SubscriptionTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let idToken: String
    let scopes: [String]
    let expiresAt: Date
    let receivedAt: Date
    let earliestRefreshAt: Date?
    static func decode(_ data: Data, now: Date = Date()) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["token_type"] as? String == "Bearer" || (root["token_type"] as? String)?.lowercased() == "bearer",
              let access = root["access_token"] as? String, !access.isEmpty, !access.contains("\n"), !access.contains("\r"),
              let refresh = root["refresh_token"] as? String, !refresh.isEmpty,
              let idToken = root["id_token"] as? String, !idToken.isEmpty,
              let scope = root["scope"] as? String,
              let expiry = root["expires_in"] as? Double, expiry.isFinite, expiry > 0, expiry < 365 * 86400 else { throw SubscriptionError.invalidIdentity }
        var earliest: Date?
        if let raw = root["earliest_refresh_at"] as? Double { earliest = Date(timeIntervalSince1970: raw > 1e12 ? raw / 1000 : raw) }
        if let raw = root["earliest_refresh_at"] as? String { earliest = ISO8601DateFormatter().date(from: raw) }
        return Self(accessToken: access, refreshToken: refresh, idToken: idToken, scopes: scope.split(whereSeparator: \.isWhitespace).map(String.init), expiresAt: now.addingTimeInterval(expiry), receivedAt: now, earliestRefreshAt: earliest)
    }
}

final class SubscriptionHTTP: @unchecked Sendable {
    private let session: URLSession
    init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? .ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 90; config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config, delegate: SubscriptionNoRedirect(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func discovery() async throws -> SubscriptionDiscovery {
        let data = try await get(URL(string: "https://auth.openai.com/.well-known/openid-configuration")!)
        return try JSONDecoder().decode(SubscriptionDiscovery.self, from: data).validated()
    }
    func keys(_ config: SubscriptionDiscovery) async throws -> Data {
        do { return try await get(config.jwks_uri) }
        catch is CancellationError { throw CancellationError() }
        catch { throw SubscriptionError.identityUnavailable }
    }
    func exchange(config: SubscriptionDiscovery, transaction: SubscriptionTransaction, code: String, clientID: String) async throws -> SubscriptionTokens {
        try await token(config.token_endpoint, values: ["grant_type": "authorization_code", "client_id": clientID, "code": code,
                                                        "code_verifier": transaction.verifier, "redirect_uri": transaction.redirectURI, "resource": "https://api.openai.com/v1"])
    }
    func refresh(config: SubscriptionDiscovery, refreshToken: String, clientID: String) async throws -> SubscriptionTokens {
        try await token(config.token_endpoint, values: ["grant_type": "refresh_token", "client_id": clientID, "refresh_token": refreshToken, "resource": "https://api.openai.com/v1"])
    }
    private func token(_ url: URL, values: [String: String]) async throws -> SubscriptionTokens {
        var request = URLRequest(url: url, timeoutInterval: 30); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
        return try SubscriptionTokens.decode(await fetch(request))
    }
    private func get(_ url: URL, accessToken: String? = nil) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        return try await fetch(request)
    }
    private func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw SubscriptionError.malformed }
        guard (200..<300).contains(http.statusCode) else { throw SubscriptionError.response(data, status: http.statusCode) }
        guard data.count <= 2 * 1024 * 1024 else { throw SubscriptionError.malformed }
        return data
    }
    func models(accessToken: String) async throws -> [SubscriptionModel] {
        let data = try await get(URL(string: "https://api.openai.com/v1/models")!, accessToken: accessToken)
        return try SubscriptionModel.catalog(data)
    }
    func stream(_ payload: SubscriptionRequest, accessToken: String,
                onProgress: @escaping @MainActor (ChatStreamProgress) -> Void,
                onEvent: @escaping @MainActor (StreamEvent) -> Void) async throws {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!, timeoutInterval: 90)
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(payload)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let start = ProcessInfo.processInfo.systemUptime
        var last = start
        var progress = ChatStreamProgress(phase: .connecting, elapsedSeconds: 0, receivedBytes: 0, httpStatus: nil)
        await onProgress(progress)
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw SubscriptionError.malformed }
        progress.httpStatus = http.statusCode; progress.phase = .waiting
        await onProgress(progress)
        guard (200..<300).contains(http.statusCode) else {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte); if errorData.count > 64000 { break } }
            throw SubscriptionError.response(errorData, status: http.statusCode)
        }
        if let type = http.value(forHTTPHeaderField: "Content-Type"), !type.lowercased().contains("text/event-stream") { throw SubscriptionError.malformed }
        var decoder = ResponsesStreamDecoder()
        for try await byte in bytes {
            try Task.checkCancellation(); progress.receivedBytes += 1
            guard progress.receivedBytes <= 32 * 1024 * 1024 else { throw SubscriptionError.malformed }
            let now = ProcessInfo.processInfo.systemUptime
            if now - last >= 1 { progress.elapsedSeconds = Int(now - start); await onProgress(progress); last = now }
            if let event = try decoder.consume(byte) {
                if !event.content.isEmpty { progress.phase = .answering }
                else if !event.reasoning.isEmpty && progress.phase != .answering { progress.phase = .thinking }
                await onEvent(event)
                if event.isDone { break }
            }
        }
        if !decoder.completed, let event = try decoder.finish() { await onEvent(event) }
        try Task.checkCancellation()
        guard decoder.completed else { throw SubscriptionError.incomplete }
        progress.phase = .complete; progress.elapsedSeconds = Int(ProcessInfo.processInfo.systemUptime - start)
        await onProgress(progress)
    }
}

private final class SubscriptionNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
