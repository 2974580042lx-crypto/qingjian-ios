import Foundation

enum StudyTopicLevel: String, Codable, CaseIterable, Sendable {
    case notStudied = "not_studied", studiedOnce = "studied_once", canOutline = "can_outline"
    var title: String { switch self { case .notStudied: return "未学"; case .studiedOnce: return "学过一遍"; case .canOutline: return "能口述提纲" } }
}
enum StudyLearningPhase: String, Codable, Sendable {
    case firstPass = "first_pass", review, unknown
    var title: String { switch self { case .firstPass: return "第一遍学习"; case .review: return "复习"; case .unknown: return "阶段未明确" } }
}
struct StudyTopic: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let outlineID: String?
    var revision: Int
    var phase: StudyLearningPhase
    var level: StudyTopicLevel
    var note: String
    var source: StudySource
    let createdAt: Date
    var updatedAt: Date
    var reference: String { "t_" + id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased() }
    var referenceNotice: String { outlineID?.hasPrefix("netmap:") == true ? "网络整理、待核" : outlineID == nil ? "自主专题" : "用户核对的学习地图" }
}
struct StudyTopicSession: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let topicID: UUID
    var threadID: UUID
    var revision: Int
    var pendingPrompt: String
    var paused: Bool
    var updatedAt: Date
}
struct StudyTopicView: Codable, Sendable {
    let topic_id: String
    let title: String
    let expected_revision: Int
    let session_revision: Int
    let phase: StudyLearningPhase
    let level: StudyTopicLevel
    let note: String
    let sourceKind: StudySource.Kind
    let pendingPrompt: String
    let paused: Bool
    var referenceNotice: String? = nil
}
struct StudyTopicEvent: Codable, Sendable {
    let id: UUID
    let action: String
    let before: StudyTopic?
    let after: StudyTopic
    let session: StudyTopicSession
    let source: StudySource
    let date: Date
}
enum StudyPracticeKind: String, Codable, CaseIterable, Sendable {
    case singleChoice = "single_choice", multipleChoice = "multiple_choice", oral, concept
    var title: String { switch self { case .singleChoice: return "单选"; case .multipleChoice: return "多选"; case .oral: return "口述"; case .concept: return "概念辨析" } }
}
enum StudyPracticeOutcome: String, Codable, Sendable { case correct, wrong, unknown }
struct StudyPractice: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var revision: Int
    var area: String
    var kind: StudyPracticeKind
    var question: String
    var answer: String
    var outcome: StudyPracticeOutcome
    var weakPoint: String
    var source: StudySource
    let createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool
    var reference: String { "p_" + id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased() }
    var questionIsQuoted: Bool { !question.isEmpty && source.text.contains(question) }
    var weakPointIsQuoted: Bool { !weakPoint.isEmpty && source.text.contains(weakPoint) }
    var countsForAccuracy: Bool { !isDeleted && source.kind == .userStatement && [.singleChoice, .multipleChoice].contains(kind) && !answer.isEmpty && outcome != .unknown }
}
struct StudyPracticeEvent: Codable, Sendable {
    let id: UUID
    let before: StudyPractice?
    let after: StudyPractice
    let source: StudySource
    let date: Date
}
struct StudyPracticeView: Codable, Sendable {
    let record_id: String
    let expected_revision: Int
    let area: String
    let kind: StudyPracticeKind
    let question: String
    let answer: String
    let outcome: StudyPracticeOutcome
    let weakPoint: String
    let sourceKind: StudySource.Kind
    let questionIsQuoted: Bool
    let weakPointIsQuoted: Bool
    let countsForAccuracy: Bool
    init(_ p: StudyPractice) {
        record_id = p.reference; expected_revision = p.revision; area = p.area; kind = p.kind
        question = p.question; answer = p.answer; outcome = p.outcome; weakPoint = p.weakPoint
        sourceKind = p.source.kind; countsForAccuracy = p.countsForAccuracy
        questionIsQuoted = p.questionIsQuoted; weakPointIsQuoted = p.weakPointIsQuoted
    }
}
struct StudyHistoryPack: Codable, Sendable {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let block: String
        let text: String
    }
    let schema: String
    let kind: String // reference or outline; outline is confirmed by the importer UI, not by model tools.
    let source: String
    let verification: String
    let entries: [Entry]
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16 * 1024 * 1024 else { throw StudyMemoryError.invalid("历史资料需小于16MB。") }
        let p = try StudyCoding.decode(Self.self, from: data)
        guard p.schema == "sermo.history.v1", ["reference", "outline"].contains(p.kind), !p.source.isEmpty,
              !p.verification.isEmpty, (1...5000).contains(p.entries.count), Set(p.entries.map(\.id)).count == p.entries.count,
              p.entries.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 160 && !$0.title.isEmpty && $0.title.count <= 200 && $0.text.count <= 12_000 && StudyLessonTools.historyAreas.contains($0.block) }) else {
            throw StudyMemoryError.invalid("历史资料格式、板块或条目标识不正确。")
        }
        return p
    }
}
struct StudyLessonReceipt: Codable, Sendable {
    let status: String
    var message: String
    var topic: StudyTopicView?
    var practice: StudyPracticeView?
}

