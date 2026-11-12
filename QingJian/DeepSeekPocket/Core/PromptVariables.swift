import Foundation

// Placeholders in a system prompt or project instructions, filled in just
// before each request: {{时间}} becomes "22:05" and so on. Unknown names are
// left as they are, so ordinary braces in a prompt are never eaten.
enum PromptVariables {
    struct Context: Sendable {
        var now: Date
        var userName: String
        var modelName: String
        var calendar = Calendar.current
    }

    /// Each variable answers to a Chinese and an English name.
    static let names: [(chinese: String, english: String, meaning: String)] = [
        ("时间", "time", "当前时间，如 22:05"),
        ("日期", "date", "今天的日期，如 2026年10月17日"),
        ("星期", "weekday", "今天星期几，如 星期六"),
        ("名字", "user", "设置里你的名字"),
        ("模型", "model", "这次回答所用的模型"),
    ]

    static func apply(_ text: String, _ context: Context) -> String {
        guard text.contains("{{") else { return text }
        let values = self.values(context)
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            result += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "}}") else { result += rest[open.lowerBound...]; return result }
            let key = after[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if let value = values[key.lowercased()], !key.isEmpty, key.count <= 20 {
                result += value
            } else {
                result += rest[open.lowerBound..<close.upperBound]
            }
            rest = after[close.upperBound...]
        }
        return result + rest
    }

    static func values(_ context: Context) -> [String: String] {
        let time = format("HH:mm", context)
        let date = format("yyyy年M月d日", context)
        let weekday = format("EEEE", context)
        let user = context.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [String: String] = ["时间": time, "日期": date, "星期": weekday,
                                       "名字": user.isEmpty ? "我" : user, "模型": context.modelName]
        var values: [String: String] = [:]
        for name in names {
            values[name.chinese] = pairs[name.chinese]
            values[name.english] = pairs[name.chinese]
        }
        return values
    }

    private static func format(_ pattern: String, _ context: Context) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = context.calendar
        formatter.timeZone = context.calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: context.now)
    }

    // MARK: Time passing

    /// Below this gap nothing is said, so a running conversation never hears the clock.
    static let quietGap: TimeInterval = 2 * 3600

    /// Always-available background clock note for system prompts when timeAwareness is not explicitly disabled.
    static func currentTimeNote(_ context: Context) -> String {
        "当前时间：\(format("yyyy年M月d日", context)) \(format("EEEE", context)) \(format("HH:mm", context))（仅作背景参考，无需刻意复述）"
    }

    /// A short note for the model when a project lets characters notice time passing:
    /// the current time on a conversation's first message, and how long it has been
    /// after a long gap. Nil while the conversation is flowing.
    static func elapsedNote(since previous: Date?, context: Context) -> String? {
        let now = "\(format("M月d日", context)) \(format("EEEE", context)) \(format("HH:mm", context))"
        guard let previous else {
            return "（时间提示，仅作背景，不必复述：现在是 \(now)。）"
        }
        let gap = context.now.timeIntervalSince(previous)
        guard gap >= quietGap else { return nil }
        return "（时间提示，仅作背景，不必复述：距离上一条消息过去了\(duration(gap))，现在是 \(now)。）"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return " \(max(1, minutes)) 分钟" }
        let hours = minutes / 60
        if hours < 48 { return " \(hours) 小时" }
        return " \(hours / 24) 天"
    }
}
