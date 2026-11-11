import Foundation

enum StudyWordTools {
    static let names: Set<String> = ["study_word_units", "study_start_words", "study_word_state", "study_find_word", "study_grade_word", "study_undo_word", "study_pause_words"]
    static let specs: [ToolSpec] = [
        .init(name: "study_word_units", description: "查看已导入词库的单元、已学和到期复习数量。用户让你抽模块时据此选择。", parameters: ToolSpec.object([], required: [])),
        .init(name: "study_start_words", description: "准备或接续一轮背词。优先接续当前未完成任务，一次只提问当前单词。", parameters: ToolSpec.object([
            ("unit_id", "string", "单元目录中的 ID；空字符串按到期复习和词库顺序选择"),
            ("count", "integer", "本轮 1 至 30 词，通常 10"),
            ("mode", "string", "start 开始，continue 接续上次（可跨窗口），review 只选到期词，practice 在用户明确要求时额外练已学词")], required: ["unit_id", "count", "mode"])),
        .init(name: "study_word_state", description: "只读取当前窗口的背词现场，不解除暂停。若 paused=true 且用户要求继续，随后必须调用 study_start_words，mode=continue，取得 paused=false 的回执后再继续提问。", parameters: ToolSpec.object([], required: [])),
        .init(name: "study_find_word", description: "从当前项目私人词库查单词及实际复习记录，用于解释、比较和找回学过的词。", parameters: ToolSpec.object([
            ("query", "string", "单词、词形片段或中文释义")], required: ["query"])),
        .init(name: "study_grade_word", description: "用户已回答或明确自评后记录当前词的评分并推进一词。单纯追问或看答案不应算作答。", parameters: ToolSpec.object([
            ("session_id", "string", "当前背词任务 ID"), ("expected_revision", "integer", "当前任务版本"),
            ("word_id", "string", "当前提问词条 ID"), ("rating", "string", "again 忘了，hard 模糊，good 记得，easy 轻松"),
            ("evidence_quote", "string", "本轮用户实际回答或自评的逐字原话")], required: ["session_id", "expected_revision", "word_id", "rating", "evidence_quote"])),
        .init(name: "study_pause_words", description: "用户说先暂停或今天到这里时保存暂停状态，保留当前词和待回答位置。", parameters: ToolSpec.object([
            ("session_id", "string", "当前任务 ID"), ("expected_revision", "integer", "当前任务版本")], required: ["session_id", "expected_revision"])),
        .init(name: "study_undo_word", description: "用户纠正上一题评分时撤销最近一题并回到该词。", parameters: ToolSpec.object([
            ("session_id", "string", "当前任务 ID"), ("expected_revision", "integer", "当前任务版本")], required: ["session_id", "expected_revision"]))
    ].map { (spec: ToolSpec) -> ToolSpec in
        guard case .object(var parameters) = spec.parameters,
              case .object(var properties) = parameters["properties"] else { return spec }
        for key in ["session_id", "word_id"] where properties[key] != nil {
            properties[key] = .object(["type": .string("string"), "enum": .array([.string("current")]),
                "description": .string("固定填写 current，客户端按当前项目和窗口绑定实际对象。")])
        }
        parameters["properties"] = .object(properties)
        return ToolSpec(name: spec.name, description: spec.description, parameters: .object(parameters))
    }
    static let note = """
背词在聊天里进行。开始、继续和找回进度必须先读取应用数据；用实际词条，不编造已学、已掌握或完成数量。
session_id 和 word_id 固定传 current，由客户端绑定当前窗口的任务和词；不要抄写或构造内部 UUID。expected_revision 仍使用回执给出的版本。
暂停任务的恢复必须执行 study_start_words，mode=continue。study_word_state 只读取状态，不能把读取成功说成已恢复；以 paused=false 的应用回执为准。
每次只问当前一个词，通常只显示单词和音标，给用户回答机会。工具返回的释义用于判断，不要在提问时提前说出答案。
资料缺少音标时省略音标；用户要求你补充时明确标为模型补充、待核验。
用户随时可以插话、比较词形或问用法，解释后接回原任务。追问、看释义和闲聊都不会自动算作答。
只有用户给出答案或明确自评时调用评分工具。评分前结合词义判断，拿不准先问清楚；用户可要求撤销上一题。
查询结果 reviewCount 为 0 只表示软件没有练习记录，不代表用户从没见过。第一次记录的词以理解和熟悉为主。
只有工具回执确认才说进度或记忆已保存。保存学习记录不代表生成周报；周报状态以study_weekly_report的实际回执为准。
"""
    static func fields(for name: String) -> Set<String>? {
        switch name {
        case "study_word_units", "study_word_state": return []
        case "study_start_words": return ["unit_id", "count", "mode"]
        case "study_find_word": return ["query"]
        case "study_grade_word": return ["session_id", "expected_revision", "word_id", "rating", "evidence_quote"]
        case "study_undo_word", "study_pause_words": return ["session_id", "expected_revision"]
        default: return nil
        }
    }
}

struct StudyWordUnitOverview: Codable, Sendable {
    let id: String
    let title: String
    let total: Int
    let learned: Int
    let due: Int
}

struct StudyWordView: Codable, Sendable {
    let word: StudyWord
    let reviewCount: Int
    let lastRating: String?
    let lastReviewedAt: Date?
    let due: Date?
}
