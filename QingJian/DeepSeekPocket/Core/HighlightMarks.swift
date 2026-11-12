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

    /// Parses inline Markdown and rescues CJK `**...**` strong emphasis spans that CommonMark's
    /// flanking rules reject when `**` sits between full-width punctuation (`。，、“”‘’（）《》【】；：？！`) and CJK characters.
    static func parseInline(_ text: String) -> AttributedString {
        let attributed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        guard text.contains("**") else { return attributed }
        return rescueCJKBold(in: attributed)
    }

    private static func rescueCJKBold(in attributed: AttributedString) -> AttributedString {
        var copy = attributed
        var safety = 0
        while safety < 64, let pair = findNextBoldPair(in: copy) {
            safety += 1
            let innerRange = pair.open.upperBound ..< pair.close.lowerBound
            var subRanges: [(Range<AttributedString.Index>, InlinePresentationIntent)] = []
            for run in copy.runs {
                let lower = max(run.range.lowerBound, innerRange.lowerBound)
                let upper = min(run.range.upperBound, innerRange.upperBound)
                guard lower < upper, run.inlinePresentationIntent?.contains(.code) != true else { continue }
                var intent = run.inlinePresentationIntent ?? []
                intent.insert(.stronglyEmphasized)
                subRanges.append((lower..<upper, intent))
            }
            for (range, intent) in subRanges {
                copy[range].inlinePresentationIntent = intent
            }
            copy.removeSubrange(pair.close)
            copy.removeSubrange(pair.open)
        }
        return copy
    }

    private static func findNextBoldPair(
        in attributed: AttributedString
    ) -> (open: Range<AttributedString.Index>, close: Range<AttributedString.Index>)? {
        let chars = attributed.characters
        var codeRanges: [Range<AttributedString.Index>] = []
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            codeRanges.append(run.range)
        }
        func isCode(_ idx: AttributedString.Index) -> Bool {
            codeRanges.contains { $0.contains(idx) }
        }

        var i = chars.startIndex
        var openRange: Range<AttributedString.Index>?

        while i < chars.endIndex {
            if chars[i].isNewline {
                openRange = nil
                i = chars.index(after: i)
                continue
            }
            let next = chars.index(after: i)
            if next < chars.endIndex,
               chars[i] == "*", chars[next] == "*",
               !isCode(i), !isCode(next) {
                let afterPair = chars.index(after: next)
                if openRange == nil {
                    if afterPair < chars.endIndex, !chars[afterPair].isWhitespace, chars[afterPair] != "*" {
                        openRange = i..<afterPair
                        i = afterPair
                        continue
                    }
                } else if let open = openRange {
                    let beforeClose = chars.index(before: i)
                    if i > open.upperBound, !chars[beforeClose].isWhitespace {
                        return (open: open, close: i..<afterPair)
                    }
                }
            }
            i = next
        }
        return nil
    }
}
