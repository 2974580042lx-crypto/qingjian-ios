import Foundation
import CryptoKit
import JWTKit

// Ported from 研习 (StudyDesk). Signing in uses OpenAI's own "Sign in with ChatGPT"
// flow; answers come from the Responses endpoint and count against the plan, not money.
enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case deepSeek, chatGPT, colab
    var id: String { rawValue }
    var title: String { self == .colab ? "Colab" : (self == .deepSeek ? "DeepSeek" : "ChatGPT 订阅") }
}

enum SubscriptionEffort: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, low, medium, high
    var id: String { rawValue }
    var title: String {
        switch self { case .automatic: return "Auto"; case .low: return "Low"; case .medium: return "Medium"; case .high: return "High" }
    }
}

struct SubscriptionModel: Codable, Equatable, Identifiable, Sendable {
    static let fallbackSlug = "gpt-5.6-sol"
    let slug: String
    let displayName: String
    var id: String { slug }
    static func catalog(_ data: Data) throws -> [Self] {
        struct Entry: Decodable { let slug: String; let display_name: String; let visibility: String? }
        struct Catalog: Decodable { let models: [Entry] }
        let entries = try JSONDecoder().decode(Catalog.self, from: data).models
        var seen = Set<String>()
        return entries.filter { $0.visibility == "list" && seen.insert($0.slug).inserted }
            .filter { !$0.slug.isEmpty && $0.slug.count <= 200 && !$0.display_name.isEmpty }
            .map { Self(slug: $0.slug, displayName: $0.display_name) }
    }
}

enum SubscriptionError: LocalizedError, Equatable {
    case notConnected, planPermission, creditsNotConfirmed, modelUnavailable
    case invalidCallback, invalidIdentity, identityUnavailable, incomplete, malformed, cancelled, timeout, storage(Int)
    case service(String, Int)
    var errorDescription: String? {
        switch self {
        case .notConnected: return "请先在设置里登录 ChatGPT。"
        case .planPermission: return "账号已登录，但尚未允许 Sermo 使用 ChatGPT 套餐。请重新授权。"
        case .creditsNotConfirmed: return "请先在设置里确认已关闭额外 credits 使用。"
        case .modelUnavailable: return "当前账号没有返回这个模型，请刷新列表后重新选择。"
        case .invalidCallback: return "登录结果与本次请求不匹配，请重新登录。"
        case .invalidIdentity: return "无法验证登录身份，请重新登录。"
        case .identityUnavailable: return "暂时无法核验 OpenAI 身份，已保留连接信息，请稍后重试。"
        case .incomplete: return "回答尚未完成时连接中断，收到的内容已保留。"
        case .malformed: return "订阅服务返回了无法解析的数据，收到的内容已保留。"
        case .cancelled: return "已取消登录。"
        case .timeout: return "登录等待已超时，请重新开始。"
        case .storage(let code): return "手机钥匙串暂不可用（\(code)），请确认签名正常并解锁后重试。"
        case .service(let code, let status):
            switch code {
            case "subscription_sharing_usage_limit_exceeded", "insufficient_quota": return "ChatGPT 订阅可用额度已用完。请查看用量或等待额度恢复。"
            case "subscription_sharing_usage_unavailable": return "当前暂不能使用 ChatGPT 订阅额度，请查看套餐用量与授权设置。"
            case "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused": return "ChatGPT 登录已失效，请重新登录。"
            case "access_denied": return "本次授权未完成，你可以重新登录。"
            case "model_not_found", "model_not_supported": return "当前订阅暂不支持这个模型，请刷新模型列表。"
            default:
                if status == 401 { return "ChatGPT 登录已失效，请重新登录。" }
                if status == 429 { return "ChatGPT 请求暂时受限，请查看用量并稍后重试。" }
                return "ChatGPT 请求未完成（HTTP \(status)），请稍后重试。"
            }
        }
    }
    var requiresSignIn: Bool {
        if case .service(let code, let status) = self {
            return status == 401 || ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"].contains(code)
        }
        return self == .invalidIdentity
    }
    static func response(_ data: Data, status: Int) -> Self {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = root?["error"] as? [String: Any]
        let code = (error?["code"] as? String) ?? (error?["type"] as? String) ?? (root?["error"] as? String) ?? "unknown"
        return .service(code, status)
    }
}

