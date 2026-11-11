import Foundation

struct APIMessage: Encodable, Equatable, Sendable {
    let role: String
    let content: String
    // Data URLs. With pictures the content goes out as OpenAI-style blocks.
    let images: [String]
    // Only within one answer that uses tools: the model's calls, the app's
    // results, and the thinking DeepSeek needs back while tools are in use.
    var toolCalls: [ToolCall]?
    var toolCallID: String?
    var reasoningContent: String?
    // Opaque Responses continuation items, kept only within a tool round.
    var subscriptionItems: [JSONValue] = []
    init(role: String, content: String, images: [String] = []) {
        self.role = role
        self.content = content
        self.images = images
    }
    static func assistantCalls(_ calls: [ToolCall], content: String, reasoning: String, subscriptionItems: [JSONValue] = []) -> APIMessage {
        var message = APIMessage(role: "assistant", content: content)
        message.toolCalls = calls
        message.subscriptionItems = subscriptionItems
        if !reasoning.isEmpty { message.reasoningContent = reasoning }
        return message
    }
    static func toolResult(_ text: String, callID: String) -> APIMessage {
        var message = APIMessage(role: "tool", content: text)
        message.toolCallID = callID
        return message
    }
    private enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case reasoningContent = "reasoning_content"
    }
    private struct Block: Encodable {
        let type: String
        var text: String?
        var imageURL: ImageURL?
        struct ImageURL: Encodable { let url: String }
        enum CodingKeys: String, CodingKey { case type, text; case imageURL = "image_url" }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
        guard !images.isEmpty else { try container.encode(content, forKey: .content); return }
        var blocks = [Block(type: "text", text: content)]
        blocks.append(contentsOf: images.map { Block(type: "image_url", imageURL: Block.ImageURL(url: $0)) })
        try container.encode(blocks, forKey: .content)
    }
}

struct ChatRequest: Encodable, Sendable {
    // Conservative UTF-8 payload ceiling, not an exact tokenizer estimate.
    // Keep ample room inside the provider's 1M-token context for output.
    static let contextByteBudget = 512000
    // Pictures are re-uploaded with every request, so only the latest few travel.
    static let imageMessageLimit = 4
    let model: String
    private(set) var messages: [APIMessage]
    let stream = true
    let streamOptions = StreamOptions()
    let thinking: Thinking
    let reasoningEffort: String?
    let maxTokens: Int
    // Set only for projects with tools switched on.
    private(set) var tools: [ToolSpec]?
    private(set) var toolChoice: String?

    var diagnosticSummary: String {
        "思考：\(thinking.type)\n档位：\(reasoningEffort ?? "关闭")\n消息数：\(messages.count)\n输入字节：\(messages.reduce(0) { $0 + $1.content.utf8.count })\n图片：\(messages.reduce(0) { $0 + $1.images.count }) 张\n输出上限：\(maxTokens)"
    }
    struct Thinking: Encodable, Sendable { let type: String }
    struct StreamOptions: Encodable, Sendable {
        let includeUsage = true
        enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
    }
    enum CodingKeys: String, CodingKey {
        case model, messages, stream, thinking
        case streamOptions = "stream_options"
        case reasoningEffort = "reasoning_effort"
        case maxTokens = "max_tokens"
        case tools
        case toolChoice = "tool_choice"
    }
    func withTools(_ specs: [ToolSpec]) -> ChatRequest {
        var copy = self
        copy.tools = specs.isEmpty ? nil : specs
        return copy
    }
    /// Puts a note before the newest user message, for this request only (not stored).
    func prefixingLastUserMessage(_ note: String) -> ChatRequest {
        guard let index = messages.lastIndex(where: { $0.role == "user" }) else { return self }
        var copy = self
        let original = copy.messages[index]
        copy.messages[index] = APIMessage(role: "user", content: note + "\n" + original.content, images: original.images)
        return copy
    }
    func withBookMaterial(_ material: String) -> ChatRequest {
        var copy = prefixingLastUserMessage(material)
        while copy.messages.reduce(0, { $0 + $1.content.utf8.count + ($1.reasoningContent?.utf8.count ?? 0) }) > Self.contextByteBudget,
              let last = copy.messages.lastIndex(where: { $0.role == "user" }),
              let first = copy.messages.firstIndex(where: { $0.role != "system" }), first < last {
            copy.messages.remove(at: first)
        }
        while let first = copy.messages.firstIndex(where: { $0.role != "system" }), copy.messages[first].role == "assistant" {
            copy.messages.remove(at: first)
        }
        return copy
    }

    func appending(_ more: [APIMessage]) -> ChatRequest {
        var copy = self
        copy.messages.append(contentsOf: more)
        return copy
    }
    // The last round of a tool chain must write the answer instead of calling again.
    // ("none" is allowed in thinking mode; "required" and named tools are not.)
    func answeringWithoutTools() -> ChatRequest {
        var copy = self
        if copy.tools != nil { copy.toolChoice = "none" }
        return copy
    }
    func addingWebContext(_ context: String) -> ChatRequest {
        var copy = self
        copy.messages.append(APIMessage(role: "user", content: context))
        return copy
    }

