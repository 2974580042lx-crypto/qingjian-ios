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
    /// flanking rules reject (or cross-pair) when `**` sits between full-width punctuation (`。，、“”‘’（）《》【】；：？！`) and CJK characters.
    static func parseInline(_ text: String) -> AttributedString {
        guard text.contains("**"), !text.contains("\u{E000}"), !text.contains("\u{E001}") else {
            return (try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(text)
        }
        let prepared = markPairedBoldDelimiters(in: text)
        let attributed = (try? AttributedString(
            markdown: prepared,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(prepared)
        return applyMarkedBold(in: attributed)
    }

    /// Replaces paired `**...**` (excluding `***` and backtick code spans) with `\u{E000}...\u{E001}`
    /// in reading order before CommonMark runs, preventing CommonMark from rejecting or cross-pairing CJK bold spans.
    private static func markPairedBoldDelimiters(in text: String) -> String {
        let chars = Array(text)
        var result = ""
        result.reserveCapacity(text.count)
        var i = 0
        var inCode = false
        var pendingOpenIndex: String.Index?

        while i < chars.count {
            let ch = chars[i]
            if ch == "`" {
                inCode.toggle()
                result.append(ch)
                i += 1
                continue
            }
            if ch.isNewline {
                if let openIdx = pendingOpenIndex {
                    result.replaceSubrange(openIdx...openIdx, with: "**")
                    pendingOpenIndex = nil
                }
                result.append(ch)
                i += 1
                continue
            }
            if !inCode,
               i + 1 < chars.count,
               chars[i] == "*",
               chars[i + 1] == "*",
               (i == 0 || chars[i - 1] != "*"),
               (i + 2 >= chars.count || chars[i + 2] != "*") {
                if pendingOpenIndex == nil {
                    if i + 2 < chars.count, !chars[i + 2].isWhitespace {
                        pendingOpenIndex = result.endIndex
                        result.append("\u{E000}")
                        i += 2
                        continue
                    }
                } else if let openIdx = pendingOpenIndex {
                    let prevIsSpace = i > 0 && chars[i - 1].isWhitespace
                    let nonEmptyInner = result.index(after: openIdx) < result.endIndex
                    if !prevIsSpace && nonEmptyInner {
                        result.append("\u{E001}")
                        pendingOpenIndex = nil
                        i += 2
                        continue
                    }
                }
            }
            result.append(ch)
            i += 1
        }
        if let openIdx = pendingOpenIndex {
            result.replaceSubrange(openIdx...openIdx, with: "**")
        }
        return result
    }

    private static func applyMarkedBold(in attributed: AttributedString) -> AttributedString {
        var copy = attributed
        var safety = 0
        while safety < 128, let pair = findNextSentinelPair(in: copy) {
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

    private static func findNextSentinelPair(
        in attributed: AttributedString
    ) -> (open: Range<AttributedString.Index>, close: Range<AttributedString.Index>)? {
        let chars = attributed.characters
        var i = chars.startIndex
        var openRange: Range<AttributedString.Index>?
        while i < chars.endIndex {
            let next = chars.index(after: i)
            if chars[i] == "\u{E000}" {
                openRange = i..<next
            } else if chars[i] == "\u{E001}", let open = openRange, i >= open.upperBound {
                return (open: open, close: i..<next)
            }
            i = next
        }
        return nil
    }
}
