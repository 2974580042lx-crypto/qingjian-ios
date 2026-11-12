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

extension Text {
    /// Emphasis as slightly heavier words, nothing drawn behind them: bold phrases in
    /// an answer are set semibold in the text colour.
    init(markdown value: AttributedString, emphasisWeight weight: Font.Weight) {
        let ranges = HighlightMarks.boldRanges(in: value)
        guard !ranges.isEmpty else { self.init(value); return }
        var result = Text(verbatim: "")
        var cursor = value.startIndex
        for range in ranges {
            if cursor < range.lowerBound {
                result = Text("\(result)\(Text(AttributedString(value[cursor..<range.lowerBound])))")
            }
            var phrase = AttributedString(value[range])
            phrase.inlinePresentationIntent?.remove(.stronglyEmphasized)
            result = Text("\(result)\(Text(phrase).fontWeight(weight))")
            cursor = range.upperBound
        }
        if cursor < value.endIndex {
            result = Text("\(result)\(Text(AttributedString(value[cursor..<value.endIndex])))")
        }
        self = result
    }
}
