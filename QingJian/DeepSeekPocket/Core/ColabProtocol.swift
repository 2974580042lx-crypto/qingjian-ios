import Foundation

struct ColabOptions: Codable, Equatable, Sendable {
    var thinking = false
    var context = 16384
    var tools = false
}

enum AuxiliaryProviderPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case follow, deepSeek
    var id: String { rawValue }
    var title: String { self == .follow ? "跟随当前聊天模型" : "固定用 DeepSeek" }
}

// Credentials are decoded from Drive, but only the non-secret configuration is persisted.
struct ColabEndpoint: Decodable, Sendable {
    let baseURL: String
    let apiKey: String
    let model: String
    let updatedAt: String
    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url", apiKey = "api_key", model, updatedAt = "updated_at"
    }
    var date: Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: updatedAt) ?? ISO8601DateFormatter().date(from: updatedAt)
    }
}

struct ColabConfiguration: Codable, Equatable, Sendable {
    var baseURL = ""
    var model = ""
    var updatedAt: Date?
    func url() throws -> URL {
        let address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let parts = URLComponents(string: address), parts.scheme == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.hasSuffix("/v1"),
              let url = parts.url, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ColabError.configuration("请填写带 /v1 的 HTTPS Base URL 和模型名。")
        }
        return url
    }
}

enum ColabError: LocalizedError {
    case offline, invalidKey, context, configuration(String), http(Int), response
    var errorDescription: String? {
        switch self {
        case .offline: return "Colab 未开机或已休眠"
        case .invalidKey: return "Colab API Key 未通过验证，请从 Drive 刷新或重新填写。"
        case .context: return "系统提示词、项目指令和当前问题超过 Colab 上下文，请缩短输入或提高最大上下文。"
        case .configuration(let text): return text
        case .http(let code): return "Colab 返回 HTTP \(code)，请核对模型名与接口配置。"
        case .response: return "Colab 返回的数据格式不正确。"
        }
    }
    static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw Self.response }
        switch response.statusCode {
        case 200...299: return
        case 401, 403: throw Self.invalidKey
        case 408, 502, 503, 504, 520...530: throw Self.offline
        default: throw Self.http(response.statusCode)
        }
    }
}

// A tag can end in the next SSE event. Hold only the possible delimiter prefix.
struct ColabThoughtParser {
    private var pending = ""
    private var thinking = false
    private var separateReasoning = false
    mutating func consume(_ input: StreamEvent, finish: Bool = false) -> StreamEvent {
        var output = input
        output.content = ""
        if !input.reasoning.isEmpty { separateReasoning = true }
        pending += input.content
        while !pending.isEmpty {
            let delimiter = thinking ? "</think>" : "<think>"
            if let range = pending.range(of: delimiter) {
                append(String(pending[..<range.lowerBound]), to: &output)
                pending.removeSubrange(..<range.upperBound)
                thinking.toggle()
            } else {
                var held = 0
                if !finish {
                    for length in 1..<delimiter.count where pending.hasSuffix(String(delimiter.prefix(length))) {
                        held = length
                    }
                }
                append(String(pending.dropLast(held)), to: &output)
                pending = held == 0 ? "" : String(pending.suffix(held))
                break
            }
        }
        return output
    }
    private func append(_ text: String, to event: inout StreamEvent) {
        if thinking {
            if !separateReasoning { event.reasoning += text }
        } else { event.content += text }
    }
}
