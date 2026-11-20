import Foundation

/// Bold text in an answer is drawn as a highlighter mark, but only the first
/// few in each answer; later bold stays plain bold, so a long answer never
/// turns into a page of yellow.
enum HighlightMarks {
    static let perAnswer = 2

    nonisolated(unsafe) private static var inlineCache: [String: AttributedString] = [:]
    private static let inlineCacheLock = NSLock()

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

    /// Parses inline Markdown with a bounded cache and rescues CJK `**...**` strong emphasis spans
    /// while respecting both single-backtick and multi-backtick inline code spans.
    static func parseInline(_ text: String) -> AttributedString {
        let cacheable = text.utf8.count <= 16_384
        if cacheable {
            inlineCacheLock.lock()
            if let hit = inlineCache[text] {
                inlineCacheLock.unlock()
                return hit
            }
            inlineCacheLock.unlock()
        }

        let resolved: AttributedString
        if !text.contains("**") || text.contains("\u{E000}") || text.contains("\u{E001}") {
            resolved = (try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(text)
        } else {
            let prepared = markPairedBoldDelimiters(in: text)
            let attributed = (try? AttributedString(
                markdown: prepared,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(prepared)
            resolved = applyMarkedBold(in: attributed)
        }

        if cacheable {
            inlineCacheLock.lock()
            if inlineCache.count >= 512 {
                inlineCache.removeAll(keepingCapacity: true)
            }
            inlineCache[text] = resolved
            inlineCacheLock.unlock()
        }
        return resolved
    }

    /// Replaces paired `**...**` (excluding `***` and single/multi-backtick code spans) with `\u{E000}...\u{E001}`
    /// in reading order before CommonMark runs, preventing CommonMark from rejecting or cross-pairing CJK bold spans.
    private static func markPairedBoldDelimiters(in text: String) -> String {
        let chars = Array(text)
        var result = ""
        result.reserveCapacity(text.count)
        var i = 0
        var activeCodeFenceTicks: Int?
        var pendingOpenIndex: String.Index?

        while i < chars.count {
            let ch = chars[i]
            if ch == "`" {
                var ticks = 0
                while i + ticks < chars.count && chars[i + ticks] == "`" {
                    ticks += 1
                }
                for _ in 0..<ticks { result.append("`") }
                if let active = activeCodeFenceTicks {
                    if ticks == active {
                        activeCodeFenceTicks = nil
                    }
                } else {
                    // Only enter code mode if a matching run of `ticks` backticks exists later on the same line/paragraph.
                    if hasMatchingBacktickRun(chars, from: i + ticks, length: ticks) {
                        activeCodeFenceTicks = ticks
                    }
                }
                i += ticks
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
            if activeCodeFenceTicks == nil,
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

    private static func hasMatchingBacktickRun(_ chars: [Character], from start: Int, length: Int) -> Bool {
        var j = start
        while j < chars.count {
            if chars[j] == "`" {
                var run = 0
                while j + run < chars.count && chars[j + run] == "`" {
                    run += 1
                }
                if run == length { return true }
                j += run
                continue
            }
            j += 1
        }
        return false
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
