import Foundation

enum SpeechEnginePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case system
    case openAI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动（优先 GPT，无密钥或断网用系统免费朗读）"
        case .system: return "始终使用免费系统中文朗读（离线可用）"
        case .openAI: return "仅使用 GPT 语音（需 OpenAI Key）"
        }
    }

    var shortLabel: String {
        switch self {
        case .auto: return "自动兜底"
        case .system: return "免费系统朗读"
        case .openAI: return "仅 GPT 语音"
        }
    }
}

enum SpeechBackendChoice: Equatable, Sendable {
    case openAIWithSystemFallback
    case openAIOnly
    case systemOnly
    case missingOpenAIKey
}

enum SpeechRouting {
    static func resolveBackend(preference: SpeechEnginePreference, hasOpenAIKey: Bool) -> SpeechBackendChoice {
        switch preference {
        case .system:
            return .systemOnly
        case .auto:
            return hasOpenAIKey ? .openAIWithSystemFallback : .systemOnly
        case .openAI:
            return hasOpenAIKey ? .openAIOnly : .missingOpenAIKey
        }
    }
}

/// Cleans Markdown prose before handing it to iOS `AVSpeechSynthesizer` so the system voice
/// never speaks raw formatting symbols (`**`, `###`, backticks, URLs, footnote refs).
enum SpeechTextCleaner {
    static func cleanForSpeech(_ markdown: String) -> String {
        var text = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Replace fenced code blocks with a brief natural spoken pause notice.
        text = replace(pattern: #"```[\s\S]*?```"#, in: text, with: "（此处为代码片段）")
        // Replace Markdown images ![alt](url) -> alt
        text = replace(pattern: #"!\[([^\]]*)\]\([^)]+\)"#, in: text, with: "$1")
        // Replace Markdown links [title](url) -> title
        text = replace(pattern: #"\[([^\]]+)\]\([^)]+\)"#, in: text, with: "$1")
        // Remove footnote references like [^1]
        text = replace(pattern: #"\[\^[^\]]+\]"#, in: text, with: "")
        // Remove heading hashes and blockquote markers at line starts
        text = replace(pattern: #"(?m)^[ \t]{0,3}#{1,6}[ \t]+"#, in: text, with: "")
        text = replace(pattern: #"(?m)^[ \t]*>[ \t]?"#, in: text, with: "")
        // Remove markdown horizontal rules & table separator lines
        text = replace(pattern: #"(?m)^[ \t]*([-*_]){3,}[ \t]*$"#, in: text, with: "")
        text = replace(pattern: #"(?m)^[ \t]*\|?([ \t]*:?-+:?[ \t]*\|)+[ \t]*$"#, in: text, with: "")
        // Strip inline bold/italic/strikethrough/code delimiters while keeping inner text
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")
        text = text.replacingOccurrences(of: "~~", with: "")
        text = text.replacingOccurrences(of: "`", with: "")
        // Replace pipe separators in tables with natural comma pause
        text = text.replacingOccurrences(of: " | ", with: "，")
        // Collapse repeated blank lines and excess spaces
        text = replace(pattern: #"[ \t]{2,}"#, in: text, with: " ")
        text = replace(pattern: #"\n{3,}"#, in: text, with: "\n\n")

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}

/// Deterministic state guard fixing bug #36 (rapid start/stop leaking AVAudioSession `.duckOthers`).
/// Ensures background music volume is ALWAYS restored once the final active playback generation ends.
struct SpeechAudioSessionGuard: Equatable, Sendable {
    private(set) var activeGeneration: UInt64 = 0
    private(set) var isSessionActive: Bool = false

    /// Begins a new speech playback generation and returns its token.
    mutating func beginPlayback() -> UInt64 {
        activeGeneration &+= 1
        if activeGeneration == 0 { activeGeneration = 1 }
        isSessionActive = true
        return activeGeneration
    }

    /// Marks playback ended for a specific generation (or `nil` for forced global stop).
    /// Returns `true` when the caller MUST call `AVAudioSession.setActive(false, options: .notifyOthersOnDeactivation)`.
    mutating func endPlayback(generation: UInt64?) -> Bool {
        if let generation, generation != activeGeneration {
            // A newer playback generation has already superseded this callback; keep session active.
            return false
        }
        let shouldDeactivate = isSessionActive
        isSessionActive = false
        return shouldDeactivate
    }
}
