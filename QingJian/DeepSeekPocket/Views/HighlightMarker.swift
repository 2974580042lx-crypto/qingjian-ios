import SwiftUI

extension Text {
    /// The Swiss look's emphasis: bold phrases in the accent colour, nothing
    /// drawn behind them, and no limit on how many.
    init(markdown value: AttributedString, emphasis color: Color) {
        let ranges = HighlightMarks.boldRanges(in: value)
        guard !ranges.isEmpty else { self.init(value); return }
        var result = Text(verbatim: "")
        var cursor = value.startIndex
        for range in ranges {
            if cursor < range.lowerBound {
                result = Text("\(result)\(Text(AttributedString(value[cursor..<range.lowerBound])))")
            }
            let phrase = Text(AttributedString(value[range])).foregroundStyle(color)
            result = Text("\(result)\(phrase)")
            cursor = range.upperBound
        }
        if cursor < value.endIndex {
            result = Text("\(result)\(Text(AttributedString(value[cursor..<value.endIndex])))")
        }
        self = result
    }
}

extension AttributedString {
    /// Applies Claude Code style warm terracotta (`Ink.seal`) styling to inline `code` and **bold** spans.
    func applyingTerracottaCodeAndEmphasis() -> AttributedString {
        var copy = self
        for run in copy.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                copy[run.range].foregroundColor = Ink.seal
                copy[run.range].backgroundColor = Ink.seal.opacity(0.12)
            }
        }
        return copy
    }
}

extension Text {
    /// Claude Code / CC style emphasis: inline `code/words` get a soft terracotta pill, and **bold** key phrases glow in warm terracotta (`Ink.seal`).
    init(markdown value: AttributedString, emphasisWeight weight: Font.Weight) {
        let styled = value.applyingTerracottaCodeAndEmphasis()
        let ranges = HighlightMarks.boldRanges(in: styled)
        guard !ranges.isEmpty else { self.init(styled); return }
        var result = Text(verbatim: "")
        var cursor = styled.startIndex
        for range in ranges {
            if cursor < range.lowerBound {
                result = Text("\(result)\(Text(AttributedString(styled[cursor..<range.lowerBound])))")
            }
            var phrase = AttributedString(styled[range])
            phrase.inlinePresentationIntent?.remove(.stronglyEmphasized)
            result = Text("\(result)\(Text(phrase).fontWeight(weight).foregroundStyle(Ink.seal))")
            cursor = range.upperBound
        }
        if cursor < styled.endIndex {
            result = Text("\(result)\(Text(AttributedString(styled[cursor..<styled.endIndex])))")
        }
        self = result
    }
}
