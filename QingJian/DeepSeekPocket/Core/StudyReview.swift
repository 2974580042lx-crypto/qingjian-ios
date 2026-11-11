import Foundation

struct StudyReviewInput: Codable, Sendable {
    let memories: [StudyMemoryRecord]
    let memoryEvents: [StudyMemoryEvent]
    let wordEvents: [StudyWordEvent]
    let wordSessions: [StudyWordSession]
    let wordNames: [String: String]
    let readingEvents: [StudyReadingEvent]
    let readingAnswers: [StudyReadingAnswer]
    let readingSessions: [StudyReadingSession]
    let readingTitles: [String: String]
    let topics: [StudyTopic]
    let topicEvents: [StudyTopicEvent]
    let topicSessions: [StudyTopicSession]
    let practices: [StudyPractice]
    let practiceEvents: [StudyPracticeEvent]
    var digest: String { (try? StudyCoding.hash(StudyCoding.encode(self))) ?? "" }
}
struct StudyWeeklyReport: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let projectID: UUID
    let start: Date
    let end: Date
    let timeZoneID: String
    let revision: Int
    let text: String
    let sourceDigest: String
    let sourceReferences: [String]
    let createdAt: Date
}
struct StudyWeeklyResult: Codable, Sendable {
    let status: String // missing, current, stale, generated
    let message: String
    let report: StudyWeeklyReport?
    var confirmsCurrentReport: Bool { ["generated", "current"].contains(status) && report != nil }
}
struct StudyReviewPresentation: Identifiable {
    let id = UUID()
    let title: String
    let text: String
    let kind: String
    let current: Bool
}
enum StudyReviewText {
    static func calendar(_ zone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = zone; c.firstWeekday = 2; c.minimumDaysInFirstWeek = 4; return c
    }
    static func day(_ now: Date, zone: TimeZone) -> DateInterval {
        calendar(zone).dateInterval(of: .day, for: now)!
    }
    static func week(_ now: Date, weeksAgo: Int, zone: TimeZone) -> DateInterval {
        let c = calendar(zone), date = c.date(byAdding: .weekOfYear, value: -weeksAgo, to: now)!
        return c.dateInterval(of: .weekOfYear, for: date)!
    }
    static func stamp(_ date: Date, zone: TimeZone) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.timeZone = zone; f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: date)
    }
    static func contains(_ date: Date, _ period: DateInterval) -> Bool { date >= period.start && date < period.end }
    static func sourceName(_ kind: StudySource.Kind) -> String {
        switch kind { case .userStatement: return "用户原话/用户报告"; case .modelInference: return "模型整理或判断，待核"; case .manual: return "手动补记，学习日期未确认" }
    }
    static func render(_ x: StudyReviewInput, subject: StudySubject, period: DateInterval, zone: TimeZone) -> String {
        var lines = ["项目：\(subject.title)", "时间范围：\(stamp(period.start, zone: zone)) 至 \(stamp(period.end, zone: zone))（不含结束时刻，\(zone.identifier)）",
            "这里只汇总软件实际保存的数据。没有记录不等于没有学习；记录日期不直接证明学习发生日期。"]
        if subject == .english { lines += ["", "【实际背词与阅读作答】"] }
        var activityCount = 0
        let wordEvents = x.wordEvents.filter { !$0.undone && contains($0.source.messageDate ?? $0.date, period) }
        if !wordEvents.isEmpty {
            let groups = Dictionary(grouping: wordEvents, by: { $0.afterProgress.wordID })
            lines += ["背词：\(wordEvents.count) 次有效回答，涉及 \(groups.count) 个词；次数不代表掌握。"]
            for id in groups.keys.sorted() {
                let last = groups[id]!.max { $0.date < $1.date }!
                let ratings = ["again":"未记住", "hard":"模糊", "good":"记得", "easy":"轻松"]
                lines += ["- \(x.wordNames[id] ?? id)：\(groups[id]!.count) 次回答；最近评分 \(ratings[last.afterProgress.lastRating ?? ""] ?? "未记录")。原话：\(last.source.quote)"]
            }
            activityCount += wordEvents.count
        }
        let firstReadAnswers = Dictionary(grouping: x.readingEvents.filter { $0.newAnswer?.skipped == false }, by: { "\($0.after.id)/\($0.newAnswer!.question)" })
        for events in firstReadAnswers.values.sorted(by: { $0[0].date < $1[0].date }) {
            guard let first = events.min(by: { $0.date < $1.date }), contains(first.source.messageDate ?? first.date, period),
                  let latest = x.readingAnswers.first(where: { $0.sessionID == first.after.id && $0.question == first.newAnswer?.question }), !latest.skipped else { continue }
            let title = x.readingTitles[first.after.passageID] ?? first.after.passageID
            let outcome = latest.correct.map { $0 ? "按当前参考答案为正确" : "按当前参考答案为错误" } ?? "参考答案待核，不判对错"
            lines += ["- 阅读 \(title) 第\(latest.question)题：当前选择 \(latest.choice ?? "未记录")，\(outcome)。原作答日期：\(stamp(first.source.messageDate ?? first.date, zone: zone))。"]
            activityCount += 1
        }
        let corrections = x.readingEvents.filter { $0.oldAnswer?.skipped == false && $0.newAnswer != nil && contains($0.source.messageDate ?? $0.date, period) }
        if !corrections.isEmpty { lines += ["另有 \(corrections.count) 次阅读作答纠正，保留旧答案，不重复计为新题。"] }
        if subject == .english && activityCount == 0 { lines += ["本时段没有已保存的背词或阅读作答。"] }

        if subject != .english { lines += ["", "【历史/政治练习记录】"] }
        let validPractices = x.practices.filter { !$0.isDeleted }
        var periodPractices: [StudyPractice] = []
        for p in validPractices {
            let first = x.practiceEvents.filter { $0.after.id == p.id && $0.before == nil }.min { $0.date < $1.date }
            let originalDate = first?.source.messageDate ?? first?.date ?? p.createdAt
            if contains(originalDate, period) { periodPractices.append(p) }
        }
        for p in periodPractices.sorted(by: { $0.createdAt < $1.createdAt }) {
            let outcome = p.outcome == .correct ? "正确" : p.outcome == .wrong ? "错误" : "未确认"
            lines += ["- \(p.area) · \(p.kind.title)：\(p.question)（\(p.questionIsQuoted ? "用户原话题目" : "模型整理摘要，原题待核")）", "  作答：\(p.answer.isEmpty ? "未记录作答" : p.answer)；结果：\(outcome)（\(sourceName(p.source.kind))）。",
                      "  薄弱点：\(p.weakPoint.isEmpty ? "尚未记录" : p.weakPoint)\(p.weakPoint.isEmpty ? "" : p.weakPointIsQuoted ? "（用户原话）" : "（模型整理，待核）")"]
            if p.source.attachmentIDs?.isEmpty == false { lines += ["  来源含用户图片；此文字导出没有携带原图，题目摘要需要对照原图，不能冒充原题。"] }
        }
        if subject != .english && periodPractices.isEmpty { lines += ["本时段没有这类练习记录。"] }
        let areas = subject == .politics ? StudyLessonTools.politicsAreas : StudyLessonTools.historyAreas
        if subject != .english {
            var unsampled: [String] = []
            for area in areas {
                let confirmed = periodPractices.filter { $0.area == area && $0.countsForAccuracy }
                if confirmed.isEmpty { unsampled.append(area) }
                else {
                    let correct = confirmed.filter { $0.outcome == .correct }.count
                    lines += ["\(area)选择题：已记录且由用户确认的 \(confirmed.count) 题中，正确 \(correct) 题，\(Int((Double(correct) / Double(confirmed.count) * 100).rounded()))%。这不是全部纸质练习的正确率。"]
                }
            }
            if !unsampled.isEmpty { lines += ["\(unsampled.joined(separator: "、"))：尚无用户确认的选择题样本，不计算正确率。"] }
        }
        let correctedPractices = x.practiceEvents.filter { $0.before != nil && contains($0.source.messageDate ?? $0.date, period) }
        if !correctedPractices.isEmpty { lines += ["本时段另有 \(correctedPractices.count) 次练习纠正或移除，不另计新题；旧报告需按当前有效记录重生成。"] }

        if subject != .english { lines += ["", "【专题活动与学习阶段】"] }
        let activeTopics = Set(x.topicEvents.filter { contains($0.source.messageDate ?? $0.date, period) }.map { $0.after.id })
        for topic in x.topics.filter({ activeTopics.contains($0.id) }).sorted(by: { $0.updatedAt < $1.updatedAt }) {
            lines += ["- \(topic.title)：\(topic.phase.title)，\(topic.level.title)（\(sourceName(topic.source.kind))；\(topic.referenceNotice)）。\(topic.note)"]
        }
        if subject != .english && activeTopics.isEmpty { lines += ["本时段没有保存专题进度。"] }

        lines += ["", "【本时段记录/整理的记忆，不等于本时段新学内容】"]
        let changedIDs = Set(x.memoryEvents.filter { contains($0.date, period) || contains($0.after.source.messageDate ?? $0.date, period) }.map { $0.after.id })
        let currentMemories = x.memories.filter { !$0.isDeleted }
        for memory in currentMemories.filter({ changedIDs.contains($0.id) }).sorted(by: { $0.updatedAt < $1.updatedAt }) {
            lines += ["- \(memory.category)：\(memory.text)（\(sourceName(memory.source.kind))）",
                      "  原话日期：\(memory.source.messageDate.map { stamp($0, zone: zone) } ?? "未知，可能是手动补记")；保存日期：\(stamp(memory.updatedAt, zone: zone))。"]
            if !memory.source.quote.isEmpty { lines += ["  原话：\(memory.source.quote)"] }
        }
        if !currentMemories.contains(where: { changedIDs.contains($0.id) }) { lines += ["没有新增的有效记忆；被移除的内容不会带出。"] }

        let learningText = lines.joined(separator: "\n")
        let keywords = Set(wordEvents.compactMap { x.wordNames[$0.afterProgress.wordID] } + x.topics.filter { activeTopics.contains($0.id) }.map(\.title) + periodPractices.map(\.area))
        let related = currentMemories.filter { memory in
            !changedIDs.contains(memory.id) && (keywords.contains { memory.text.localizedCaseInsensitiveContains($0) } || (!memory.text.isEmpty && learningText.contains(memory.text)))
        }.sorted { $0.updatedAt > $1.updatedAt }
        lines += ["", "【相关长期记忆，与本时段记录分开】"]
        if related.isEmpty { lines += ["没有按当前词、专题或板块匹配到相关长期记录，不凭空补充学习经历。"] }
        else { for m in related { lines += ["- \(m.category)：\(m.text)（\(sourceName(m.source.kind))；保存于\(stamp(m.updatedAt, zone: zone))）"] } }

        lines += ["", "【可以从哪里继续：已保存的现场，可能早于本时段】"]
        lines += ["各类列最近3个窗口的当前现场；更早现场仍保留，可在聊天中按单元或篇目/专题找回。"]
        var resumes = 0
        let wordScenes = Dictionary(grouping: x.wordSessions.filter { !$0.completed }, by: \.threadID).values.compactMap { $0.max { $0.updatedAt < $1.updatedAt } }.sorted { $0.updatedAt > $1.updatedAt }
        for s in wordScenes.prefix(3) {
            lines += ["- 背词：\(s.unitID.isEmpty ? "当前单元" : s.unitID)，当前第\(s.position + 1)/\(s.wordIDs.count)次提问：\(s.currentWordID.flatMap { x.wordNames[$0] } ?? "待查询")，\(s.paused ? "已暂停" : "待继续")。"]
            resumes += 1
        }
        let readingScenes = Dictionary(grouping: x.readingSessions, by: \.threadID).values.compactMap { $0.max { $0.updatedAt < $1.updatedAt } }.sorted { $0.updatedAt > $1.updatedAt }
        for s in readingScenes.prefix(3) {
            let answer = x.readingAnswers.first { $0.sessionID == s.id && $0.question == s.question }
            lines += ["- 阅读：\(x.readingTitles[s.passageID] ?? s.passageID)，第\(s.paragraph)段，\(s.question.map { "第\($0)题" } ?? "尚未选题")，\(answer == nil ? "尚无本题作答" : answer!.skipped ? "此前跳过" : "已有作答，可先核对后继续")。"]
            resumes += 1
        }
        let topicScenes = Dictionary(grouping: x.topicSessions, by: \.threadID).values.compactMap { $0.max { $0.updatedAt < $1.updatedAt } }.sorted { $0.updatedAt > $1.updatedAt }
        for s in topicScenes.prefix(3) {
            if let t = x.topics.first(where: { $0.id == s.topicID }) {
                lines += ["- 专题：\(t.title)，\(s.paused ? "已暂停" : "可继续")。待回答：\(s.pendingPrompt.isEmpty ? "尚未记录具体问题，可先问我想从哪一点继续" : s.pendingPrompt)"]
                resumes += 1
            }
        }
        if resumes == 0 { lines += ["没有保存的继续位置，请先问我准备复习哪一项。"] }
        return lines.joined(separator: "\n")
    }
    static func voicePrompt(_ x: StudyReviewInput, subject: StudySubject, instructions: String, now: Date, zone: TimeZone) -> String {
        let facts = render(x, subject: subject, period: day(now, zone: zone), zone: zone)
        var text = """
请作为我的聊天复习伙伴，在接下来的文字或语音通话中陪我复习。
这是从我的学习软件导出的实际记录。今天是\(stamp(now, zone: zone))（\(zone.identifier)）。请区分当天实际练习、当天补记/纠正、长期记忆和旧的继续位置；没记录的事不要编造。
自然地聊天，一次只提一个小问题。可以用关键词回忆、联系例子或让我解释一个区别。先给我思考和回答机会，再根据我的回答补充或纠正；不要提前泄露答案，不要一上来长篇讲课，也不要连续考试式追问。
标记为第一遍学习的内容以理解、熟悉和建立框架为主，不要求马上背熟。阶段未知时先问我的熟悉程度。针对实际错题、模糊评分和易混点灵活回顾，随时允许插话。
模型整理/判断和待核答案不是可靠标准答案；历史以我的书为准，政治时政只认我提供的资料。图片没有随文字带出，摘要不充分时先请我描述原题，不猜图片内容。
先用一句话说明这份记录里可以复习什么，再给一个轻量问题，等我回答。若今天无实际学习记录，坦诚说明，可问我要不要从保存的旧现场继续。

"""
        if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text += "【我自己填写的项目指令】\n" + instructions + "\n\n" }
        return text + "【学习记录与出处】\n" + facts
    }
}

