import Foundation
import FSRS

struct StudyWord: Codable, Equatable, Identifiable, Sendable {
    struct Unit: Codable, Equatable, Sendable {
        let collection: String
        let unit: Int?
        let position: Int
        var number: Int { unit ?? 0 }
        var id: String { "\(collection)-\(number)" }
        var isCore: Bool { collection == "required" || collection == "basic" }
        var title: String { "\(collection == "required" ? "必考" : "基础") Unit \(number)" }
    }
    let id: String
    let word: String
    let translation: String
    let coreMeaning: String?
    let phonetic: String?
    let meaningStatus: String?
    let phoneticStatus: String?
    let phoneticSourceURL: String?
    let units: [Unit]
    enum CodingKeys: String, CodingKey {
        case id, word, phonetic
        case translation = "translation_zh", coreMeaning = "core_meaning", meaningStatus = "meaning_status", units = "unit_order"
        case phoneticStatus = "phonetic_status", phoneticSourceURL = "phonetic_source_url"
    }
    var meaning: String { coreMeaning?.isEmpty == false ? coreMeaning! : translation }
}

struct StudyWordPack: Codable, Sendable {
    let schema: String
    let cards: [StudyWord]
    enum CodingKeys: String, CodingKey { case schema = "schema_version", cards }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32 * 1024 * 1024 else { throw StudyMemoryError.invalid("词库文件需在 32 MB 以内。") }
        let pack = try JSONDecoder().decode(Self.self, from: data)
        guard ["yanxi.private-import.v2-stage1", "yanxi.private-import.v2-stage2"].contains(pack.schema),
              !pack.cards.isEmpty, pack.cards.count <= 20_000, Set(pack.cards.map(\.id)).count == pack.cards.count else {
            throw StudyMemoryError.invalid("词库版本、数量或词条标识不正确。")
        }
        for word in pack.cards {
            guard !word.id.isEmpty, word.id.count <= 200, !word.word.isEmpty, word.word.count <= 200,
                  word.translation.count <= 10_000, (word.coreMeaning?.count ?? 0) <= 4000,
                  (word.phonetic?.count ?? 0) <= 500, !word.units.isEmpty,
                  word.units.allSatisfy({ ["required", "basic", "basic_simple", "extra"].contains($0.collection)
                      && ($0.isCore ? (1...200).contains($0.number) : (0...200).contains($0.number)) && (1...5000).contains($0.position) }) else {
                throw StudyMemoryError.invalid("词库中有无效的单词或单元位置。")
            }
        }
        return pack
    }
}

struct StudyWordProgress: Codable, Equatable, Sendable {
    let wordID: String
    var card: Card?
    var logs: [ReviewLog] = []
    var lastRating: String?
    var lastReviewedAt: Date?
    var reviewCount: Int { logs.count }
    var due: Date { card?.due ?? .distantPast }
}

enum StudyWordMode: String, Codable, Sendable { case start, resume = "continue", review, practice }

struct StudyWordSession: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var threadID: UUID
    let unitID: String
    var mode: StudyWordMode = .start
    var wordIDs: [String]
    var position: Int
    var revision: Int
    var paused: Bool
    var updatedAt: Date
    var questionIssuedAt: Date? = nil
    var promptMessageID: UUID? = nil
    var lastEventID: UUID?
    var currentWordID: String? { wordIDs.indices.contains(position) ? wordIDs[position] : nil }
    var completed: Bool { currentWordID == nil }
}

struct StudyWordEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let beforeSession: StudyWordSession
    let afterSession: StudyWordSession
    let beforeProgress: StudyWordProgress
    let afterProgress: StudyWordProgress
    let source: StudySource
    let date: Date
    var undone = false
}

struct StudyWordReceipt: Codable, Sendable {
    let session: StudyWordSession
    let event: StudyWordEvent?
    let message: String
}

struct StudyWordGrade: Codable, Sendable {
    let sessionID: UUID
    let expectedRevision: Int
    let wordID: String
    let rating: String
    var source: StudySource
    func operationFingerprint() throws -> String {
        var copy = self; copy.source.messageDate = nil
        return StudyCoding.hash(try StudyCoding.encode(copy))
    }
}

