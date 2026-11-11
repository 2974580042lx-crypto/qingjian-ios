import Foundation

enum MessageRole: String, Codable, Sendable { case user, assistant }
enum MessageState: String, Codable, Sendable { case complete, streaming, stopped, failed }
enum DeepSeekModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case flash = "deepseek-flash"
    case pro = "deepseek-v4-pro"
    var id: String { rawValue }
    var title: String { self == .flash ? "Flash" : "V4 Pro" }
}
enum ThinkingEffort: String, Codable, CaseIterable, Identifiable, Sendable {
    case low, high, max
    var id: String { rawValue }
    var title: String {
        switch self { case .low: return "Low"; case .high: return "High"; case .max: return "Max" }
    }
}

struct TokenUsage: Codable, Equatable, Sendable {
    let promptTokens: Int
    let completionTokens: Int
    let cachedTokens: Int
    var totalTokens: Int { promptTokens + completionTokens }
    init(promptTokens: Int, completionTokens: Int, cachedTokens: Int = 0) {
        self.promptTokens = max(0, promptTokens)
        self.completionTokens = max(0, completionTokens)
        self.cachedTokens = min(max(0, cachedTokens), max(0, promptTokens))
    }
    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case cachedTokens = "prompt_cache_hit_tokens"
        case promptDetails = "prompt_tokens_details"
    }
    private struct PromptDetails: Decodable { let cached_tokens: Int? }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let prompt = try c.decode(Int.self, forKey: .promptTokens)
        let output = try c.decode(Int.self, forKey: .completionTokens)
        let cached = try c.decodeIfPresent(Int.self, forKey: .cachedTokens)
            ?? c.decodeIfPresent(PromptDetails.self, forKey: .promptDetails)?.cached_tokens ?? 0
        self.init(promptTokens: prompt, completionTokens: output, cachedTokens: cached)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(promptTokens, forKey: .promptTokens)
        try c.encode(completionTokens, forKey: .completionTokens)
        try c.encode(cachedTokens, forKey: .cachedTokens)
    }
}

struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var role: MessageRole
    var content = ""
    var reasoning = ""
    var createdAt = Date()
    var state: MessageState = .complete
    var usage: TokenUsage?
    var note: String?
    var isBookmarked: Bool?
    // The complete play state at this message, for a true rewind/branch.
    var storyState: StorySession?
    var reasoningTranslation: String?
    var translationUsage: TokenUsage?
    // File names of attached pictures; the image data lives beside conversations.json.
    var images: [String]?
    // The model that produced this answer, kept so its cost can be worked out later.
    var model: DeepSeekModel?
    var replySuggestions: ReplySuggestionBatch?
    // Answers from the ChatGPT plan carry its model slug and cost no money.
    var provider: AIProvider?
    var subscriptionModel: String?
    var colabModel: String?
    // How long the model thought before writing; set when the answer starts.
    var webSources: [WebSource]?
    var searchUsage: TokenUsage?
    var thinkingSeconds: Int?
    // nil means Flash wrote the translation, as before 1.5.2.
    var translatedBy: AIProvider?
    // Tools the answer used (1.5.8), shown under it; their raw output is not kept.
    var toolActivity: [ToolActivity]?
    // A request the app wrote for you (1.8.0), e.g. a bookshelf character's opening.
    // It goes to the model like your own message but shows only as this short label.
    var directive: String?
    // Shown under the marker for you to read, e.g. the recap a story starts from (1.9.0).
    var directiveDetail: String?
    // 「他在想什么」(1.12.0): the character's unspoken thoughts behind this answer, written
    // on request and shown apart from it. Never sent back into the conversation.
    var innerThoughts: String?
    var bookReferences: [BookReference]?
    // An explicit, one-turn question to a book character; nil is ordinary discussion.
    var discussionCharacter: String?
    var isSubscription: Bool { provider == .chatGPT }
}

