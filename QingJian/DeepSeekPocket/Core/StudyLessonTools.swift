import Foundation

enum StudyLessonTools {
    static let historyAreas = ["中国古代史", "中国近现代史", "世界古代中世纪史", "世界近现代史"]
    static let politicsAreas = ["马原", "毛中特", "习思想", "史纲", "思修法治", "时政"]
    static let fields: [String: Set<String>] = [
        "study_topic_state": [], "study_start_topic": ["title", "outline_id", "mode", "phase", "evidence_quote"],
        "study_update_topic": ["expected_revision", "session_revision", "phase", "level", "note", "pending_prompt", "source_kind", "evidence_quote"],
        "study_pause_topic": ["session_revision", "evidence_quote"],
        "study_list_practice": ["query"],
        "study_record_practice": ["area", "kind", "question", "answer", "outcome", "weak_point", "source_kind", "evidence_quote"],
        "study_correct_practice": ["record_id", "expected_revision", "area", "kind", "question", "answer", "outcome", "weak_point", "source_kind", "evidence_quote"],
        "study_remove_practice": ["record_id", "expected_revision", "evidence_quote"],
        "study_history_search": ["query", "kind"], "study_history_read": ["record_id", "kind"],
        "study_weekly_report": ["weeks_ago", "mode"]
    ]
    static let names = Set(fields.keys)
    static let titles = ["study_topic_state":"已读取专题现场", "study_start_topic":"已保存专题现场", "study_update_topic":"已更新专题记录",
        "study_pause_topic":"已暂停专题", "study_list_practice":"已读取练习记录", "study_record_practice":"已保存练习",
        "study_correct_practice":"已更正原练习", "study_remove_practice":"已移出有效练习", "study_history_search":"已查询历史资料",
        "study_history_read":"已读取历史参考", "study_weekly_report":"周报状态已读取"]
    private static func spec(_ name: String, _ description: String, _ props: [(String, String, String)]) -> ToolSpec {
        .init(name: name, description: description, parameters: ToolSpec.object(props, required: props.map { $0.0 }))
    }
    private static let revision = ("expected_revision", "integer", "应用给出的当前记录版本")
    private static let sessionRevision = ("session_revision", "integer", "当前窗口专题现场版本")
    private static let quote = ("evidence_quote", "string", "逐字引用本轮用户原话；只有图片且无文字时留空并使用model_inference")
    private static let sourceKind = ("source_kind", "string", "user_statement 用户明确陈述；model_inference 模型判断/图片识别，须待核")
    private static let practiceFields: [(String, String, String)] = [
        ("area", "string", "历史四大板块之一；政治为马原/毛中特/习思想/史纲/思修法治/时政"),
        ("kind", "string", "single_choice 单选，multiple_choice 多选，oral 口述，concept 概念辨析"),
        ("question", "string", "本次题目或专题摘要；未给完整题干时写题干未完整提供，不编补；图片识别是模型整理"),
        ("answer", "string", "用户实际作答；尚未作答留空，不能填模型答案"),
        ("outcome", "string", "correct/wrong/unknown。模型自己的判断使用model_inference，不进入用户确认正确率"),
        ("weak_point", "string", "有原话依据的错因或易混点，没有则留空"), sourceKind, quote]
    static let all: [ToolSpec] = [
        spec("study_topic_state", "读取当前专题、待口述问题和项目复习顺序，不改变状态。", []),
        spec("study_start_topic", "开始或跨窗口接续历史/政治专题，保留待答问题。开始不代表已学完。", [
            ("title", "string", "用户想学的专题；继续上次可为空"), ("outline_id", "string", "已核对地图ID或netmap:开头的临时地图ID；自主专题留空"),
            ("mode", "string", "start开始，continue接续实际存在的现场"), ("phase", "string", "明确第一遍才first_pass，复习review，否则unknown"), quote]),
        spec("study_update_topic", "保存专题阶段、口述进度、薄弱点和待答问题，依据真实回答，保留修改历史。", [revision, sessionRevision,
            ("phase", "string", "first_pass/review/unknown"), ("level", "string", "not_studied未学完，studied_once学过一遍，can_outline能口述提纲"),
            ("note", "string", "本轮实际进度和薄弱点，不冒充教材知识或已掌握"), ("pending_prompt", "string", "留待用户回答的一个小问题，无则空"), sourceKind, quote]),
        spec("study_pause_topic", "用户暂停时保存当前专题和待答内容。", [sessionRevision, quote]),
        spec("study_list_practice", "查看本项目实际练习，返回短引用和版本供更正。", [("query", "string", "关键词，可为空")]),
        spec("study_record_practice", "保存用户实际做过的口述、纸质错题或概念练习。没有作答不计正确率，图片识别是模型整理。", practiceFields),
        spec("study_correct_practice", "更正原练习，保留历史，不另计一道题。", [("record_id", "string", "p_开头的记录短引用"), revision] + practiceFields),
        spec("study_remove_practice", "按用户明确要求移出有效练习，原历史保留。", [("record_id", "string", "p_开头的记录短引用"), revision, quote]),
        spec("study_history_search", "按需查询参考词条、用户核对地图或网络待核临时地图，三者不可混称官方考纲。", [("query", "string", "关键词"), ("kind", "string", "reference参考词条，outline用户核对地图，temporary网络待核地图")]),
        spec("study_history_read", "读取指定历史条目，保留来源及差异，不擅自消除冲突。", [("record_id", "string", "搜索返回的资料ID"), ("kind", "string", "reference、outline或temporary")]),
        spec("study_weekly_report", "读取或生成本项目指定周报；生成以真实记录为依据，返回真实生成状态。", [("weeks_ago", "integer", "0本周，1上周，最多52"), ("mode", "string", "read读取已有，generate生成或更新")])
    ]
    static func specs(for subject: StudySubject) -> [ToolSpec] {
        all.filter { spec in
            if spec.name == "study_weekly_report" { return true }
            if subject == .english { return false }
            return !spec.name.hasPrefix("study_history_") || subject == .history
        }
    }
    static let note = """
学习仍以聊天为主，不自动加题库。历史按用户纸质书核对，参考词条的AI整理与正式大纲分开；未导入已核对大纲时使用自主专题，不虚构考纲范围。
temporary临时地图全部是网络整理、待核，保留多个来源和差异，不代表官方或完整考纲。按地图学习时把netmap:条目ID交给专题工具，进度绑稳定条目而非标题；不要因模型改写标题另建进度。
政治围绕用户口述或单题图片；时政只认用户提供资料，模型自带知识不能冒充本年事实。
专题开始、暂停、继续用应用工具保存；先查真实现场，没记录就说明没记录，不能假装记得上次。阶段不明用unknown，第一遍以理解和搭框架为主。
实际做了什么与模型建议分开。source_kind用于作答和对错的来源：模型评估、图片识别用model_inference；用户明确报告的答案和对错才能作为user_statement。题干和错因摘要另按是否出自原话标注；没有提供题干时写“题干未完整提供”，不能编补。没有作答不写模型答案进去，不计正确率。
同一纸质题的纠正要用原记录短引用与版本更正，不要另存成一道新题。原始图片只保存出处，识别出的题目文字需要用户核对。
记录日期是记录日期。用户说几个月前学过，不能写成今天新学会。复习列表按记录时间排序，并非科学间隔或掌握度保证。
只有study_weekly_report返回generated，才能声称本轮周报生成/更新成功；保存记忆或出题不等于写入周报。普通“记到周报”先保存学习记录，需生成周报时再调用对应工具。
"""
}

