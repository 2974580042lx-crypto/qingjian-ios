import Foundation
import Combine
import Security
import AuthenticationServices
import UIKit

private struct SubscriptionConnection: Codable {
    let clientID: String
    let subject: String
    let email: String?
    var tokens: SubscriptionTokens
    var pendingRefresh: SubscriptionTokens?
}
private struct SubscriptionVault: Codable {
    var hostID = "urn:uuid:" + UUID().uuidString.lowercased()
    var connection: SubscriptionConnection?
    var registeredClientID: String?
    var includedUsageConfirmed = false
}
private enum SubscriptionKeychain {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.xiaolong.qingjian.chatgpt.subscription", kSecAttrAccount as String: "local-account"] }
    static func read() throws -> SubscriptionVault {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return SubscriptionVault() }
        guard status == errSecSuccess, let data = value as? Data else { throw SubscriptionError.storage(Int(status)) }
        SecItemUpdate(query as CFDictionary,
                      [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
        return try JSONDecoder().decode(SubscriptionVault.self, from: data)
    }
    static func save(_ value: SubscriptionVault) throws {
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(query as CFDictionary, [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(q as CFDictionary, nil)
            guard result == errSecSuccess else { throw SubscriptionError.storage(Int(result)) }
        } else if status != errSecSuccess { throw SubscriptionError.storage(Int(status)) }
    }
}

@MainActor
final class SubscriptionStore: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var connected = false
    @Published private(set) var planAllowed = false
    @Published private(set) var accountLabel = "尚未登录"
    @Published private(set) var models: [SubscriptionModel] = []
    @Published private(set) var signingIn = false
    @Published private(set) var loadingModels = false
    @Published private(set) var testing = false
    @Published private(set) var includedUsageConfirmed = false
    @Published private(set) var reauthenticationRequired = false
    @Published var issue: String?
    @Published var testResult: String?
    @Published private(set) var loginStage = ""
    private var vault = SubscriptionVault()
    private var canSave = true
    private let preview = ProcessInfo.processInfo.arguments.contains("--ui-preview")
    // Some models refuse a thinking summary; after one refusal we stop asking for it.
    private var summaryRefused = false
    func title(for slug: String) -> String { models.first(where: { $0.slug == slug })?.displayName ?? slug }
    private let api = SubscriptionHTTP()
    private var webSession: ASWebAuthenticationSession?
    private var listener: SubscriptionLoopback?
    private var loginTask: Task<Void, Never>?
    private var refreshTask: Task<String, Error>?
    private var requestCount = 0
    var busy: Bool { signingIn || loadingModels || testing || requestCount > 0 || refreshTask != nil }
    var ready: Bool { connected && planAllowed && includedUsageConfirmed && !reauthenticationRequired && !signingIn }
    var readinessMessage: String {
        if !connected || reauthenticationRequired { return SubscriptionError.notConnected.localizedDescription }
        if !planAllowed { return SubscriptionError.planPermission.localizedDescription }
        if !includedUsageConfirmed { return SubscriptionError.creditsNotConfirmed.localizedDescription }
        return SubscriptionError.modelUnavailable.localizedDescription
    }
    override init() {
        super.init()
        if preview { return }
        reloadIfNeeded()
    }
    func reloadIfNeeded() {
        guard !preview else { return }
        do { vault = try SubscriptionKeychain.read(); canSave = true; issue = nil; publish() }
        catch { canSave = false; issue = error.localizedDescription }
    }
    private func publish() {
        connected = vault.connection != nil
        planAllowed = vault.connection?.tokens.scopes.contains("chatgpt.tokens.use.direct") == true
        accountLabel = vault.connection?.email ?? (connected ? "ChatGPT 账号" : "尚未登录")
        includedUsageConfirmed = vault.includedUsageConfirmed
    }
    private func save(_ next: SubscriptionVault) throws {
        guard canSave else { throw SubscriptionError.storage(-34018) }
        if !preview { try SubscriptionKeychain.save(next) }
        vault = next; publish()
    }
    func confirmIncludedUsage(_ value: Bool) {
        guard !busy else { return }
        do { var next = vault; next.includedUsageConfirmed = value; try save(next) }
        catch { issue = error.localizedDescription }
    }
    func signIn() {
        guard !busy else { return }
        guard !preview else { issue = "界面测试模式不连接真实账号。"; return }
        // Retry access after the device was locked or a previous Keychain read failed.
        if !canSave {
            do { vault = try SubscriptionKeychain.read(); canSave = true; publish() }
            catch { issue = error.localizedDescription; return }
        }
        signingIn = true; issue = nil; testResult = nil; loginStage = "正在准备官方登录"
        loginTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.listener?.cancel(); self.listener = nil
                self.webSession?.cancel(); self.webSession = nil
                self.signingIn = false; self.loginTask = nil; self.loginStage = ""
            }
            do {
                try self.save(self.vault) // Persist the host identifier before registration.
                let config = try await self.api.discovery()
                let state = try Self.random(), nonce = try Self.random(), verifier = try Self.random()
                let server = SubscriptionLoopback(state: state); self.listener = server
                let redirect = try await server.start()
                try Task.checkCancellation()
                let transaction = SubscriptionTransaction(state: state, nonce: nonce, verifier: verifier, redirectURI: redirect.absoluteString)
                let clientID = self.vault.connection?.clientID ?? self.vault.registeredClientID
                let url = transaction.authorizationURL(endpoint: config.authorization_endpoint, hostID: self.vault.hostID, clientID: clientID, idTokenHint: self.vault.connection?.tokens.idToken, reconsent: self.connected && !self.planAllowed)
                self.loginStage = "请在官方页面登录并审核套餐授权"
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, error in
                    Task { @MainActor [weak self] in
                        guard let self, self.webSession != nil else { return }
                        if error != nil { self.listener?.cancel() }
                    }
                }
                self.webSession = session
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                guard session.start() else { throw SubscriptionError.cancelled }
                let callback = try await server.result()
                // The HTTP loopback received the callback; close Apple's browser sheet.
                self.webSession = nil; session.cancel()
                self.loginStage = "正在核验账号与订阅权限"
                let value = try transaction.validateCallback(callback, savedClientID: clientID)
                var registered = self.vault; registered.registeredClientID = value.clientID
                try self.save(registered)
                let tokens = try await self.api.exchange(config: config, transaction: transaction, code: value.code, clientID: value.clientID)
                let keys = try await self.api.keys(config)
                let identity = try SubscriptionJWT.verify(tokens.idToken, jwks: keys, clientID: value.clientID, nonce: nonce, expectedSubject: self.vault.connection?.subject)
                var next = self.vault
                next.connection = SubscriptionConnection(clientID: value.clientID, subject: identity.subject, email: identity.email, tokens: tokens)
                next.includedUsageConfirmed = false
                try self.save(next)
                self.reauthenticationRequired = false
                if self.planAllowed { self.models = try await self.api.models(accessToken: tokens.accessToken) }
                else { self.issue = SubscriptionError.planPermission.localizedDescription }
            } catch {
                if !(error is CancellationError) { self.issue = error.localizedDescription }
            }
        }
    }
    func cancelSignIn() { listener?.cancel(); loginTask?.cancel(); webSession?.cancel() }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? UIWindow()
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw SubscriptionError.invalidIdentity }
        return Data(bytes).base64URL
    }
    private func validAccessToken() async throws -> String {
        guard let connection = vault.connection else { throw SubscriptionError.notConnected }
        guard !reauthenticationRequired else { throw SubscriptionError.notConnected }
        guard planAllowed else { throw SubscriptionError.planPermission }
        if let refreshTask { return try await refreshTask.value }
        if connection.pendingRefresh == nil && connection.tokens.expiresAt.timeIntervalSinceNow > 60 { return connection.tokens.accessToken }
        let task = Task { @MainActor [weak self] () throws -> String in
            guard let self else { throw CancellationError() }
            let config = try await self.api.discovery()
            let tokens: SubscriptionTokens
            if let pending = connection.pendingRefresh { tokens = pending }
            else {
                if let earliest = connection.tokens.earliestRefreshAt, earliest > Date() {
                    guard connection.tokens.expiresAt > Date() else { throw SubscriptionError.notConnected }
                    return connection.tokens.accessToken
                }
                tokens = try await self.api.refresh(config: config, refreshToken: connection.tokens.refreshToken, clientID: connection.clientID)
                // A rotating refresh token must survive a JWKS outage. It is kept
                // encrypted and is unusable until identity validation succeeds.
                var pending = self.vault; pending.connection?.pendingRefresh = tokens
                try self.save(pending)
            }
            let keys = try await self.api.keys(config)
            _ = try SubscriptionJWT.verify(tokens.idToken, jwks: keys, clientID: connection.clientID, nonce: nil, expectedSubject: connection.subject, now: tokens.receivedAt)
            var next = self.vault; next.connection?.tokens = tokens; next.connection?.pendingRefresh = nil
            try self.save(next)
            guard self.planAllowed else { throw SubscriptionError.planPermission }
            return tokens.accessToken
        }
        refreshTask = task
        defer { refreshTask = nil }
        do { return try await task.value }
        catch { observe(error); throw error }
    }
    private func observe(_ error: Error) {
        if let failure = error as? SubscriptionError, failure.requiresSignIn { reauthenticationRequired = true }
    }
    func refreshModels() async {
        guard !busy else { return }
        loadingModels = true; issue = nil
        defer { loadingModels = false }
        do { models = try await api.models(accessToken: validAccessToken()) }
        catch { observe(error); issue = error.localizedDescription }
    }
    func disconnect() {
        guard !busy else { return }
        do {
            var next = SubscriptionVault(); next.hostID = vault.hostID
            try save(next); models = []; reauthenticationRequired = false; issue = nil; testResult = nil
        } catch { issue = error.localizedDescription }
    }
    // summary asks for a readable thinking summary; if the model rejects it before
    // sending anything, the request is repeated once without it.
    func stream(request: ChatRequest, model: String, effort: SubscriptionEffort, summary: Bool = false,
                onProgress: @escaping @MainActor (ChatStreamProgress) -> Void,
                onEvent: @escaping @MainActor (StreamEvent) -> Void) async throws {
        guard connected && !reauthenticationRequired else { throw SubscriptionError.notConnected }
        guard planAllowed else { throw SubscriptionError.planPermission }
        guard includedUsageConfirmed else { throw SubscriptionError.creditsNotConfirmed }
        guard !signingIn else { throw SubscriptionError.notConnected }
        requestCount += 1; defer { requestCount -= 1 }
        let access = try await validAccessToken()
        try Task.checkCancellation()
        if models.isEmpty { models = try await api.models(accessToken: access) }
        try Task.checkCancellation()
        guard models.contains(where: { $0.slug == model }) else { throw SubscriptionError.modelUnavailable }
        let asksSummary = summary && !summaryRefused
        let received = ReceivedFlag()
        do {
            try await api.stream(SubscriptionRequest(request: request, model: model, effort: effort, summary: asksSummary), accessToken: access,
                                 onProgress: onProgress) { event in received.value = true; onEvent(event) }
        } catch SubscriptionError.service(_, 400) where asksSummary && !received.value {
            summaryRefused = true
            do { try await api.stream(SubscriptionRequest(request: request, model: model, effort: effort), accessToken: access, onProgress: onProgress, onEvent: onEvent) }
            catch { observe(error); throw error }
        } catch { observe(error); throw error }
    }
    func test(model: String) async {
        guard ready, !busy else { return }
        testing = true; issue = nil; testResult = nil
        defer { testing = false }
        var settings = AppSettings(); settings.systemPrompt = "只回复：连接成功"
        let request = ChatRequest(settings: settings, messages: [ChatMessage(role: .user, content: "请确认连接。")])
        var answer = ""
        do {
            try await stream(request: request, model: model, effort: .automatic, onProgress: { _ in }) { answer += $0.content }
            testResult = "\(model) 已返回完整回答：\(String(answer.prefix(80)))"
        } catch { issue = error.localizedDescription }
    }
}

@MainActor private final class ReceivedFlag { var value = false }
