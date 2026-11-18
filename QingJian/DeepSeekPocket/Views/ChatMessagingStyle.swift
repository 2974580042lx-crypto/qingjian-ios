import Observation
import SwiftUI
import UIKit

enum ChatLayoutMode: String, CaseIterable, Identifiable, Sendable {
    case editorial
    case imessage
    case smart

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editorial: return "书页"
        case .imessage: return "信息气泡"
        case .smart: return "智能"
        }
    }

    var symbol: String {
        switch self {
        case .editorial: return "doc.plaintext"
        case .imessage: return "bubble.left.and.bubble.right"
        case .smart: return "sparkles"
        }
    }

    var summary: String {
        switch self {
        case .editorial: return "无气泡杂志排版，读长文最舒展"
        case .imessage: return "左右双气泡、极简清爽，长文自动放宽"
        case .smart: return "短聊套轻盈小气泡，长文平滑铺成书页"
        }
    }
}

/// Manages default and per-conversation chat layout style in `UserDefaults`,
/// preserving backward compatibility with `qingjian.reading.aiBubble`.
@MainActor @Observable
final class ChatLayoutPreferences {
    static let shared = ChatLayoutPreferences()

    private static let defaultKey = "sermo.chat.layoutMode.default"
    private static let perThreadKey = "sermo.chat.layoutMode.byThread"
    private static let legacyBubbleKey = "qingjian.reading.aiBubble"

    var defaultMode: ChatLayoutMode
    private var overrides: [String: String]

    private init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.defaultKey),
           let saved = ChatLayoutMode(rawValue: raw) {
            self.defaultMode = saved
        } else if defaults.bool(forKey: Self.legacyBubbleKey) {
            self.defaultMode = .imessage
        } else {
            self.defaultMode = .editorial
        }

        if let map = defaults.dictionary(forKey: Self.perThreadKey) as? [String: String] {
            self.overrides = map
        } else {
            self.overrides = [:]
        }
    }

    func mode(for threadID: UUID?) -> ChatLayoutMode {
        guard let threadID,
              let raw = overrides[threadID.uuidString],
              let parsed = ChatLayoutMode(rawValue: raw) else {
            return defaultMode
        }
        return parsed
    }

    func hasOverride(for threadID: UUID?) -> Bool {
        guard let threadID else { return false }
        return overrides[threadID.uuidString] != nil
    }

    func setMode(_ mode: ChatLayoutMode, for threadID: UUID?) {
        guard let threadID else {
            setDefaultMode(mode)
            return
        }
        var updated = overrides
        updated[threadID.uuidString] = mode.rawValue
        if updated.count > 500 {
            let trimmed = Dictionary(updated.prefix(450), uniquingKeysWith: { first, _ in first })
            updated = trimmed
        }
        overrides = updated
        UserDefaults.standard.set(updated, forKey: Self.perThreadKey)
    }

    func setDefaultMode(_ mode: ChatLayoutMode) {
        defaultMode = mode
        let defaults = UserDefaults.standard
        defaults.set(mode.rawValue, forKey: Self.defaultKey)
        defaults.set(mode == .imessage, forKey: Self.legacyBubbleKey)
    }
}