// Official list prices in CNY per million tokens (api-docs.deepseek.com, checked 2026-10).
// An estimate only: public holidays count as off-peak upstream but are not known here.
enum Pricing {
    struct Rate: Equatable, Sendable { let cacheHit: Double; let cacheMiss: Double; let output: Double }
    static func rate(for model: DeepSeekModel, peak: Bool) -> Rate {
        switch model {
        case .flash:
            return peak ? Rate(cacheHit: 0.04, cacheMiss: 2, output: 8) : Rate(cacheHit: 0.02, cacheMiss: 1, output: 4)
        case .pro:
            return peak ? Rate(cacheHit: 0.30, cacheMiss: 9, output: 27) : Rate(cacheHit: 0.15, cacheMiss: 4.5, output: 13.5)
        }
    }
    // Peak hours are Beijing time, Monday to Friday, 9:00-12:00 and 14:00-18:00.
    static func isPeak(_ date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        let parts = calendar.dateComponents([.weekday, .hour], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour, (2...6).contains(weekday) else { return false }
        return (9..<12).contains(hour) || (14..<18).contains(hour)
    }
    static func cost(model: DeepSeekModel, usage: TokenUsage, at date: Date) -> Double {
        let price = rate(for: model, peak: isPeak(date))
        let missed = usage.promptTokens - usage.cachedTokens
        return (Double(usage.cachedTokens) * price.cacheHit + Double(missed) * price.cacheMiss
            + Double(usage.completionTokens) * price.output) / 1_000_000
    }
    static func label(_ yuan: Double) -> String {
        String(format: yuan < 0.01 ? "¥%.4f" : "¥%.3f", yuan)
    }
}

struct SystemPromptPreset: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var content: String
    var updatedAt = Date()
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 60,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, content.count <= 20_000 else {
            throw ChatError.invalidBackup("系统指令需要名称和正文，名称最多60字，正文最多2万字。")
        }
    }
}

struct ChatThread: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title = "新的对话"
    var createdAt = Date()
    var updatedAt = Date()
    var messages: [ChatMessage] = []
    var draft: String?
    var isPinned: Bool?
    var parentThreadID: UUID?
    var projectID: UUID?
    var modelSelection: ChatModelSelection?
    // Set for conversations started from the bookshelf (1.8.0).
    var story: StorySession?
    var bookDiscussion: BookDiscussionSession?
    var discussionDraftCharacter: String?
    var storyCheckpoints: [StoryCheckpoint]?
    // A copy selected for this conversation; library edits cannot silently change it.
    var systemPromptPreset: SystemPromptPreset?
    var preview: String {
        messages.last(where: { !$0.content.isEmpty })?.content.replacingOccurrences(of: "\n", with: " ") ?? "暂无消息"
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    static let defaultPrompt = "请用简体中文自然交流，回答清楚、具体，先说重点。遇到不确定的事实请明确说明，必要时提醒核验来源。不要编造文献、链接或已经完成的操作。"
    static let learningPrompt = "你是一位耐心的学习伙伴。优先用简体中文，先用生活例子解释，再讲概念与区别，最后给一个简短的主动回忆问题。涉及历史史料或学术观点时，区分事实与解释，不编造文献和引文。"
    var model: DeepSeekModel = .flash
    var thinkingEnabled = true
    var effort: ThinkingEffort = .high
    var systemPrompt = Self.defaultPrompt
    var maxOutputTokens = 16384
    var contextMessageLimit = 200
    var contextPolicyVersion: Int? = 1
    // Optional so settings and backups from older releases still decode.
    var replySuggestionsEnabled: Bool? = true
    var shouldSuggestReplies: Bool { replySuggestionsEnabled != false }
    // The service for conversations outside projects, and the current ChatGPT choice.
    var provider: AIProvider?
    var subscriptionModelID: String?
    var subscriptionEffort: SubscriptionEffort?
    var colab: ColabOptions?
    var auxiliaryProviderPolicy: AuxiliaryProviderPolicy?
    var colabOptions: ColabOptions { colab ?? ColabOptions() }
    var selectedProvider: AIProvider { provider ?? .deepSeek }
    var subscriptionModel: String { subscriptionModelID ?? SubscriptionModel.fallbackSlug }
    var selectedSubscriptionEffort: SubscriptionEffort { subscriptionEffort ?? .automatic }
    func migratingDefaultContext() -> AppSettings {
        var copy = self
        if copy.contextPolicyVersion == nil {
            if copy.contextMessageLimit == 40 { copy.contextMessageLimit = 200 }
            copy.contextPolicyVersion = 1
        }
        return copy
    }
    func validated() -> AppSettings {
        var copy = self
        copy.maxOutputTokens = min(max(copy.maxOutputTokens, 1024), 65536)
        copy.contextMessageLimit = min(max(copy.contextMessageLimit, 2), 400)
        copy.systemPrompt = String(copy.systemPrompt.prefix(20000))
        return copy
    }
}

