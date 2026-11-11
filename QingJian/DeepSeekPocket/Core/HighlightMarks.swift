import Foundation

/// Bold text in an answer is drawn as a highlighter mark, but only the first
/// few in each answer; later bold stays plain bold, so a long answer never
/// turns into a page of yellow.
enum HighlightMarks {
    static let perAnswer = 2

    /// Bold ranges in reading order. Neighbouring bold runs (bold split by
    /// italics or a link) are merged, so one phrase is always one mark.
    static func boldRanges(in text: AttributedString) -> [Range<AttributedString.Index>] {
        var ranges: [Range<AttributedString.Index>] = []
        for run in text.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            if let last = ranges.last, last.upperBound == run.range.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<run.range.upperBound
            } else {
                ranges.append(run.range)
            }
        }
        return ranges
    }

    /// A cheap count of closed `**…**` pairs, used to share the per-answer
    /// budget between paragraphs without re-parsing every paragraph on each
    /// streamed token. An unclosed pair is not counted. (`__` is left out:
    /// it shows up in code names like `__init__` far more than as bold.)
    static func estimatedBoldCount(_ markdown: String) -> Int {
        (markdown.components(separatedBy: "**").count - 1) / 2
    }

    /// How many marks each paragraph may draw, in order, within one answer.
    static func budgets(forBoldCounts counts: [Int], limit: Int = perAnswer) -> [Int] {
        var left = max(0, limit)
        return counts.map { count in
            let used = min(max(0, count), left)
            left -= used
            return used
        }
    }
}