enum ChatBubbleRules {
    static func hasStructuredMarkdown(_ text: String) -> Bool {
        if text.contains("```") || text.contains("$$") { return true }
        if text.contains("\n|") && text.contains("---") { return true }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("# ") || trimmed.hasPrefix("## ") || trimmed.hasPrefix("### ")
                || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ")
                || trimmed.hasPrefix("> ") {
                return true
            }
            if let dot = trimmed.firstIndex(of: "."), dot != trimmed.startIndex {
                let prefix = trimmed[..<dot]
                if prefix.count <= 2 && prefix.allSatisfy(\.isNumber) {
                    let afterDot = trimmed.index(after: dot)
                    if afterDot < trimmed.endIndex && trimmed[afterDot] == " " {
                        return true
                    }
                }
            }
        }
        return false
    }

    static func isCasualShortReply(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 145, !hasStructuredMarkdown(trimmed) else { return false }
        let paragraphs = trimmed.components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return paragraphs.count <= 3
    }

    static func casualBubbleParts(for text: String, mode: ChatLayoutMode, isStreaming: Bool) -> [String]? {
        guard !isStreaming, mode == .imessage || mode == .smart else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 260, !hasStructuredMarkdown(trimmed) else { return nil }

        let doubleNewlineParts = trimmed.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if (2...4).contains(doubleNewlineParts.count),
           doubleNewlineParts.allSatisfy({ $0.count <= 110 }) {
            return doubleNewlineParts
        }

        if doubleNewlineParts.count <= 1 {
            let singleLineParts = trimmed.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if (2...4).contains(singleLineParts.count),
               singleLineParts.allSatisfy({ $0.count <= 85 }) {
                return singleLineParts
            }
        }
        return nil
    }

    static func isCompactSingleBubble(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 145 && !hasStructuredMarkdown(trimmed)
    }
}

enum BubbleGroupPosition: Sendable {
    case single, first, middle, last

    static func forIndex(_ index: Int, total: Int) -> BubbleGroupPosition {
        guard total > 1 else { return .single }
        if index == 0 { return .first }
        if index == total - 1 { return .last }
        return .middle
    }
}

enum AsymmetricBubbleShape {
    static func chatBubbleShape(isUser: Bool, position: BubbleGroupPosition) -> UnevenRoundedRectangle {
        let large: CGFloat = 20
        let tail: CGFloat = 6
        let inner: CGFloat = 10

        let topLeading: CGFloat
        let topTrailing: CGFloat
        let bottomLeading: CGFloat
        let bottomTrailing: CGFloat

        if isUser {
            topLeading = large
            bottomLeading = large
            switch position {
            case .single: topTrailing = large; bottomTrailing = tail
            case .first: topTrailing = large; bottomTrailing = inner
            case .middle: topTrailing = inner; bottomTrailing = inner
            case .last: topTrailing = inner; bottomTrailing = tail
            }
        } else {
            topTrailing = large
            bottomTrailing = large
            switch position {
            case .single: topLeading = large; bottomLeading = tail
            case .first: topLeading = large; bottomLeading = inner
            case .middle: topLeading = inner; bottomLeading = inner
            case .last: topLeading = inner; bottomLeading = tail
            }
        }

        return UnevenRoundedRectangle(
            topLeadingRadius: topLeading,
            bottomLeadingRadius: bottomLeading,
            bottomTrailingRadius: bottomTrailing,
            topTrailingRadius: topTrailing,
            style: .continuous
        )
    }
}

/// iMessage-style 3-dot bouncing indicator shown while waiting for the first streamed token.
@MainActor
struct TypingIndicatorBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        HStack {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Ink.ink3.opacity(0.75))
                        .frame(width: 7, height: 7)
                        .offset(y: (!reduceMotion && phase) ? -3.5 : 0)
                        .opacity(reduceMotion ? 0.65 : (phase ? 1.0 : 0.45))
                        .animation(
                            reduceMotion
                                ? nil
                                : .easeInOut(duration: 0.48)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.14),
                            value: phase
                        )
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(Ink.raised, in: AsymmetricBubbleShape.chatBubbleShape(isUser: false, position: .single))
            .overlay(
                AsymmetricBubbleShape.chatBubbleShape(isUser: false, position: .single)
                    .stroke(Ink.line.opacity(0.55), lineWidth: 0.6)
                    .allowsHitTesting(false)
            )
            Spacer(minLength: 42)
        }
        .onAppear {
            if !reduceMotion { phase = true }
        }
        .accessibilityLabel("对方正在输入")
        .accessibilityIdentifier("stream-activity")
    }
}

