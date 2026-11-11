import Foundation
import CryptoKit

enum StudySubject: String, Codable, CaseIterable, Sendable {
    case english, history, politics
    var title: String {
        switch self { case .english: return "考研英语"; case .history: return "313 历史"; case .politics: return "考研政治" }
    }
    var projectID: UUID {
        switch self {
        case .english: return UUID(uuidString: "05FCF1D0-9AB2-4C9B-8FD1-575046DA3101")!
        case .history: return UUID(uuidString: "05FCF1D0-9AB2-4C9B-8FD1-575046DA3102")!
        case .politics: return UUID(uuidString: "05FCF1D0-9AB2-4C9B-8FD1-575046DA3103")!
        }
    }
    var categories: [String] {
        switch self {
        case .english: return ["已做篇目", "错题类型", "生词", "长难句薄弱点"]
        case .history: return ["大纲条目状态", "下次复习专题", "练过的论述题", "选择错题", "反复忘的点"]
        case .politics: return ["各部分选择题正确率", "错题", "易混点"]
        }
    }
}

enum StudyProjects {
    static func seed(projects: inout [ChatProject], installed: inout [StudySubject]) throws {
        var next = projects, marks = Set(installed)
        for subject in StudySubject.allCases where !marks.contains(subject) {
            if next.contains(where: { $0.studySubject == subject }) { marks.insert(subject); continue }
            guard next.count < 200, !next.contains(where: { $0.id == subject.projectID }) else {
                throw StudyMemoryError.invalid("学习项目初始化遇到项目数量或标识冲突。")
            }
            var project = ChatProject(name: subject.title)
            project.id = subject.projectID
            project.studySubject = subject
            project.provider = subject == .english ? .deepSeek : .chatGPT
            project.autoMemory = true
            next.append(project)
            marks.insert(subject)
        }
        projects = next
        installed = StudySubject.allCases.filter(marks.contains)
    }
}

struct ChatModelSelection: Codable, Equatable, Sendable {
    var provider: AIProvider
    var model: DeepSeekModel
    var thinking: Bool
    var effort: ThinkingEffort
    var subscriptionModel: String
    var subscriptionEffort: SubscriptionEffort
    var colabThinking: Bool

    init(settings: AppSettings, project: ChatProject?) {
        provider = project?.service ?? settings.selectedProvider
        model = project?.model ?? settings.model
        thinking = project?.thinkingEnabled ?? settings.thinkingEnabled
        effort = project?.effort ?? settings.effort
        subscriptionModel = project?.subscriptionModel ?? settings.subscriptionModel
        subscriptionEffort = project?.subscriptionEffort ?? settings.selectedSubscriptionEffort
        colabThinking = settings.colabOptions.thinking
    }
    func applying(to settings: AppSettings) -> AppSettings {
        var next = settings
        next.provider = provider; next.model = model; next.thinkingEnabled = thinking; next.effort = effort
        next.subscriptionModelID = subscriptionModel; next.subscriptionEffort = subscriptionEffort
        var options = next.colabOptions; options.thinking = colabThinking; next.colab = options
        return next
    }
    static func migrate(_ threads: inout [ChatThread], projects: [ChatProject], settings: AppSettings) {
        for index in threads.indices where threads[index].modelSelection == nil {
            threads[index].modelSelection = ChatModelSelection(settings: settings,
                project: projects.first { $0.id == threads[index].projectID })
        }
    }
}

struct StudyScope: Equatable, Sendable {
    let projectID: UUID
    let threadID: UUID
    let subject: StudySubject
}

struct StudyArchivedProject: Codable, Identifiable, Sendable {
    let project: ChatProject
    let keptThreadIDs: [UUID]
    let archivedAt: Date
    var id: UUID { project.id }
}

