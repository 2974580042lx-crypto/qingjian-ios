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

struct CompatibleEndpointConfig: Codable, Equatable, Sendable {
    var activePreset: CompatiblePresetID = .openAI
    var presets: [String: CompatiblePresetConfig] = [:]

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
            throw ColabError.configuration("请填写模型名称。")
        }
        guard let parts = URLComponents(string: address),
              let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              let url = parts.url else {
            throw ColabError.configuration("请填写有效的 Base URL（如 https://api.openai.com/v1）。")
        }
        if scheme == "https" {
            return url
        }
        if scheme == "http" && Self.isLocalHost(host) {
            return url
        }
        throw ColabError.configuration("远程接口请使用 HTTPS；HTTP 仅限 localhost 或局域网地址。")
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

/// Lightweight OpenAI-compatible SSE client for OpenAI, Anthropic, Gemini, Ollama, and custom endpoints.
final class CompatibleEndpointClient: @unchecked Sendable {
    private let baseURL: URL
    private let model: String
    private let key: String

    init(baseURL: URL, model: String, key: String) {
        self.baseURL = baseURL
        self.model = model
        self.key = key
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }

    private func request(_ url: URL, body: [String: Any]? = nil) throws -> URLRequest {
        guard !key.contains("\n"), !key.contains("\r") else { throw ColabError.invalidKey }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
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
        try ColabError.validate(response)
    }

    func stream(
        _ chatRequest: ChatRequest,
        onProgress: (@MainActor (ChatStreamProgress) -> Void)? = nil,
        onEvent: @escaping @MainActor (StreamEvent) -> Void
    ) async throws {
        let url = baseURL.appendingPathComponent("chat/completions")
        var body: [String: Any] = [
            "model": model,
            "messages": chatRequest.messages.map(\.payload),
            "stream": true,
            "stream_options": ["include_usage": true]
        ]
        if let temp = chatRequest.temperature {
            body["temperature"] = temp
        }
        let req = try request(url, body: body)
        let session = session()
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var errorText = ""
            for try await line in bytes.lines {
                errorText += line
                if errorText.count > 1024 { break }
            }
            if !errorText.isEmpty {
                throw ColabError.configuration("接口返回 \(http.statusCode)：\(errorText.prefix(200))")
            }
            try ColabError.validate(response)
        }
        try ColabError.validate(response)

        if let onProgress { await onProgress(.receiving) }
        var lineBuffer = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            if byte == 0x0A {
                if let line = String(data: lineBuffer, encoding: .utf8) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("data:") {
                        let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let data = payload.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            try await emitEvents(from: json, onEvent: onEvent)
                        }
                    }
                }
                lineBuffer.removeAll(keepingCapacity: true)
            } else if byte != 0x0D {
                lineBuffer.append(byte)
            }
        }
        await onEvent(.done)
    }

    private func emitEvents(from json: [String: Any], onEvent: @escaping @MainActor (StreamEvent) -> Void) async throws {
        if let err = json["error"] as? [String: Any], let message = err["message"] as? String {
            throw ColabError.configuration(message)
        }
        if let usageDict = json["usage"] as? [String: Any] {
            let prompt = usageDict["prompt_tokens"] as? Int ?? 0
            let completion = usageDict["completion_tokens"] as? Int ?? 0
            let total = usageDict["total_tokens"] as? Int ?? (prompt + completion)
            await onEvent(.usage(TokenUsage(promptTokens: prompt, completionTokens: completion, totalTokens: total, cachedTokens: 0)))
        }
        guard let choices = json["choices"] as? [[String: Any]], let first = choices.first else { return }
        if let delta = first["delta"] as? [String: Any] {
            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                await onEvent(.reasoning(reasoning))
            }
            if let content = delta["content"] as? String, !content.isEmpty {
                await onEvent(.content(content))
            }
        }
    }
}