struct SubscriptionTransaction: Sendable {
    let state: String
    let nonce: String
    let verifier: String
    let redirectURI: String
    var challenge: String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URL }
    func authorizationURL(endpoint: URL, hostID: String, clientID: String?, idTokenHint: String?, reconsent: Bool = false) -> URL {
        var values = ["client_id": clientID ?? "dynamic_agent_client", "response_type": "code", "redirect_uri": redirectURI,
                      "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
                      "resource": "https://api.openai.com/v1", "state": state, "nonce": nonce,
                      "code_challenge_method": "S256", "code_challenge": challenge, "ext_agent_host_id": hostID]
        if clientID == nil { values["agent_name_hint"] = "Sermo" }
        else if let hint = idTokenHint { values["id_token_hint"] = hint }
        if reconsent { values["prompt"] = "consent" }
        var url = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        url.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }
    func validateCallback(_ url: URL, savedClientID: String?) throws -> (code: String, clientID: String) {
        guard let expected = URLComponents(string: redirectURI), let actual = URLComponents(url: url, resolvingAgainstBaseURL: false),
              actual.scheme == expected.scheme, actual.host == expected.host, actual.port == expected.port,
              actual.path == expected.path, actual.user == nil, actual.password == nil, actual.fragment == nil else { throw SubscriptionError.invalidCallback }
        let query = actual.queryItems ?? []
        func single(_ key: String) throws -> String? {
            let entries = query.filter { $0.name == key }
            guard entries.count <= 1 else { throw SubscriptionError.invalidCallback }
            return entries.first?.value
        }
        guard try single("state") == state else { throw SubscriptionError.invalidCallback }
        if let error = try single("error") { throw SubscriptionError.service(error, 400) }
        guard let code = try single("code"), !code.isEmpty, code.count < 16000,
              let client = try single("client_id") ?? savedClientID,
              client != "dynamic_agent_client", client.range(of: "^[A-Za-z0-9_-]{1,200}$", options: .regularExpression) != nil,
              savedClientID == nil || savedClientID == client else { throw SubscriptionError.invalidCallback }
        return (code, client)
    }
}

extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URL: String) {
        let s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: s + String(repeating: "=", count: (4 - s.count % 4) % 4))
    }
}

struct SubscriptionIdentity: Equatable, Sendable { let subject: String; let email: String?; let name: String? }

enum SubscriptionJWT {
    struct Audience: Codable {
        let values: [String]
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let single = try? c.decode(String.self) { values = [single] } else { values = try c.decode([String].self) }
        }
        func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(values) }
    }
    struct Claims: JWTPayload {
        let iss: String; let sub: String; let aud: Audience; let exp: Double; let iat: Double
        let nonce: String?; let azp: String?; let nbf: Double?; let email: String?; let name: String?
        func verify(using signer: JWTSigner) throws {
            guard iss == "https://auth.openai.com", !sub.isEmpty else { throw SubscriptionError.invalidIdentity }
        }
    }
    static func verify(_ token: String, jwks: Data, clientID: String, nonce: String?, expectedSubject: String? = nil, now: Date = Date()) throws -> SubscriptionIdentity {
        guard token.utf8.count < 128000, jwks.count < 512000 else { throw SubscriptionError.invalidIdentity }
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3, let headerData = Data(base64URL: String(pieces[0])),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", header["crit"] == nil,
              let kid = header["kid"] as? String, !kid.isEmpty,
              let keys = (try JSONSerialization.jsonObject(with: jwks) as? [String: Any])?["keys"] as? [[String: Any]] else { throw SubscriptionError.invalidIdentity }
        let matching = keys.filter { key in
            key["kid"] as? String == kid && key["kty"] as? String == "RSA"
                && (key["alg"] == nil || key["alg"] as? String == "RS256")
                && (key["use"] == nil || key["use"] as? String == "sig")
                && (key["key_ops"] == nil || (key["key_ops"] as? [String])?.contains("verify") == true)
        }
        guard matching.count == 1 else { throw SubscriptionError.identityUnavailable }
        let signers = JWTSigners()
        try signers.use(jwksJSON: String(decoding: JSONSerialization.data(withJSONObject: ["keys": matching]), as: UTF8.self))
        let claims: Claims
        do { claims = try signers.verify(token, as: Claims.self) } catch { throw SubscriptionError.invalidIdentity }
        let seconds = now.timeIntervalSince1970
        guard claims.exp.isFinite, claims.iat.isFinite, claims.exp > seconds - 5, claims.iat <= seconds + 5,
              claims.nbf == nil || claims.nbf! <= seconds + 5, claims.aud.values.contains(clientID),
              claims.azp == nil || claims.azp == clientID,
              claims.aud.values.count <= 1 || claims.azp == clientID,
              nonce == nil || claims.nonce == nonce,
              expectedSubject == nil || claims.sub == expectedSubject else { throw SubscriptionError.invalidIdentity }
        return .init(subject: claims.sub, email: claims.email, name: claims.name)
    }
}

