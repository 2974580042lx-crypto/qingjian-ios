import Foundation

// Tool calling for DeepSeek's chat completions (OpenAI-compatible format).
// The model only asks for a tool; the app decides whether and how to run it.

/// A small JSON value, enough to write a tool's parameter schema.
indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct ToolSpec: Encodable, Equatable, Sendable {
    let name: String
    let description: String
    let parameters: JSONValue
    private enum CodingKeys: String, CodingKey { case type, function }
    private struct Function: Encodable { let name: String; let description: String; let parameters: JSONValue }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("function", forKey: .type)
        try container.encode(Function(name: name, description: description, parameters: parameters), forKey: .function)
    }

    /// An object schema with string/integer/boolean properties: (name, type, description).
    static func object(_ properties: [(String, String, String)], required: [String]) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        for (name, type, description) in properties {
            fields[name] = .object(["type": .string(type), "description": .string(description)])
        }
        return .object(["type": .string("object"), "properties": .object(fields),
                        "required": .array(required.map { .string($0) })])
    }
}

/// One complete call the model asked for. `arguments` is the model's JSON text,
/// which may be invalid: each tool validates it before doing anything.
struct ToolCall: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let arguments: String
    private enum CodingKeys: String, CodingKey { case id, type, function }
    private struct Function: Codable { let name: String; let arguments: String }
    init(id: String, name: String, arguments: String) {
        self.id = id; self.name = name; self.arguments = arguments
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let function = try container.decode(Function.self, forKey: .function)
        name = function.name; arguments = function.arguments
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode("function", forKey: .type)
        try container.encode(Function(name: name, arguments: arguments), forKey: .function)
    }
    /// The arguments as a dictionary; an empty or blank string counts as `{}`.
    func argumentObject() throws -> [String: Any] {
        let text = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return [:] }
        guard text.utf8.count <= 400_000, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError.invalidArguments("参数不是有效的 JSON 对象。")
        }
        return object
    }
}

/// A piece of a tool call as it streams in. The first piece of each call
/// carries its id and name; later pieces carry more of the arguments.
struct ToolCallDelta: Decodable, Equatable, Sendable {
    let index: Int
    var id: String?
    var name: String?
    var arguments: String?
    private enum CodingKeys: String, CodingKey { case index, id, function }
    private struct Function: Decodable { let name: String?; let arguments: String? }
    init(index: Int, id: String? = nil, name: String? = nil, arguments: String? = nil) {
        self.index = index; self.id = id; self.name = name; self.arguments = arguments
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decodeIfPresent(Int.self, forKey: .index) ?? 0
        id = try container.decodeIfPresent(String.self, forKey: .id)
        let function = try container.decodeIfPresent(Function.self, forKey: .function)
        name = function?.name
        arguments = function?.arguments
    }
}

/// Joins streamed pieces into whole calls, in the order the model gave them.
struct ToolCallCollector: Sendable {
    private var parts: [Int: (id: String, name: String, arguments: String)] = [:]
    mutating func consume(_ deltas: [ToolCallDelta]) {
        for delta in deltas {
            var part = parts[delta.index] ?? ("", "", "")
            if let id = delta.id, !id.isEmpty { part.id = id }
            if let name = delta.name, !name.isEmpty { part.name += name }
            if let more = delta.arguments { part.arguments += more }
            parts[delta.index] = part
        }
    }
    /// Calls without a name are dropped; a missing id gets a stable stand-in.
    var calls: [ToolCall] {
        parts.keys.sorted().compactMap { index in
            guard let part = parts[index], !part.name.isEmpty else { return nil }
            return ToolCall(id: part.id.isEmpty ? "call_\(index)" : part.id, name: part.name, arguments: part.arguments)
        }
    }
}

enum ToolError: LocalizedError, Equatable {
    case invalidArguments(String), unknownTool(String), disabledTool(String)
    var errorDescription: String? {
        switch self {
        case .invalidArguments(let detail): return detail
        case .unknownTool(let name): return "没有名为 \(name) 的工具。"
        case .disabledTool(let name): return "当前项目未启用工具 \(name)，操作没有执行。"
        }
    }
}

/// Execution uses the same exact tool names as the request, and is checked
/// again after approval so a switch turned off while waiting takes effect.
struct ProjectToolAccess {
    private let names: Set<String>

    init(project: ChatProject?, provider: AIProvider, colabTools: Bool = false) {
        var specs: [ToolSpec] = []
        if provider == .deepSeek || (provider == .colab && colabTools) {
            if project?.usesDriveTools == true { specs += DriveTools.specs }
            if project?.usesGitHubTools == true { specs += GitHubTools.specs }
            if provider == .deepSeek, project?.usesWebTools == true { specs += WebTools.specs }
        }
        names = Set(specs.map(\.name))
    }

    func require(_ name: String) throws {
        guard names.contains(name) else { throw ToolError.disabledTool(name) }
    }
}

/// What a tool did, kept on the answer so the conversation shows it afterwards.
/// The tool's raw output is not kept: it only travels within that one answer.
struct ToolActivity: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case running, done, failed, declined, needsSignIn }
    var id: String
    var title: String
    var status: Status
    var detail: String?
    // "drive" or "github" (1.6.0); answers from 1.5.8 have none, which means Drive.
    var kind: String?
    // Trusted local excerpts, stored separately from model-written prose.
    var studyExcerpts: [StudyReadingExcerpt]? = nil
    var studyReport: StudyWeeklyReport? = nil
}

enum ToolLoop {
    /// Model requests per answer, tool rounds included. The last one is asked
    /// to answer without tools, so a long chain still ends in a reply.
    static let maxRounds = 8
    /// Longest tool result handed back to the model, in characters.
    static let resultCharacterLimit = 30_000

    static func clipped(_ text: String) -> String {
        guard text.count > resultCharacterLimit else { return text }
        return String(text.prefix(resultCharacterLimit)) + "\n\n（内容过长，只返回了前 \(resultCharacterLimit) 个字符。）"
    }
}

extension TokenUsage {
    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(promptTokens: lhs.promptTokens + rhs.promptTokens,
                   completionTokens: lhs.completionTokens + rhs.completionTokens,
                   cachedTokens: lhs.cachedTokens + rhs.cachedTokens)
    }
    /// The sum of two optional usages; nil only when both are nil.
    static func combined(_ lhs: TokenUsage?, _ rhs: TokenUsage?) -> TokenUsage? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return lhs + rhs
    }
}
