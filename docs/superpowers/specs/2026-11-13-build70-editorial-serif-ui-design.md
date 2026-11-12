# Sermo 1.37.0 (Build 70) — 1:1 Claude Desktop Editorial Serif UI Design

## Goal
Replicate Claude Desktop and Antigravity's editorial reading typography, color hierarchy, and minimalist thinking row 1:1 on iOS without sacrificing `NavigationUITests` compatibility, streaming smoothness, or live appearance redraws.

## Key Design Decisions

1. **Editorial Serif Cascade (`Georgia` + `NotoSerifSC`)**
   - `FontChoice.builtIn` (`"内置宋体"`) now resolves prose and display headings via `FontLibrary.editorialUIFont(size:bold:italic:)`, which builds a `UIFontDescriptor` with `Georgia` / `Georgia-Bold` / `Georgia-Italic` / `Georgia-BoldItalic` as the primary face and `[NotoSerifSC-Regular / NotoSerifSC-Bold]` in `.cascadeList`.
   - Every ASCII letter, italic phrase, and number (`123`, `1158`, `4200`) renders in authentic `Georgia` with old-style editorial proportions, while Chinese characters and full-width punctuation fall back seamlessly to `NotoSerifSC`.
   - `applyReadingDefaultsOnce()` runs a one-time `sermo.typography.defaults.v137.editorial` migration upgrading `.system` / unset defaults to `.builtIn` (`18pt`) while respecting `.custom` user fonts.

2. **Safe Per-Run Styling Without Stripping `.cascadeList`**
   - Calling SwiftUI `.bold()`, `.italic()`, or `.fontWeight(...)` on a cascaded `Font(uiFont)` causes CoreText/UIKit to re-query `"Georgia"` by symbolic traits and drop `.cascadeList`.
   - `AttributedString.applyingEditorialStyle(baseSize:boldColor:forceBold:)` resolves exact `UIFont` variants per run and removes `.stronglyEmphasized` / `.emphasized` from `inlinePresentationIntent` after applying the resolved font.

3. **Color Hierarchy (`**Bold**` vs `` `Inline Code` ``)**
   - Headings, list markers (`•`, `1.`, `2.`), and `**bold**` (`stronglyEmphasized`) render in deep ink black (`Ink.ink`) by default, with an opt-in `"加粗使用强调色"` toggle in `设置 → 个性化` (`Personal.boldUsesAccent`).
   - Only backtick `` `inline code` `` spans render as warm terracotta brick ink (`#B84A27` light / `#E28262` dark) inside a warm oatmeal stone chip (`#ECE8DE` light / `#2D2B27` dark).

4. **AI Prose vs. User Input & UI Chrome**
   - AI answers use `18pt` `Georgia + NotoSerifSC` (`MarkdownParagraph`, `EditorialHeadingRow`, `EditorialListMarker`, `TableCell`).
   - User chat bubbles, composer input, model pill, and small labels (`size < 17`) remain in crisp Apple sans-serif (`UserMessageStyle` / `.system`).

5. **Bubble-Free `ThinkingRow`**
   - Removes capsule fill/border/horizontal padding and finished orange flower; shows flush-left muted grey `已思考 X 秒 ›` (`Ink.ink3`) while keeping the animated flower for live `思考中 · X 秒 ›` and preserving `"thinking-row"` accessibility identifiers.