struct StudySource: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case userStatement, modelInference, manual }
    let kind: Kind
    let threadID: UUID
    let messageID: UUID?
    let text: String
    let quote: String
    var messageDate: Date? = nil
    var material: StudyMaterialReference? = nil
    var attachmentIDs: [String]? = nil
    static func from(message: ChatMessage, scope: StudyScope, kind: Kind, quote: String) -> StudySource {
        .init(kind: kind, threadID: scope.threadID, messageID: message.id, text: message.content, quote: quote,
              messageDate: message.createdAt, attachmentIDs: message.images?.isEmpty == false ? message.images : nil)
    }
    var fingerprint: String { StudyCoding.hash(Data(text.utf8)) }
    func validate(scope: StudyScope) throws {
        let textEvidence = !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.contains(quote)
        let images = attachmentIDs ?? []
        let imageEvidence = !images.isEmpty && quote.isEmpty && kind == .modelInference
        guard threadID == scope.threadID, textEvidence || imageEvidence,
              images.count <= 20, images.allSatisfy({ !$0.isEmpty && $0.count <= 200 && !$0.contains("/") && !$0.contains("\\") && !$0.contains("..") }),
              quote.count <= 4000, text.count <= 100_000,
              kind == .manual || messageID != nil else { throw StudyMemoryError.invalid("记忆出处与当前用户消息不一致。") }
    }
}

struct StudyMemoryRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var revision: Int
    var category: String
    var text: String
    var source: StudySource
    var createdAt: Date
    var updatedAt: Date
    var isDeleted = false
    var toolReference: String { "m_" + id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased() }
}

struct StudyModelMemory: Encodable {
    let record_id: String
    let expected_revision: Int
    let category: String
    let text: String
    let material: StudyMaterialReference?
    init(_ record: StudyMemoryRecord) {
        record_id = record.toolReference; expected_revision = record.revision; category = record.category; text = record.text
        material = record.source.material
    }
}

struct StudyMemoryCommand: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case remember, correct, forget }
    var action: Action
    var recordID: UUID?
    var expectedRevision: Int?
    var category: String
    var text: String
    var source: StudySource
    func operationFingerprint() throws -> String {
        var copy = self
        copy.source.messageDate = nil
        return StudyCoding.hash(try StudyCoding.encode(copy))
    }
    func validate(scope: StudyScope) throws {
        try source.validate(scope: scope)
        guard scope.subject.categories.contains(category), text.count <= 4000,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StudyMemoryError.invalid("请选择有效的记忆栏目，内容需在 4000 字以内。")
        }
        if action == .remember {
            guard recordID == nil, expectedRevision == nil else { throw StudyMemoryError.invalid("新增记忆参数不正确。") }
        } else {
            guard recordID != nil, let revision = expectedRevision, (1..<1_000_000_000).contains(revision) else {
                throw StudyMemoryError.invalid("更正或删除需要记录标识和当前版本。")
            }
        }
    }
}

struct StudyMemoryEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let projectID: UUID
    let operationID: String
    let before: StudyMemoryRecord?
    let after: StudyMemoryRecord
    let date: Date
    let undoOf: UUID?
}

struct StudyReceipt: Codable, Equatable, Sendable {
    let event: StudyMemoryEvent
    var message: String {
        if event.undoOf != nil { return "已撤销，修改历史已保留" }
        if event.after.isDeleted { return "已移出有效记忆" }
        return event.before == nil ? "已保存到项目学习记忆" : "已更正项目学习记忆"
    }
}

struct StudyCheckpoint: Codable, Equatable, Sendable {
    let threadID: UUID
    var revision: Int
    var materialID: String?
    var itemIDs: [String]
    var position: Int
    var pendingQuestion: String?
    var paused: Bool
}

struct StudySummary: Codable, Equatable, Identifiable, Sendable {
    struct Reference: Codable, Equatable, Sendable { let recordID: UUID; let revision: Int }
    let id: UUID
    var text: String
    let sources: [Reference]
    var isValid: Bool
}

struct StudyPendingOperation: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let scopeProject: UUID
    let scopeThread: UUID
    let subject: StudySubject
    let command: StudyMemoryCommand
    let createdAt: Date
    var error: String?
}

enum StudyMemoryError: LocalizedError {
    case invalid(String), conflict, unavailable
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .conflict: return "记录已在别处更新，请刷新后再修改。"
        case .unavailable: return "学习记录暂时无法保存，请检查可用空间后重试。"
        }
    }
}

enum StudyCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
