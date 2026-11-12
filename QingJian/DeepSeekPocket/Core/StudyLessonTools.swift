import Foundation

enum StudyLessonTools {
    static let historyAreas = ["中国古代史", "中国近现代史", "世界古代中世纪史", "世界近现代史"]
    static let politicsAreas = ["马原", "毛中特", "习思想", "史纲", "思修法治", "时政"]

    static let fields: [String: Set<String>] = [
        "study_save_topic": ["title", "outline_id", "phase", "level", "note", "pending_prompt"],
        "study_save_practice": ["record_id", "action", "area", "kind", "question", "answer", "outcome", "weak_point", "source_kind"],
        "study_list_practice": ["query"],
        "study_history_search": ["query", "record_id", "kind"],
        "study_weekly_report": ["weeks_ago", "mode"],
        // Legacy internal tool schemas preserved for backward compatibility
        "study_topic_state": [],
        "study_start_topic": ["title", "outline_id", "mode", "phase", "evidence_quote"],
        "study_update_topic": ["expected_revision", "session_revision", "phase", "level", "note", "pending_prompt", "source_kind", "evidence_quote"],
        "study_pause_topic": ["session_revision", "evidence_quote"],
        "study_record_practice": ["area", "kind", "question", "answer", "outcome", "weak_point", "source_kind", "evidence_quote"],
        "study_correct_practice": ["record_id", "expected_revision", "area", "kind", "question", "answer", "outcome", "weak_point", "source_kind", "evidence_quote"],
        "study_remove_practice": ["record_id", "expected_revision", "evidence_quote"],
        "study_history_read": ["record_id", "kind"]
    ]
    static let names = Set(fields.keys)
    static let titles = [
        "study_save_topic": "已保存专题进度",
        "study_save_practice": "已保存练习记录",
        "study_topic_state": "已读取专题现场", "study_start_topic": "已保存专题现场", "study_update_topic": "已更新专题记录",
        "study_pause_topic": "已暂停专题", "study_list_practice": "已读取练习记录", "study_record_practice": "已保存练习",
        "study_correct_practice": "已更正原练习", "study_remove_practice": "已移出有效练习", "study_history_search": "已查询历史资料",
        "study_history_read": "已读取历史参考", "study_weekly_report": "周报状态已读取"
    ]

    static let streamlinedSpecs: [ToolSpec] = [
        .init(
            name: "study_save_topic",
            description: "开始、接续或更新历史/政治专题的学习进度、口述程度与待思考问题（无版本号与暂停锁）。",
            parameters: ToolSpec.object([
                ("title", "string", "专题名称；接续或更新当前专题时可留空"),
                ("outline_id", "string", "可选：历史大纲条目 ID 或 netmap: 临时地图 ID"),
                ("phase", "string", "可选：first_pass（第一遍）、review（复习）或 unknown"),
                ("level", "string", "可选：not_studied（未学完）、studied_once（学过一遍）、can_outline（能口述提纲）"),
                ("note", "string", "可选：本轮梳理进度或薄弱点备注"),
                ("pending_prompt", "string", "可选：留待下次接续的小问题")
            ], required: [])
        ),
        .init(
            name: "study_save_practice",
            description: "记录、更正或删除一道历史/政治练习题、口述题或错题复盘（无版本号与原话锁）。",
            parameters: ToolSpec.object([
                ("record_id", "string", "可选：更正或删除已有练习时传 p_ 开头的短引用；新建练习留空"),
                ("action", "string", "可选：save（默认）或 delete（移出有效练习）"),
                ("area", "string", "可选：历史四大板块之一，或政治 马原/毛中特/习思想/史纲/思修法治/时政"),
                ("kind", "string", "可选：single_choice / multiple_choice / oral / concept"),
                ("question", "string", "题目或考点摘要（未提供完整题干时如实简述）"),
                ("answer", "string", "可选：用户实际作答；未作答留空"),
                ("outcome", "string", "可选：correct / wrong / unknown"),
                ("weak_point", "string", "可选：易混点或错因备注"),
                ("source_kind", "string", "可选：user_statement（用户亲口确认）或 model_inference（模型推断/看图整理）")
            ], required: [])
        ),
        .init(
            name: "study_list_practice",
            description: "查询本项目已记录的练习与错题（返回 p_ 短引用供更正）。",
            parameters: ToolSpec.object([
                ("query", "string", "可选：关键词，留空列最近 30 条")
            ], required: [])
        ),
        .init(
            name: "study_history_search",
            description: "检索或直接读取 313 历史参考词条、用户核对大纲或网络临时地图（传 query 搜索列表，传 record_id 直接读取单条正文）。",
            parameters: ToolSpec.object([
                ("query", "string", "可选：搜索关键词"),
                ("record_id", "string", "可选：已知条目 ID 时直接传入以读取完整内容"),
                ("kind", "string", "可选：reference（默认参考词条）、outline（已核对大纲）或 temporary（网络待核地图）")
            ], required: [])
        ),
        .init(
            name: "study_weekly_report",
            description: "读取或生成本项目指定周的学习周报（返回 status == generated 时代表周报已生成）。",
            parameters: ToolSpec.object([
                ("weeks_ago", "integer", "可选：0 表示本周（默认），1 表示上周，最多 52"),
                ("mode", "string", "可选：read（默认读取已有）或 generate（汇总真实记录生成/更新周报）")
            ], required: [])
        )
    ]