extension StudyMemoryStore {
    private func rawReviewInput(_ project: UUID) throws -> StudyReviewInput {
        func values<T: Decodable>(_ type: T.Type, _ kind: String) throws -> [T] { try rows(projectID: project, kind: kind).map { try StudyCoding.decode(type, from: $0) } }
        let pack = try read(StudyWordPack.self, projectID: project, kind: "word_pack", id: "core")
        let catalog = try read([StudyReadingCatalogEntry].self, projectID: project, kind: "reading_catalog", id: "index") ?? []
        return try .init(memories: values(StudyMemoryRecord.self, "memory"), memoryEvents: values(StudyMemoryEvent.self, "event"),
            wordEvents: values(StudyWordEvent.self, "word_event"), wordSessions: values(StudyWordSession.self, "word_session"),
            wordNames: Dictionary(uniqueKeysWithValues: (pack?.cards ?? []).map { ($0.id, $0.word) }),
            readingEvents: values(StudyReadingEvent.self, "reading_event"), readingAnswers: values(StudyReadingAnswer.self, "reading_answer"),
            readingSessions: values(StudyReadingSession.self, "reading_session"), readingTitles: Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0.title) }),
            topics: values(StudyTopic.self, "topic"), topicEvents: values(StudyTopicEvent.self, "topic_event"), topicSessions: values(StudyTopicSession.self, "topic_session"),
            practices: values(StudyPractice.self, "practice"), practiceEvents: values(StudyPracticeEvent.self, "practice_event"))
    }
    func reviewInput(projectID: UUID) throws -> StudyReviewInput { try transaction { try rawReviewInput(projectID) } }
    func voiceReview(scope: StudyScope, instructions: String, now: Date = Date(), zone: TimeZone = .current) throws -> String {
        try StudyReviewText.voicePrompt(reviewInput(projectID: scope.projectID), subject: scope.subject, instructions: instructions, now: now, zone: zone)
    }
    func weeklyReport(scope: StudyScope, weeksAgo: Int, generate: Bool, now: Date = Date(), zone: TimeZone = .current) throws -> StudyWeeklyResult {
        guard (0...52).contains(weeksAgo) else { throw StudyMemoryError.invalid("最多查看52周内的周报。") }
        let period = StudyReviewText.week(now, weeksAgo: weeksAgo, zone: zone)
        return try transaction {
            let input = try rawReviewInput(scope.projectID)
            let digest = StudyCoding.hash(try StudyCoding.encode(input))
            let reports = try rows(projectID: scope.projectID, kind: "weekly_report").map { try StudyCoding.decode(StudyWeeklyReport.self, from: $0) }
            let previous = reports.filter { $0.start == period.start && $0.end == period.end && $0.timeZoneID == zone.identifier }.max { $0.revision < $1.revision }
            if !generate {
                let status = previous == nil ? "missing" : previous?.sourceDigest == digest ? "current" : "stale"
                return .init(status: status, message: status == "missing" ? "这周尚未生成周报。" : status == "stale" ? "学习记录已变化，旧周报需要重新生成。" : "已有周报与当前记录一致。", report: previous)
            }
            if let previous, previous.sourceDigest == digest { return .init(status: "generated", message: "已确认周报为最新，无需重复保存。", report: previous) }
            let refs = input.memoryEvents.map { "memory-event/\($0.id)" } + input.wordEvents.map { "word-event/\($0.id)" } + input.readingEvents.map { "reading-event/\($0.id)" } + input.topicEvents.map { "topic-event/\($0.id)" } + input.practiceEvents.map { "practice-event/\($0.id)" }
            let report = StudyWeeklyReport(id: UUID(), projectID: scope.projectID, start: period.start, end: period.end,
                timeZoneID: zone.identifier, revision: (previous?.revision ?? 0) + 1,
                text: "学习周报\n\n" + StudyReviewText.render(input, subject: scope.subject, period: period, zone: zone),
                sourceDigest: digest, sourceReferences: refs, createdAt: now)
            try write(report, projectID: scope.projectID, kind: "weekly_report", id: report.id.uuidString)
            return .init(status: "generated", message: "本周报已生成并保存，包含实际来源；没有记录的部分明确留空。", report: report)
        }
    }
}
