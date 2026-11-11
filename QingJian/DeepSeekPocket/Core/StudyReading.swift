import Foundation

struct StudyReadingPassage: Codable, Equatable, Identifiable, Sendable {
    struct Question: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let number: Int
        let stem: String
        let options: [String]
        let answer: Int?
        let explanation: String?
        let verification: String
        let source: String
        let sourceURL: String?
        var verifiedAnswer: Int? { verification == "verified" ? answer : nil }
    }
    let id: String
    let title: String
    let year: Int
    let textNumber: Int
    let paragraphs: [String]
    let questions: [Question]
    let source: String
    let sourceURL: String?
    let topic: String?
    var fingerprint: String { (try? StudyCoding.hash(StudyCoding.encode(self))) ?? "" }
    var catalog: StudyReadingCatalogEntry {
        .init(id: id, title: title, year: year, textNumber: textNumber, topic: topic,
              words: paragraphs.joined(separator: " ").split { !$0.isLetter && $0 != "'" && $0 != "’" }.count,
              paragraphs: paragraphs.count, questions: questions.map(\.number),
              pendingAnswers: questions.filter { $0.verifiedAnswer == nil }.map(\.number), fingerprint: fingerprint)
    }
}

struct StudyReadingPack: Codable, Sendable {
    let schema: String
    let passages: [StudyReadingPassage]
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32 * 1024 * 1024 else { throw StudyMemoryError.invalid("阅读资料需小于 32 MB。") }
        let pack = try StudyCoding.decode(Self.self, from: data)
        guard pack.schema == "sermo.readings.v1", !pack.passages.isEmpty, pack.passages.count <= 400,
              Set(pack.passages.map(\.id)).count == pack.passages.count else { throw StudyMemoryError.invalid("阅读资料格式或篇目标识有误。") }
        for p in pack.passages {
            guard p.id.range(of: #"^[a-zA-Z0-9_-]{1,100}$"#, options: .regularExpression) != nil,
                  (1900...2200).contains(p.year), (1...4).contains(p.textNumber), !p.title.isEmpty,
                  !p.source.isEmpty, (1...40).contains(p.paragraphs.count),
                  p.paragraphs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 15_000 && !$0.contains("\u{FFFD}") }),
                  (1...20).contains(p.questions.count), Set(p.questions.map(\.number)).count == p.questions.count,
                  Set(p.questions.map(\.id)).count == p.questions.count else { throw StudyMemoryError.invalid("篇目内容缺失、乱码或标识重复：\(p.id)") }
            for q in p.questions {
                guard !q.id.isEmpty, (1...100).contains(q.number), !q.stem.isEmpty, q.stem.count <= 4000,
                      q.options.count == 4, q.options.allSatisfy({ !$0.isEmpty && $0.count <= 4000 }),
                      q.answer.map({ (0...3).contains($0) }) ?? true,
                      q.verification != "verified" || q.answer != nil else { throw StudyMemoryError.invalid("题目或选项不完整：\(q.id)") }
            }
        }
        return pack
    }
}

struct StudyReadingCatalogEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let year: Int
    let textNumber: Int
    let topic: String?
    let words: Int
    let paragraphs: Int
    let questions: [Int]
    let pendingAnswers: [Int]
    let fingerprint: String
}

struct StudyReadingExcerpt: Codable, Equatable, Sendable {
    let title: String
    let text: String
    let source: String
    let sourceURL: String?
}

struct StudyMaterialReference: Codable, Equatable, Sendable {
    let passageID: String
    let passageTitle: String
    let passageFingerprint: String
    let paragraph: Int
    let originalSentence: String
    let word: String
    let linkedWordIDs: [String]
    let source: String
    let sourceURL: String?
}

struct StudyReadingSession: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var threadID: UUID
    let passageID: String
    let passageFingerprint: String
    var paragraph = 1
    var question: Int?
    var questionMessageID: UUID?
    var questionIssuedAt: Date?
    var revision = 1
    var paused = false
    var updatedAt: Date
}

struct StudyReadingAnswer: Codable, Equatable, Sendable {
    let sessionID: UUID
    let question: Int
    let revision: Int
    let choice: String?
    let skipped: Bool
    let referenceAnswer: String?
    let correct: Bool?
    let source: StudySource
    let date: Date
}

struct StudyReadingEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let action: String
    let before: StudyReadingSession?
    let after: StudyReadingSession
    let oldAnswer: StudyReadingAnswer?
    let newAnswer: StudyReadingAnswer?
    let source: StudySource
    let date: Date
}

/// Only cursor metadata is resident. Paragraphs, questions and answers are read separately.
struct StudyReadingState: Codable, Sendable {
    let passageID: String
    let title: String
    let revision: Int
    let paragraph: Int
    let paragraphCount: Int
    let question: Int?
    let questions: [Int]
    let answeredChoice: String?
    let skipped: Bool
    let paused: Bool
}