    static func specs(for subject: StudySubject) -> [ToolSpec] {
        streamlinedSpecs.filter { spec in
            if spec.name == "study_weekly_report" { return true }
            if subject == .english { return false }
            return spec.name != "study_history_search" || subject == .history
        }
    }

    static let weeklyReportNote = "只有调用 study_weekly_report(mode: \"generate\") 返回 generated 时才代表周报已生成；日常保存学习记录不等于已生成周报。"
    static let note = """
历史与政治陪伴提示：保持项目人设自然交流，史实以用户纸质教材为准，时政以用户提供的本年资料为准；网络临时地图（temporary）注明待核对。练习与专题进度随时用 study_save_topic / study_save_practice 无锁保存。
"""
    static func note(for subject: StudySubject) -> String {
        subject == .english ? weeklyReportNote : note
    }
}

extension StudyToolExecutor {
    func performLessonAction(_ action: StudyToolAction, message: ChatMessage) throws -> String {
        let allowedInSubject = action.name == "study_weekly_report"
            || (scope.subject != .english && (!action.name.hasPrefix("study_history_") || scope.subject == .history))
        guard allowedInSubject else { throw StudyMemoryError.invalid("这项工具不属于当前项目。") }
        func json<T: Encodable>(_ x: T) throws -> String { String(decoding: try StudyCoding.encode(x), as: UTF8.self) }

        if action.name == "study_save_topic" {
            let receipt = try store.saveTopicFree(
                scope: scope,
                title: action.optionalText("title"),
                outlineID: action.optionalText("outline_id"),
                phase: action.optionalText("phase", default: "unknown"),
                level: action.optionalText("level"),
                note: action.optionalText("note"),
                pendingPrompt: action.optionalText("pending_prompt"),
                message: message
            )
            return try json(receipt)
        }
        if action.name == "study_save_practice" {
            let receipt = try store.savePracticeFree(
                scope: scope,
                recordRef: action.optionalText("record_id"),
                action: action.optionalText("action", default: "save"),
                area: action.optionalText("area"),
                kind: action.optionalText("kind", default: "oral"),
                question: action.optionalText("question"),
                answer: action.optionalText("answer"),
                outcome: action.optionalText("outcome", default: "unknown"),
                weakPoint: action.optionalText("weak_point"),
                sourceKind: action.optionalText("source_kind", default: "user_statement"),
                message: message
            )
            return try json(receipt)
        }
        if action.name == "study_topic_state" {
            struct Result: Encodable { let current: StudyTopicView?; let reviewOrder: [String] }
            return try json(Result(current: store.studyTopicState(scope: scope), reviewOrder: store.studyTopics(projectID: scope.projectID).map { "\($0.title) · \($0.level.title) · 记录日期 \($0.updatedAt)" }))
        }
        if action.name == "study_list_practice" {
            let q = try action.optionalText("query")
            return try json(store.studyPractices(projectID: scope.projectID).filter { q.isEmpty || ($0.question + $0.weakPoint + $0.area).localizedCaseInsensitiveContains(q) }.prefix(30).map(StudyPracticeView.init))
        }
        if action.name.hasPrefix("study_history_") {
            let kind = try action.optionalText("kind", default: "reference")
            let recordID = try action.optionalText("record_id").trimmingCharacters(in: .whitespacesAndNewlines)
            let isRead = action.name == "study_history_read" || !recordID.isEmpty
            if kind == "temporary" {
                guard let map = try store.temporaryHistoryMap(projectID: scope.projectID) else { return "还没有导入网络临时地图，可先按自主专题学习。" }
                let topics = try store.studyTopics(projectID: scope.projectID)
                struct Item: Encodable { let entry: StudyTemporaryMap.Entry; let sources: [StudyTemporaryMap.Source]; let progress: String }
                let selected: [StudyTemporaryMap.Entry]
                if isRead {
                    guard let entry = map.entries.first(where: { $0.id == recordID }) else { throw StudyMemoryError.invalid("临时地图里没有这项。") }
                    selected = [entry]
                } else {
                    let q = try action.optionalText("query")
                    selected = Array(map.entries.filter { q.isEmpty || ($0.title + $0.block).localizedCaseInsensitiveContains(q) }.prefix(30))
                }
                return "网络整理、待核；不是官方考纲。关联词条仅为关键词匹配。\n" + (try json(selected.map { e in
                    Item(entry: e, sources: map.sources.filter { e.sourceIDs.contains($0.id) }, progress: topics.first { $0.outlineID == e.id }?.level.title ?? "未学")
                }))
            }
            guard ["reference", "outline"].contains(kind) else { throw StudyMemoryError.invalid("请选择参考词条或已核对大纲。") }
            guard let pack = try store.studyHistoryPack(projectID: scope.projectID, kind: kind) else {
                return kind == "outline" ? "尚未导入用户核对的大纲，不能声称考纲完整。可以按自主专题学习。" : "尚未导入历史参考词条，可使用用户提供的书和项目文件。"
            }
            if isRead {
                guard let entry = pack.entries.first(where: { $0.id == recordID }) else { throw StudyMemoryError.invalid("当前项目没有这条资料。") }
                return "来源：\(pack.source)；核验状态：\(pack.verification)\n" + (try json(entry))
            }
            let query = try action.optionalText("query")
            struct Entry: Encodable { let id: String; let title: String; let block: String }
            let found = pack.entries.filter { query.isEmpty || ($0.title + $0.text).localizedCaseInsensitiveContains(query) }.prefix(30).map { Entry(id: $0.id, title: $0.title, block: $0.block) }
            return "来源：\(pack.source)；核验状态：\(pack.verification)\n" + (try json(found))
        }
        if action.name == "study_weekly_report" {
            let weeks = try action.optionalInt("weeks_ago", range: 0..<53) ?? 0
            let mode = try action.optionalText("mode", default: "read")
            guard ["read", "generate"].contains(mode) else { throw StudyMemoryError.invalid("请选择读取或生成周报。") }
            return try json(store.weeklyReport(scope: scope, weeksAgo: weeks, generate: mode == "generate"))
        }
        return try json(store.performLesson(action, scope: scope, message: message))
    }
}
