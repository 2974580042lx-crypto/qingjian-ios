import SwiftUI

extension Text {
    /// The Swiss look's emphasis: bold phrases in the accent colour, nothing
    /// drawn behind them, and no limit on how many.
    init(markdown value: AttributedString, emphasis color: Color) {
        self.init(value.applyingEditorialStyle(baseSize: 16, boldColor: color))
    }
}

extension AttributedString {
    /// Applies Claude Desktop / Antigravity editorial typography per run:
    /// - Resolves `Georgia` + `NotoSerifSC` cascaded fonts directly onto runs (removing `.stronglyEmphasized`
    ///   / `.emphasized` intents afterwards so SwiftUI never strips `.cascadeList`).
    /// - Draws `**bold**` in deep ink (`Ink.ink`) by default (or `Ink.seal` when `Personal.boldUsesAccent` is on).
    /// - Draws `` `inline code` `` in warm terracotta brick (`#B84A27` / `#E28262`) over an oatmeal chip (`#ECE8DE` / `#2D2B27`).
    func applyingEditorialStyle(baseSize: CGFloat = 18, boldColor: Color? = nil, forceBold: Bool = false) -> AttributedString {
        var copy = self
        let usesDefaultClay = Personal.value(Personal.accentKey).isEmpty || Personal.value(Personal.accentKey) == "clay"
        let codeInk: Color = InterfaceStyle.isSwiss || InterfaceStyle.isNight || !usesDefaultClay
            ? Ink.seal
            : Color.adaptive(light: 0xB84A27, dark: 0xE28262)
        let codeFill: Color = InterfaceStyle.isSwiss || InterfaceStyle.isNight
            ? Ink.raised
            : Color.adaptive(light: 0xECE8DE, dark: 0x2D2B27)
        let monoSize = max(13.5, TypeScale.scaled(baseSize - 2, .body))
        let resolvedBoldColor = boldColor ?? (Personal.boldUsesAccent ? Ink.seal : Ink.ink)

        let runsSnapshot: [(range: Range<AttributedString.Index>, intents: InlinePresentationIntent, hasLink: Bool)] =
            copy.runs.map { ($0.range, $0.inlinePresentationIntent ?? [], $0.link != nil) }

        for entry in runsSnapshot {
            let range = entry.range
            if entry.intents.contains(.code) {
                copy[range].foregroundColor = codeInk
                copy[range].backgroundColor = codeFill
                copy[range].font = .system(size: monoSize, weight: .medium, design: .monospaced)
            } else {
                let isBold = forceBold || entry.intents.contains(.stronglyEmphasized)
                let isItalic = entry.intents.contains(.emphasized)
                copy[range].font = ReadingFont.resolve(baseSize: baseSize, bold: isBold, italic: isItalic)
                var cleaned = entry.intents
                cleaned.remove(.stronglyEmphasized)
                cleaned.remove(.emphasized)
                copy[range].inlinePresentationIntent = cleaned.isEmpty ? nil : cleaned
                if entry.hasLink {
                    copy[range].foregroundColor = Ink.seal
                } else if isBold && !forceBold {
                    copy[range].foregroundColor = resolvedBoldColor
                } else if forceBold {
                    copy[range].foregroundColor = boldColor ?? Ink.ink
                }
            }
        }
        return copy
    }

    /// Backwards-compatible wrapper delegating to `applyingEditorialStyle`.
    func applyingTerracottaCodeAndEmphasis(baseSize: CGFloat = 18, boldColor: Color = Ink.seal) -> AttributedString {
        applyingEditorialStyle(baseSize: baseSize, boldColor: boldColor)
    }
}

extension Text {
    /// Editorial Markdown rendering: deep-ink bold (or accent colour if toggled), Georgia+NotoSerifSC prose,
    /// and warm oatmeal-terracotta inline code chips.
    init(markdown value: AttributedString, emphasisWeight _: Font.Weight, baseSize: CGFloat = 18) {
        self.init(value.applyingEditorialStyle(baseSize: baseSize))
    }
}