extension StudyMemoryStore {
    func studyTopics(projectID: UUID) throws -> [StudyTopic] {
        try transaction { try rows(projectID: projectID, kind: "topic").map { try StudyCoding.decode(StudyTopic.self, from: $0) }.sorted { $0.updatedAt < $1.updatedAt } }
    }
    func studyPractices(projectID: UUID, includeDeleted: Bool = false) throws -> [StudyPractice] {
        try transaction { try rows(projectID: projectID, kind: "practice").map { try StudyCoding.decode(StudyPractice.self, from: $0) }.filter { includeDeleted || !$0.isDeleted }.sorted { $0.updatedAt > $1.updatedAt } }
    }
    func studyHistoryPack(projectID: UUID, kind: String) throws -> StudyHistoryPack? {
        try transaction { try read(StudyHistoryPack.self, projectID: projectID, kind: "history_pack", id: kind) }
    }
    func importStudyHistory(_ pack: StudyHistoryPack, scope: StudyScope, userConfirmedOutline: Bool) throws {
        guard scope.subject == .history, pack.kind != "outline" || userConfirmedOutline else { throw StudyMemoryError.invalid("正式学习地图须由用户核对后导入。") }
        _ = try StudyHistoryPack.decode(StudyCoding.encode(pack))
        try transaction {
            if let old = try read(StudyHistoryPack.self, projectID: scope.projectID, kind: "history_pack", id: pack.kind) {
                let previous = Dictionary(uniqueKeysWithValues: old.entries.map { ($0.id, $0) })
                guard pack.entries.allSatisfy({ previous[$0.id] == nil || previous[$0.id] == $0 }) else { throw StudyMemoryError.invalid("相同条目ID内容不同，尚未覆盖。资料版本迁移待实现。") }
                let incoming = Set(pack.entries.map(\.id))
                let merged = StudyHistoryPack(schema: pack.schema, kind: pack.kind, source: pack.source, verification: pack.verification,
                    entries: pack.entries + old.entries.filter { !incoming.contains($0.id) })
                guard merged.entries.count <= 5000, old.source == pack.source, old.verification == pack.verification else {
                    throw StudyMemoryError.invalid("不同来源的历史资料请分别整理，当前没有覆盖旧来源。")
                }
                try write(merged, projectID: scope.projectID, kind: "history_pack", id: pack.kind)
            } else { try write(pack, projectID: scope.projectID, kind: "history_pack", id: pack.kind) }
        }
    }
    private func lessonSessions(_ project: UUID) throws -> [StudyTopicSession] {
        try rows(projectID: project, kind: "topic_session").map { try StudyCoding.decode(StudyTopicSession.self, from: $0) }.sorted { $0.updatedAt > $1.updatedAt }
    }
    private func topicView(_ topic: StudyTopic, _ session: StudyTopicSession) -> StudyTopicView {
        .init(topic_id: topic.reference, title: topic.title, expected_revision: topic.revision, session_revision: session.revision,
              phase: topic.phase, level: topic.level, note: topic.note, sourceKind: topic.source.kind, pendingPrompt: session.pendingPrompt, paused: session.paused, referenceNotice: topic.referenceNotice)
    }
    func studyTopicState(scope: StudyScope) throws -> StudyTopicView? {
        try transaction {
            guard let session = try lessonSessions(scope.projectID).first(where: { $0.threadID == scope.threadID }),
                  let topic = try read(StudyTopic.self, projectID: scope.projectID, kind: "topic", id: session.topicID.uuidString) else { return nil }
            return topicView(topic, session)
        }
    }
    func performLesson(_ action: StudyToolAction, scope: StudyScope, message: ChatMessage) throws -> StudyLessonReceipt {
        guard scope.subject != .english, message.role == .user else { throw StudyMemoryError.invalid("请在历史或政治项目中引用用户消息。") }
        if let raw = action.arguments["source_kind"] as? String, !["user_statement", "model_inference"].contains(raw) { throw StudyMemoryError.invalid("来源类型不正确。") }
        let kind: StudySource.Kind = action.arguments["source_kind"] as? String == "model_inference" ? .modelInference : .userStatement
        let quote = (action.arguments["evidence_quote"] as? String) ?? String(message.content.prefix(4000))
        let source = StudySource.from(message: message, scope: scope, kind: kind, quote: quote)
        try source.validate(scope: scope)
        var sourceIdentity = source; sourceIdentity.messageDate = nil
        var identity = try JSONSerialization.data(withJSONObject: action.arguments, options: [.sortedKeys])
        identity.append(try StudyCoding.encode(sourceIdentity))
        let fingerprint = StudyCoding.hash(identity)
        let target = (action.arguments["record_id"] as? String) ?? (action.arguments["title"] as? String) ?? "current"
        let op = StudyCoding.hash(Data((message.id.uuidString + "/" + action.name + "/" + target).utf8))
        struct Operation: Codable { let fingerprint: String; let receipt: StudyLessonReceipt }
        return try transaction {
            if let old = try read(Operation.self, projectID: scope.projectID, kind: "lesson_operation", id: op) {
                guard old.fingerprint == fingerprint else { throw StudyMemoryError.conflict }; return old.receipt
            }
            let now = Date()
            var receipt = StudyLessonReceipt(status: "committed", message: "学习记录已保存。")
            if action.name.contains("practice") {
                let all = try rows(projectID: scope.projectID, kind: "practice").map { try StudyCoding.decode(StudyPractice.self, from: $0) }
                var old: StudyPractice?
                if action.name != "study_record_practice" {
                    let ref = try action.text("record_id"), revision = try action.integer("expected_revision")
                    let found = all.filter { $0.reference == ref && !$0.isDeleted }
                    guard found.count == 1, found[0].revision == revision else { throw StudyMemoryError.conflict }; old = found[0]
                }
                var next: StudyPractice
                if action.name == "study_remove_practice", var value = old {
                    guard source.kind == .userStatement else { throw StudyMemoryError.invalid("删除练习记录需要用户明确原话。") }
                    value.isDeleted = true; value.revision += 1; value.updatedAt = now; value.source = source; next = value
                } else {
                    let area = try action.text("area"), question = try action.text("question"), answer = try action.text("answer")
                    let areas = scope.subject == .history ? StudyLessonTools.historyAreas : StudyLessonTools.politicsAreas
                    guard areas.contains(area), let type = StudyPracticeKind(rawValue: try action.text("kind")),
                          let outcome = StudyPracticeOutcome(rawValue: try action.text("outcome")), !question.isEmpty,
                          !answer.isEmpty || outcome == .unknown else { throw StudyMemoryError.invalid("请选择有效板块、题型和实际作答；未作答不能判断对错。") }
                    next = .init(id: old?.id ?? UUID(), revision: (old?.revision ?? 0) + 1, area: area, kind: type,
                                 question: question, answer: answer, outcome: outcome, weakPoint: try action.text("weak_point"),
                                 source: source, createdAt: old?.createdAt ?? now, updatedAt: now, isDeleted: false)
                }
                try write(next, projectID: scope.projectID, kind: "practice", id: next.id.uuidString)
                let event = StudyPracticeEvent(id: UUID(), before: old, after: next, source: source, date: now)
                try write(event, projectID: scope.projectID, kind: "practice_event", id: op)
                receipt.practice = StudyPracticeView(next)
                receipt.message = next.isDeleted ? "已移出有效练习记录，历史保留。" : old == nil ? "已保存本次练习，模型判断与用户确认分别标记。" : "已更正原练习，原记录留在历史，没有重复计题。"
            } else {
                let sessions = try lessonSessions(scope.projectID)
                var old: StudyTopic?, topic: StudyTopic, session: StudyTopicSession
                if action.name == "study_start_topic" {
                    var title = try action.text("title")
                    let outline = try action.text("outline_id"), mode = try action.text("mode")
                    guard ["start", "continue"].contains(mode), title.count <= 200, let phase = StudyLearningPhase(rawValue: try action.text("phase")) else { throw StudyMemoryError.invalid("专题参数不正确。") }
                    let topics = try rows(projectID: scope.projectID, kind: "topic").map { try StudyCoding.decode(StudyTopic.self, from: $0) }
                    let eligible = sessions.filter { s in topics.contains { $0.id == s.topicID && (outline.isEmpty ? (title.isEmpty || $0.title == title) : $0.outlineID == outline) } }
                    if mode == "continue", var previous = eligible.first(where: { $0.threadID == scope.threadID }) ?? eligible.first,
                       let t = topics.first(where: { $0.id == previous.topicID }) {
                        old = t; topic = t; previous.threadID = scope.threadID; previous.paused = false; previous.revision += 1; session = previous
                    } else {
                        guard mode == "start" else { throw StudyMemoryError.invalid("没有找到已保存的专题现场，请先确认要开始的专题。") }
                        if !outline.isEmpty {
                            guard scope.subject == .history else { throw StudyMemoryError.invalid("地图条目只用于历史项目。") }
                            if outline.hasPrefix("netmap:") {
                                guard let map = try read(StudyTemporaryMap.self, projectID: scope.projectID, kind: "temporary_map", id: "network"),
                                      let entry = map.entries.first(where: { $0.id == outline }) else { throw StudyMemoryError.invalid("找不到这条临时地图记录。") }
                                title = entry.title
                            } else {
                                guard let map = try read(StudyHistoryPack.self, projectID: scope.projectID, kind: "history_pack", id: "outline"),
                                      let entry = map.entries.first(where: { $0.id == outline }) else { throw StudyMemoryError.invalid("该大纲条目尚未由用户核对导入；可使用临时地图或自主专题。") }
                                title = entry.title
                            }
                        }
                        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudyMemoryError.invalid("请先告诉我想学什么。") }
                        old = topics.first { outline.isEmpty ? ($0.title == title && $0.outlineID == nil) : $0.outlineID == outline }
                        topic = old ?? .init(id: UUID(), title: title, outlineID: outline.isEmpty ? nil : outline, revision: 1,
                            phase: phase, level: .notStudied, note: "", source: source, createdAt: now, updatedAt: now)
                        session = .init(id: UUID(), topicID: topic.id, threadID: scope.threadID, revision: 1, pendingPrompt: "", paused: false, updatedAt: now)
                    }
                } else {
                    guard var s = sessions.first(where: { $0.threadID == scope.threadID }), s.revision == (try action.integer("session_revision")),
                          let t = try read(StudyTopic.self, projectID: scope.projectID, kind: "topic", id: s.topicID.uuidString) else { throw StudyMemoryError.conflict }
                    old = t; topic = t
                    if action.name == "study_pause_topic" { s.paused = true }
                    else {
                        guard !s.paused, t.revision == (try action.integer("expected_revision")),
                              let phase = StudyLearningPhase(rawValue: try action.text("phase")),
                              let level = StudyTopicLevel(rawValue: try action.text("level")) else { throw StudyMemoryError.conflict }
                        topic.phase = phase; topic.level = level; topic.note = try action.text("note"); topic.source = source
                        topic.revision += 1; topic.updatedAt = now; s.pendingPrompt = try action.text("pending_prompt")
                    }
                    s.revision += 1; session = s
                }
                session.updatedAt = now
                try write(topic, projectID: scope.projectID, kind: "topic", id: topic.id.uuidString)
                try write(session, projectID: scope.projectID, kind: "topic_session", id: session.id.uuidString)
                try write(StudyTopicEvent(id: UUID(), action: action.name, before: old, after: topic, session: session, source: source, date: now), projectID: scope.projectID, kind: "topic_event", id: op)
                receipt.topic = topicView(topic, session)
                receipt.message = session.paused ? "已暂停，专题与待回答内容已保存。" : "专题现场已保存，进度判断保留出处。"
            }
            try write(Operation(fingerprint: fingerprint, receipt: receipt), projectID: scope.projectID, kind: "lesson_operation", id: op)
            return receipt
        }
    }

    func saveTopicFree(
        scope: StudyScope,
        title: String,
        outlineID: String,
        phase: String,
        level: String,
        note: String,
        pendingPrompt: String,
        message: ChatMessage
    ) throws -> StudyLessonReceipt {
        guard scope.subject != .english, message.role == .user else {
            throw StudyMemoryError.invalid("请在历史或政治项目中保存专题进度。")
        }
        let now = Date()
        let quote = message.content.isEmpty ? "专题学习" : String(message.content.prefix(4000))
        let kind: StudySource.Kind = message.content.isEmpty ? .modelInference : .userStatement
        let source = StudySource.from(message: message, scope: scope, kind: kind, quote: quote)

        return try transaction {
            let sessions = try lessonSessions(scope.projectID)
            let topics = try rows(projectID: scope.projectID, kind: "topic").map { try StudyCoding.decode(StudyTopic.self, from: $0) }
            var cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanOutline = outlineID.trimmingCharacters(in: .whitespacesAndNewlines)

            if !cleanOutline.isEmpty, scope.subject == .history {
                if cleanOutline.hasPrefix("netmap:"),
                   let map = try read(StudyTemporaryMap.self, projectID: scope.projectID, kind: "temporary_map", id: "network"),
                   let entry = map.entries.first(where: { $0.id == cleanOutline }) {
                    cleanTitle = entry.title
                } else if let map = try read(StudyHistoryPack.self, projectID: scope.projectID, kind: "history_pack", id: "outline"),
                          let entry = map.entries.first(where: { $0.id == cleanOutline }) {
                    cleanTitle = entry.title
                }
            }

            let old: StudyTopic?
            var topic: StudyTopic
            var session: StudyTopicSession

            if cleanTitle.isEmpty && cleanOutline.isEmpty {
                guard var activeSession = sessions.first(where: { $0.threadID == scope.threadID }) ?? sessions.first,
                      let existingTopic = topics.first(where: { $0.id == activeSession.topicID }) else {
                    throw StudyMemoryError.invalid("当前还没有进行中的专题，请传入专题名称 title。")
                }
                old = existingTopic
                topic = existingTopic
                activeSession.threadID = scope.threadID
                activeSession.paused = false
                activeSession.revision += 1
                session = activeSession
            } else {
                let matchedTopic = topics.first {
                    !cleanOutline.isEmpty ? $0.outlineID == cleanOutline : ($0.title == cleanTitle && $0.outlineID == nil)
                }
                old = matchedTopic
                let resolvedTitle = cleanTitle.isEmpty ? (matchedTopic?.title ?? cleanOutline) : String(cleanTitle.prefix(200))
                topic = matchedTopic ?? StudyTopic(
                    id: UUID(),
                    title: resolvedTitle,
                    outlineID: cleanOutline.isEmpty ? nil : cleanOutline,
                    revision: 0,
                    phase: StudyLearningPhase(rawValue: phase) ?? .unknown,
                    level: StudyTopicLevel(rawValue: level) ?? .notStudied,
                    note: "",
                    source: source,
                    createdAt: now,
                    updatedAt: now
                )
                if var matchedSession = sessions.first(where: { $0.topicID == topic.id && $0.threadID == scope.threadID })
                    ?? sessions.first(where: { $0.topicID == topic.id }) {
                    matchedSession.threadID = scope.threadID
                    matchedSession.paused = false
                    matchedSession.revision += 1
                    session = matchedSession
                } else {
                    session = StudyTopicSession(
                        id: UUID(), topicID: topic.id, threadID: scope.threadID,
                        revision: 1, pendingPrompt: "", paused: false, updatedAt: now
                    )
                }
            }

            if let parsedPhase = StudyLearningPhase(rawValue: phase) { topic.phase = parsedPhase }
            if let parsedLevel = StudyTopicLevel(rawValue: level) { topic.level = parsedLevel }
            if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { topic.note = note }
            if !pendingPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || argumentsCleared(pendingPrompt) {
                session.pendingPrompt = pendingPrompt
            }
            topic.revision += 1
            topic.source = source
            topic.updatedAt = now
            session.updatedAt = now

            let op = StudyCoding.hash(Data("\(message.id.uuidString)/free-topic/\(topic.id.uuidString)/\(topic.revision)".utf8))
            try write(topic, projectID: scope.projectID, kind: "topic", id: topic.id.uuidString)
            try write(session, projectID: scope.projectID, kind: "topic_session", id: session.id.uuidString)
            try write(StudyTopicEvent(id: UUID(), action: "study_save_topic", before: old, after: topic, session: session, source: source, date: now),
                      projectID: scope.projectID, kind: "topic_event", id: op)
            return StudyLessonReceipt(status: "committed", message: "已保存专题进度《\(topic.title)》。", topic: topicView(topic, session), practice: nil)
        }
    }

    private func argumentsCleared(_ text: String) -> Bool {
        text.isEmpty
    }

    func savePracticeFree(
        scope: StudyScope,
        recordRef: String,
        action: String,
        area: String,
        kind: String,
        question: String,
        answer: String,
        outcome: String,
        weakPoint: String,
        sourceKind: String,
        message: ChatMessage
    ) throws -> StudyLessonReceipt {
        guard scope.subject != .english, message.role == .user else {
            throw StudyMemoryError.invalid("请在历史或政治项目中保存练习记录。")
        }
        let now = Date()
        let inferred = sourceKind == "model_inference" || message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let resolvedSourceKind: StudySource.Kind = inferred ? .modelInference : .userStatement
        let quote = message.content.isEmpty ? "" : String(message.content.prefix(4000))
        let source = StudySource.from(message: message, scope: scope, kind: resolvedSourceKind, quote: quote)

        return try transaction {
            let all = try rows(projectID: scope.projectID, kind: "practice").map { try StudyCoding.decode(StudyPractice.self, from: $0) }
            let cleanRef = recordRef.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let old: StudyPractice?
            if !cleanRef.isEmpty {
                guard let hit = all.first(where: { !$0.isDeleted && ($0.reference == cleanRef || $0.id.uuidString.lowercased() == cleanRef) }) else {
                    throw StudyMemoryError.invalid("找不到对应的练习记录（\(recordRef)）。")
                }
                old = hit
            } else {
                old = nil
            }

            let isDelete = ["delete", "remove", "forget"].contains(action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            let next: StudyPractice
            if isDelete {
                guard var existing = old else { throw StudyMemoryError.invalid("删除练习记录时请提供 record_id。") }
                existing.isDeleted = true
                existing.revision += 1
                existing.updatedAt = now
                existing.source = source
                next = existing
            } else {
                let validAreas = scope.subject == .history ? StudyLessonTools.historyAreas : StudyLessonTools.politicsAreas
                let resolvedArea = validAreas.contains(area) ? area : (old?.area ?? validAreas[0])
                let resolvedKind = StudyPracticeKind(rawValue: kind) ?? old?.kind ?? .oral
                let trimmedQ = question.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedQuestion = trimmedQ.isEmpty ? (old?.question ?? "题干未完整提供") : trimmedQ
                let resolvedAnswer = answer.isEmpty && old != nil && trimmedQ.isEmpty ? (old?.answer ?? "") : answer
                var resolvedOutcome = StudyPracticeOutcome(rawValue: outcome) ?? old?.outcome ?? .unknown
                if resolvedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    resolvedOutcome = .unknown
                }
                let resolvedWeak = weakPoint.isEmpty ? (old?.weakPoint ?? "") : weakPoint
                next = StudyPractice(
                    id: old?.id ?? UUID(),
                    revision: (old?.revision ?? 0) + 1,
                    area: resolvedArea,
                    kind: resolvedKind,
                    question: resolvedQuestion,
                    answer: resolvedAnswer,
                    outcome: resolvedOutcome,
                    weakPoint: resolvedWeak,
                    source: source,
                    createdAt: old?.createdAt ?? now,
                    updatedAt: now,
                    isDeleted: false
                )
            }

            let op = StudyCoding.hash(Data("\(message.id.uuidString)/free-practice/\(next.id.uuidString)/\(next.revision)".utf8))
            try write(next, projectID: scope.projectID, kind: "practice", id: next.id.uuidString)
            try write(StudyPracticeEvent(id: UUID(), before: old, after: next, source: source, date: now),
                      projectID: scope.projectID, kind: "practice_event", id: op)
            return StudyLessonReceipt(
                status: "committed",
                message: next.isDeleted ? "已移出有效练习记录。" : (old == nil ? "已保存本次练习记录。" : "已更新原练习记录。"),
                topic: nil,
                practice: StudyPracticeView(next)
            )
        }
    }
}
