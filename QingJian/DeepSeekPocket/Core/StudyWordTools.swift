import Foundation

enum StudyWordTools {
    static let names: Set<String> = [
        "study_draw_words", "study_find_word", "study_grade_word",
        // Legacy aliases kept routable for backward compatibility
        "study_word_units", "study_start_words", "study_word_state", "study_undo_word", "study_pause_words"
    ]

    static let specs: [ToolSpec] = [
        .init(
            name: "study_draw_words",
            description: "从私人词库抽取一批单词（一次性返回整批单词、音标、释义与复习记录，供你自由决定逐个考、对比考、乱序考或串讲；无需先查状态或暂停）。",
            parameters: ToolSpec.object([
                ("mode", "string", "smart（默认：优先到期复习词+新词）、shuffle（真随机大乱序）、review（只练到期/薄弱旧词）、continue（接续未完批次）、units_overview（查看单元列表）"),
                ("count", "integer", "抽取数量 1 至 30，默认 10"),
                ("unit_id", "string", "可选：留空表示全词库；也可填 required-1、basic-1 或单元号")
            ], required: [])
        ),
        .init(
            name: "study_find_word",
            description: "在私人词库中查词、找形近词或同词根词（一次最多返回 15 词）。用户想要几个形近词对比、查某个单词或中文意思时调用。",
            parameters: ToolSpec.object([
                ("query", "string", "英文单词、词根片段或中文词义"),
                ("match_mode", "string", "可选：auto（默认智能匹配+形近补充）或 lookalike（专门按拼写相似度找形近词）")
            ], required: ["query"])
        ),
        .init(
            name: "study_grade_word",
            description: "无锁记录单词掌握度并自动按 FSRS v6 遗忘曲线排期（支持单条记录，也支持传 JSON 字符串 items 一次批量记多个词；日常在任意窗口随口问到或聊到的单词也应主动调用记录，不在 4356 词库内的生词会自动记入项目『生词』笔记）。",
            parameters: ToolSpec.object([
                ("word", "string", "要记分的英文单词（如 radical）；批量记分时可留空并填 items"),
                ("rating", "string", "easy（轻松秒答）、good（记得/核心意思懂了）、hard（模糊/提示后想出）、again（忘了/答错）、undo（撤回该词刚记的评分）"),
                ("items", "string", "可选：一次批量给多个词记分时传 JSON 数组字符串，如 [{\"word\":\"adapt\",\"rating\":\"good\"},{\"word\":\"adopt\",\"rating\":\"hard\"}]")
            ], required: [])
        )
    ]

    static let note = """
【英语词库与记忆账本说明】
- 自由陪伴优先：出题节奏、互动语气、一次考 1 个还是给几个词对比、词根联想或趣味造句，全部按项目人设和用户心意自由发挥，没有单步流程束缚。
- 跨窗口无感联结与随手记词：不管用户在哪个窗口随口问了几个单词、聊到某个词的用法，还是在背词互动中作答，你都应顺手调用 `study_grade_word` 把这些词记进共享账本（词库内单词自动走 FSRS 排期，词库外生词自动存入『生词』记忆），这样切去其他窗口或回顾『今日在不同窗口聊了哪些词』时都能一目了然，无需用户专门说『开始学习/帮我记回去』。
- 语义理解判分（不死抠字眼）：词库里的中文释义只是简明参考锚点，不是死板的填空标准答案！例如词库写“阳光”而用户答“光线”，只要核心语义和感觉对上了，直接算掌握（`good`），顺口自然提一嘴常用译法即可；一词多义或轻微混淆也可灵性点拨后判 `good` 或 `hard`。
- 省 Token 抽词与记分：需要考词或换一批乱序词时调 1 次 `study_draw_words` 即可拿到整批词；找形近词调 `study_find_word(query, match_mode: "lookalike")`；用户答出或聊过某词后随时调 `study_grade_word` 写入账本（隔了一两轮闲聊再顺手补记也完全支持）。
"""

    static func fields(for name: String) -> Set<String>? {
        switch name {
        case "study_draw_words": return ["mode", "count", "unit_id"]
        case "study_find_word": return ["query", "match_mode"]
        case "study_grade_word": return ["word", "word_id", "rating", "items", "session_id", "expected_revision", "evidence_quote"]
        case "study_word_units", "study_word_state": return []
        case "study_start_words": return ["unit_id", "count", "mode"]
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
