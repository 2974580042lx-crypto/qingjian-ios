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

struct StudyWordPracticeSummary: Codable, Sendable {
    let totalWords: Int
    let learnedWords: Int
    let todayWords: Int
    let dueWords: Int
    let activeSessionUnit: String?
    let activeSessionPosition: Int
    let activeSessionCount: Int
    let recentWords: [StudyWordView]
    var todayWordsList: [StudyWordView] = []
    var weakWordsList: [String] = []
}

struct StudyWordDrawResult: Codable, Sendable {
    let mode: String
    let totalInPack: Int
    let learnedCount: Int
    let dueCount: Int
    let unitID: String?
    let words: [StudyWordView]
    let units: [StudyWordUnitOverview]?
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
        let todayPracticed = practiced.filter { $0.lastReviewedAt.map { calendar.isDate($0, inSameDayAs: now) } == true }
        let todayCount = todayPracticed.count
        let dueCount = practiced.filter { $0.due <= now }.count
        let recent: [StudyWordView] = practiced.prefix(30).compactMap { p in
            guard let word = cardByID[p.wordID] else { return nil }
            return StudyWordView(word: word, reviewCount: p.reviewCount, lastRating: p.lastRating, lastReviewedAt: p.lastReviewedAt, due: p.due)
        }
        let todayList: [StudyWordView] = todayPracticed.prefix(30).compactMap { p in
            guard let word = cardByID[p.wordID] else { return nil }
            return StudyWordView(word: word, reviewCount: p.reviewCount, lastRating: p.lastRating, lastReviewedAt: p.lastReviewedAt, due: p.due)
        }
        let weakList: [String] = practiced.filter { ["again", "hard"].contains($0.lastRating ?? "") }
            .prefix(15)
            .compactMap { cardByID[$0.wordID]?.word }
        return StudyWordPracticeSummary(
            totalWords: pack?.cards.count ?? 0,
            learnedWords: practiced.count,
            todayWords: todayCount,
            dueWords: dueCount,
            activeSessionUnit: active.map { $0.unitID.isEmpty ? "智能顺序/复习" : $0.unitID },
            activeSessionPosition: active?.position ?? 0,
            activeSessionCount: active?.wordIDs.count ?? 0,
            recentWords: recent,
            todayWordsList: todayList,
            weakWordsList: weakList
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

    // MARK: - Lock-Free High-Freedom Vocabulary APIs

    func drawWords(scope: StudyScope, mode rawMode: String, count rawCount: Int, unitID rawUnitID: String, now: Date = Date()) throws -> StudyWordDrawResult {
        guard scope.subject == .english else { throw StudyMemoryError.invalid("请在考研英语项目中背词。") }
        guard let pack = try wordPack(projectID: scope.projectID) else {
            throw StudyMemoryError.invalid("请先在项目记忆页导入私人词库，只需导入一次。")
        }
        let count = min(max(rawCount > 0 ? rawCount : 10, 1), 30)
        let modeLower = rawMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isShuffle = ["shuffle", "random", "乱序", "随机"].contains(modeLower)
            || ["random", "shuffle", "乱序", "随机"].contains(rawUnitID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        let normalizedMode = isShuffle ? "shuffle" : (modeLower.isEmpty ? "smart" : modeLower)
        let resolvedUnitID = Self.normalizeUnitID(rawUnitID, in: pack)

        return try transaction {
            let progressList = try rows(projectID: scope.projectID, kind: "word_progress").map { try StudyCoding.decode(StudyWordProgress.self, from: $0) }
            let lookup = Dictionary(uniqueKeysWithValues: progressList.map { ($0.wordID, $0) })
            let learnedTotal = progressList.filter { $0.reviewCount > 0 }.count
            let dueTotal = progressList.filter { $0.reviewCount > 0 && $0.due <= now }.count

            func view(for word: StudyWord) -> StudyWordView {
                let p = lookup[word.id]
                return StudyWordView(word: word, reviewCount: p?.reviewCount ?? 0, lastRating: p?.lastRating, lastReviewedAt: p?.lastReviewedAt, due: p?.due)
            }

            if ["units_overview", "units", "单元"].contains(normalizedMode) {
                var unitsMap: [String: StudyWord.Unit] = [:]
                for word in pack.cards { for unit in word.units where unit.isCore { unitsMap[unit.id] = unit } }
                let ordered = unitsMap.values.sorted { ($0.collection == "required" ? 0 : 1, $0.number) < ($1.collection == "required" ? 0 : 1, $1.number) }
                let overviews = ordered.map { unit in
                    let words = pack.cards.filter { $0.units.contains { $0.id == unit.id } }
                    return StudyWordUnitOverview(
                        id: unit.id,
                        title: unit.title,
                        total: words.count,
                        learned: words.filter { (lookup[$0.id]?.reviewCount ?? 0) > 0 }.count,
                        due: words.filter { lookup[$0.id].map { $0.reviewCount > 0 && $0.due <= now } == true }.count
                    )
                }
                return StudyWordDrawResult(mode: "units_overview", totalInPack: pack.cards.count, learnedCount: learnedTotal, dueCount: dueTotal, unitID: nil, words: [], units: overviews)
            }

            if normalizedMode == "continue" || normalizedMode == "resume" {
                let sessions = try wordSessions(scope.projectID).filter { !$0.completed }
                if var existing = sessions.first(where: { $0.threadID == scope.threadID }) ?? sessions.first {
                    existing.threadID = scope.threadID
                    existing.paused = false
                    existing.updatedAt = now
                    existing.revision += 1
                    try write(existing, projectID: scope.projectID, kind: "word_session", id: existing.id.uuidString)
                    let cardByID = Dictionary(uniqueKeysWithValues: pack.cards.map { ($0.id, $0) })
                    let remainingIDs = Array(existing.wordIDs.dropFirst(min(existing.position, existing.wordIDs.count)))
                    let remaining = remainingIDs.compactMap { cardByID[$0] }.map(view(for:))
                    if !remaining.isEmpty {
                        return StudyWordDrawResult(mode: "continue", totalInPack: pack.cards.count, learnedCount: learnedTotal, dueCount: dueTotal, unitID: existing.unitID.isEmpty ? nil : existing.unitID, words: remaining, units: nil)
                    }
                }
            }

            var candidates: [StudyWord]
            if resolvedUnitID.isEmpty {
                candidates = pack.cards
            } else {
                candidates = pack.cards.filter { word in word.units.contains { $0.isCore && $0.id == resolvedUnitID } }
                if candidates.isEmpty {
                    // Fallback gracefully to whole pack instead of throwing a rigid error if AI guessed an unknown unit tag
                    candidates = pack.cards
                } else {
                    candidates.sort { ($0.units.first { $0.id == resolvedUnitID }?.position ?? 0) < ($1.units.first { $0.id == resolvedUnitID }?.position ?? 0) }
                }
            }

            let dueCards = candidates.filter { lookup[$0.id].map { $0.reviewCount > 0 && $0.due <= now } == true }
                .sorted { lookup[$0.id]!.due < lookup[$1.id]!.due }
            let weakCards = candidates.filter { ["again", "hard"].contains(lookup[$0.id]?.lastRating ?? "") }
                .sorted { (lookup[$0.id]?.lastReviewedAt ?? .distantPast) > (lookup[$1.id]?.lastReviewedAt ?? .distantPast) }
            let freshCards = candidates.filter { (lookup[$0.id]?.reviewCount ?? 0) == 0 }
            let practicedCards = candidates.filter { (lookup[$0.id]?.reviewCount ?? 0) > 0 }

            var chosen: [StudyWord] = []
            if normalizedMode == "shuffle" {
                let duePick = Array(dueCards.shuffled().prefix(max(1, count / 3)))
                let chosenIDs = Set(duePick.map(\.id))
                let freshPool = freshCards.filter { !chosenIDs.contains($0.id) }.shuffled()
                chosen = duePick + Array(freshPool.prefix(max(0, count - duePick.count)))
                if chosen.count < count {
                    let used = Set(chosen.map(\.id))
                    chosen += Array(candidates.filter { !used.contains($0.id) }.shuffled().prefix(count - chosen.count))
                }
                chosen.shuffle()
            } else if normalizedMode == "review" {
                var pool = dueCards
                let dueSet = Set(pool.map(\.id))
                for w in weakCards where !dueSet.contains(w.id) { pool.append(w) }
                if pool.isEmpty { pool = practicedCards.sorted { (lookup[$0.id]?.due ?? .distantFuture) < (lookup[$1.id]?.due ?? .distantFuture) } }
                chosen = Array((pool.isEmpty ? freshCards : pool).prefix(count))
            } else {
                chosen = Array((dueCards + freshCards).prefix(count))
                if chosen.count < count {
                    let used = Set(chosen.map(\.id))
                    chosen += Array(practicedCards.filter { !used.contains($0.id) }.prefix(count - chosen.count))
                }
            }

            let sessionUnitLabel = normalizedMode == "shuffle" ? (resolvedUnitID.isEmpty ? "乱序抽词" : "\(resolvedUnitID)·乱序") : resolvedUnitID
            // Replace any unfinished session on this thread so UI summary reflects the latest batch cleanly
            for var old in try wordSessions(scope.projectID) where old.threadID == scope.threadID && !old.completed {
                old.position = old.wordIDs.count
                old.paused = false
                old.updatedAt = now
                try write(old, projectID: scope.projectID, kind: "word_session", id: old.id.uuidString)
            }
            let session = StudyWordSession(
                id: UUID(),
                threadID: scope.threadID,
                unitID: sessionUnitLabel,
                mode: normalizedMode == "review" ? .review : .start,
                wordIDs: chosen.map(\.id),
                position: 0,
                revision: 1,
                paused: false,
                updatedAt: now,
                questionIssuedAt: now,
                promptMessageID: nil,
                lastEventID: nil
            )
            try write(session, projectID: scope.projectID, kind: "word_session", id: session.id.uuidString)

            return StudyWordDrawResult(
                mode: normalizedMode,
                totalInPack: pack.cards.count,
                learnedCount: learnedTotal,
                dueCount: dueTotal,
                unitID: resolvedUnitID.isEmpty ? nil : resolvedUnitID,
                words: chosen.map(view(for:)),
                units: nil
            )
        }
    }

    func findWords(projectID: UUID, query rawQuery: String, matchMode rawMode: String = "auto", limit rawLimit: Int = 15) throws -> [StudyWordView] {
        guard let pack = try wordPack(projectID: projectID) else {
            throw StudyMemoryError.invalid("请先在项目记忆页导入私人词库。")
        }
        let limit = min(max(rawLimit > 0 ? rawLimit : 15, 1), 25)
        let progressList = try wordProgress(projectID: projectID)
        let lookup = Dictionary(uniqueKeysWithValues: progressList.map { ($0.wordID, $0) })
        func toView(_ word: StudyWord) -> StudyWordView {
            let p = lookup[word.id]
            return StudyWordView(word: word, reviewCount: p?.reviewCount ?? 0, lastRating: p?.lastRating, lastReviewedAt: p?.lastReviewedAt, due: p?.due)
        }

        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "`\"'")))
        let qLower = query.lowercased()
        let mode = rawMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if query.isEmpty || ["random", "shuffle", "随机", "抽查", "any"].contains(qLower) {
            let fresh = pack.cards.filter { (lookup[$0.id]?.reviewCount ?? 0) == 0 }.shuffled()
            let picked = fresh.isEmpty ? Array(pack.cards.shuffled().prefix(limit)) : Array(fresh.prefix(limit))
            return picked.map(toView)
        }

