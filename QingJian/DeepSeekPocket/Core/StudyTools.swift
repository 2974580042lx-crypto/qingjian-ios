import Foundation
import CoreFoundation

enum StudyTools {
    static let completedTitles = [
        "study_remember": "已保存学习记忆", "study_update_memory": "已更新学习记忆",
        "study_correct": "已更正学习记忆", "study_forget": "已移出有效记忆",
        "study_draw_words": "已抽取本批单词",
        "study_start_words": "已保存本轮学习现场", "study_grade_word": "已保存单词掌握度与排期",
        "study_undo_word": "已撤销上一题评分", "study_pause_words": "已暂停，学习现场已保存",
        "study_word_units": "已读取词库单元", "study_word_state": "已读取背词进度", "study_find_word": "已查询单词与形近词",
        "study_list_memory": "已读取项目学习记忆", "study_read_material": "已读取项目资料"
    ]
    static let names: Set<String> = Set([
        "study_list_memory", "study_remember", "study_update_memory",
        "study_correct", "study_forget", "study_read_material"
    ]).union(StudyWordTools.names).union(StudyReadingTools.names).union(StudyLessonTools.names)

    static let specs: [ToolSpec] = [
        ToolSpec(name: "study_list_memory", description: "查找当前学习项目的有效记忆笔记（空 query 列出最近记录，返回 record_id 供修改或删除）。", parameters: ToolSpec.object([
            ("query", "string", "可选：要检索的词、概念或短语，留空列最近记录")], required: [])),
        ToolSpec(name: "study_remember", description: "随手记下当前学习项目里值得留存的易混点、生词或学习心得（无原话与版本号锁）。", parameters: ToolSpec.object([
            ("category", "string", "可选：当前项目栏目名，留空自动归入默认栏目"),
            ("text", "string", "要记住的学习笔记内容，最多 4000 字")], required: ["text"])),
        ToolSpec(name: "study_update_memory", description: "按 record_id 修改或删除一条已有的项目学习记忆（无需版本号与原话引用）。", parameters: ToolSpec.object([
            ("record_id", "string", "记录短引用（如 m_ 开头）或 UUID"),
            ("action", "string", "可选：update（默认，修改内容）或 delete（移出有效记忆）"),
            ("category", "string", "可选：更新后的栏目名"),
            ("text", "string", "修改后的内容（delete 时可省略）")], required: ["record_id"])),
        ToolSpec(name: "study_read_material", description: "读取当前项目资料目录中的一份文件全文。", parameters: ToolSpec.object([
            ("document_id", "string", "资料目录中的 UUID")], required: ["document_id"]))
    ]

    static let note = """
学习账本工具仅作用于当前项目，说话语气、人设性格与陪伴节奏完全遵循用户的项目指令自由发挥。
保存记忆、背词排期、做题记录与周报生成各自独立，以工具实际回执为准；内部 ID 仅供工具使用，不必念给用户。
"""
}

struct StudyToolAction {
    let name: String
    let arguments: [String: Any]

    init(_ call: ToolCall) throws {
        guard StudyTools.names.contains(call.name) else { throw ToolError.unknownTool(call.name) }
        try Self.rejectDuplicateKeys(call.arguments)
        let arguments = try call.argumentObject()
        let legacyMemory: Set<String> = ["category", "text", "source_kind", "evidence_quote"]
        let allowed: Set<String>
        if let fields = StudyLessonTools.fields[call.name] { allowed = fields }
        else if let fields = StudyReadingTools.fields[call.name] { allowed = fields }
        else if let fields = StudyWordTools.fields(for: call.name) { allowed = fields }
        else {
            switch call.name {
            case "study_list_memory": allowed = ["query"]
            case "study_read_material": allowed = ["document_id"]
            case "study_remember": allowed = legacyMemory
            case "study_update_memory": allowed = ["record_id", "action", "category", "text"]
            default: allowed = legacyMemory.union(["record_id", "expected_revision"])
            }
        }
        guard Set(arguments.keys).isSubset(of: allowed) else { throw StudyMemoryError.invalid("学习操作字段不正确。") }
        self.name = call.name
        self.arguments = arguments
    }