struct StudyReadingResult: Codable, Sendable {
    let message: String
    let state: StudyReadingState
    let excerpts: [StudyReadingExcerpt]
    var applicationReceipt = true
}

extension StudyMemoryStore {
    func readingCatalog(projectID: UUID) throws -> [StudyReadingCatalogEntry] {
        try transaction { try read([StudyReadingCatalogEntry].self, projectID: projectID, kind: "reading_catalog", id: "index") ?? [] }
    }
    func importReadings(_ pack: StudyReadingPack, projectID: UUID) throws -> Int {
        // Revalidate typed packs too, so callers cannot bypass import validation.
        _ = try StudyReadingPack.decode(StudyCoding.encode(pack))
        return try transaction {
            var catalog = try read([StudyReadingCatalogEntry].self, projectID: projectID, kind: "reading_catalog", id: "index") ?? []
            for passage in pack.passages {
                if let old = try read(StudyReadingPassage.self, projectID: projectID, kind: "reading_passage", id: passage.id), old != passage {
                    throw StudyMemoryError.invalid("同一篇目有不同内容，未覆盖原资料与进度：\(passage.title)。请先核对资料版本。")
                }
                try write(passage, projectID: projectID, kind: "reading_passage", id: passage.id)
                catalog.removeAll { $0.id == passage.id }; catalog.append(passage.catalog)
            }
            guard catalog.count <= 400 else { throw StudyMemoryError.invalid("阅读资料最多 400 篇。") }
            catalog.sort { ($0.year, $0.textNumber, $0.id) < ($1.year, $1.textNumber, $1.id) }
            try write(catalog, projectID: projectID, kind: "reading_catalog", id: "index")
            return catalog.count
        }
    }
    func readingSessions(projectID: UUID) throws -> [StudyReadingSession] {
        try transaction { try rawReadingSessions(projectID) }
    }
    private func rawReadingSessions(_ projectID: UUID) throws -> [StudyReadingSession] {
        try rows(projectID: projectID, kind: "reading_session").map { try StudyCoding.decode(StudyReadingSession.self, from: $0) }.sorted { $0.updatedAt > $1.updatedAt }
    }
    func readingAnswers(projectID: UUID) throws -> [StudyReadingAnswer] {
        try transaction { try rows(projectID: projectID, kind: "reading_answer").map { try StudyCoding.decode(StudyReadingAnswer.self, from: $0) } }
    }
    func readingEvents(projectID: UUID) throws -> [StudyReadingEvent] {
        try transaction { try rows(projectID: projectID, kind: "reading_event").map { try StudyCoding.decode(StudyReadingEvent.self, from: $0) } }
    }
    private func readingPassage(_ id: String, project: UUID) throws -> StudyReadingPassage {
        guard let p = try read(StudyReadingPassage.self, projectID: project, kind: "reading_passage", id: id) else {
            throw StudyMemoryError.invalid("没有找到这篇阅读，请先查看资料目录或导入私人阅读包。")
        }
        return p
    }
    private func readingState(_ session: StudyReadingSession, passage: StudyReadingPassage, project: UUID) throws -> StudyReadingState {
        guard session.passageFingerprint == passage.fingerprint else { throw StudyMemoryError.conflict }
        let answer = try session.question.flatMap { try read(StudyReadingAnswer.self, projectID: project, kind: "reading_answer", id: session.id.uuidString + "/\($0)") }
        return .init(passageID: passage.id, title: passage.title, revision: session.revision, paragraph: session.paragraph,
                     paragraphCount: passage.paragraphs.count, question: session.question, questions: passage.questions.map(\.number),
                     answeredChoice: answer?.choice, skipped: answer?.skipped ?? false, paused: session.paused)
    }
    func readingState(scope: StudyScope) throws -> StudyReadingState? {
        try transaction {
            guard let session = try rawReadingSessions(scope.projectID).first(where: { $0.threadID == scope.threadID }) else { return nil }
            return try readingState(session, passage: readingPassage(session.passageID, project: scope.projectID), project: scope.projectID)
        }
    }
    private func paragraphExcerpt(_ session: StudyReadingSession, passage: StudyReadingPassage) -> StudyReadingExcerpt {
        .init(title: "\(passage.title) · 第 \(session.paragraph) 段", text: passage.paragraphs[session.paragraph - 1], source: passage.source, sourceURL: passage.sourceURL)
    }
    private func questionExcerpt(_ question: StudyReadingPassage.Question, passage: StudyReadingPassage) -> StudyReadingExcerpt {
        let options = zip(["A", "B", "C", "D"], question.options).map { "\($0). \($1)" }.joined(separator: "\n")
        return .init(title: "\(passage.title) · 第 \(question.number) 题", text: question.stem + "\n\n" + options, source: passage.source, sourceURL: passage.sourceURL)
    }
    /// One transaction records the cursor, answer revision, event and replay receipt.
    func performReading(_ action: StudyToolAction, scope: StudyScope, message: ChatMessage) throws -> StudyReadingResult {
        guard scope.subject == .english, message.role == .user else { throw StudyMemoryError.invalid("请在英语项目中学习阅读。") }
        let source = StudySource(kind: .userStatement, threadID: scope.threadID, messageID: message.id, text: message.content,
            quote: (action.arguments["evidence_quote"] as? String) ?? String(message.content.prefix(4000)), messageDate: message.createdAt)
        try source.validate(scope: scope)
        let encoded = try JSONSerialization.data(withJSONObject: action.arguments, options: [.sortedKeys])
        let fingerprint = StudyCoding.hash(encoded)
        let target = (action.arguments["passage_id"] as? String ?? "") + "/" + (action.arguments["kind"] as? String ?? "") + "/" + String(describing: action.arguments["number"] ?? "")
        let opID = StudyCoding.hash(Data((message.id.uuidString + "/" + action.name + "/" + target).utf8))
        struct Operation: Codable { let fingerprint: String; let result: StudyReadingResult }
        return try transaction {
            if let previous = try read(Operation.self, projectID: scope.projectID, kind: "reading_operation", id: opID) {
                guard previous.fingerprint == fingerprint else { throw StudyMemoryError.conflict }; return previous.result
            }
            let sessions = try rawReadingSessions(scope.projectID)
            let local = sessions.first { $0.threadID == scope.threadID }
            var before = local
            var session: StudyReadingSession
            var p: StudyReadingPassage
            var excerpts: [StudyReadingExcerpt] = []
            var oldAnswer: StudyReadingAnswer?, newAnswer: StudyReadingAnswer?
            var receipt = "阅读位置已保存；展示资料不表示已经学会。"
            let now = Date()
            if action.name == "study_open_reading" {
                let id = try action.text("passage_id"), mode = try action.text("mode")
                guard ["start", "continue"].contains(mode) else { throw StudyMemoryError.invalid("请选择开始或继续阅读。") }
                let matching = sessions.filter { id.isEmpty || $0.passageID == id }
                let chosen = matching.first { $0.threadID == scope.threadID } ?? (mode == "continue" ? matching.first : nil)
                guard let passageID = chosen?.passageID ?? (id.isEmpty ? nil : id) else { throw StudyMemoryError.invalid("请先指定年份与 Text 篇目，当前没有可接续的阅读。") }
                p = try readingPassage(passageID, project: scope.projectID)
                before = chosen
                if var chosen {
                    guard chosen.passageFingerprint == p.fingerprint else { throw StudyMemoryError.conflict }
                    chosen.threadID = scope.threadID; chosen.paused = false; chosen.revision += 1; session = chosen
                } else { session = .init(id: UUID(), threadID: scope.threadID, passageID: p.id, passageFingerprint: p.fingerprint, updatedAt: now) }
                excerpts = [paragraphExcerpt(session, passage: p)]
                if let number = session.question, let q = p.questions.first(where: { $0.number == number }) { excerpts.append(questionExcerpt(q, passage: p)) }
            } else {
                guard let current = local, current.revision == (try action.integer("expected_revision")) else { throw StudyMemoryError.conflict }
                session = current; p = try readingPassage(session.passageID, project: scope.projectID)
                guard p.fingerprint == session.passageFingerprint else { throw StudyMemoryError.conflict }
                if action.name == "study_pause_reading" { session.paused = true; receipt = "已暂停，原段落和待答题均已保存。" }
                else {
                    guard !session.paused else { throw StudyMemoryError.invalid("阅读已暂停，请先用 study_open_reading(mode=continue) 接续。") }
                    if action.name == "study_show_reading" {
                        let number = try action.integer("number"), kind = try action.text("kind")
                        if kind == "paragraph" {
                            guard (1...p.paragraphs.count).contains(number) else { throw StudyMemoryError.invalid("段落不存在。") }
                            session.paragraph = number; excerpts = [paragraphExcerpt(session, passage: p)]
                        } else if kind == "question", let q = p.questions.first(where: { $0.number == number }) {
                            session.question = number; session.questionMessageID = message.id; session.questionIssuedAt = now
                            excerpts = [questionExcerpt(q, passage: p)]
                        } else { throw StudyMemoryError.invalid("题目或资料类型不存在。") }
                    } else {
                        guard let number = session.question, let q = p.questions.first(where: { $0.number == number }) else { throw StudyMemoryError.invalid("请先展示要回答的题目。") }
                        let answerID = session.id.uuidString + "/\(number)"
                        oldAnswer = try read(StudyReadingAnswer.self, projectID: scope.projectID, kind: "reading_answer", id: answerID)
                        if action.name == "study_answer_reading" {
                            let choice = try action.text("choice").uppercased()
                            let isCorrection = oldAnswer != nil && oldAnswer?.source.messageID != message.id
                            guard ["A", "B", "C", "D"].contains(choice), isCorrection || (message.id != session.questionMessageID &&
                                  floor(message.createdAt.timeIntervalSince1970) >= floor((session.questionIssuedAt ?? now).timeIntervalSince1970)) else {
                                throw StudyMemoryError.invalid("请在展示题目后等待用户实际作答；只接受 A、B、C、D。")
                            }
                            let correctAnswer = q.verifiedAnswer.map { ["A", "B", "C", "D"][$0] }
                            newAnswer = .init(sessionID: session.id, question: number, revision: (oldAnswer?.revision ?? 0) + 1,
                                choice: choice, skipped: false, referenceAnswer: correctAnswer, correct: correctAnswer.map { $0 == choice }, source: source, date: now)
                            receipt = oldAnswer == nil ? "本题实际作答已保存；尚未推进到下一题。" : "已更正本题作答，原作答保留在修改历史；没有重复计题。"
                            if q.verifiedAnswer == nil { receipt += "参考答案待核，暂不判定对错。" }
                        } else if action.name == "study_reading_reference" {
                            let skip = action.arguments["skip_without_answer"] as? Bool ?? false
                            guard oldAnswer != nil || skip else { throw StudyMemoryError.invalid("请先给用户作答机会。用户明确要直接看答案时才可标记跳过，不计为已作答。") }
                            if oldAnswer == nil {
                                newAnswer = .init(sessionID: session.id, question: number, revision: 1, choice: nil, skipped: true,
                                    referenceAnswer: nil, correct: nil, source: source, date: now)
                            }
                            let text = q.verifiedAnswer.map { "参考答案：" + ["A", "B", "C", "D"][$0] + "\n" + (q.explanation ?? "") } ?? "答案待核，不能据此判定对错。请以你的纸质原卷或可靠答案核对。"
                            excerpts = [.init(title: "第 \(number) 题 · 参考答案（非官方）", text: text, source: q.source, sourceURL: q.sourceURL)]
                            receipt = "已读取参考资料；模型讲解与资料原文需要区分。"
                        } else { throw StudyMemoryError.invalid("未知阅读操作。") }
                        if let newAnswer { try write(newAnswer, projectID: scope.projectID, kind: "reading_answer", id: answerID) }
                    }
                }
                session.revision += 1
            }
            session.updatedAt = now
            try write(session, projectID: scope.projectID, kind: "reading_session", id: session.id.uuidString)
            try write(StudyReadingEvent(id: UUID(), action: action.name, before: before, after: session, oldAnswer: oldAnswer,
                newAnswer: newAnswer, source: source, date: now), projectID: scope.projectID, kind: "reading_event", id: opID)
            let result = try StudyReadingResult(message: receipt, state: readingState(session, passage: p, project: scope.projectID), excerpts: excerpts)
            try write(Operation(fingerprint: fingerprint, result: result), projectID: scope.projectID, kind: "reading_operation", id: opID)
            return result
        }
    }
    func readingWordReference(scope: StudyScope, word: String, originalSentence: String, expectedRevision: Int) throws -> StudyMaterialReference {
        let linked = try wordPack(projectID: scope.projectID)?.cards.filter { $0.word.caseInsensitiveCompare(word) == .orderedSame }.map(\.id) ?? []
        return try transaction {
            guard let session = try rawReadingSessions(scope.projectID).first(where: { $0.threadID == scope.threadID }), session.revision == expectedRevision else { throw StudyMemoryError.conflict }
            let p = try readingPassage(session.passageID, project: scope.projectID)
            guard !word.isEmpty, word.count <= 100, !originalSentence.isEmpty, originalSentence.count <= 4000,
                  p.fingerprint == session.passageFingerprint, p.paragraphs[session.paragraph - 1].contains(originalSentence),
                  originalSentence.range(of: #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![\p{L}\p{N}_])"#,
                    options: [.regularExpression, .caseInsensitive]) != nil else { throw StudyMemoryError.invalid("单词与原句必须来自当前段落，不能用模型改写句冒充原文。") }
            return .init(passageID: p.id, passageTitle: p.title, passageFingerprint: p.fingerprint, paragraph: session.paragraph,
                         originalSentence: originalSentence, word: word, linkedWordIDs: linked, source: p.source, sourceURL: p.sourceURL)
        }
    }
}
