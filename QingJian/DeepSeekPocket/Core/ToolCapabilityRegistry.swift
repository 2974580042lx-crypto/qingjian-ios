import Foundation

/// Per-conversation tool execution permission policy exposed in the 1:1 Claude「添加到会话」sheet.
enum ToolPermissionPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case alwaysAsk = "always_ask"
    case chatOnly = "chat_only"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .alwaysAsk: return "每次询问"
        case .chatOnly: return "仅纯聊天"
        }
    }

    var subtitle: String {
        switch self {
        case .auto:
            return "只读检索与本地整理自动执行；涉及云盘或 GitHub 写入时仍向你确认"
        case .alwaysAsk:
            return "每次调用外部检索、读取或写入工具前都先经你点按同意"
        case .chatOnly:
            return "本会话暂时关闭所有工具与联网，仅进行纯文字交流"
        }
    }
}

/// Sidecar per-thread preferences for Agent research mode and tool permission policy.
/// Stored outside `ChatThread` / `ChatMessage` so `conversations.json` keeps 100% schema compatibility.
struct SessionAgentPreferences: Codable, Equatable, Sendable {
    var permissionPolicy: ToolPermissionPolicy = .auto
    var researchMode: Bool = false
    var driveEnabled: Bool? = nil
    var githubEnabled: Bool? = nil
    var webEnabled: Bool? = nil
}

final class SessionAgentPreferencesStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL?
    private let maxEntries: Int
    private var entries: [String: SessionAgentPreferences] = [:]
    private var order: [String] = []

    private struct DiskPayload: Codable {
        var order: [String]
        var entries: [String: SessionAgentPreferences]
    }

    init(fileURL: URL? = SessionAgentPreferencesStore.defaultFileURL(), maxEntries: Int = 600) {
        self.fileURL = fileURL
        self.maxEntries = max(32, maxEntries)
        loadFromDisk()
    }

    static func defaultFileURL() -> URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("QingJian/session-agent-prefs.json")
    }

    func preferences(for threadID: UUID?) -> SessionAgentPreferences {
        guard let threadID else { return SessionAgentPreferences() }
        lock.lock()
        defer { lock.unlock() }
        return entries[threadID.uuidString] ?? SessionAgentPreferences()
    }

    func update(for threadID: UUID, _ mutate: (inout SessionAgentPreferences) -> Void) {
        let key = threadID.uuidString
        var snapshotData: Data?
        let targetURL = fileURL
        lock.lock()
        var current = entries[key] ?? SessionAgentPreferences()
        mutate(&current)
        if current == SessionAgentPreferences() {
            entries.removeValue(forKey: key)
            order.removeAll { $0 == key }
        } else {
            entries[key] = current
            order.removeAll { $0 == key }
            order.append(key)
            while order.count > maxEntries {
                let oldest = order.removeFirst()
                entries.removeValue(forKey: oldest)
            }
        }
        if targetURL != nil {
            snapshotData = try? JSONEncoder().encode(DiskPayload(order: order, entries: entries))
        }
        lock.unlock()

        if let targetURL, let snapshotData {
            try? FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? snapshotData.write(to: targetURL, options: [.atomic])
        }
    }

    private func loadFromDisk() {
        guard let fileURL,
              FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(DiskPayload.self, from: data) else { return }
        lock.lock()
        entries = decoded.entries
        order = decoded.order.filter { decoded.entries[$0] != nil }
        lock.unlock()
    }
}

/// Single source of truth for provider tool/vision capabilities, permission confirmation rules,
/// and multi-step research guidance injection.
enum ToolCapabilityRegistry {
    static func supportsFunctionTools(
        provider: AIProvider,
        colabToolsEnabled: Bool,
        compatibleToolsEnabled: Bool = true
    ) -> Bool {
        switch provider {
        case .deepSeek, .chatGPT:
            return true
        case .colab:
            return colabToolsEnabled
        case .compatible:
            return compatibleToolsEnabled
        }
    }

    static func supportsDirectVision(provider: AIProvider, deepSeekModel: DeepSeekModel) -> Bool {
        switch provider {
        case .chatGPT, .colab, .compatible:
            return true
        case .deepSeek:
            return deepSeekModel == .flash
        }
    }

    static func shouldConfirmToolCall(
        name: String,
        isIntrinsicWrite: Bool,
        policy: ToolPermissionPolicy
    ) -> Bool {
        if OperationManualTools.names.contains(name) { return false }
        switch policy {
        case .auto:
            return isIntrinsicWrite
        case .alwaysAsk, .chatOnly:
            return true
        }
    }

    static func shouldUseAgentResearchPrompt(
        userText: String,
        explicitResearchMode: Bool,
        hasTools: Bool
    ) -> Bool {
        guard hasTools else { return false }
        if explicitResearchMode { return true }
        let clean = PendingDocumentCodec.extractEditableUserText(userText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 28 else { return false }
        let multiStepSignals = ["先", "再", "然后", "对比", "核对", "逐条", "整理成", "汇总", "分别", "梳理", "查一下"]
        var hitCount = 0
        for token in multiStepSignals where clean.contains(token) {
            hitCount += 1
            if hitCount >= 2 { return true }
        }
        return clean.count >= 90 && hitCount >= 1
    }

    static let researchAgentSystemNote = """
    当前请求涉及多步查证或系统整理。请按清晰步骤推进工作：先通过可用工具检索并核对原始资料/网页/仓库事实，确认关键页码、数据或代码无误后再归纳成文；若证据不足请如实说明，绝不编造出处或假装执行未调用的工具。
    """
}

/// Bounded persistent cache for DeepSeek V4 Pro vision/OCR image descriptions so follow-up questions
/// in multi-turn conversations retain full awareness of earlier attached images without paying twice (#18).
final class VisionDescriptionCache: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL?
    private let maxEntries: Int
    private var entries: [String: String] = [:]
    private var order: [String] = []

    private struct DiskPayload: Codable {
        var order: [String]
        var entries: [String: String]
    }

    init(fileURL: URL? = VisionDescriptionCache.defaultFileURL(), maxEntries: Int = 200) {
        self.fileURL = fileURL
        self.maxEntries = max(16, maxEntries)
        loadFromDisk()
    }

    static func defaultFileURL() -> URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("QingJian/vision-cache.json")
    }

    func description(for imageName: String) -> String? {
        guard !imageName.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return entries[imageName]
    }

    func cachedDescription(for imageNames: [String]) -> String? {
        let cleaned = imageNames.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        return description(for: cleaned.joined(separator: "|"))
    }

    func storeDescription(_ text: String, for imageNames: [String]) {
        let cleaned = imageNames.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        store(description: text, for: cleaned.joined(separator: "|"))
    }

    func store(description: String, for imageName: String) {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !imageName.isEmpty, !trimmed.isEmpty else { return }
        var snapshotData: Data?
        let targetURL = fileURL
        lock.lock()
        entries[imageName] = String(trimmed.prefix(16_000))
        order.removeAll { $0 == imageName }
        order.append(imageName)
        while order.count > maxEntries {
            let oldest = order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        if targetURL != nil {
            snapshotData = try? JSONEncoder().encode(DiskPayload(order: order, entries: entries))
        }
        lock.unlock()

        if let targetURL, let snapshotData {
            try? FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? snapshotData.write(to: targetURL, options: [.atomic])
        }
    }

    private func loadFromDisk() {
        guard let fileURL,
              FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(DiskPayload.self, from: data) else { return }
        lock.lock()
        entries = decoded.entries
        order = decoded.order.filter { decoded.entries[$0] != nil }
        lock.unlock()
    }
}