/// Persists Tapback-style emoji badges locally without modifying `ChatMessage` Codable schema.
@MainActor @Observable
final class MessageReactionStore {
    static let shared = MessageReactionStore()
    static let quickEmojis = ["❤️", "😂", "👍", "😮"]
    static let moreEmojis = ["🤔", "🙏", "🔥", "👏"]

    private(set) var reactions: [String: String] = [:]
    private let fileURL: URL?

    private init() {
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support?.appendingPathComponent("QingJian", isDirectory: true)
        if let dir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let url = dir?.appendingPathComponent("message-reactions.json")
        self.fileURL = url
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.reactions = decoded
        }
    }

    func reaction(for messageID: UUID) -> String? {
        reactions[messageID.uuidString]
    }

    func toggle(_ emoji: String, for messageID: UUID) {
        let key = messageID.uuidString
        Haptic.tap()
        if reactions[key] == emoji {
            reactions.removeValue(forKey: key)
        } else {
            reactions[key] = emoji
        }
        persist()
    }

    func clear(for messageID: UUID) {
        let key = messageID.uuidString
        guard reactions[key] != nil else { return }
        Haptic.tap()
        reactions.removeValue(forKey: key)
        persist()
    }

    private func persist() {
        guard let url = fileURL else { return }
        var snapshot = reactions
        if snapshot.count > 2000 {
            snapshot = Dictionary(snapshot.prefix(1500), uniquingKeysWith: { first, _ in first })
            reactions = snapshot
        }
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}

@MainActor
struct MessageReactionBadge: View {
    let messageID: UUID

    var body: some View {
        if let emoji = MessageReactionStore.shared.reaction(for: messageID) {
            Button {
                MessageReactionStore.shared.clear(for: messageID)
            } label: {
                Text(emoji)
                    .font(.system(size: 13))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Ink.paper, in: Capsule())
                    .overlay(Capsule().stroke(Ink.line, lineWidth: 0.8))
                    .shadow(color: Color.black.opacity(0.10), radius: 4, y: 1.5)
            }
            .buttonStyle(.pressFeedback)
            .accessibilityLabel("心情贴纸 \(emoji)，点一下移除")
        }
    }
}

@MainActor
struct QuotedReplyCard: View {
    let quote: QuotedMessage
    let alignTrailing: Bool
    let swiss: Bool

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.25, style: .continuous)
                .fill(Ink.seal.opacity(0.8))
                .frame(width: 2.5)
            VStack(alignment: .leading, spacing: 2) {
                Text("回复 \(quote.author)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Ink.seal)
                    .lineLimit(1)
                Text(quote.excerpt)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ink.ink3)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Ink.raised.opacity(0.85), in: RoundedRectangle(cornerRadius: swiss ? 0 : 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: swiss ? 0 : 12, style: .continuous)
                .stroke(Ink.line.opacity(0.55), lineWidth: 0.6)
        )
        .frame(maxWidth: 265, alignment: alignTrailing ? .trailing : .leading)
    }
}

enum MessageTimeDivider {
    private static let todayFormatter: DateFormatter = make("'今天' HH:mm")
    private static let yesterdayFormatter: DateFormatter = make("'昨天' HH:mm")
    private static let sameYearFormatter: DateFormatter = make("M月d日 HH:mm")
    private static let otherYearFormatter: DateFormatter = make("yyyy年M月d日 HH:mm")

    private static func make(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = format
        return formatter
    }

    static func shouldShow(previous: ChatMessage?, current: ChatMessage) -> Bool {
        guard current.directive == nil else { return false }
        guard let previous else { return true }
        let gap = current.createdAt.timeIntervalSince(previous.createdAt)
        return gap >= 1800 || !Calendar.current.isDate(previous.createdAt, inSameDayAs: current.createdAt)
    }

    static func label(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return todayFormatter.string(from: date) }
        if calendar.isDateInYesterday(date) { return yesterdayFormatter.string(from: date) }
        return (calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? sameYearFormatter : otherYearFormatter)
            .string(from: date)
    }
}
