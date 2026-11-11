import Foundation

enum StudyReadingTools {
    static let fields: [String: Set<String>] = [
        "study_reading_catalog": ["query"], "study_reading_state": [],
        "study_open_reading": ["passage_id", "mode"],
        "study_show_reading": ["kind", "number", "expected_revision"],
        "study_answer_reading": ["choice", "expected_revision", "evidence_quote"],
        "study_reading_reference": ["skip_without_answer", "expected_revision", "evidence_quote"],
        "study_pause_reading": ["expected_revision"],
        "study_collect_reading_word": ["word", "original_sentence", "expected_revision", "evidence_quote"]
    ]
    static let names = Set(fields.keys)
    static let titles = ["study_reading_catalog": "已读取阅读目录", "study_reading_state": "已找回阅读位置",
        "study_open_reading": "已接续阅读", "study_show_reading": "已读取资料原文", "study_answer_reading": "已保存本题作答",
        "study_reading_reference": "已读取参考答案", "study_pause_reading": "阅读现场已保存", "study_collect_reading_word": "已保存生词与原文出处"]
    private static func spec(_ name: String, _ description: String, _ fields: [(String, String, String)]) -> ToolSpec {
        .init(name: name, description: description, parameters: ToolSpec.object(fields, required: fields.map { $0.0 }))
    }
    static let specs: [ToolSpec] = [
        spec("study_reading_catalog", "查看当前项目真实存在的阅读篇目，不读取整年正文。", [("query", "string", "年份、标题或主题；空字符串列全部")]),
        spec("study_reading_state", "只查询当前窗口的段落、待答题和版本，不改变进度、不解除暂停。", []),
        spec("study_open_reading", "打开指定篇目，或接续原阅读（可跨窗口转移原任务）。应用直接展示原段落和待答题。", [
            ("passage_id", "string", "目录中的篇目 ID；继续上次可为空"), ("mode", "string", "start 开始指定篇目；continue 接续未完成现场")]),
        spec("study_show_reading", "读取并直接展示一个原文段落或一道题目，不含答案。读段落不会清掉待答题，出题不计作答。", [
            ("kind", "string", "paragraph 原文段落，question 题目"), ("number", "integer", "从1开始的段号，或原卷题号"), ("expected_revision", "integer", "当前阅读版本")]),
        spec("study_answer_reading", "记录用户实际选项或更正当前题答案，保留原记录。不会自动转下一题；待核答案不判对错。", [
            ("choice", "string", "用户实际选择 A/B/C/D"), ("expected_revision", "integer", "当前版本"), ("evidence_quote", "string", "逐字引用本轮用户作答")]),
        spec("study_reading_reference", "用户答后查看参考答案；用户明确要直接看答案时才标记跳过，不算作答。待核答案不返回可疑选项。", [
            ("skip_without_answer", "boolean", "通常 false；只有用户明确要求不答直接看答案才 true"), ("expected_revision", "integer", "当前版本"), ("evidence_quote", "string", "本轮用户的作答或明确要求看答案的原话")]),
        spec("study_pause_reading", "暂停并保留原段落和待答题。", [("expected_revision", "integer", "当前版本")]),
        spec("study_collect_reading_word", "按用户要求收藏当前段落里的生词，带原句、年份篇目和已有词库关联；不自动增加背词评分。", [
            ("word", "string", "原文中的单词或短语"), ("original_sentence", "string", "逐字引用当前段落的原句，不得改写"),
            ("expected_revision", "integer", "当前版本"), ("evidence_quote", "string", "用户本轮明确要记这个词的原话")])
    ]
    static let note = """
阅读在聊天里进行，目录是索引，正文按段、题目按题取用，不一次载入整年资料。
打开和继续阅读先调用应用工具，使用真实游标，不从聊天措辞猜进度。另开窗口继续时用 study_open_reading(mode=continue)。
未答题时，用户仅要求继续、返回原题或重新展示，正文只用一句话邀请作答；不要主动翻译原文、解读选项或指出解题线索。用户明确要讲词句时只讲所问部分。
词义补充应与资料区分；没有可靠来源时不附加词源拆解或音标。用户要求词源时说明需核验来源。
资料工具的 excerpts 由 App 在聊天中直接显示，保持原文与选项，不要重复抄写、改写或翻译成“原文”。你只补充引导和标明“讲解”的解释。
一次通常一段或一题。先给用户思考和回答机会，用户询问单词时可以先给线索；用户明确要解释时再讲，不连续盘问。
阅读目录没有题目与段落的精确对应表。根据实际题干与已读段落安排练习，不把推断的对应关系当作资料事实。
用户插话或问词只解答，不自动改位置，不替用户选择答案或记分。展示段落不代表已学会，第一遍以理解和熟悉为主。
已做题的选项更正仍写原题；只在用户明确答题时调用 study_answer_reading。答案待核时明确说明，服从用户提供的纸质原卷。
参考答案与讲解分别标明来源；未作答先不取答案，用户明确直接看答案时可跳过并说明没有计为作答。
收藏单词须附资料里的原句。只用查到的词库关联和学习次数，不把收藏说成已背熟或已加入复习调度。
学习记录保存与周报生成不同，周报是否生成须以周报工具的实际回执为准。
"""
}

extension StudyToolExecutor {
    func performReadingAction(_ action: StudyToolAction, message: ChatMessage) throws -> String {
        guard scope.subject == .english else { throw StudyMemoryError.invalid("请在英语项目中使用阅读资料。") }
        if action.name == "study_reading_catalog" {
            let query = try action.text("query").trimmingCharacters(in: .whitespacesAndNewlines)
            let catalog = try store.readingCatalog(projectID: scope.projectID).filter { query.isEmpty || ($0.title + " " + ($0.topic ?? "")).localizedCaseInsensitiveContains(query) }
            return String(decoding: try StudyCoding.encode(catalog), as: UTF8.self)
        }
        if action.name == "study_reading_state" {
            return String(decoding: try StudyCoding.encode(store.readingState(scope: scope)), as: UTF8.self)
        }
        if action.name == "study_collect_reading_word" {
            let ref = try store.readingWordReference(scope: scope, word: action.text("word"),
                originalSentence: action.text("original_sentence"), expectedRevision: action.integer("expected_revision"))
            let source = StudySource(kind: .userStatement, threadID: scope.threadID, messageID: message.id, text: message.content,
                quote: try action.text("evidence_quote"), messageDate: message.createdAt, material: ref)
            let command = StudyMemoryCommand(action: .remember, category: "生词",
                text: "\(ref.word) · \(ref.passageTitle) 第\(ref.paragraph)段\n用户记录：\(source.quote)", source: source)
            let opID = StudyCoding.hash(Data((message.id.uuidString + "/reading-word/" + ref.passageID + "/\(ref.paragraph)/" + ref.word.lowercased()).utf8))
            let receipt = try store.apply(command, scope: scope, operationID: opID)
            return "生词和原文出处已保存，未增加背词作答次数。\n" + String(decoding: try StudyCoding.encode(StudyModelMemory(receipt.event.after)), as: UTF8.self)
        }
        if action.name == "study_reading_reference" { _ = try action.boolean("skip_without_answer") }
        return String(decoding: try StudyCoding.encode(store.performReading(action, scope: scope, message: message)), as: UTF8.self)
    }
}
