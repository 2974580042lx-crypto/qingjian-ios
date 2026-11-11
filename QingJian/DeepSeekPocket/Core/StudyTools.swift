import Foundation
import CoreFoundation

enum StudyTools {
    static let completedTitles = [
        "study_remember": "已保存学习记忆", "study_correct": "已更正学习记忆", "study_forget": "已移出有效记忆",
        "study_start_words": "已保存本轮学习现场", "study_grade_word": "已保存本题与复习进度", "study_undo_word": "已撤销上一题评分", "study_pause_words": "已暂停，学习现场已保存",
        "study_word_units": "已读取词库单元", "study_word_state": "已读取背词进度", "study_find_word": "已查询单词和学习记录",
        "study_list_memory": "已读取项目学习记忆", "study_read_material": "已读取项目资料"
    ]
    static let names: Set<String> = Set(["study_list_memory", "study_remember", "study_correct", "study_forget", "study_read_material"]).union(StudyWordTools.names).union(StudyReadingTools.names).union(StudyLessonTools.names)
    static let specs: [ToolSpec] = [
        ToolSpec(name: "study_list_memory", description: "查找当前学习项目的有效记忆，空 query 列出最近记录。返回记录 ID 和版本用于更正。", parameters: ToolSpec.object([
            ("query", "string", "要找的词、概念或短语，可为空")], required: ["query"])),
        ToolSpec(name: "study_read_material", description: "读取当前项目资料目录中的一份文件。", parameters: ToolSpec.object([
            ("document_id", "string", "资料目录中的 UUID")], required: ["document_id"])),
        ToolSpec(name: "study_remember", description: "记录本轮用户要求记住的学习内容，或有原话证据的学习认识。内容必须忠实于来源。成功由应用回执确认。", parameters: ToolSpec.object([
            ("category", "string", "使用当前项目的一个栏目"), ("text", "string", "学习事实或认识，最多4000字"),
            ("source_kind", "string", "user_statement 或 model_inference"),
            ("evidence_quote", "string", "逐字引用本轮用户原话，最多4000字")], required: ["category", "text", "source_kind", "evidence_quote"])),
        ToolSpec(name: "study_correct", description: "根据本轮用户的纠正更新一条记忆，保留修改历史。", parameters: ToolSpec.object([
            ("record_id", "string", "查询结果中的记录短引用，例如 m_ 开头的 record_id"), ("expected_revision", "integer", "查到的当前版本"),
            ("category", "string", "当前项目栏目"), ("text", "string", "更正后的完整内容"),
            ("source_kind", "string", "user_statement 或 model_inference"),
            ("evidence_quote", "string", "逐字引用本轮用户原话")], required: ["record_id", "expected_revision", "category", "text", "source_kind", "evidence_quote"])),
        ToolSpec(name: "study_forget", description: "按用户明确要求把一条学习记忆移出有效记忆，历史保留以便撤销。", parameters: ToolSpec.object([
            ("record_id", "string", "查询结果中的记录短引用，例如 m_ 开头的 record_id"), ("expected_revision", "integer", "查到的当前版本"),
            ("category", "string", "原记录栏目"), ("text", "string", "原记录内容"),
            ("source_kind", "string", "user_statement"),
            ("evidence_quote", "string", "用户本轮明确要求删除的原话")], required: ["record_id", "expected_revision", "category", "text", "source_kind", "evidence_quote"]))
    ]
    static let note = """
学习记录工具只作用于当前项目。用户项目指令和人格由用户编辑。当前展示过的问题不等于用户已掌握。
保存学习事实时区分用户明确陈述和模型推断，原文资料中的知识不能冒充用户学习事实。
工具参数中的引用逐字来自本轮用户消息。执行成功以工具 committed 回执为准，失败时不能声称已记住。
记忆保存仅表示学习记录已保存。只有周报工具确认当前报告生成或有效，才能说周报已经生成；保存记忆本身不能说“已记入周报”。复习任务或学习完成状态必须以相应应用结果为准。
回答自然简短，内部记录 ID、版本和 JSON 用于工具交互，用户问到时再解释。
"""
}

struct StudyToolAction {
    let name: String
    let arguments: [String: Any]
    init(_ call: ToolCall) throws {
        guard StudyTools.names.contains(call.name) else { throw ToolError.unknownTool(call.name) }
        try Self.rejectDuplicateKeys(call.arguments)
        let arguments = try call.argumentObject()
        let common: Set<String> = ["category", "text", "source_kind", "evidence_quote"]
        let expected: Set<String>
        if let fields = StudyLessonTools.fields[call.name] { expected = fields }
        else if let fields = StudyReadingTools.fields[call.name] { expected = fields }
        else if let fields = StudyWordTools.fields(for: call.name) { expected = fields }
        else { switch call.name {
        case "study_list_memory": expected = ["query"]
        case "study_read_material": expected = ["document_id"]
        case "study_remember": expected = common
        default: expected = common.union(["record_id", "expected_revision"])
        } }
        guard Set(arguments.keys) == expected else { throw StudyMemoryError.invalid("学习操作字段不正确。") }
        self.name = call.name; self.arguments = arguments
    }
    func text(_ key: String) throws -> String {
        guard let value = arguments[key] as? String, value.count <= 4000 else { throw StudyMemoryError.invalid("学习操作内容格式不正确。") }
        return value
    }
    func integer(_ key: String, range: Range<Int> = 1..<1_000_000_000) throws -> Int {
        guard let value = arguments[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue == Double(value.intValue), range.contains(value.intValue) else {
            throw StudyMemoryError.invalid("学习操作的数字参数不正确。")
        }
        return value.intValue
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
    // The tool schema is flat. Scan JSON strings at the object root so duplicate
    // keys cannot silently replace a value before the Foundation decoder sees it.
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
