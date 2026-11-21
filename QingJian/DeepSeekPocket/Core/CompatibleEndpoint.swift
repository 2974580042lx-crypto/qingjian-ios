import Foundation

/// Presets for the "Other Models (OpenAI-Compatible)" settings drawer.
enum CompatiblePresetID: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI = "openai"
    case anthropic = "anthropic"
    case gemini = "gemini"
    case local = "local"
    case custom = "custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic (Claude)"
        case .gemini: return "Google Gemini"
        case .local: return "局域网 / 本地模型"
        case .custom: return "自定义兼容端点"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .local: return "http://localhost:11434/v1"
        case .custom: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-4o"
        case .anthropic: return "claude-sonnet-4-20250514"
        case .gemini: return "gemini-2.5-flash"
        case .local: return "qwen2.5:14b"
        case .custom: return ""
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .openAI: return "sk-..."
        case .anthropic: return "sk-ant-..."
        case .gemini: return "AIza..."
        case .local: return "本地服务一般可留空"
        case .custom: return "Bearer API Key（可选）"
        }
    }
}

struct CompatiblePresetConfig: Codable, Equatable, Sendable {
    var baseURL: String
    var model: String
}

enum CompatibleEndpointError: LocalizedError, Equatable {
    case configuration(String)
    case invalidKey
    case unauthorized
    case rateLimited
    case http(Int)
    case response
    case offline

    var errorDescription: String? {
        switch self {
        case .configuration(let msg): return msg
        case .invalidKey: return "API Key 包含换行或无效字符，请重新粘贴。"
        case .unauthorized: return "API Key 未通过验证（HTTP 401/403），请检查密钥与端点权限。"
        case .rateLimited: return "兼容接口请求受限（HTTP 429），请稍后重试。"
        case .http(let status): return "兼容接口返回错误（HTTP \(status)），请检查地址与模型名称。"
        case .response: return "兼容接口返回了无法识别的数据格式，请确认该地址支持 OpenAI Chat Completions 协议。"
        case .offline: return "兼容接口连接中断或未响应，请检查网络与接口地址。"
        }
    }

    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw Self.response }
        switch http.statusCode {
        case 200...299: return
        case 401, 403: throw Self.unauthorized
        case 429: throw Self.rateLimited
        default: throw Self.http(http.statusCode)
        }
    }
}

struct CompatibleEndpointConfig: Codable, Equatable, Sendable {
    var activePreset: CompatiblePresetID = .openAI
    var presets: [String: CompatiblePresetConfig] = [:]
    var toolsEnabled: Bool? = true

    var allowsTools: Bool { toolsEnabled != false }

    func settings(for preset: CompatiblePresetID) -> CompatiblePresetConfig {
        presets[preset.rawValue] ?? CompatiblePresetConfig(baseURL: preset.defaultBaseURL, model: preset.defaultModel)
    }

    mutating func set(_ config: CompatiblePresetConfig, for preset: CompatiblePresetID) {
        presets[preset.rawValue] = config
        activePreset = preset
    }

    var activeSettings: CompatiblePresetConfig { settings(for: activePreset) }
    var activeModel: String { activeSettings.model.trimmingCharacters(in: .whitespacesAndNewlines) }

    func validatedURL(for preset: CompatiblePresetID? = nil) throws -> URL {
        let target = settings(for: preset ?? activePreset)
        let address = target.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let modelName = target.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelName.isEmpty else {
            throw CompatibleEndpointError.configuration("请填写模型名称。")
        }
        guard let parts = URLComponents(string: address),
              let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              let url = parts.url else {
            throw CompatibleEndpointError.configuration("请填写有效的 Base URL（如 https://api.openai.com/v1）。")
        }
        if scheme == "https" {
            return url
        }
        if scheme == "http" && Self.isLocalHost(host) {
            return url
        }
        throw CompatibleEndpointError.configuration("远程接口请使用 HTTPS；HTTP 仅限 localhost 或局域网地址。")
    }

    static func isLocalHost(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") { return true }
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") { return true }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return false
    }
}

/// Lightweight OpenAI-compatible SSE client for OpenAI, Anthropic OpenAI-compat, Gemini, Ollama, and custom endpoints.
final class CompatibleEndpointClient: @unchecked Sendable {
    private let baseURL: URL
    private let model: String
    private let key: String
    private let toolsEnabled: Bool