    // imageLoader turns a stored picture name into a data URL; nil sends text only.
    // systemPrompt replaces the settings' prompt, e.g. a project's instructions and documents.
    // includeReasoning sends earlier DeepSeek thinking back, which DeepSeek expects
    // when a request carries tools; without tools it would only cost upload time.
    init(settings: AppSettings, messages: [ChatMessage], imageLoader: ((String) -> String?)? = nil, systemPrompt: String? = nil,
         includeReasoning: Bool = false) {
        var config = settings.validated()
        if let systemPrompt { config.systemPrompt = systemPrompt }
        model = config.model.rawValue
        thinking = Thinking(type: config.thinkingEnabled ? "enabled" : "disabled")
        reasoningEffort = config.thinkingEnabled ? config.effort.rawValue : nil
        maxTokens = config.maxOutputTokens
        // Failed/unfinished answers remain visible locally, but do not masquerade
        // as complete assistant responses in subsequent API calls.
        var history = messages.filter {
            !$0.content.isEmpty && ($0.role == .user || $0.state == .complete)
        }
        history = Array(history.suffix(config.contextMessageLimit))
        func reasoning(of message: ChatMessage) -> String? {
            guard includeReasoning, message.role == .assistant, message.provider != .chatGPT, !message.reasoning.isEmpty else { return nil }
            return message.reasoning
        }
        func bytes(of message: ChatMessage) -> Int { message.content.utf8.count + (reasoning(of: message)?.utf8.count ?? 0) }
        var contentBytes = config.systemPrompt.utf8.count + history.reduce(0) { $0 + bytes(of: $1) }
        while contentBytes > Self.contextByteBudget && history.count > 1 {
            contentBytes -= bytes(of: history.removeFirst())
        }
        while history.first?.role == .assistant { history.removeFirst() }
        var outgoing: [APIMessage] = []
        if !config.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            outgoing.append(APIMessage(role: "system", content: config.systemPrompt))
        }
        let withPictures = history.filter { $0.role == .user && !($0.images ?? []).isEmpty }
        let pictureIDs = Set(withPictures.suffix(Self.imageMessageLimit).map(\.id))
        for message in history {
            var urls: [String] = []
            if let imageLoader, pictureIDs.contains(message.id) {
                urls = (message.images ?? []).compactMap { imageLoader($0) }
            }
            var item = APIMessage(role: message.role.rawValue, content: message.content, images: urls)
            item.reasoningContent = reasoning(of: message)
            outgoing.append(item)
        }
        self.messages = outgoing
    }
}

struct StreamEvent: Equatable, Sendable {
    var content = ""
    var reasoning = ""
    var usage: TokenUsage?
    var finishReason: String?
    var isDone = false
    var toolCalls: [ToolCallDelta] = []
    var subscriptionItems: [JSONValue] = []
}

// Reads SSE events, including comments, CRLF and multi-line data fields.
// The network transport must preserve empty lines: they delimit SSE events.
struct SSEDecoder {
    private var dataLines: [String] = []
    mutating func consume(line rawLine: String) throws -> StreamEvent? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty { return try flush() }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            dataLines.append(value)
        }
        return nil
    }
    mutating func flush() throws -> StreamEvent? {
        guard !dataLines.isEmpty else { return nil }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        if payload.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            return StreamEvent(isDone: true)
        }
        guard let data = payload.data(using: .utf8) else { throw ChatError.malformedStream }
        let chunk: APIChunk
        do { chunk = try JSONDecoder().decode(APIChunk.self, from: data) }
        catch { throw ChatError.malformedStream }
        if chunk.error != nil { throw ChatError.server("DeepSeek 在生成过程中返回错误，请重试。") }
        guard chunk.choices != nil || chunk.usage != nil else { throw ChatError.malformedStream }
        let choice = chunk.choices?.first
        return StreamEvent(content: choice?.delta?.content ?? "",
                           reasoning: choice?.delta?.reasoningContent ?? "",
                           usage: chunk.usage, finishReason: choice?.finishReason,
                           toolCalls: choice?.delta?.toolCalls ?? [])
    }
    private struct APIChunk: Decodable {
        let choices: [Choice]?
        let usage: TokenUsage?
        let error: APIError?
        struct APIError: Decodable { let message: String? }
        struct Choice: Decodable {
            let delta: Delta?
            let finishReason: String?
            enum CodingKeys: String, CodingKey { case delta; case finishReason = "finish_reason" }
        }
        struct Delta: Decodable {
            let content: String?
            let reasoningContent: String?
            let toolCalls: [ToolCallDelta]?
            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
            }
        }
    }
}

// Split the original bytes ourselves. Text-line adapters may omit the empty
// lines that separate events, joining several JSON chunks into one payload.
// Decode UTF-8 only after a whole line arrives, so split Chinese scalars are safe.
struct SSEByteDecoder {
    private var decoder = SSEDecoder()
    private var lineBytes: [UInt8] = []
    private var skipNextLF = false
    private var firstLine = true

    mutating func consume(byte: UInt8) throws -> StreamEvent? {
        if skipNextLF {
            skipNextLF = false
            if byte == 0x0A { return nil }
        }
        if byte == 0x0D {
            skipNextLF = true
            return try consumeLine()
        }
        if byte == 0x0A { return try consumeLine() }
        lineBytes.append(byte)
        return nil
    }

    mutating func finish() throws -> StreamEvent? {
        if !lineBytes.isEmpty, let event = try consumeLine() { return event }
        return try decoder.flush()
    }

    private mutating func consumeLine() throws -> StreamEvent? {
        guard var line = String(bytes: lineBytes, encoding: .utf8) else {
            throw ChatError.malformedStream
        }
        lineBytes.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
        }
        return try decoder.consume(line: line)
    }
}