        let isLatinQuery = qLower.unicodeScalars.allSatisfy { ($0.value >= 97 && $0.value <= 122) || $0.value == 45 || $0.value == 32 }
        let wantsLookalike = ["lookalike", "similar", "形近", "形近词", "相似"].contains(mode)

        if wantsLookalike && isLatinQuery && qLower.count >= 2 {
            let scored: [(StudyWord, Int)] = pack.cards.compactMap { card in
                let w = card.word.lowercased()
                let lenDiff = abs(w.count - qLower.count)
                if w == qLower { return (card, 0) }
                if lenDiff <= 3 {
                    let dist = Self.levenshtein(qLower, w)
                    if dist == 1 { return (card, 10 + lenDiff) }
                    if dist == 2 && qLower.count >= 4 {
                        let sameEdge = w.first == qLower.first || w.last == qLower.last
                        return (card, (sameEdge ? 20 : 28) + lenDiff)
                    }
                    if dist == 3 && qLower.count >= 6 && w.prefix(2) == qLower.prefix(2) {
                        return (card, 40 + lenDiff)
                    }
                }
                if qLower.count >= 3 && (w.contains(qLower) || qLower.contains(w)) {
                    return (card, 34 + lenDiff)
                }
                return nil
            }
            return scored.sorted { $0.1 == $1.1 ? $0.0.word < $1.0.word : $0.1 < $1.1 }.prefix(limit).map { toView($0.0) }
        }