extension StudyToolExecutor {
    func performLessonAction(_ action: StudyToolAction, message: ChatMessage) throws -> String {
        guard StudyLessonTools.specs(for: scope.subject).contains(where: { $0.name == action.name }) else { throw StudyMemoryError.invalid("这项工具不属于当前项目。") }
        func json<T: Encodable>(_ x: T) throws -> String { String(decoding: try StudyCoding.encode(x), as: UTF8.self) }
        if action.name == "study_topic_state" {
            struct Result: Encodable { let current: StudyTopicView?; let reviewOrder: [String] }
            return try json(Result(current: store.studyTopicState(scope: scope), reviewOrder: store.studyTopics(projectID: scope.projectID).map { "\($0.title) · \($0.level.title) · 记录日期 \($0.updatedAt)" }))
        }
        if action.name == "study_list_practice" {
            let q = try action.text("query")
            return try json(store.studyPractices(projectID: scope.projectID).filter { q.isEmpty || ($0.question + $0.weakPoint + $0.area).localizedCaseInsensitiveContains(q) }.prefix(30).map(StudyPracticeView.init))
        }
        if action.name.hasPrefix("study_history_") {
            let kind = try action.text("kind")
            if kind == "temporary" {
                guard let map = try store.temporaryHistoryMap(projectID: scope.projectID) else { return "还没有导入网络临时地图，可先按自主专题学习。" }
                let topics = try store.studyTopics(projectID: scope.projectID)
                struct Item: Encodable { let entry: StudyTemporaryMap.Entry; let sources: [StudyTemporaryMap.Source]; let progress: String }
                let selected: [StudyTemporaryMap.Entry]
                if action.name == "study_history_read" {
                    let id = try action.text("record_id")
                    guard let entry = map.entries.first(where: { $0.id == id }) else { throw StudyMemoryError.invalid("临时地图里没有这项。") }
                    selected = [entry]
                } else {
                    let q = try action.text("query")
                    selected = Array(map.entries.filter { q.isEmpty || ($0.title + $0.block).localizedCaseInsensitiveContains(q) }.prefix(30))
                }
                return "网络整理、待核；不是官方考纲。关联词条仅为关键词匹配。\n" + (try json(selected.map { e in
                    Item(entry: e, sources: map.sources.filter { e.sourceIDs.contains($0.id) }, progress: topics.first { $0.outlineID == e.id }?.level.title ?? "未学")
                }))
            }
            guard ["reference", "outline"].contains(kind) else { throw StudyMemoryError.invalid("请选择参考词条或已核对大纲。") }
            guard let pack = try store.studyHistoryPack(projectID: scope.projectID, kind: kind) else { return kind == "outline" ? "尚未导入用户核对的大纲，不能声称考纲完整。可以按自主专题学习。" : "尚未导入历史参考词条，可使用用户提供的书和项目文件。" }
            if action.name == "study_history_read" {
                guard let entry = pack.entries.first(where: { $0.id == (try? action.text("record_id")) }) else { throw StudyMemoryError.invalid("当前项目没有这条资料。") }
                return "来源：\(pack.source)；核验状态：\(pack.verification)\n" + (try json(entry))
            }
            let query = try action.text("query")
            struct Entry: Encodable { let id: String; let title: String; let block: String }
            let found = pack.entries.filter { query.isEmpty || ($0.title + $0.text).localizedCaseInsensitiveContains(query) }.prefix(30).map { Entry(id: $0.id, title: $0.title, block: $0.block) }
            return "来源：\(pack.source)；核验状态：\(pack.verification)\n" + (try json(found))
        }
        if action.name == "study_weekly_report" {
            let weeks = try action.integer("weeks_ago", range: 0..<53), mode = try action.text("mode")
            guard ["read", "generate"].contains(mode) else { throw StudyMemoryError.invalid("请选择读取或生成周报。") }
            return try json(store.weeklyReport(scope: scope, weeksAgo: weeks, generate: mode == "generate"))
        }
        return try json(store.performLesson(action, scope: scope, message: message))
    }
}
