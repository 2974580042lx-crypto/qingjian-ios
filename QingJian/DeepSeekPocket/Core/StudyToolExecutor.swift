import Foundation

/// Shared by the iOS chat path and the macOS live-model acceptance test.
/// The caller supplies the authorized project/window and the real user message.
struct StudyToolExecutor {
    let store: StudyMemoryStore
    let scope: StudyScope
    let documents: [ProjectDocument]

    func context(query: String) throws -> String {
        let context = try store.context(scope: scope, query: query)
        let catalog = documents.map { "\($0.id.uuidString) · \($0.name)" }.joined(separator: "\n")
        var result = context + (catalog.isEmpty ? "" : "\n项目资料目录\n" + catalog)
        if scope.subject != .english {
            if let state = try store.studyTopicState(scope: scope) { result += "\n当前专题现场：" + String(decoding: try StudyCoding.encode(state), as: UTF8.self) }
            let topics = try store.studyTopics(projectID: scope.projectID)
            if !topics.isEmpty { result += "\n复习顺序（按上次记录日期，未声称已学会）：\n" + topics.prefix(15).map { "\($0.title) · \($0.level.title) · \($0.phase.title)" }.joined(separator: "\n") }
            if scope.subject == .history {
                let outline = try store.studyHistoryPack(projectID: scope.projectID, kind: "outline")
                result += outline == nil ? "\n尚未导入用户核对的正式大纲。参考词条不能替代正式大纲。" : "\n用户核对的学习地图共\(outline!.entries.count)条，按需搜索读取。"
                if let map = try store.temporaryHistoryMap(projectID: scope.projectID) {
                    result += "\n另有网络临时学习地图\(map.entries.count)条，全部网络整理、待核。用study_history_search/read，kind=temporary按需查，保留来源差异；进度使用netmap:条目ID。"
                }
            }
        }
        if scope.subject == .english {
            let readingIndex = try store.readingCatalog(projectID: scope.projectID)
            if !readingIndex.isEmpty {
                result += "\n阅读 index.md（仅目录，正文按需读取）\n" + readingIndex.map {
                    "\($0.id) · \($0.title) · \($0.words)词 · \($0.topic ?? "主题未标注")"
                }.joined(separator: "\n")
            }
            if let reading = try store.readingState(scope: scope) {
                result += "\n阅读现场（不是完成或掌握声明）：" + String(decoding: try StudyCoding.encode(reading), as: UTF8.self)
            }
            let state = try store.wordState(scope: scope)
            if state.session != nil {
                result += "\n当前背词现场：" + String(decoding: try StudyCoding.encode(state), as: UTF8.self)
            }
        }
        return result
    }
    func perform(_ action: StudyToolAction, sourceMessage: ChatMessage) throws -> String {
        guard sourceMessage.role == .user else { throw StudyMemoryError.invalid("学习操作需要用户消息出处。") }
        if StudyLessonTools.names.contains(action.name) { return try performLessonAction(action, message: sourceMessage) }
        if StudyReadingTools.names.contains(action.name) { return try performReadingAction(action, message: sourceMessage) }
        let memory = store
        if StudyWordTools.names.contains(action.name) {
            return try performWordAction(action, message: sourceMessage)
        }
        if action.name == "study_list_memory" {
            let query = try action.text("query").trimmingCharacters(in: .whitespacesAndNewlines)
            let records = try memory.records(projectID: scope.projectID).filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || $0.category.contains(query) }
            return String(decoding: try StudyCoding.encode(records.prefix(30).map(StudyModelMemory.init)), as: UTF8.self)
        }
        if action.name == "study_read_material" {
            let id = try action.text("document_id")
            guard let document = documents.first(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else {
                throw StudyMemoryError.invalid("当前项目找不到这份资料。")
            }
            return "引用资料《\(document.name)》\n" + document.text
        }
        var resolved = action
        if action.name == "study_correct" || action.name == "study_forget" {
            let reference = try action.text("record_id")
            if UUID(uuidString: reference) == nil {
                let matches = try memory.records(projectID: scope.projectID).filter { $0.toolReference == reference.lowercased() }
                guard matches.count == 1 else { throw StudyMemoryError.invalid("记录引用不存在或不唯一，请重新查询当前项目记忆。") }
                var arguments = action.arguments; arguments["record_id"] = matches[0].id.uuidString
                resolved = try StudyToolAction(ToolCall(id: "resolved", name: action.name, arguments: String(decoding: JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)))
            }
        }
        let command = try resolved.command(scope: scope, message: sourceMessage)
        // One logical change per message, action and target. A network retry or
        // regeneration must reuse it even when the provider changes its call ID.
        let operationID = StudyCoding.hash(Data((sourceMessage.id.uuidString + "/" + action.name + "/" + (command.recordID?.uuidString ?? command.category)).utf8))
        let receipt = try memory.apply(command, scope: scope, operationID: operationID)
        struct Result: Encodable { let status = "committed"; let message: String; let record: StudyModelMemory }
        return String(decoding: try StudyCoding.encode(Result(message: receipt.message, record: StudyModelMemory(receipt.event.after))), as: UTF8.self)
    }
    private func performWordAction(_ action: StudyToolAction, message: ChatMessage) throws -> String {
        guard scope.subject == .english else { throw StudyMemoryError.invalid("请在考研英语项目中背词。") }
        let memory = store
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try StudyCoding.encode(value), as: UTF8.self) }
        func sessionID() throws -> UUID {
            let raw = try action.text("session_id")
            if raw == "current" {
                guard let id = try memory.wordState(scope: scope).session?.id else { throw StudyMemoryError.invalid("当前窗口还没有背词任务，请先开始或接续一轮。") }
                return id
            }
            return try action.uuid("session_id")
        }
        if action.name == "study_word_state" {
            let state = try memory.wordState(scope: scope)
            return try json(state)
        }
        if action.name == "study_start_words" {
            guard let mode = StudyWordMode(rawValue: try action.text("mode")) else { throw StudyMemoryError.invalid("背词模式不正确。") }
            _ = try memory.startWords(scope: scope, unitID: action.text("unit_id"), count: action.integer("count", range: 1..<31), mode: mode, sourceMessageID: message.id)
            return try json(memory.wordState(scope: scope))
        }
        if action.name == "study_grade_word" {
            let source = StudySource(kind: .userStatement, threadID: scope.threadID, messageID: message.id,
                text: message.content, quote: try action.text("evidence_quote"), messageDate: message.createdAt)
            let wordReference = try action.text("word_id")
            let wordID: String
            if wordReference == "current" {
                guard let id = try memory.wordState(scope: scope).session?.currentWordID else { throw StudyMemoryError.invalid("当前没有等待回答的词。") }
                wordID = id
            } else { wordID = wordReference }
            let grade = StudyWordGrade(sessionID: try sessionID(), expectedRevision: try action.integer("expected_revision"),
                wordID: wordID, rating: try action.text("rating"), source: source)
            let id = StudyCoding.hash(Data((message.id.uuidString + "/word/" + grade.sessionID.uuidString + "/" + grade.wordID).utf8))
            _ = try memory.gradeWord(grade, scope: scope, operationID: id)
            return "本次回答、评分及进度已保存。周报尚未生成。\n" + (try json(memory.wordState(scope: scope)))
        }
        if action.name == "study_undo_word" {
            _ = try memory.undoWord(scope: scope, sessionID: sessionID(), expectedRevision: action.integer("expected_revision"))
            return "已撤销最近一题评分。\n" + (try json(memory.wordState(scope: scope)))
        }
        if action.name == "study_pause_words" {
            _ = try memory.pauseWords(scope: scope, sessionID: sessionID(), expectedRevision: action.integer("expected_revision"))
            return "已暂停，当前词和进度已保存。\n" + (try json(memory.wordState(scope: scope)))
        }
        guard let pack = try memory.wordPack(projectID: scope.projectID) else { throw StudyMemoryError.invalid("请先在项目记忆页导入私人词库。") }
        let progress = try memory.wordProgress(projectID: scope.projectID)
        let lookup = Dictionary(uniqueKeysWithValues: progress.map { ($0.wordID, $0) })
        if action.name == "study_find_word" {
            let query = try action.text("query").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { throw StudyMemoryError.invalid("请提供要查的词或释义。") }
            let found = pack.cards.filter { $0.id == query || $0.word.localizedCaseInsensitiveContains(query) || $0.meaning.localizedCaseInsensitiveContains(query) || $0.translation.localizedCaseInsensitiveContains(query) }.prefix(12)
            return try json(found.map { word in StudyWordView(word: word, reviewCount: lookup[word.id]?.reviewCount ?? 0,
                lastRating: lookup[word.id]?.lastRating, lastReviewedAt: lookup[word.id]?.lastReviewedAt, due: lookup[word.id]?.due) })
        }
        var units: [String: StudyWord.Unit] = [:]
        for word in pack.cards { for unit in word.units where unit.isCore { units[unit.id] = unit } }
        let ordered = units.values.sorted { ($0.collection == "required" ? 0 : 1, $0.number) < ($1.collection == "required" ? 0 : 1, $1.number) }
        return try json(ordered.map { unit in
            let words = pack.cards.filter { $0.units.contains { $0.id == unit.id } }
            return StudyWordUnitOverview(id: unit.id, title: unit.title, total: words.count,
                learned: words.filter { (lookup[$0.id]?.reviewCount ?? 0) > 0 }.count,
                due: words.filter { lookup[$0.id].map { $0.reviewCount > 0 && $0.due <= Date() } == true }.count)
        })
    }

}
