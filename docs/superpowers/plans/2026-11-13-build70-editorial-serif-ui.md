# Implementation Plan: Sermo 1.37.0 (Build 70) Editorial Serif UI

1. **Docs**: Save spec (`2026-11-13-build70-editorial-serif-ui-design.md`) and plan (`2026-11-13-build70-editorial-serif-ui.md`).
2. **`FontLibrary.swift`**:
   - Default `choice` fallback to `.builtIn`; keep `FontChoice` titles intact (`"内置宋体"`, `"系统字体"`, `"自定义字体"`).
   - Add one-time `sermo.typography.defaults.v137.editorial` migration (`builtIn`, `18.0` pt) preserving `.custom` fonts.
   - Add `usesEditorialSerif` and `NSLock`-guarded cached `editorialUIFont(size:bold:italic:)` cascading `Georgia*` -> `NotoSerifSC*`.
3. **`AppTheme.swift`**:
   - Update `TypeScale.serif` (`size >= 17` uses editorial cascade, `size < 17` stays sans-serif), `TypeScale.heavy`, and `InkAppearance.apply()`.
   - Add `ReadingFont.resolve(baseSize:bold:italic:)`.
   - Update `ReadingStyle` (`size = 18.0`, only apply `.fontWeight(.medium)` for `.custom`).
   - Add `UserMessageStyle` / `.userMessageStyle()`.
   - Add `Personal.boldAccentKey` / `boldUsesAccent` (default `false`) and tune `Personal.lineSpacing` (`7.5` default).
4. **`HighlightMarker.swift`**:
   - Implement `applyingEditorialStyle(baseSize:boldColor:forceBold:)` with oatmeal-terracotta inline code chips, deep-ink bold (or accent via toggle), and `.stronglyEmphasized`/`.emphasized` intent stripping after font assignment.
   - Keep `applyingTerracottaCodeAndEmphasis` wrapper and simplify `Text.init(markdown:...)`.
5. **Views (`ContentView.swift`, `ReasoningView.swift`, `InterfaceStyle.swift`, `ToolSettingsSections.swift`)**:
   - Update composer, user bubble, model pill, usage label, `EditorialHeadingRow`, `EditorialListMarker`, `TableCell`, and `MarkdownParagraph` + `EditorialParagraphBody`.
   - Make `ThinkingRow` bubble-free and flush-left.
   - Update `PersonalizationView` (`18pt` default, `"加粗使用强调色"` toggle), `PersonalPreview`, and `FontSettingsRows` caption.
6. **Tests & Versioning**:
   - Add mixed Markdown test in `HighlightMarksTests.swift`.
   - Bump `CURRENT_PROJECT_VERSION` to `70` in `project.pbxproj`, `generate-project.py`, and `apply-source-overlay.py`.
   - Run `check-project.py`, `rebuild-source-overlay.py`, and `apply-source-overlay.py`.
7. **CI & Delivery**:
   - Commit on `cleanup-1.37`, push, run `study-step7.yml`, download artifact, deliver `G:\我的云端硬盘\Sermo-1.37.0-build70-unsigned.ipa`, and verify `Info.plist` + bundled fonts.