// One Responses input item. Pictures travel as input_image blocks, not the chat-completions shape.
struct ResponsesInput: Encodable, Equatable, Sendable {
    let role: String
    let content: String
    let images: [String]
    var raw: JSONValue?
    init(_ message: APIMessage) { role = message.role; content = message.content; images = message.images }
    private enum CodingKeys: String, CodingKey { case role, content }
    private struct Block: Encodable {
        let type: String
        var text: String?
        var image_url: String?
    }
    func encode(to encoder: Encoder) throws {
        if let raw { try raw.encode(to: encoder); return }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        guard !images.isEmpty, role == "user" else { try c.encode(content, forKey: .content); return }
        try c.encode([Block(type: "input_text", text: content)] + images.map { Block(type: "input_image", image_url: $0) }, forKey: .content)
    }
    static func items(_ message: APIMessage) -> [Self] {
        func item(_ value: JSONValue) -> Self { var input = Self(message); input.raw = value; return input }
        if message.role == "tool", let id = message.toolCallID {
            return [item(.object(["type": .string("function_call_output"), "call_id": .string(id), "output": .string(message.content)]))]
        }
        var result = message.subscriptionItems.map(item)
        if let calls = message.toolCalls, !calls.isEmpty {
            if !message.content.isEmpty { result.append(Self(message)) }
            result += calls.map { call in item(.object([
                "type": .string("function_call"), "namespace": .string("study"), "call_id": .string(call.id),
                "name": .string(call.name), "arguments": .string(call.arguments)
            ])) }
        } else { result.append(Self(message)) }
        return result
    }
}

struct SubscriptionRequest: Encodable, Sendable {
    let model: String
    let instructions: String
    let input: [ResponsesInput]
    let store = false
    let stream = true
    let reasoning: Reasoning?
    let tools: [Namespace]?
    let tool_choice: String?
    struct Namespace: Encodable, Sendable {
        let type = "namespace"
        let name = "study"
        let description = "Tools for this study project."
        let tools: [Function]
    }
    struct Function: Encodable, Sendable {
        let type = "function"
        let name: String
        let description: String
        let parameters: JSONValue
        let strict = false
    }
    struct Reasoning: Encodable, Sendable {
        let effort: String?
        // "auto" asks for a readable summary of the thinking, shown in the thinking panel.
        let summary: String?
    }
    init(request: ChatRequest, model: String, effort: SubscriptionEffort = .automatic, summary: Bool = false) {
        self.model = model
        instructions = request.messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        input = request.messages.filter { $0.role == "user" || $0.role == "assistant" || $0.role == "tool" }.flatMap(ResponsesInput.items)
        tools = request.tools.map { [Namespace(tools: $0.map { Function(name: $0.name, description: $0.description, parameters: $0.parameters) })] }
        tool_choice = request.toolChoice
        let level = effort == .automatic ? nil : effort.rawValue
        reasoning = level == nil && !summary ? nil : Reasoning(effort: level, summary: summary ? "auto" : nil)
    }
}