        // Direct substring / root / Chinese meaning search, supplemented by lookalikes when Latin query has few hits
        let direct = pack.cards.filter {
            $0.id.caseInsensitiveCompare(query) == .orderedSame
                || $0.word.localizedCaseInsensitiveContains(query)
                || $0.meaning.localizedCaseInsensitiveContains(query)
                || $0.translation.localizedCaseInsensitiveContains(query)
        }.sorted { a, b in
            let aw = a.word.lowercased(), bw = b.word.lowercased()
            let aRank = aw == qLower ? 0 : (aw.hasPrefix(qLower) ? 1 : (aw.contains(qLower) ? 2 : 3))
            let bRank = bw == qLower ? 0 : (bw.hasPrefix(qLower) ? 1 : (bw.contains(qLower) ? 2 : 3))
            if aRank != bRank { return aRank < bRank }
            return a.word.count < b.word.count
        }

        var results = Array(direct.prefix(limit))
        if isLatinQuery && qLower.count >= 4 && results.count < min(6, limit) {
            let existingIDs = Set(results.map(\.id))
            let near = pack.cards.filter { !existingIDs.contains($0.id) && abs($0.word.count - qLower.count) <= 2 }
                .compactMap { card -> (StudyWord, Int)? in
                    let d = Self.levenshtein(qLower, card.word.lowercased())
                    return d <= 2 ? (card, d) : nil
                }
                .sorted { $0.1 == $1.1 ? $0.0.word < $1.0.word : $0.1 < $1.1 }
                .prefix(limit - results.count)
                .map(\.0)
            results.append(contentsOf: near)
        }
        return results.map(toView)
    }

    func gradeWordsFree(scope: StudyScope, items: [(word: String, rating: String)], message: ChatMessage, now: Date = Date()) throws -> [StudyWordView] {
        guard scope.subject == .english else { throw StudyMemoryError.invalid("请在考研英语项目中记录单词评分。") }
        guard !items.isEmpty else { throw StudyMemoryError.invalid("请提供要记录评分的单词。") }
        let pack = try wordPack(projectID: scope.projectID)

        let ratingMap: [String: (String, Rating)] = [
            "easy": ("easy", .easy), "轻松": ("easy", .easy), "熟练": ("easy", .easy),
            "good": ("good", .good), "记得": ("good", .good), "认识": ("good", .good), "pass": ("good", .good),
            "hard": ("hard", .hard), "模糊": ("hard", .hard), "不熟": ("hard", .hard),
            "again": ("again", .again), "忘了": ("again", .again), "不认识": ("again", .again), "wrong": ("again", .again), "forgot": ("again", .again)
        ]
        let undoTokens: Set<String> = ["undo", "revert", "撤销", "撤回"]
        var outOfPackItems: [(word: String, canonicalRating: String)] = []

        var updatedViews: [StudyWordView] = try transaction {
            var activeSession = try wordSessions(scope.projectID).first { $0.threadID == scope.threadID && !$0.completed }
            let cards = pack?.cards ?? []
            let cardByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
            let scheduler = FSRS(parameters: FSRSParameters(w: FSRSDefaults.defaultWv6, enableFuzz: false))
            var views: [StudyWordView] = []
            let quote = message.content.isEmpty ? "背词记录" : String(message.content.prefix(4000))
            let source = StudySource.from(message: message, scope: scope, kind: message.content.isEmpty ? .modelInference : .userStatement, quote: quote)

            for item in items {
                let cleanedWord = item.word.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "`\"'")))
                let cleanedRating = item.rating.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

                let targetCard: StudyWord?
                if cleanedWord.isEmpty || cleanedWord.lowercased() == "current" {
                    targetCard = activeSession?.currentWordID.flatMap { cardByID[$0] }
                } else {
                    targetCard = cards.first { $0.word.caseInsensitiveCompare(cleanedWord) == .orderedSame }
                        ?? cards.first { $0.id.caseInsensitiveCompare(cleanedWord) == .orderedSame }
                }
                guard let wordCard = targetCard else {
                    if !cleanedWord.isEmpty, cleanedWord.lowercased() != "current" {
                        if undoTokens.contains(cleanedRating) { continue }
                        let canonical = ratingMap[cleanedRating]?.0 ?? "good"
                        outOfPackItems.append((word: cleanedWord, canonicalRating: canonical))
                        continue
                    }
                    throw StudyMemoryError.invalid("未指定要评分的单词，且当前没有正在进行的背词批次。")
                }

                let existing = try read(StudyWordProgress.self, projectID: scope.projectID, kind: "word_progress", id: wordCard.id)
                    ?? StudyWordProgress(wordID: wordCard.id, card: nil)

                if undoTokens.contains(cleanedRating) {
                    var reverted = existing
                    if !reverted.logs.isEmpty {
                        reverted.logs.removeLast()
                    }
                    if reverted.logs.isEmpty {
                        reverted.card = nil
                        reverted.lastRating = nil
                        reverted.lastReviewedAt = nil
                    } else {
                        var replayCard = Card(due: reverted.logs[0].review)
                        var lastName = "good"
                        for log in reverted.logs {
                            let step = try scheduler.next(card: replayCard, now: log.review, grade: log.rating)
                            replayCard = step.card
                            switch log.rating {
                            case .easy: lastName = "easy"
                            case .good: lastName = "good"
                            case .hard: lastName = "hard"
                            case .again, .manual: lastName = "again"
                            }
                        }
                        reverted.card = replayCard
                        reverted.lastRating = lastName
                        reverted.lastReviewedAt = reverted.logs.last?.review
                    }
                    try write(reverted, projectID: scope.projectID, kind: "word_progress", id: wordCard.id)
                    let events = try rows(projectID: scope.projectID, kind: "word_event").map { try StudyCoding.decode(StudyWordEvent.self, from: $0) }
                    if var latestEvent = events.filter({ !$0.undone && $0.afterProgress.wordID == wordCard.id }).max(by: { $0.date < $1.date }) {
                        latestEvent.undone = true
                        try write(latestEvent, projectID: scope.projectID, kind: "word_event", id: latestEvent.id.uuidString)
                    }
                    views.append(StudyWordView(word: wordCard, reviewCount: reverted.reviewCount, lastRating: reverted.lastRating, lastReviewedAt: reverted.lastReviewedAt, due: reverted.card?.due))
                    continue
                }

                guard let (canonicalRating, fsrsRating) = ratingMap[cleanedRating] else {
                    throw StudyMemoryError.invalid("评分请使用 easy（轻松）、good（记得）、hard（模糊）、again（忘了）或 undo（撤回）。")
                }

                let scheduled = try scheduler.next(card: existing.card ?? Card(due: now), now: now, grade: fsrsRating)
                var after = existing
                after.card = scheduled.card
                after.logs.append(scheduled.log)
                after.lastRating = canonicalRating
                after.lastReviewedAt = now
                try write(after, projectID: scope.projectID, kind: "word_progress", id: wordCard.id)

                let beforeSession = activeSession ?? StudyWordSession(
                    id: UUID(),
                    threadID: scope.threadID,
                    unitID: "自由背词",
                    mode: .start,
                    wordIDs: [wordCard.id],
                    position: 0,
                    revision: 1,
                    paused: false,
                    updatedAt: now
                )
                var afterSession = beforeSession
                let eventID = UUID()
                if var session = activeSession {
                    if session.currentWordID == wordCard.id {
                        session.position += 1
                    } else if let idx = session.wordIDs.firstIndex(of: wordCard.id), idx >= session.position {
                        session.wordIDs.remove(at: idx)
                        session.wordIDs.insert(wordCard.id, at: session.position)
                        session.position += 1
                    }
                    session.revision += 1
                    session.updatedAt = now
                    session.lastEventID = eventID
                    try write(session, projectID: scope.projectID, kind: "word_session", id: session.id.uuidString)
                    activeSession = session
                    afterSession = session
                } else {
                    afterSession.position = 1
                    afterSession.revision = 2
                    afterSession.updatedAt = now
                    afterSession.lastEventID = eventID
                }

                let event = StudyWordEvent(
                    id: eventID,
                    beforeSession: beforeSession,
                    afterSession: afterSession,
                    beforeProgress: existing,
                    afterProgress: after,
                    source: source,
                    date: now
                )
                try write(event, projectID: scope.projectID, kind: "word_event", id: eventID.uuidString)

                views.append(StudyWordView(word: wordCard, reviewCount: after.reviewCount, lastRating: after.lastRating, lastReviewedAt: after.lastReviewedAt, due: after.due))
            }
            return views
        }

        for outItem in outOfPackItems {
            let label = ["easy": "轻松掌握", "good": "记得", "hard": "印象模糊", "again": "待加强"][outItem.canonicalRating] ?? "已聊"
            _ = try saveMemoryFree(
                scope: scope,
                recordRef: nil,
                action: "save",
                category: "生词",
                text: "\(outItem.word)（聊天/阅读随手记词 · \(label)）",
                message: message
            )
            let fallbackWord = StudyWord(
                id: "notebook:\(outItem.word.lowercased())",
                word: outItem.word,
                translation: "已自动记入项目生词本（\(label)）",
                coreMeaning: "已自动记入项目生词本（\(label)）",
                phonetic: nil,
                meaningStatus: nil,
                phoneticStatus: nil,
                phoneticSourceURL: nil,
                units: []
            )
            updatedViews.append(StudyWordView(word: fallbackWord, reviewCount: 1, lastRating: outItem.canonicalRating, lastReviewedAt: now, due: nil))
        }
        return updatedViews
    }

    private static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}
