import Foundation

enum VoiceInputMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case dictation
    case oralDrill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: return "语音转文字"
        case .oralDrill: return "口述抽背判分"
        }
    }

    var sendButtonTitle: String {
        switch self {
        case .dictation: return "直接发送"
        case .oralDrill: return "发给 Sermo 判分"
        }
    }
}

enum VoiceAuthorizationState: Equatable, Sendable {
    case notDetermined
    case authorized
    case microphoneDenied
    case speechDenied
    case restricted
    case unavailable(String)

    var isReady: Bool {
        self == .authorized
    }

    var userMessage: String? {
        switch self {
        case .notDetermined, .authorized:
            return nil
        case .microphoneDenied:
            return "未开启麦克风权限。请前往 iPhone「设置 → 隐私与安全性 → 麦克风」打开 Sermo 后再试。"
        case .speechDenied:
            return "未开启语音识别权限。请前往 iPhone「设置 → 隐私与安全性 → 语音识别」打开 Sermo 后再试。"
        case .restricted:
            return "当前设备受「屏幕使用时间」或系统策略限制，暂时无法使用语音识别。"
        case .unavailable(let detail):
            return detail
        }
    }
}

enum OralDrillPromptBuilder {
    /// Recommends oral-drill mode automatically inside 313 History / Politics / Study projects.
    static func defaultMode(for project: ChatProject?) -> VoiceInputMode {
        guard let subject = project?.studySubject else { return .dictation }
        switch subject {
        case .history, .politics, .english:
            return .oralDrill
        }
    }

    /// Merges spoken transcript cleanly onto an existing composer draft.
    static func mergeIntoDraft(existing: String, spoken: String) -> String {
        let cleanSpoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSpoken.isEmpty else { return existing }
        let trimmedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExisting.isEmpty else { return cleanSpoken }

        let endsWithPunctuation = trimmedExisting.last.map { "。！？；，、,.!?;:\n".contains($0) } ?? false
        if endsWithPunctuation {
            return existing + cleanSpoken
        }
        return existing + "，" + cleanSpoken
    }

    /// Wraps a spoken recitation transcript into a crisp grading prompt tailored to Xiaolong's study subject.
    static func buildOralDrillSubmission(spoken: String, project: ChatProject?) -> String {
        let cleanSpoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSpoken.isEmpty else { return "" }

        let subjectHint: String
        switch project?.studySubject {
        case .history:
            subjectHint = "请严格对照 313 历史学考研标准采分点，逐项指出：① 我已答中的得分点；② 遗漏的核心史实/背景/影响；③ 时间、人物、制度名词的纠偏；④ 一段可直接背诵的考场高分表述。"
        case .politics:
            subjectHint = "请对照考研政治大纲与分析题采分点，逐项指出：① 命中的原理/关键词；② 遗漏的表述要点；③ 易混概念纠偏；④ 标准答题句式。"
        case .english:
            subjectHint = "请先核对我的口述释义/翻译/背诵是否准确，再指出漏掉的熟词僻义、固定搭配或语法细节。"
        case nil:
            subjectHint = "这是我的口述背诵回答，请按采分点批改：① 答对的要点；② 遗漏的关键内容；③ 需要纠正的表述；④ 精炼标准答案。"
        }

        return """
        【口述抽背作答】
        \(cleanSpoken)

        \(subjectHint)
        """
    }
}
