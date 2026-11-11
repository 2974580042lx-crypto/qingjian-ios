import Foundation

/// Buffer a sentence before display so a claim split across SSE chunks cannot
/// briefly appear as a completed weekly report. A trusted project-scoped tool
/// receipt enables report claims until another learning write invalidates it.
struct StudyOutputGuard {
    private var pending = ""
    private var reportConfirmed = false
    mutating func observeTool(name: String, result: String, projectID: UUID) {
        if name == "study_weekly_report" {
            let receipt = try? StudyCoding.decode(StudyWeeklyResult.self, from: Data(result.utf8))
            reportConfirmed = receipt?.confirmsCurrentReport == true && receipt?.report?.projectID == projectID
        } else if StudyTools.names.contains(name) && !["study_list_memory", "study_read_material", "study_word_units", "study_word_state", "study_find_word", "study_reading_catalog", "study_reading_state", "study_topic_state", "study_list_practice", "study_history_search", "study_history_read"].contains(name) {
            reportConfirmed = false
        }
    }
    mutating func consume(_ text: String, finish: Bool = false) -> String {
        pending += text
        var output = ""
        while let end = pending.firstIndex(where: { "。！？.!?".contains($0) }) {
            let after = pending.index(after: end)
            output += Self.checked(String(pending[..<after]), reportConfirmed: reportConfirmed)
            pending = String(pending[after...])
        }
        if finish || pending.count > 16_000 {
            output += Self.checked(pending, reportConfirmed: reportConfirmed); pending = ""
        }
        return output
    }
    static func checked(_ sentence: String, reportConfirmed: Bool = false) -> String {
        if reportConfirmed { return sentence }
        // Keep valid teaching content in neighbouring clauses. A rejected claim
        // does not erase the whole sentence or an explanation quoted as an example.
        var output = "", clause = ""
        for character in sentence {
            if "，,；;。！？.!?".contains(character) {
                output += checkedClause(clause, sentence: sentence, isQuestion: character == "？" || character == "?") + String(character)
                clause = ""
            } else { clause.append(character) }
        }
        return output + checkedClause(clause, sentence: sentence)
    }
    private static func checkedClause(_ clause: String, sentence: String, isQuestion: Bool = false) -> String {
        if isQuestion { return clause }
        let plain = clause.replacingOccurrences(of: #"[\s*_`]+"#, with: "", options: .regularExpression)
        if plain.range(of: #"^(?:原文|译文|例句|示例|翻译)[：:]|^(?:报社|编辑|作者|文中的人|他们|她|他)(?:已经|已|刚刚|刚才)"#, options: .regularExpression) != nil { return clause }
        if plain.range(of: #"^(?:如果|假如|假设|若|等到|当|要是|将)|(?:我会|会把|会将|会在|会为|会帮|会写|会生成|会更新|将会|将要|我将|准备|打算|计划|可以|才能|是否|是不是|能否)[^。！？]{0,35}(?:周报|本周总结)|(?:周报|本周总结)[^。！？]{0,15}(?:能否|是否|是不是)"#, options: .regularExpression) != nil { return clause }
        let quoted = plain.contains("“") || plain.contains("「") || plain.contains("\"") || plain.contains("'") || plain.contains("‘")
        if quoted && sentence.range(of: #"例如|比如|示例|原话|引用|原文|译文|例句|翻译|这句话|这句|这种说法|这个表述|避免|不准确|不应|不能|不要|说[：:“「\"]"#, options: .regularExpression) != nil { return clause }
        let patterns = [
            #"(?:已经|已|成功|刚刚|刚才)[^。！？.!?]{0,40}(?:记入|写入|加入|记到|放进|放入|更新|生成|完成)[^。！？.!?]{0,16}(?:周报|本周总结)"#,
            #"(?:周报|本周总结)[^。！？.!?]{0,12}(?:已经|已)[^。！？.!?]{0,10}(?:生成|更新|完成|写好)"#,
            #"(?:记入|写入|加入|记到|放进|放入)[^。！？.!?]{0,16}(?:周报|本周总结)(?:里|中)?(?:了|啦)"#,
            #"(?:周报|本周总结)[^。！？.!?]{0,12}(?:生成|更新|完成|写好)了"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let range = Range(match.range, in: plain) else { continue }
                let prefix = String(plain[..<range.lowerBound].suffix(20))
                if prefix.range(of: #"(?:不能|不要|不会|不应|没有|未曾|并非)(?:说|声称|表示)?[“「\"]*$"#, options: .regularExpression) != nil { continue }
                return "本轮尚未确认周报生成或更新，请以应用回执为准"
            }
        }
        return clause
    }
}
