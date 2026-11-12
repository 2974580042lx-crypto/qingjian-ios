import SwiftUI

extension Text {
    /// The Swiss look's emphasis: bold phrases in the accent colour, nothing
    /// drawn behind them, and no limit on how many.
    init(markdown value: AttributedString, emphasis color: Color) {
        let styled = value.applyingTerracottaCodeAndEmphasis(baseSize: 16, boldColor: color)
        let ranges = HighlightMarks.boldRanges(in: styled)
        guard !ranges.isEmpty else { self.init(styled); return }
        var result = Text(verbatim: "")
        var cursor = styled.startIndex
        for range in ranges {
            if cursor < range.lowerBound {
                result = Text("\(result)\(Text(AttributedString(styled[cursor..<range.lowerBound])))")
            }
            var phrase = AttributedString(styled[range])
            phrase.foregroundColor = color
            result = Text("\(result)\(Text(phrase).foregroundColor(color))")
            cursor = range.upperBound
        }
        if cursor < styled.endIndex {
            result = Text("\(result)\(Text(AttributedString(styled[cursor..<styled.endIndex])))")
        }
        self = result
    }
}

extension AttributedString {
    /// Applies Claude Code (CC) warm terracotta (`Ink.seal`) styling directly inside `AttributedString` runs
    /// so outer `.foregroundStyle(Ink.ink)` modifiers never erase emphasis or inline code pill colors.
    func applyingTerracottaCodeAndEmphasis(baseSize: CGFloat = 17, boldColor: Color = Ink.seal) -> AttributedString {
        var copy = self
        let monoSize = max(13, baseSize - 1.5)
        for run in copy.runs {
            let isCode = run.inlinePresentationIntent?.contains(.code) == true
            let isBold = run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            if isCode {
                copy[run.range].foregroundColor = boldColor
                copy[run.range].backgroundColor = boldColor.opacity(0.14)
                copy[run.range].font = .system(size: monoSize, weight: .medium, design: .monospaced)
            } else if isBold {
                copy[run.range].foregroundColor = boldColor
            }
        }
        return copy
    }
}

extension Text {
    /// Claude Code / CC style emphasis: inline `code/words` get a crisp SF Mono terracotta sugar-pill,
    /// and **bold** key phrases glow in rich warm terracotta (`Ink.seal`) with semibold weight.
    init(markdown value: AttributedString, emphasisWeight weight: Font.Weight, baseSize: CGFloat = 17) {
        let styled = value.applyingTerracottaCodeAndEmphasis(baseSize: baseSize, boldColor: Ink.seal)
        let ranges = HighlightMarks.boldRanges(in: styled)
        guard !ranges.isEmpty else { self.init(styled); return }
        var result = Text(verbatim: "")
        var cursor = styled.startIndex
        for range in ranges {
            if cursor < range.lowerBound {
                result = Text("\(result)\(Text(AttributedString(styled[cursor..<range.lowerBound])))")
            }
            var phrase = AttributedString(styled[range])
            let hasCode = phrase.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true }
            if !hasCode {
                phrase.inlinePresentationIntent?.remove(.stronglyEmphasized)
            }
            phrase.foregroundColor = Ink.seal
            result = Text("\(result)\(Text(phrase).fontWeight(weight).foregroundColor(Ink.seal))")
            cursor = range.upperBound
        }
        if cursor < styled.endIndex {
            result = Text("\(result)\(Text(AttributedString(styled[cursor..<styled.endIndex])))")
        }
        self = result
    }
}