struct StudyWordPracticeSummary: Sendable {
    let totalWords: Int
    let learnedWords: Int
    let todayWords: Int
    let dueWords: Int
    let activeSessionUnit: String?
    let activeSessionPosition: Int
    let activeSessionCount: Int
    let recentWords: [StudyWordView]
}

struct StudyWordState: Encodable, Sendable {
    let session: StudyWordSession?
    let currentWord: StudyWord?
    let progress: StudyWordProgress?
    let recentUnfamiliar: [String]
    private enum CodingKeys: String, CodingKey { case session, currentWord, progress, recentUnfamiliar, resumeRequired, resumeAction }
    private struct ProgressInfo: Encodable {
        let reviewCount: Int
        let lastRating: String?
        let lastReviewedAt: Date?
        let due: Date?
    }
    private struct SessionInfo: Encodable {
        let id = "current"
        let unitID: String
        let position: Int
        let count: Int
        let revision: Int
        let paused: Bool
        let currentWordID: String?
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let session {
            try c.encode(SessionInfo(unitID: session.unitID, position: session.position, count: session.wordIDs.count,
                revision: session.revision, paused: session.paused, currentWordID: session.currentWordID == nil ? nil : "current"), forKey: .session)
        }
        if session?.paused == true {
            try c.encode(true, forKey: .resumeRequired)
            try c.encode("用户请求继续时调用 study_start_words，mode=continue；此查询没有解除暂停。", forKey: .resumeAction)
        }
        try c.encodeIfPresent(currentWord, forKey: .currentWord)
        if let progress {
            try c.encode(ProgressInfo(reviewCount: progress.reviewCount, lastRating: progress.lastRating,
                lastReviewedAt: progress.lastReviewedAt, due: progress.reviewCount > 0 ? progress.due : nil), forKey: .progress)
        }
        try c.encode(recentUnfamiliar, forKey: .recentUnfamiliar)
    }
}