// API keys are intentionally not part of this structure or any exported backup.
struct AppSnapshot: Codable, Sendable {
    var version = 1
    var exportedAt = Date()
    var settings: AppSettings
    var threads: [ChatThread]
    var activeThreadID: UUID?
    // Optional so backups from releases before projects and the usage ledger still load.
    var projects: [ChatProject]?
    var usage: UsageLedger?
    var systemPromptPresets: [SystemPromptPreset]?
    var installedStudySubjects: [StudySubject]?
    func validate() throws {
        guard version == 1 else { throw ChatError.invalidBackup("这个备份的版本暂不支持。") }
        guard threads.count <= 2000 else { throw ChatError.invalidBackup("备份中的对话数量过多。") }
        let presets = systemPromptPresets ?? []
        guard presets.count <= 100, Set(presets.map(\.id)).count == presets.count else {
            throw ChatError.invalidBackup("系统指令库最多100份，且编号不能重复。")
        }
        for preset in presets { try preset.validate() }
        let projectList = projects ?? []
        guard projectList.count <= 200, Set(projectList.map(\.id)).count == projectList.count else {
            throw ChatError.invalidBackup("备份中的项目数量或编号不正确。")
        }
        for project in projectList { try project.validate() }
        guard Set(threads.map(\.id)).count == threads.count else {
            throw ChatError.invalidBackup("备份中有重复的对话编号。")
        }
        for thread in threads {
            if let selection = thread.modelSelection {
                guard !selection.subscriptionModel.isEmpty, selection.subscriptionModel.count <= 200 else {
                    throw ChatError.invalidBackup("对话模型标识不正确。")
                }
            }
            try thread.systemPromptPreset?.validate()
            guard thread.messages.count <= 20000,
                  Set(thread.messages.map(\.id)).count == thread.messages.count else {
                throw ChatError.invalidBackup("备份中的消息数量或编号不正确。")
            }
            for message in thread.messages {
                if let batch = message.replySuggestions {
                    guard (1...ReplySuggestions.maximumCount).contains(batch.replies.count),
                          batch.replies.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= ReplySuggestions.maximumLength }) else {
                        throw ChatError.invalidBackup("备份中的回复建议格式不正确。")
                    }
                }
            }
        }
    }
    static func decode(_ data: Data) throws -> AppSnapshot {
        guard data.count <= 50 * 1024 * 1024 else { throw ChatError.invalidBackup("请选择小于 50 MB 的备份文件。") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(Self.self, from: data)
        try result.validate()
        return result
    }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

enum ChatError: LocalizedError {
    case missingKey, invalidKey, insufficientBalance, rateLimited
    case http(Int), invalidResponse, malformedStream, incompleteStream
    case server(String), invalidBackup(String)
    var errorDescription: String? {
        switch self {
        case .missingKey: return "先在设置里填写你的 DeepSeek API Key。"
        case .invalidKey: return "API Key 未通过验证，请检查或重新填写。"
        case .insufficientBalance: return "DeepSeek API 余额不足，请到开放平台查看。"
        case .rateLimited: return "请求暂时过多，稍等一会儿再试。"
        case .http(let code): return "DeepSeek 返回 HTTP \(code)，请稍后重试。"
        case .invalidResponse: return "收到的响应格式不正确。"
        case .malformedStream: return "收到的数据流无法解析，已保留收到的内容。"
        case .incompleteStream: return "连接在回答完成前中断，已保留收到的内容。"
        case .server(let message): return message
        case .invalidBackup(let message): return message
        }
    }
}
