import Foundation

/// A single node in the Claude-style continuous vertical working timeline.
struct AgentTimelineStep: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case dot
        case event
        case live
    }

    enum IconKind: String, Codable, Sendable {
        case search
        case doc
        case task
        case steer
        case warning
    }

    var id: String
    var kind: Kind
    var icon: IconKind?
    var text: String
    var tech: String?
    var status: ToolActivity.Status
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        kind: Kind,
        icon: IconKind? = nil,
        text: String,
        tech: String? = nil,
        status: ToolActivity.Status = .done,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.icon = icon
        self.text = text
        self.tech = tech
        self.status = status
        self.createdAt = createdAt
    }

    static func iconKind(forToolKind kind: String?, title: String, status: ToolActivity.Status) -> IconKind {
        if status == .failed || status == .needsSignIn { return .warning }
        switch kind {
        case "web":
            return title.contains("读取网页") ? .doc : .search
        case "book":
            return .search
        case "drive", "github":
            if title.contains("搜索") || title.contains("查看") { return .search }
            if title.contains("读取") { return .doc }
            return .task
        case "study":
            return .task
        case "image":
            return .task
        default:
            if title.contains("搜索") || title.contains("检索") { return .search }
            if title.contains("读取") || title.contains("核对") { return .doc }
            return .task
        }
    }
}

/// Sidecar record of an AI turn's multi-step working process, mid-run user steering,
/// and pause/resume/stop lifecycle — persisted outside `ChatMessage` for 100% schema safety.
struct AgentRunRecord: Codable, Equatable, Identifiable, Sendable {
    enum Phase: String, Codable, Sendable {
        case running
        case paused
        case completed
        case stopped
        case failed
    }

    var messageID: UUID
    var threadID: UUID
    var phase: Phase
    var steps: [AgentTimelineStep]
    var steeredNotes: [String]
    var updatedAt: Date

    var id: UUID { messageID }

    init(
        messageID: UUID,
        threadID: UUID,
        phase: Phase = .running,
        steps: [AgentTimelineStep] = [],
        steeredNotes: [String] = [],
        updatedAt: Date = Date()
    ) {
        self.messageID = messageID
        self.threadID = threadID
        self.phase = phase
        self.steps = steps
        self.steeredNotes = steeredNotes
        self.updatedAt = updatedAt
    }

    var isActive: Bool {
        phase == .running || phase == .paused
    }

    var visibleSteps: [AgentTimelineStep] {
        steps
    }

    /// Concise 1-line summary rendered quietly in the chat stream (with inline chevron right after text).
    var summaryLine: String {
        let total = steps.count
        if phase == .paused {
            return total > 0 ? "已暂停执行 · 已完成 \(completedStepCount) 步" : "已暂停执行"
        }
        if phase == .running {
            if let runningStep = steps.last(where: { $0.status == .running || $0.kind == .live }) {
                let done = completedStepCount
                return done > 0 ? "\(runningStep.text) · 已完成 \(done) 步" : runningStep.text
            }
            if let last = steps.last {
                return last.text
            }
            return "正在规划与准备步骤…"
        }
        if phase == .stopped {
            return total > 0 ? "已停止执行 · 完成 \(completedStepCount) 步" : "已停止执行"
        }
        if phase == .failed {
            if let failedStep = steps.last(where: { $0.status == .failed || $0.status == .needsSignIn }) {
                return failedStep.text
            }
            return total > 0 ? "执行中断 · 已完成 \(completedStepCount) 步" : "执行未完成"
        }

        // Completed state: build natural Claude-style summary without fake metrics.
        if total == 1, let only = steps.first {
            return only.text
        }
        var searchCount = 0
        var docCount = 0
        var taskCount = 0
        for step in steps where step.kind == .event {
            switch step.icon {
            case .search: searchCount += 1
            case .doc: docCount += 1
            case .task: taskCount += 1
            default: break
            }
        }
        var parts: [String] = []
        if searchCount > 0 { parts.append("检索了 \(searchCount) 次资料") }
        if docCount > 0 { parts.append("读取了 \(docCount) 份内容") }
        if taskCount > 0 { parts.append("执行了 \(taskCount) 项操作") }
        if !steeredNotes.isEmpty { parts.append("并入 \(steeredNotes.count) 条补充要求") }
        if parts.isEmpty {
            return "已完成 \(total) 步工作过程"
        }
        let prefix = parts.prefix(2).joined(separator: "、")
        return total > 2 ? "\(prefix)，共完成 \(total) 步" : prefix
    }