struct ResponsesStreamDecoder {
    private var lineBytes = Data()
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var afterCR = false
    private var firstLine = true
    private(set) var completed = false
    private var functionIndices: Set<Int> = []
    mutating func consume(_ byte: UInt8) throws -> StreamEvent? {
        if afterCR { afterCR = false; if byte == 10 { return nil } }
        if byte == 13 || byte == 10 {
            afterCR = byte == 13
            guard var line = String(data: lineBytes, encoding: .utf8) else { throw SubscriptionError.malformed }
            lineBytes.removeAll(keepingCapacity: true)
            if firstLine { firstLine = false; if line.hasPrefix("\u{FEFF}") { line.removeFirst() } }
            if line.isEmpty { return try flush() }
            if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5)); if value.hasPrefix(" ") { value.removeFirst() }
                eventBytes += value.utf8.count
                guard eventBytes <= 4 * 1024 * 1024 else { throw SubscriptionError.malformed }
                dataLines.append(value)
            }
        } else {
            lineBytes.append(byte)
            guard lineBytes.count <= 4 * 1024 * 1024 else { throw SubscriptionError.malformed }
        }
        return nil
    }
    mutating func finish() throws -> StreamEvent? {
        if !lineBytes.isEmpty { _ = try consume(10) }
        return try flush()
    }
    private mutating func flush() throws -> StreamEvent? {
        guard !dataLines.isEmpty else { return nil }
        let data = Data(dataLines.joined(separator: "\n").utf8)
        dataLines.removeAll(keepingCapacity: true); eventBytes = 0
        if data == Data("[DONE]".utf8) { return nil }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = object["type"] as? String else { throw SubscriptionError.malformed }
        switch type {
        case "response.output_item.added":
            guard let item = object["item"] as? [String: Any], item["type"] as? String == "function_call" else { return nil }
            guard let index = object["output_index"] as? Int, let id = item["call_id"] as? String,
                  let name = item["name"] as? String, item["namespace"] as? String == "study",
                  !functionIndices.contains(index) else { throw SubscriptionError.malformed }
            functionIndices.insert(index)
            return StreamEvent(toolCalls: [.init(index: index, id: id, name: name, arguments: item["arguments"] as? String ?? "")])
        case "response.function_call_arguments.delta":
            guard let index = object["output_index"] as? Int, functionIndices.contains(index), let delta = object["delta"] as? String else { throw SubscriptionError.malformed }
            return StreamEvent(toolCalls: [.init(index: index, arguments: delta)])
        case "response.output_item.done":
            guard let item = object["item"] as? [String: Any], item["type"] as? String == "reasoning" else { return nil }
            let value = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: item))
            return StreamEvent(subscriptionItems: [value])
        case "response.output_text.delta": return StreamEvent(content: object["delta"] as? String ?? "")
        case "response.reasoning_summary_text.delta": return StreamEvent(reasoning: object["delta"] as? String ?? "")
        // Each summary part is its own paragraph in the thinking panel.
        case "response.reasoning_summary_part.added":
            return (object["summary_index"] as? Int ?? 0) > 0 ? StreamEvent(reasoning: "\n\n") : nil
        case "response.failed", "error":
            let failure = (object["response"] as? [String: Any]) ?? object
            throw SubscriptionError.response(try JSONSerialization.data(withJSONObject: failure), status: 200)
        case "response.incomplete": throw SubscriptionError.incomplete
        case "response.completed":
            let response = object["response"] as? [String: Any]
            guard response?["status"] as? String == "completed" else { throw SubscriptionError.incomplete }
            var usage: TokenUsage?
            if let u = response?["usage"] as? [String: Any], let input = u["input_tokens"] as? Int, let output = u["output_tokens"] as? Int {
                let details = u["input_tokens_details"] as? [String: Any]
                let cached = (details?["cached_tokens"] as? Int) ?? 0
                usage = TokenUsage(promptTokens: input, completionTokens: output, cachedTokens: cached)
            }
            completed = true
            return StreamEvent(usage: usage, finishReason: "stop", isDone: true)
        default: return nil
        }
    }
}
