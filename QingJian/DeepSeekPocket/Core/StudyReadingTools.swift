import Foundation

enum StudyReadingTools {
    static let fields: [String: Set<String>] = [
        "study_reading_catalog": ["query"],
        "study_read_passage": ["passage_id", "paragraph", "question", "show_answer"],
        "study_answer_reading": ["passage_id", "question", "choice", "expected_revision", "evidence_quote"],
        // Legacy internal tool schemas preserved for backward compatibility
        "study_reading_state": [],
        "study_open_reading": ["passage_id", "mode"],
        "study_show_reading": ["kind", "number", "expected_revision"],
        "study_reading_reference": ["skip_without_answer", "expected_revision", "evidence_quote"],
        "study_pause_reading": ["expected_revision"],
        "study_collect_reading_word": ["word", "original_sentence", "expected_revision", "evidence_quote"]
    ]
    static let names = Set(fields.keys)
    static let titles = [
        "study_reading_catalog": "已读取阅读目录",
        "study_read_passage": "已读取阅读原文与题目",
        "study_reading_state": "已找回阅读位置",
        "study_open_reading": "已接续阅读",
        "study_show_reading": "已读取资料原文",
        "study_answer_reading": "已保存本题作答",
        "study_reading_reference": "已读取参考答案",
        "study_pause_reading": "阅读现场已保存",
        "study_collect_reading_word": "已保存生词与原文出处"
    ]

    static let specs: [ToolSpec] = [
        .init(
            name: "study_reading_catalog",
            description: "检索当前英语项目的真题阅读篇目目录（按年份、标题或话题筛选，留空列出全部目录）。",
            parameters: ToolSpec.object([
                ("query", "string", "可选：年份（如 2024）、标题或主题关键词；留空列全部")
            ], required: [])
        ),
        .init(
            name: "study_read_passage",
            description: "一步读取或接续真题阅读的指定段落、题目与参考解析（App 会直接在气泡上方渲染清晰的资料原文卡片，你在回复里不要重复抄写整段英文或选项）。",
            parameters: ToolSpec.object([
                ("passage_id", "string", "可选：目录中的篇目 ID（如 2024-text-1）；已在读或接续上次时可留空"),
                ("paragraph", "integer", "可选：要展示的原文段落号（从 1 开始）"),
                ("question", "integer", "可选：要展示的原卷题号（如 21、36）"),
                ("show_answer", "boolean", "可选：默认 false；用户答完后需要查看官方参考解析卡片或明确要求直接看答案时传 true")
            ], required: [])
        ),
        .init(
            name: "study_answer_reading",
            description: "无锁记录用户的阅读题选项（如口语说‘是不是应该选 A’‘我猜 B’即视为作答），并直接返回参考答案与解析供你自然点评。",
            parameters: ToolSpec.object([
                ("passage_id", "string", "可选：篇目 ID；留空默认使用当前正在读的篇目"),
                ("question", "integer", "可选：原卷题号；留空默认使用当前待答题目"),
                ("choice", "string", "用户选择的 A / B / C / D；若用户明确不答直接跳过传 skip")
            ], required: ["choice"])
        )
    ]

    static let note = """
阅读陪伴提示：工具返回的原文段落与题目选项由 App 直接渲染为卡片，回复中无需重复抄写英文原文；未答题前不提前剧透答案，用户口语猜选项（如“是不是选 A”）即可调 study_answer_reading 判分并自然讲解。需要收藏文中生词时直接调 study_remember(category: "生词", text: "...")。
"""
}

extension StudyToolExecutor {
    func performReadingAction(_ action: StudyToolAction, message: ChatMessage) throws -> String {
        guard scope.subject == .english else { throw StudyMemoryError.invalid("请在英语项目中使用阅读资料。") }
        if action.name == "study_reading_catalog" {
            let query = try action.optionalText("query").trimmingCharacters(in: .whitespacesAndNewlines)
            let catalog = try store.readingCatalog(projectID: scope.projectID).filter {
                query.isEmpty || ($0.id + " " + $0.title + " " + ($0.topic ?? "")).localizedCaseInsensitiveContains(query)
            }
            return String(decoding: try StudyCoding.encode(catalog), as: UTF8.self)
        }
        if action.name == "study_read_passage" {
            let result = try store.readPassageFree(
                scope: scope,
                passageID: action.optionalText("passage_id"),
                paragraph: action.optionalInt("paragraph", range: 1..<200),
                question: action.optionalInt("question", range: 1..<200),
                showAnswer: action.optionalBool("show_answer", default: false),
                message: message
            )
            return String(decoding: try StudyCoding.encode(result), as: UTF8.self)
        }
        if action.name == "study_answer_reading", action.arguments["expected_revision"] == nil {
            let result = try store.answerReadingFree(
                scope: scope,
                passageID: action.optionalText("passage_id"),
                question: action.optionalInt("question", range: 1..<200),
                choice: action.text("choice"),
                message: message
            )
            return String(decoding: try StudyCoding.encode(result), as: UTF8.self)
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