    /// Short, non-truncated title for the native bottom timeline sheet header.
    var sheetHeaderTitle: String {
        let done = completedStepCount
        switch phase {
        case .running:
            return done > 0 ? "正在执行 · 已完成 \(done) 步" : "正在执行工作步骤"
        case .paused:
            return done > 0 ? "已暂停 · 完成 \(done) 步" : "已暂停执行"
        case .stopped:
            return done > 0 ? "已停止 · 完成 \(done) 步" : "已停止执行"
        case .failed:
            return done > 0 ? "执行中断 · 已完成 \(done) 步" : "执行未完成"
        case .completed:
            return "已完成 \(max(1, steps.count)) 步工作"
        }
    }

    var completedStepCount: Int {
        steps.filter { $0.status == .done && $0.kind != .live }.count
    }

    mutating func appendPlanningNote(_ rawNote: String) {
        let firstSentence = Self.condensePlanningSentence(rawNote)
        guard !firstSentence.isEmpty else { return }
        if steps.contains(where: { $0.kind == .dot && $0.text == firstSentence }) { return }
        steps.append(AgentTimelineStep(kind: .dot, text: firstSentence, status: .done))
        updatedAt = Date()
    }

    mutating func upsertToolStep(
        id: String,
        kind: String?,
        title: String,
        status: ToolActivity.Status,
        detail: String?
    ) {
        // Keep silent completed internal manual checks hidden, matching clean Claude UX.
        if kind == "manual" && status == .done {
            steps.removeAll { $0.id == id }
            updatedAt = Date()
            return
        }
        let icon = AgentTimelineStep.iconKind(forToolKind: kind, title: title, status: status)
        let cleanDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let techText = (cleanDetail?.isEmpty == false) ? cleanDetail : nil
        if let idx = steps.firstIndex(where: { $0.id == id }) {
            steps[idx].icon = icon
            steps[idx].text = title
            steps[idx].status = status
            if let techText { steps[idx].tech = techText }
        } else {
            steps.append(AgentTimelineStep(
                id: id,
                kind: .event,
                icon: icon,
                text: title,
                tech: techText,
                status: status
            ))
        }
        updatedAt = Date()
    }

    mutating func appendSteeringNote(_ note: String) {
        let clean = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        steeredNotes.append(clean)
        steps.append(AgentTimelineStep(
            kind: .event,
            icon: .steer,
            text: "已并入补充要求：\(clean)",
            tech: "用户中途追加 · 当前步骤完成后衔接执行",
            status: .done
        ))
        updatedAt = Date()
    }

    mutating func finish(phase finalPhase: Phase) {
        steps.removeAll { $0.kind == .live }
        for idx in steps.indices where steps[idx].status == .running {
            steps[idx].status = finalPhase == .completed ? .done : .failed
        }
        self.phase = finalPhase
        updatedAt = Date()
    }

    private static func condensePlanningSentence(_ raw: String) -> String {
        let firstLine = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        guard !firstLine.isEmpty else { return "" }
        let stripped = firstLine
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-*•1234567890. "))
        guard stripped.count >= 4 else { return "" }
        if stripped.count <= 46 { return stripped }
        return String(stripped.prefix(45)) + "…"
    }