    init(baseURL: URL, model: String, key: String, toolsEnabled: Bool = true) {
        self.baseURL = baseURL
        self.model = model
        self.key = key
        self.toolsEnabled = toolsEnabled
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 3600
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: CompatibleRedirectDelegate(), delegateQueue: nil)
    }

    private func request(_ url: URL, body: [String: Any]? = nil) throws -> URLRequest {
        guard !key.contains("\n"), !key.contains("\r") else { throw CompatibleEndpointError.invalidKey }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 180)
        if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if url.host?.lowercased() == "api.anthropic.com" {
                req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            }
        }
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    func probe() async throws {
        let url = baseURL.appendingPathComponent("models")
        let session = session()
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request(url))
        try CompatibleEndpointError.validate(response)
    }

    func stream(
        _ chatRequest: ChatRequest,
        onProgress: (@MainActor (ChatStreamProgress) -> Void)? = nil,
        onEvent: @escaping @MainActor (StreamEvent) -> Void
    ) async throws {
        let url = baseURL.appendingPathComponent("chat/completions")
        guard var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(chatRequest)) as? [String: Any] else {
            throw CompatibleEndpointError.response
        }
        body["model"] = model
        body.removeValue(forKey: "thinking")
        body.removeValue(forKey: "reasoning_effort")
        if !toolsEnabled {
            body.removeValue(forKey: "tools")
            body.removeValue(forKey: "tool_choice")
        }

        var req = try request(url, body: body)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let session = session()
        defer { session.invalidateAndCancel() }

        let started = ProcessInfo.processInfo.systemUptime
        var lastTick = started
        var progress = ChatStreamProgress(phase: .connecting, elapsedSeconds: 0, receivedBytes: 0, httpStatus: nil)
        await onProgress?(progress)

        let (bytes, response) = try await session.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var errorText = ""
            for try await line in bytes.lines {
                errorText += line
                if errorText.count > 1024 { break }
            }
            if !errorText.isEmpty {
                throw CompatibleEndpointError.configuration("兼容接口返回 HTTP \(http.statusCode)：\(errorText.prefix(200))")
            }
            try CompatibleEndpointError.validate(response)
        }
        try CompatibleEndpointError.validate(response)

        progress.httpStatus = (response as? HTTPURLResponse)?.statusCode
        progress.phase = .waiting
        await onProgress?(progress)

        var decoder = SSEByteDecoder()
        var parser = ColabThoughtParser()
        var done = false, finished = false
        for try await byte in bytes {
            try Task.checkCancellation()
            progress.receivedBytes += 1
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastTick >= 1 {
                progress.elapsedSeconds = Int(now - started)
                await onProgress?(progress)
                lastTick = now
            }
            guard let raw = try decoder.consume(byte: byte) else { continue }
            let event = parser.consume(raw, finish: raw.isDone || raw.finishReason != nil)
            let previousPhase = progress.phase
            if !event.content.isEmpty { progress.phase = .answering }
            else if !event.reasoning.isEmpty && progress.phase != .answering { progress.phase = .thinking }
            if progress.phase != previousPhase {
                progress.elapsedSeconds = Int(ProcessInfo.processInfo.systemUptime - started)
                await onProgress?(progress)
            }
            await onEvent(event)
            finished = finished || raw.finishReason != nil
            if raw.isDone { done = true; break }
        }
        if !done, let trailing = try decoder.finish() {
            await onEvent(parser.consume(trailing, finish: true))
            done = trailing.isDone
            finished = finished || trailing.finishReason != nil
        }
        try Task.checkCancellation()
        guard done || finished else { throw CompatibleEndpointError.offline }
        await onEvent(parser.consume(StreamEvent(), finish: true))
        progress.phase = .complete
        progress.elapsedSeconds = Int(ProcessInfo.processInfo.systemUptime - started)
        await onProgress?(progress)
    }
}

private final class CompatibleRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let orig = task.originalRequest?.url
        let sameOrigin = request.url?.scheme?.lowercased() == orig?.scheme?.lowercased()
            && request.url?.host?.lowercased() == orig?.host?.lowercased()
        completionHandler(sameOrigin ? request : nil)
    }
}