extension StudyMemoryStore {
    func wordPack(projectID: UUID) throws -> StudyWordPack? {
        try transaction { try read(StudyWordPack.self, projectID: projectID, kind: "word_pack", id: "core") }
    }
    @discardableResult func importWords(_ pack: StudyWordPack, projectID: UUID) throws -> Int {
        try transaction {
            var merged = pack
            if let old = try read(StudyWordPack.self, projectID: projectID, kind: "word_pack", id: "core") {
                let previous = Dictionary(uniqueKeysWithValues: old.cards.map { ($0.id, $0.word) })
                for word in pack.cards where previous[word.id] != nil {
                    guard previous[word.id] == word.word else { throw StudyMemoryError.invalid("同一词条标识对应不同单词，导入已停止。") }
                }
                let incoming = Set(pack.cards.map(\.id))
                merged = StudyWordPack(schema: pack.schema, cards: pack.cards + old.cards.filter { !incoming.contains($0.id) })
            }
            guard merged.cards.count <= 20_000 else { throw StudyMemoryError.invalid("合并后的词库超过 20000 词，请先分开整理。") }
            try write(merged, projectID: projectID, kind: "word_pack", id: "core")
            return merged.cards.count
        }
    }
    private func wordSessions(_ projectID: UUID) throws -> [StudyWordSession] {
        try rows(projectID: projectID, kind: "word_session").map { try StudyCoding.decode(StudyWordSession.self, from: $0) }.sorted { $0.updatedAt > $1.updatedAt }
    }
    func wordProgress(projectID: UUID) throws -> [StudyWordProgress] {
        try transaction { try rows(projectID: projectID, kind: "word_progress").map { try StudyCoding.decode(StudyWordProgress.self, from: $0) } }
    }
    func wordPracticeSummary(projectID: UUID, now: Date = Date()) throws -> StudyWordPracticeSummary {
        let pack = try wordPack(projectID: projectID)
        let progress = try wordProgress(projectID: projectID)
        let sessions = try transaction { try wordSessions(projectID) }
        let active = sessions.first { !$0.completed }
        let cardByID = Dictionary(uniqueKeysWithValues: (pack?.cards ?? []).map { ($0.id, $0) })
        let practiced = progress.filter { $0.reviewCount > 0 }.sorted { ($0.lastReviewedAt ?? .distantPast) > ($1.lastReviewedAt ?? .distantPast) }
        let calendar = Calendar.current
        let todayCount = practiced.filter { $0.lastReviewedAt.map { calendar.isDateInToday($0) } == true }.count
        let dueCount = practiced.filter { $0.due <= now }.count
        let recent: [StudyWordView] = practiced.prefix(30).compactMap { p in
            guard let word = cardByID[p.wordID] else { return nil }
            return StudyWordView(word: word, reviewCount: p.reviewCount, lastRating: p.lastRating, lastReviewedAt: p.lastReviewedAt, due: p.due)
        }
        return StudyWordPracticeSummary(
            totalWords: pack?.cards.count ?? 0,
            learnedWords: practiced.count,
            todayWords: todayCount,
            dueWords: dueCount,
            activeSessionUnit: active.map { $0.unitID.isEmpty ? "智能顺序/复习" : $0.unitID },
            activeSessionPosition: active?.position ?? 0,
            activeSessionCount: active?.wordIDs.count ?? 0,
            recentWords: recent
        )
    }
    private static func normalizeUnitID(_ raw: String, in pack: StudyWordPack) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lower = trimmed.lowercased()
        if ["all", "random", "default", "auto", "any", "current", "随机", "全部", "默认", "任意"].contains(lower) {
            return ""
        }
        if pack.cards.contains(where: { word in word.units.contains { $0.isCore && $0.id.caseInsensitiveCompare(trimmed) == .orderedSame } }) {
            return lower
        }
        let digits = trimmed.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first
        if let num = digits {
            let prefersBasic = lower.contains("basic") || lower.contains("基础")
            let candidateID = "\(prefersBasic ? "basic" : "required")-\(num)"
            if pack.cards.contains(where: { word in word.units.contains { $0.isCore && $0.id == candidateID } }) {
                return candidateID
            }
            let altID = "\(prefersBasic ? "required" : "basic")-\(num)"
            if pack.cards.contains(where: { word in word.units.contains { $0.isCore && $0.id == altID } }) {
                return altID
            }
        }
        return trimmed
    }
    func wordState(scope: StudyScope) throws -> StudyWordState {
        let pack = try wordPack(projectID: scope.projectID)
        let progress = try wordProgress(projectID: scope.projectID)
        return try transaction {
            let session = try wordSessions(scope.projectID).first { $0.threadID == scope.threadID }
            let word = pack?.cards.first { $0.id == session?.currentWordID }
            let recent = progress.filter { ["again", "hard"].contains($0.lastRating ?? "") }.sorted { ($0.lastReviewedAt ?? .distantPast) > ($1.lastReviewedAt ?? .distantPast) }
            return StudyWordState(session: session, currentWord: word, progress: progress.first { $0.wordID == word?.id },
                                  recentUnfamiliar: recent.prefix(12).compactMap { progress in pack?.cards.first { $0.id == progress.wordID }?.word })
        }
    }
    func startWords(scope: StudyScope, unitID: String, count: Int, mode: StudyWordMode, sourceMessageID: UUID? = nil, now: Date = Date()) throws -> StudyWordReceipt {
        guard scope.subject == .english, (1...30).contains(count) else { throw StudyMemoryError.invalid("请选择英语项目，每轮 1 至 30 个词。") }
        guard let pack = try wordPack(projectID: scope.projectID) else { throw StudyMemoryError.invalid("请先在项目记忆页导入私人词库，只需导入一次。") }
        let resolvedUnitID = Self.normalizeUnitID(unitID, in: pack)
        return try transaction {
            let unfinished = try wordSessions(scope.projectID).filter { !$0.completed }
            let local = unfinished.first { $0.threadID == scope.threadID && (resolvedUnitID.isEmpty || $0.unitID == resolvedUnitID) && (mode == .resume || $0.mode == mode) }
            if var existing = local ?? (mode == .resume ? unfinished.first(where: { resolvedUnitID.isEmpty || $0.unitID == resolvedUnitID }) : nil) {
                if existing.questionIssuedAt == nil { existing.questionIssuedAt = existing.updatedAt }
                existing.threadID = scope.threadID; existing.paused = false; existing.updatedAt = now; existing.revision += 1
                try write(existing, projectID: scope.projectID, kind: "word_session", id: existing.id.uuidString)
                return StudyWordReceipt(session: existing, event: nil, message: "已接续未完成的一轮")
            }
            let progress = try rows(projectID: scope.projectID, kind: "word_progress").map { try StudyCoding.decode(StudyWordProgress.self, from: $0) }
            let lookup = Dictionary(uniqueKeysWithValues: progress.map { ($0.wordID, $0) })
            var candidates = pack.cards.filter { word in word.units.contains { $0.isCore && (resolvedUnitID.isEmpty || $0.id == resolvedUnitID) } }
            if !resolvedUnitID.isEmpty { candidates.sort { ($0.units.first { $0.id == resolvedUnitID }?.position ?? 0) < ($1.units.first { $0.id == resolvedUnitID }?.position ?? 0) } }
            guard !candidates.isEmpty else { throw StudyMemoryError.invalid("找不到这个单元。") }
            let due = candidates.filter { lookup[$0.id].map { $0.reviewCount > 0 && $0.due <= now } == true }.sorted { lookup[$0.id]!.due < lookup[$1.id]!.due }
            let fresh = mode == .review ? [] : candidates.filter { (lookup[$0.id]?.reviewCount ?? 0) == 0 }
            let practice = candidates.filter { (lookup[$0.id]?.reviewCount ?? 0) > 0 }.sorted { (lookup[$0.id]?.lastReviewedAt ?? .distantPast) > (lookup[$1.id]?.lastReviewedAt ?? .distantPast) }
            let chosen = Array((mode == .practice ? practice : due + fresh).prefix(count))
            guard !chosen.isEmpty else { throw StudyMemoryError.invalid("当前范围暂时没有到期复习词或未学新词。可以选择别的单元。") }
            let session = StudyWordSession(id: UUID(), threadID: scope.threadID, unitID: resolvedUnitID, mode: mode,
                wordIDs: chosen.map(\.id), position: 0, revision: 1, paused: false, updatedAt: now, questionIssuedAt: now, promptMessageID: sourceMessageID, lastEventID: nil)
            try write(session, projectID: scope.projectID, kind: "word_session", id: session.id.uuidString)
            return StudyWordReceipt(session: session, event: nil, message: "本轮已准备，等待用户回答第一个词")
        }
    }
    func gradeWord(_ grade: StudyWordGrade, scope: StudyScope, operationID: String, now: Date = Date()) throws -> StudyWordReceipt {
        try grade.source.validate(scope: scope)
        let ratings: [String: Rating] = ["again": .again, "hard": .hard, "good": .good, "easy": .easy]
        guard let rating = ratings[grade.rating], grade.source.kind != .modelInference else { throw StudyMemoryError.invalid("请选择有效评分并引用用户实际回答。") }
        struct Operation: Codable { let fingerprint: String; let receipt: StudyWordReceipt }
        return try transaction {
            let fingerprint = try grade.operationFingerprint()
            if let prior = try read(Operation.self, projectID: scope.projectID, kind: "word_operation", id: operationID) {
                guard prior.fingerprint == fingerprint else { throw StudyMemoryError.conflict }
                if let eventID = prior.receipt.event?.id,
                   try read(StudyWordEvent.self, projectID: scope.projectID, kind: "word_event", id: eventID.uuidString)?.undone == true {
                    throw StudyMemoryError.invalid("这次评分已撤销，请按当前学习现场重新回答。")
                }
                return prior.receipt
            }
            guard var session = try read(StudyWordSession.self, projectID: scope.projectID, kind: "word_session", id: grade.sessionID.uuidString),
                  session.threadID == scope.threadID, session.revision == grade.expectedRevision, !session.paused,
                  try wordSessions(scope.projectID).first(where: { $0.threadID == scope.threadID })?.id == session.id,
                  session.currentWordID == grade.wordID else { throw StudyMemoryError.conflict }
            guard let answeredAt = grade.source.messageDate, grade.source.messageID != session.promptMessageID,
                  floor(answeredAt.timeIntervalSince1970) >= floor((session.questionIssuedAt ?? session.updatedAt).timeIntervalSince1970) else {
                throw StudyMemoryError.invalid("这个词尚未收到提问之后的用户回答，不能提前评分。")
            }
            let beforeSession = session
            let before = try read(StudyWordProgress.self, projectID: scope.projectID, kind: "word_progress", id: grade.wordID) ?? StudyWordProgress(wordID: grade.wordID, card: nil)
            let scheduler = FSRS(parameters: FSRSParameters(w: FSRSDefaults.defaultWv6, enableFuzz: false))
            let scheduled = try scheduler.next(card: before.card ?? Card(due: now), now: now, grade: rating)
            var after = before; after.card = scheduled.card; after.logs.append(scheduled.log)
            after.lastRating = grade.rating; after.lastReviewedAt = now
            if grade.rating == "again", session.wordIDs.filter({ $0 == grade.wordID }).count < 3 { session.wordIDs.append(grade.wordID) }
            let eventID = UUID()
            session.position += 1; session.revision += 1; session.updatedAt = now; session.lastEventID = eventID
            session.questionIssuedAt = now
            session.promptMessageID = grade.source.messageID
            let event = StudyWordEvent(id: eventID, beforeSession: beforeSession, afterSession: session,
                beforeProgress: before, afterProgress: after, source: grade.source, date: now)
            let receipt = StudyWordReceipt(session: session, event: event, message: "本次作答与复习安排已保存")
            try write(after, projectID: scope.projectID, kind: "word_progress", id: grade.wordID)
            try write(session, projectID: scope.projectID, kind: "word_session", id: session.id.uuidString)
            try write(event, projectID: scope.projectID, kind: "word_event", id: eventID.uuidString)
            try write(Operation(fingerprint: fingerprint, receipt: receipt), projectID: scope.projectID, kind: "word_operation", id: operationID)
            return receipt
        }
    }
    func undoWord(scope: StudyScope, sessionID: UUID, expectedRevision: Int) throws -> StudyWordReceipt {
        try transaction {
            guard var session = try read(StudyWordSession.self, projectID: scope.projectID, kind: "word_session", id: sessionID.uuidString),
                  session.threadID == scope.threadID, session.revision == expectedRevision, let eventID = session.lastEventID,
                  var event = try read(StudyWordEvent.self, projectID: scope.projectID, kind: "word_event", id: eventID.uuidString), !event.undone,
                  let progress = try read(StudyWordProgress.self, projectID: scope.projectID, kind: "word_progress", id: event.afterProgress.wordID),
                  progress == event.afterProgress else { throw StudyMemoryError.conflict }
            let revision = session.revision + 1
            session = event.beforeSession; session.threadID = scope.threadID; session.revision = revision; session.updatedAt = Date()
            session.lastEventID = nil; event.undone = true
            try write(event.beforeProgress, projectID: scope.projectID, kind: "word_progress", id: event.beforeProgress.wordID)
            try write(session, projectID: scope.projectID, kind: "word_session", id: session.id.uuidString)
            try write(event, projectID: scope.projectID, kind: "word_event", id: event.id.uuidString)
            return StudyWordReceipt(session: session, event: event, message: "已撤销上一题评分，回到该词")
        }
    }
    func pauseWords(scope: StudyScope, sessionID: UUID, expectedRevision: Int) throws -> StudyWordReceipt {
        try transaction {
            guard var session = try read(StudyWordSession.self, projectID: scope.projectID, kind: "word_session", id: sessionID.uuidString),
                  session.threadID == scope.threadID, session.revision == expectedRevision else { throw StudyMemoryError.conflict }
            session.paused = true; session.revision += 1; session.updatedAt = Date()
            try write(session, projectID: scope.projectID, kind: "word_session", id: session.id.uuidString)
            return StudyWordReceipt(session: session, event: nil, message: "已暂停，当前词和进度已保存")
        }
    }
}