    /// Synthesizes an `AgentRunRecord` on the fly from `ChatMessage.toolActivity` when no sidecar
    /// record was saved (e.g. historical chats from earlier versions), ensuring 100% uniform UI.
    static func synthesized(
        from message: ChatMessage,
        threadID: UUID?,
        existing: AgentRunRecord?
    ) -> AgentRunRecord? {
        let visibleTools = (message.toolActivity ?? []).filter { item in
            !(item.kind == "manual" && item.status == .done && item.studyReport == nil && item.studyExcerpts == nil)
        }
        if var record = existing {
            // Merge any newly updated tool activities from the message so status stays completely in sync.
            for item in visibleTools {
                record.upsertToolStep(
                    id: item.id,
                    kind: item.kind,
                    title: item.title,
                    status: item.status,
                    detail: item.detail
                )
            }
            if message.state != .streaming && record.isActive {
                let mappedPhase: Phase = switch message.state {
                case .complete: .completed
                case .stopped: .stopped
                case .failed: .failed
                case .streaming: .running
                }
                record.finish(phase: mappedPhase)
            }
            return record.steps.isEmpty ? nil : record
        }

        guard !visibleTools.isEmpty else { return nil }
        let resolvedThreadID = threadID ?? UUID()
        let mappedPhase: Phase = switch message.state {
        case .streaming: .running
        case .complete: .completed
        case .stopped: .stopped
        case .failed: .failed
        }
        var record = AgentRunRecord(messageID: message.id, threadID: resolvedThreadID, phase: mappedPhase, updatedAt: message.createdAt)
        if !message.reasoning.isEmpty {
            record.appendPlanningNote(message.reasoning)
        }
        for item in visibleTools {
            record.upsertToolStep(
                id: item.id,
                kind: item.kind,
                title: item.title,
                status: item.status,
                detail: item.detail
            )
        }
        return record.steps.isEmpty ? nil : record
    }
}

/// Thread-safe sidecar persistence for `AgentRunRecord` entries (`agent-runs.json`).
final class AgentRunStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL?
    private let maxRecords: Int
    private var records: [UUID: AgentRunRecord] = [:]
    private var order: [UUID] = []

    private struct DiskPayload: Codable {
        var order: [UUID]
        var records: [AgentRunRecord]
    }

    init(fileURL: URL? = Self.defaultFileURL(), maxRecords: Int = 400) {
        self.fileURL = fileURL
        self.maxRecords = max(32, maxRecords)
        loadFromDisk()
    }

    static func defaultFileURL() -> URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("QingJian/agent-runs.json")
    }

    func record(for messageID: UUID) -> AgentRunRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records[messageID]
    }

    func save(_ record: AgentRunRecord, flushImmediately: Bool = true) {
        var encodedData: Data?
        let targetURL = fileURL
        lock.lock()
        records[record.messageID] = record
        order.removeAll { $0 == record.messageID }
        order.append(record.messageID)
        while order.count > maxRecords {
            let oldest = order.removeFirst()
            records.removeValue(forKey: oldest)
        }
        if flushImmediately, targetURL != nil {
            let orderedRecords = order.compactMap { records[$0] }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encodedData = try? encoder.encode(DiskPayload(order: order, records: orderedRecords))
        }
        lock.unlock()

        if let targetURL, let encodedData {
            try? FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encodedData.write(to: targetURL, options: [.atomic])
        }
    }

    func flushToDisk() {
        guard let targetURL = fileURL else { return }
        let encodedData: Data?
        lock.lock()
        let orderedRecords = order.compactMap { records[$0] }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encodedData = try? encoder.encode(DiskPayload(order: order, records: orderedRecords))
        lock.unlock()

        if let encodedData {
            try? FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encodedData.write(to: targetURL, options: [.atomic])
        }
    }

    private func loadFromDisk() {
        guard let fileURL,
              FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(DiskPayload.self, from: data) else { return }
        lock.lock()
        records = Dictionary(uniqueKeysWithValues: decoded.records.map { ($0.messageID, $0) })
        order = decoded.order.filter { records[$0] != nil }
        for item in decoded.records where !order.contains(item.messageID) {
            order.append(item.messageID)
        }
        // Any run left in .running / .paused across an app restart is finalized cleanly as .stopped.
        for key in Array(records.keys) {
            if var r = records[key], r.isActive {
                r.finish(phase: .stopped)
                records[key] = r
            }
        }
        lock.unlock()
    }
}