    func text(_ key: String) throws -> String {
        guard let value = arguments[key] as? String, value.count <= 4000 else {
            throw StudyMemoryError.invalid("学习操作内容格式不正确。")
        }
        return value
    }

    func optionalText(_ key: String, default fallback: String = "") throws -> String {
        guard let raw = arguments[key], !(raw is NSNull) else { return fallback }
        guard let value = raw as? String, value.count <= 4000 else {
            throw StudyMemoryError.invalid("学习操作内容格式不正确。")
        }
        return value
    }

    func integer(_ key: String, range: Range<Int> = 1..<1_000_000_000) throws -> Int {
        guard let value = arguments[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue == Double(value.intValue), range.contains(value.intValue) else {
            throw StudyMemoryError.invalid("学习操作的数字参数不正确。")
        }
        return value.intValue
    }

    func optionalInt(_ key: String, range: Range<Int> = 0..<1_000_000_000) throws -> Int? {
        guard let raw = arguments[key], !(raw is NSNull) else { return nil }
        return try integer(key, range: range)
    }

    func uuid(_ key: String) throws -> UUID {
        guard let value = UUID(uuidString: try text(key)) else { throw StudyMemoryError.invalid("学习操作标识不正确。") }
        return value
    }

    func boolean(_ key: String) throws -> Bool {
        guard let value = arguments[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw StudyMemoryError.invalid("学习操作的开关参数不正确。")
        }
        return value.boolValue
    }

    func optionalBool(_ key: String, default fallback: Bool = false) throws -> Bool {
        guard let raw = arguments[key], !(raw is NSNull) else { return fallback }
        return try boolean(key)
    }

    func command(scope: StudyScope, message: ChatMessage) throws -> StudyMemoryCommand {
        guard message.role == .user else { throw StudyMemoryError.invalid("记忆需要用户消息出处。") }
        let kind: StudySource.Kind
        switch try text("source_kind") {
        case "user_statement": kind = .userStatement
        case "model_inference": kind = .modelInference
        default: throw StudyMemoryError.invalid("记忆来源类型不正确。")
        }
        let action: StudyMemoryCommand.Action
        switch name {
        case "study_remember": action = .remember
        case "study_correct": action = .correct
        case "study_forget": action = .forget
        default: throw StudyMemoryError.invalid("这项操作不能写入记忆。")
        }
        var recordID: UUID?, revision: Int?
        if action != .remember {
            guard let id = UUID(uuidString: try text("record_id")),
                  let raw = arguments["expected_revision"] as? NSNumber,
                  CFGetTypeID(raw) != CFBooleanGetTypeID(), raw.doubleValue == Double(raw.intValue),
                  (1..<1_000_000_000).contains(raw.intValue) else { throw StudyMemoryError.invalid("记录标识或版本不正确。") }
            recordID = id; revision = raw.intValue
        }
        let source = StudySource.from(message: message, scope: scope, kind: kind, quote: try text("evidence_quote"))
        let command = StudyMemoryCommand(action: action, recordID: recordID, expectedRevision: revision,
            category: try text("category"), text: try text("text"), source: source)
        try command.validate(scope: scope)
        return command
    }

    // Scan JSON strings at the object root so duplicate keys cannot silently replace a value.
    private static func rejectDuplicateKeys(_ text: String) throws {
        let bytes = Array(text.utf8)
        var index = 0, depth = 0, keys = Set<String>()
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 123 || byte == 91 { depth += 1 }
            if byte == 125 || byte == 93 { depth -= 1 }
            if byte != 34 { index += 1; continue }
            let start = index; index += 1
            while index < bytes.count {
                if bytes[index] == 92 { index += 2; continue }
                if bytes[index] == 34 { break }
                index += 1
            }
            guard index < bytes.count else { throw StudyMemoryError.invalid("学习操作 JSON 不完整。") }
            let token = Data(bytes[start...index]); index += 1
            var next = index
            while next < bytes.count && [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
            if depth == 1, next < bytes.count, bytes[next] == 58 {
                let key = try JSONDecoder().decode(String.self, from: token)
                guard keys.insert(key).inserted else { throw StudyMemoryError.invalid("学习操作包含重复字段。") }
            }
        }
    }
}
