import SwiftUI

/// Tags the part of a Text that gets a highlighter mark.
struct MarkerMark: TextAttribute {}

/// Draws a half-height highlighter stroke under marked text: it covers the
/// lower part of the characters, the way a real marker is dragged along a
/// line, instead of boxing the whole line height. `progress` sweeps the stroke
/// in from the left (0 = not drawn, 1 = full length).
struct MarkerRenderer: TextRenderer {
    var color: Color
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        if progress > 0 {
            // Strokes first, then all glyphs, so a stroke's small overhang
            // never covers the character just before or after it.
            for line in layout {
                for run in line where run[MarkerMark.self] != nil {
                    let bounds = run.typographicBounds.rect
                    let height = bounds.height * 0.42
                    let stroke = CGRect(x: bounds.minX - 1.5,
                                        y: bounds.maxY - bounds.height * 0.08 - height,
                                        width: (bounds.width + 3) * min(1, progress),
                                        height: height)
                    context.fill(Path(roundedRect: stroke, cornerRadius: min(4, height / 2), style: .continuous),
                                 with: .color(color))
                }
            }
        }
        for line in layout { context.draw(line) }
    }
}

extension Text {
    /// Builds a Text from parsed Markdown, marking the first `marks` bold
    /// phrases for `MarkerRenderer`. Later bold phrases stay plain bold.
    init(markdown value: AttributedString, marks: Int) {
        let ranges = HighlightMarks.boldRanges(in: value)
        guard marks > 0, !ranges.isEmpty else { self.init(value); return }
        var result = Text(verbatim: "")
        var cursor = value.startIndex
        for (index, range) in ranges.enumerated() {
            if cursor < range.lowerBound {
                result = Text("\(result)\(Text(AttributedString(value[cursor..<range.lowerBound])))")
            }
            let phrase = Text(AttributedString(value[range]))
            result = index < marks ? Text("\(result)\(phrase.customAttribute(MarkerMark()))") : Text("\(result)\(phrase)")
            cursor = range.upperBound
        }
        if cursor < value.endIndex {
            result = Text("\(result)\(Text(AttributedString(value[cursor..<value.endIndex])))")
        }
        self = result
    }
}

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
