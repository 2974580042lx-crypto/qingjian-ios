# Sermo (QingJian iOS) Full-App Frontend 1:1 Claude iOS Visual Overhaul Design

Date: 2026-11-21
Branch / Baseline: `main` (`1.38.0` / build 79, commit `63601d5`)
Target Scope: Full frontend UI/UX design system unification across all ~25 SwiftUI/UIKit views in `QingJian/DeepSeekPocket/Views/` (Paper / default look aligned 1:1 with Claude iOS on iOS 26 Liquid Glass; Swiss and Night-River themes preserved intact).

---

## 1. Intent & Why

Xiaolong compared Sermo side-by-side against the latest Claude iOS app (sidebar, settings, and chat screens) and also noticed a deeper structural problem across the whole app: **entering different areas of Sermo (Settings sub-pages, Projects, Study Memory, All Chats, Bookshelf, Compatible Endpoints) feels like switching between several unrelated apps.**

A full audit of all 25+ views in `QingJian/DeepSeekPocket/Views/` revealed the exact root causes:
1. **Global Serif Leakage**: `TypeScale.serif(size)` routes any `size >= 17` to `Georgia + NotoSerifSC` whenever the default `.builtIn` font is active. Because nearly every view calls `TypeScale.body` (18pt), `TypeScale.serif(17)`, or `InkAppearance` (32pt serif nav bar), **all menus, sidebars, settings rows, footers, project lists, and modals turned into oversized Songti serif**.
2. **Yellowed Neutrals & Missing Surface Hierarchy**: `Personal.paper` (`#FAF9F5`), `sheetFor["ivory"]` (`#F3F0E8`), `Ink.raised` (`#F2EFE6`), and `Personal.bubble` (`#EFECE4`) are noticeably yellow compared to Claude iOS's measured neutral chalk/stone palette (`#F8F8F6` chat canvas, `#F3F3F1` sidebar, `#F6F6F4` settings canvas, `#FFFFFF` grouped cards, `#EFEEEA` bubbles/pills). Meanwhile, many lists/forms clear row backgrounds (`.listRowBackground(Color.clear)`), leaving text pasted flat on the canvas instead of floating in crisp white rounded cards.
3. **Fractured Sub-page Chrome**: Sub-pages accumulated different styles over 15+ releases — `CompatibleEndpointSettingsView` and `StudyReviewView` fell back to stock iOS blue/grey; `SettingsView`, `ColabSettingsView`, `StudyMemoryView`, and `StoryPlayViews` forced `.font(TypeScale.body)` on entire `Form` containers (inflating section headers and footers to 18pt); modal close controls mix `"取消"`, `"完成"`, `"保存"`, and `"×"`; icons mix heavy filled symbols with thin outlines; and `defaultProvider` even lacks an icon.
4. **Chat & Sidebar Polish Gaps**:
   - Sidebar: `"查看全部 >"` collides with the bottom-left avatar/balance strip; price-band text truncates (`空闲时段·半...`); `"+ 新建会话"` is a heavy solid black pill; `SidebarPan` adds an extra `44pt` corner radius and `0.5pt` border to the back drawer itself.
   - Chat: `KeyboardChatLayout` hides iOS 26's native `topEdgeEffect` (`isHidden = true`), replacing Claude's soft glass top blur with a flat solid fade; top menu uses two uneven bars instead of Claude's three balanced thin lines; code/math blocks and blockquotes overuse bright terracotta borders/labels; `ThinkingRow` already extracts live `snippet` text but never displays it (showing spinning petals + timer instead of Claude's two tiny pulsing terracotta dots + live status snippet); action bar icons are oversized/dark and use `selection.pin.in.out` (looks like a photo crop tool); empty composer shows a faded orange send circle and a heavy globe; new conversations show a centered `"今天 HH:mm"` divider above the very first message.

---

## 2. Goals, Non-Goals & Anti-Goals

### Goals
- **One Cohesive App**: Every single screen in Sermo (Chat, Welcome, Sidebar, Settings + all 12 sub-pages, Projects + Project Detail + Designer/Files/Memory/Service, Study Memory/Review/Backup, All Chats, Conversation Versions, Profile, Bookshelf + Book Detail/Discussion/Story modals, Usage, Feature Overview, Operation Manual, HTML Preview) shares one unified Claude iOS visual system: neutral chalk palette, crisp white grouped cards, system sans-serif UI chrome, unified thin muted-grey icons, and consistent circular glass `×` modal close controls.
- **1:1 Claude iOS Visual Fidelity on Primary Surfaces**:
  - **Sidebar**: Neutral `#F3F3F1` full-bleed background (no drawer border/corner radius), refined serif `"Sermo"` wordmark (`~24pt` medium/semibold), thin circular chat bubble icons, clean sans-serif list items, soft bottom fade mask with generous scroll clearance so `"查看全部 >"` never overlaps footer, compact balance + price-band kept cleanly next to avatar without truncation, and light translucent soft-grey `"+ 新建会话"` pill.
  - **Settings & Sub-pages**: Compact inline centered `"设置"` title, circular glass `×` (top-left) and `i` (top-right, opening About Sermo), no top-level `"取消 / 保存"` (top-level toggles/pickers like Default Provider save immediately), profile row housed inside the first crisp white rounded card, uniform thin muted-grey icons on every row (including `"默认服务"`), compact grey section headers and footnote-sized footers, and **every** settings sub-page (`DeepSeek`, `Colab`, `CompatibleEndpointSettingsView`, `ChatGPT`, `Personalization`, `Chat & Prompts`, `SystemPromptLibrary`, `OperationManual`, `Connections`, `Usage & Backup`, `LocalDataStatus`, `FeatureOverview`, `ProfileEditor`) styled with the exact same shared grouped-form chrome modifier.
  - **Chat Main Screen**: Neutral `#F8F8F6` canvas, iOS 26 native soft `topEdgeEffect` restored (removing the flat opaque header mask) with 3-line balanced thin sidebar glyph and refined top-right icons, clean system sans-serif body + pure black bold by default (while preserving Personalization's font/Songti/accent-bold choices scoped strictly to reading prose), neutral `#EFEEEA` user bubble, Claude-style two tiny pulsing terracotta dots + live thinking snippet (`ThinkingRow`), restrained neutral code/math/table/blockquote styling, refined thin muted action icons (replacing the crop-like icon), slimmer light-bordered composer with refined `+`, model pill, slim muted globe beside the pill, clean neutral idle/stop button and terracotta active send button, and no redundant time divider above the very first message of a conversation in editorial/smart mode.
- **Dark Mode Consistency**: Update matching dark palette values so dark mode stays equally calm, neutral charcoal (no muddy yellow-brown tint), with crisp elevated card contrast.

### Non-Goals
- Do **not** alter `ChatMessage`, `ChatThread`, `AppSnapshot`, or any `.sermobackup` / `conversations.json` / SQLite persistence schema.
- Do **not** change networking, API protocols, tool execution, study logic, or backup logic.
- Do **not** remove or break `InterfaceStyle.swiss` ("瑞士") or `InterfaceStyle.night` ("夜江"), nor remove `ChatLayoutMode` ("书页 / 信息气泡 / 智能") or Personalization presets/color pickers.
- Do **not** rewrite the core text-canvas pagination engine of `LocalNovelReader` / `NovelReaderCanvas` (only align surrounding chrome/sheets/toolbars if touched).

### Anti-Goals (Failure Conditions Even If It Compiles)
- Leaving ANY modal or sub-page (`CompatibleEndpointSettingsView`, `StudyMemoryView`, `StudyReviewView`, `ProjectsView`, `AllChatsView`, `FeatureOverviewView`, `BookshelfView`, etc.) looking like a separate stock-iOS or legacy-Songti app.
- Blocking or breaking chat scrolling, left-swipe timestamp reveal, keyboard docking, sidebar 120Hz UIKit dragging, or breaking any `ChatMessage` decode / `preflight_sermo.py` checks.
- Making the sidebar footer overlap `"查看全部 >"` or truncate `"空闲时段"` into broken half-characters on standard 390pt iPhone widths.
- Breaking existing UI test accessibility identifiers (`history-title`, `sidebar-profile`, `sidebar-new-chat`, `sidebar-projects`, `sidebar-books`, `sidebar-all-chats`, `sidebar-pinned-project`, `settings-personalization`, `feature-overview`, `chat-composer`, `model-effort-pill`, `web-search-toggle`, `thinking-row`, `stream-activity`, and `"完成"` accessibility label where `NavigationUITests` taps it).

---

## 3. Constraints & Project Guardrails

1. **Zero Schema Changes**: `QingJian/DeepSeekPocket/Core/Models.swift` must remain untouched. No new persisted fields on `ChatMessage` or `AppSnapshot`.
2. **Never Block Active Chat Input**: Composer input stays uninterrupted by sheets/attachments/URL imports.
3. **Windows Build & Sync Gate**: Swift cannot compile locally on Windows. After all edits under `QingJian/`, must run:
   - Static syntax/brace balance check across modified `.swift` files
   - Sermo preflight + 4-step sync (`generate-project.py` → `check-project.py` → `rebuild-source-overlay.py` → `apply-source-overlay.py`, via `preflight_sermo.py --sync`)
   - Wait for user confirmation before `git push` (or push to `main` if user approves delivery), then monitor GitHub Actions macOS build via `gh run view` and verify the built `.ipa`.
4. **Migration Compatibility**: Existing installs on Xiaolong's phone have `sermo.typography.defaults.v137.editorial = true`, `qingjian.font.choice = "builtIn"`, `sermo.personal.boldAccent` unset (previously defaulted to `true`), and `sermo.personal.paper` unset (defaults to `"ivory"`).
   - Because updating `"ivory"` light/dark hex values in `Personal.paperPresets` & `sheetFor` automatically updates unset/`"ivory"` users immediately, colors migrate cleanly with zero reset of custom hexes!
   - For typography & bold accent: add a one-time `v139.claude_ui` migration in `FontLibrary.applyReadingDefaultsOnce()` (only upgrading users still on the previous v137 automatic default `.builtIn` / 18pt to `.system` / 17pt, leaving `.custom` fonts untouched), and change `Personal.boldUsesAccent` default from `true` (`!= "0"`) to `false` (`== "1"`) so bold text defaults to crisp near-black like Claude while still toggleable in Personalization.

---

## 4. Approaches Considered

| Approach | Summary | Trade-offs | Decision |
| :--- | :--- | :--- | :--- |
| **Approach 1: Full-App Design System Overhaul on Default Theme (Paper -> Claude 1:1)** | Refactor `AppTheme` / `TypeScale` / shared chrome modifiers once at the foundation, then systematically align all 5 surface groups (Theme+Chrome, Sidebar, Chat+Markdown+Composer, Settings+all 12 sub-pages, Projects+Study+AllChats+Bookshelf). | Larger diff across ~18-22 View files, requires careful static verification and preserving Swiss/Night checks; yields 100% visual cohesion across every screen and zero theme duplication. | **Selected by Xiaolong** |
| Approach 2: Add a 4th standalone theme ("清简白") | Keep legacy yellowed Songti Paper untouched and add a new 4th theme. | Duplicates light-mode maintenance, still leaves legacy default out of the box, doesn't fix fractured sub-pages. | Rejected |
| Approach 3: Patch only Sidebar + Settings | Fix only the first 4 screenshots and leave Chat/Projects/Sub-pages untouched. | Leaves glaring color/font/chrome fractures between main chat, projects, and sub-pages. | Rejected |

---

## 5. Detailed Design Specification

### 5.1 Foundation: Color Tokens, Typography Separation & Shared Chrome (`AppTheme.swift`, `FontLibrary.swift`, `InterfaceStyle.swift`)

#### A. Calibrated Neutral Palette (Measured from Xiaolong's Claude iOS Screenshots)
All values apply to Paper (default `"ivory"` / `"柔白"` preset); Swiss and Night-River stay unchanged:

| Semantic Token | Light (Paper / `ivory`) | Dark (Paper / `ivory`) | Purpose |
| :--- | :--- | :--- | :--- |
| `Ink.paper` (Chat & main canvas) | `#F8F8F6` | `#191918` | Main chat canvas, welcome page, composer backdrop |
| `Ink.sheet` (Sidebar background) | `#F3F3F1` | `#121211` | Full-bleed sidebar drawer surface |
| `Ink.groupedBg` *(new)* | `#F4F4F2` | `#141413` | Background behind grouped white cards (Settings, Projects, Sub-pages, Sheets) |
| `Ink.card` *(new)* | `#FFFFFF` | `#222220` | Grouped white rounded cards inside Forms/Lists |
| `Ink.raised` (Pills / subtle surfaces) | `#EFEEEA` | `#262624` | User bubble default, model pill, search circle, sidebar active pill, code block header/subtle chip |
| `Ink.ink` (Primary text) | `#1A1A18` | `#ECEBE7` | Primary crisp near-black text |
| `Ink.ink2` (Secondary text / thin icons) | `#4A4945` | `#C7C5BE` | Secondary labels, primary thin UI icons |
| `Ink.ink3` (Muted metadata / chevrons) | `#7A7872` | `#8E8C85` | Section headers, footers, timestamps, subtle icons |
| `Ink.line` (Hairline borders/dividers) | `#1A1A18` @ `0.09` | `#ECEBE7` @ `0.11` | Hairline separators, light composer/code card strokes |
| `Ink.seal` (Terracotta accent) | `#C96442` | `#D97757` | Restrained strictly to key actions (active send button, thinking dots, active toggles, links, study highlight badges) |

- Update `Personal.paperPresets` `"ivory"` to `light: 0xF8F8F6, dark: 0x191918` and `sheetFor["ivory"]` to `(0xF3F3F1, 0x121211)`.
- Update `Personal.bubble` default (when `"grey"` / unset) to `Color.adaptive(light: 0xEFEEEA, dark: 0x2A2A27)`.
- Update `Personal.textPresets` `"black"` to `light: 0x1A1A18, dark: 0xECEBE7`.
- For non-Paper themes:
  - `Ink.groupedBg`: Night `0x051117`, Swiss `0xF2F2EF / 0x111214`, Paper `Color.adaptive(light: 0xF4F4F2, dark: 0x141413)` (following non-ivory presets cleanly when user picks custom paper preset!).
  - `Ink.card`: Night `0x0F1D24`, Swiss `0xFFFFFF / 0x1D1E21`, Paper `Color.adaptive(light: 0xFFFFFF, dark: 0x222220)`.

#### B. Strict Typography Separation (UI Chrome vs. Reading Prose vs. Brand Display)
Eliminate global Serif leakage permanently:
1. **`TypeScale` becomes System Sans-Serif (`SF Pro` + `PingFang SC`) for ALL UI Chrome**:
   - `TypeScale.ui(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font` (dynamic-type scaled `.system(size:weight:)`).
   - Change `TypeScale.serif(_ size:relativeTo:)` so that all existing UI chrome callers across the 25 views automatically render in clean system sans-serif (`.system(size: scaled(size, style))`), **instead of** switching to `NotoSerifSC` at `size >= 17`!
   - Add an explicit **`TypeScale.editorialDisplay(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .title) -> Font`** strictly for the **two** Claude editorial serif display spots:
     1. Sidebar brand wordmark `"Sermo"` (`25pt` medium-semibold `Georgia` / `NotoSerifSC-Bold` in Paper/Night; `PingFangSC-Semibold` in Swiss).
     2. Welcome screen greeting (`WelcomeView`, `28pt` `Georgia + NotoSerifSC-Regular` in Paper/Night).
   - `InkAppearance.apply()`: Navigation bar inline title (`17pt` `.semibold` system font) and large title (`30pt` `.bold` system font) always use clean system sans-serif (no more 32pt Songti navigation titles).
2. **Reading Prose (`ReadingFont` / `ReadingStyle`)**:
   - Remains the ONLY place governed by Personalization's font choice (`系统字体` / `内置宋体` / `自定义字体`), reading size (`17pt` default), medium weight toggle, and line spacing.
   - One-time migration `sermo.typography.defaults.v139.claude`: if user has not imported a custom font and was auto-migrated by v137 to `.builtIn` @ `18pt`, migrate once to `.system` @ `17pt`; user can switch back to `内置宋体` anytime in `设置 → 个性化`, and doing so affects ONLY chat reading prose, never sidebars/settings/menus.
   - `Personal.mediumBody` default: keep `false` for crisp Claude iOS body legibility (`stored(mediumKey) == "1"`), or keep toggleable in Personalization — wait: let's check current Claude iOS screenshot: Chinese PingFang SC Regular at 16.5-17pt on `#F8F8F6` with `#1A1A18` ink is crisp without forcing `.medium` on every character (forcing `.medium` made regular vs bold contrast weak). So default `Personal.mediumBody` to `false` (`stored(mediumKey) == "1"`) and `Personal.boldUsesAccent` to `false` (`stored(boldAccentKey) == "1"`).

#### C. Shared Unified Chrome Components (in `AppTheme.swift`)
Create reusable building blocks so **every** sheet, settings sub-page, project page, and list across all 25 views looks 100% identical in polish:
1. **`ClaudeSheetCloseButton`**: Standard circular Liquid Glass `×` button (`xmark`, `14pt` `.medium`, `Ink.ink`, accessible as `"关闭"` or custom label like `"完成"` when UI tests expect `"完成"`). On iOS 26 inside a `ToolbarItem(placement: .topBarLeading)`, SwiftUI automatically renders an icon-only `Button` inside a native circular liquid glass pill — matching Claude's exact top-left `×` and top-right `i` buttons in Screenshot 3!
2. **`ClaudeIconBadge`**: Thin uniform leading icon helper for Settings/Menu rows (`Image(systemName:)` at `18pt`, `.light` weight, `Ink.ink2`, fixed `frame(width: 24, alignment: .center)`).
3. **`.claudeGroupedFormStyle()` ViewModifier**: Applied to every `Form` and insetGrouped `List` across Settings, Personalization, Colab, Compatible Endpoints, Study Memory, Study Backup, Study Review, Profile Editor, Story Play sheets, System Prompt Library, Operation Manual, Conversation Versions, and Projects:
   - `.listStyle(.insetGrouped)` (for `List`)
   - `.scrollContentBackground(.hidden)`
   - `.background(Ink.groupedBg.ignoresSafeArea())`
   - `.listRowBackground(Ink.card)` (applied at `Section` or row level, never `Color.clear` for data rows)
   - `.listRowSeparatorTint(Ink.line)`
   - `.foregroundStyle(Ink.ink)`
   - `.tint(Ink.ink)` (**Builder-check resolution #4**: keep container tint neutral near-black `Ink.ink` so standard `Form` action buttons like `"检查密钥与余额"`, `"测试连接"`, `"立即备份"`, `"保存"`, and back chevrons stay calm near-black instead of turning bright orange-red; apply `.tint(Ink.seal)` selectively only on `Toggle` controls or explicit accent highlights).
   - **CRITICAL**: Remove `.font(TypeScale.body)` from every `Form` container! Leaving `Form` at iOS native text style hierarchy immediately fixes oversized 18pt section headers and giant footers across the entire app, giving exact Claude proportions (~16pt row text, ~13pt muted section header, ~12.5pt muted footer).
4. **`.claudeSecondaryPillButton()`** for `"+ 新建会话"` in Sidebar & Project Detail (**Builder-check resolution #5**):
   - **Paper**: soft airy neutral grey pill (`Color.adaptive(light: 0xE5E4E0, dark: 0x2E2E2B)`) with crisp `Ink.ink` (`#1A1A18` / `#ECEBE7`) text, subtle `0.6pt` `Ink.line` stroke, and `.glassEffect(.regular.interactive(), in: Capsule())` — matching Claude Screenshot 1's light airy visual weight while maintaining WCAG AAA contrast in bright light.
   - **Night-River**: preserves `Ink.seal` (pale gold) fill with `Ink.onSeal` text.
   - **Swiss**: preserves square `InkCapsule()` (`Path(rect)`) with `Ink.solid` fill and `Ink.onSolid` text.

#### D. Non-Paper Theme Preservation (**Builder-check resolution #2**)
- **Swiss ("瑞士")** preserves its square geometry (`InkRounded`/`InkCapsule`), `1.5pt` black `ClearGlass` composer box, square `PulseDot`, flush-left `WelcomeView.swissBody`, and `SwissThreadHeader`.
- **Night-River ("夜江")** preserves `MoonDisc` on `WelcomeView` and `StreamActivityView` ("月出"), `MoonPhaseIcon` and `"千江有水千江月"` in `HistorySidebar`, gold `"+ 新建会话"` pill, and `TypeScale.editorialDisplay(...)` serif book titles on `NightShelf` spines and covers.
- Inside grouped forms/sheets, `Ink.groupedBg` (`#051117` in Night, `#F2F2EF/#111214` in Swiss) and `Ink.card` (`#0F1D24` in Night, `#FFFFFF/#1D1E21` in Swiss) adapt seamlessly to each theme.

---

### 5.2 Sidebar Drawer (`HistoryView.swift`, `SidebarPan.swift`)

1. **Drawer Geometry (`SidebarPan.swift`)**:
   - Remove `backContainerView.layer.cornerRadius = backRadius` and `backContainerView.layer.borderWidth = 0.5`! The sidebar sits cleanly full-bleed on `Ink.sheet` (`#F3F3F1` light / `#121211` dark), just like Claude.
   - Keep the front main chat page's `54pt` continuous corner radius and soft subtle drop shadow (`shadowOpacity = 0.08`, `shadowRadius = 18`) while dragged/open, with a hairline `0.5pt` `Ink.line` border only on the front card edge so it cleanly separates from the sidebar without harsh dark outlines.
2. **Header (`HistoryView.swift`)**:
   - `"Sermo"` wordmark: `TypeScale.editorialDisplay(25, weight: .medium)` (refined, balanced with Claude's ~24-25pt wordmark instead of oversized 30pt bold).
   - Top-right search circle: `40×40` soft neutral circle (`Ink.raised` with subtle glass effect on iOS 26), thin `magnifyingglass` (`16pt`, `.regular`, `Ink.ink2`).
3. **Navigation & Thread Rows**:
   - Menu items (`项目`, `书架`, pinned projects): thin `.light` / `.regular` icons (`17pt`, `Ink.ink2`, `frame(width: 22)`), clean system sans-serif `16pt` `.regular`, tighter airy vertical padding (`10pt`).
   - Section label (`最近`): `13pt` `.medium` `Ink.ink3` (matching Claude's delicate small grey `"最近"`), `.padding(.top, 18).padding(.bottom, 6)`.
   - Thread rows: replace boxy `bubble.left` with rounded thin `message` / `message.fill` (or custom fine circular chat bubble matching Claude's rounded-circle bubble with tiny bottom-left tail!) at `15.5pt` `.light`, `Ink.ink2`; text in `15.5pt` system sans-serif (`.medium` when active, `.regular` otherwise); active row highlight uses subtle `Ink.raised` rounded capsule (`cornerRadius: 12` or `Capsule()`) with `Ink.ink` text (no loud accent fill).
   - `"查看全部 >"`: `14.5pt` `.medium` `Ink.ink3`, trailing thin `chevron.right` (`11pt`), clear spacing below the last thread.
4. **Bottom Footer & Zero-Overlap Guarantee (Per Xiaolong's explicit preference A2)**:
   - Scroll view bottom margin increased to `110pt` (`contentMargins(.bottom, 110)`), PLUS a smooth bottom fade mask / gradient scrim (`Ink.sheet.opacity(0)` -> `Ink.sheet.opacity(0.96)` -> `Ink.sheet`) behind `footer` so scrolling threads and `"查看全部 >"` gently fade out above the footer and **can never collide with the avatar**.
   - **Left side (Profile + Compact Balance/Price Band)**:
     - Circular avatar sized to `38×38` (matching Claude's delicate circle), clean hairline border.
     - Beside avatar: two super-clean compact lines (`11.5pt` `Ink.ink2` medium for balance e.g. `¥0.00` or `余额 ¥12.4`, and `10.5pt` `Ink.ink3` for compact price band e.g. `空闲 · 半价` / `高峰 · 原价` — add a compact display helper so it **never** wraps or truncates into `空闲时段·半...` on 390pt screens!).
     - Ensure `layoutPriority` and `minimumScaleFactor(0.85)` protect both sides cleanly.
   - **Right side (`+ 新建会话`)**:
     - Airy Claude-style pill (`height: 40`, horizontal padding `15`, `14.5pt` `.medium` system sans-serif, subtle soft-grey translucent fill or glass pill — NOT solid black), `fixedSize(horizontal: true, vertical: false)` so button text never wraps.

---

### 5.3 Main Chat Screen, Welcome, Thinking, Markdown & Composer (`ContentView.swift`, `KeyboardChatLayout.swift`, `WelcomeView.swift`, `ReasoningView.swift`, `StreamActivityView.swift`, `ChatMessagingStyle.swift`, `ToolViews.swift`)

1. **Top & Bottom Native iOS 26 Soft Edge Blur + Centered Floating Jump Button (**Builder-check resolution #1**)**:
   - Keep `KeyboardChatLayout`'s proven detached UIKit keyboard-docking architecture completely intact (do NOT alter `safeAreaRegions` or `.ignoresSafeArea(.container, edges: .top)`).
   - In `KeyboardChatLayout.swift`: configure `scroll.topEdgeEffect.isHidden = false; scroll.topEdgeEffect.style = .soft` AND `scroll.bottomEdgeEffect.isHidden = false; scroll.bottomEdgeEffect.style = .soft`. In `ContentView.swift`, replace `.scrollEdgeEffectHidden(true, for: .top)` with `.scrollEdgeEffectStyle(.soft, for: .top)` and `.scrollEdgeEffectStyle(.soft, for: .bottom)`.
   - **Status-bar clock safety belt**: keep a compact, sheer top fade strictly over the status bar (`height: topInset + 16`, stops `0.86` at `0`, `0.48` at `0.55`, `0` at `1.0`) so the clock stays readable even in detached hosts while scrolling text still passes visibly behind the floating Liquid Glass toolbar buttons below the status bar.
   - **Translucent bottom composer backdrop**: replace the thick opaque `0.92 -> 1.0` paper wall behind the composer with a sheer soft fade (`0` -> `0.55` -> `0.82`) and keep `.clearGlass(radius: 26)` on the composer card (preserving Swiss's square black-bordered box and giving Paper/Night native iOS 26 Liquid Glass with text visibly softening underneath).
   - Center the floating `↓` jump-to-latest Liquid Glass circular button (`ChatFloatingControlsOverlay`) dead-center right above the composer (matching Claude's centered glass `↓` orb), while keeping any optional project menu aligned left on empty pages.
   - `SidebarGlyph` in `AppTheme.swift`: replace the two uneven thick lines with **three balanced thin horizontal lines** (`16pt` width, `1.4pt` height, `4.5pt` spacing, rounded caps).
   - Top-right `square.and.pencil` and `ellipsis`: apply `.font(.system(size: 16, weight: .regular))` so stroke weight matches Claude's light crisp toolbar icons.
2. **Welcome Screen (`WelcomeView.swift`)**:
   - In **Paper**: replace `PulseDot` above the greeting with a refined static terracotta `ThinkingMark(live: false, size: 28)` and `TypeScale.editorialDisplay(27, weight: .regular)` greeting line (`spacing: 16`).
   - In **Night-River**: preserve `MoonDisc(size: 20)` + `TypeScale.editorialDisplay(27)` greeting.
   - In **Swiss**: preserve `swissBody` unchanged.
3. **Messages, Claude System Typography Rhythm, User Bubble & Time Dividers (`ContentView.swift`, `ChatMessagingStyle.swift`, `HighlightMarker.swift`)**:
   - **Why Claude's system font looks so refined (measured directly from Xiaolong's screenshot)**:
     - Clean **Regular** body weight (`Personal.mediumBody` defaults to `false`) contrasted sharply against **Semibold/Bold** pure near-black headings, numbered markers (`1.` `2.` `3.`), and `**bold**` phrases (`Personal.boldUsesAccent` defaults to `false`).
     - Crisp `16.5–17pt` body size, generous `7pt` line spacing (`~26pt` line pitch, ~1.55x–1.6x line height), `16pt` paragraph gap, `18pt` standard horizontal margin (~19–20 CJK chars/line).
     - **Hanging-indent lists**: increase list item vertical spacing from `8pt` to `12pt`, bold numbered markers (`1.`, `2.`, `3.`) with tight `6pt` horizontal gap so wrapped second lines align flush with the first character of the item text.
   - User bubble (Editorial / Smart mode): crisp neutral `Personal.bubble` (`#EFEEEA` light / `#2A2A27` dark), `cornerRadius: 20`, comfortable `15pt` horizontal / `10.5pt` vertical padding, `16.5pt` Regular system sans-serif.
   - Time divider (`MessageTimeDivider.shouldShow`): return `false` when `previous == nil` so opening a fresh conversation and saying `"你好"` stays spotless like Claude — centered timestamps only appear after a `>= 30 min` gap or cross-day jump, while left-swipe timestamp reveal works on every message anytime.
4. **Live & Finished Thinking Row (`ReasoningView.swift`, `StreamActivityView.swift`)**:
   - Introduce `ClaudeThinkingDots` (two tiny `4.5pt` terracotta circles spaced `4pt` apart with gentle alternating opacity/scale pulse, zero spinning flower distraction).
   - While thinking (`live`): show `[ClaudeThinkingDots]  [live snippet text or "正在思考…"]  [thin chevron.right]` in `13.5pt` `Ink.ink3`, single-line truncating tail — directly surfacing the `snippet` already computed by `ThinkingRow`!
   - When finished: show a delicate thin **`clock`** icon (`13.5pt` `.light` `Ink.ink3`) + `"已思考 X 秒"` (matching Claude's finished thinking row with thin circular clock icon!) + thin `chevron.right`.
   - When connecting/waiting before first reasoning token (`StreamActivityView`): in **Paper**, use `ClaudeThinkingDots` + subtle `Ink.ink3` status line (`"正在连接…"` / `"等待回应…"`); in **Night-River** and **Swiss**, preserve `PulseDot()` (so Night keeps glowing `MoonDisc` "月出" and Swiss keeps its square indicator).
5. **Markdown Code Blocks, Math, Tables, Quotes (`ContentView.swift`)**:
   - **Code blocks (`MarkdownCodeBlockView`)**:
     - Clean card background: `Ink.card` (light `#FFFFFF` / dark `#1F1F1D`) with `14pt` corner radius and subtle `0.8pt` `Ink.line` border (NO terracotta border!).
     - Top bar: subtle `Ink.raised.opacity(0.65)` strip (or clean padded header with hairline bottom divider), lowercase/plain language label (`python`, `swift`, `代码`) in `12pt` `.medium` `Ink.ink3` (NO terracotta text!), and thin `doc.on.doc` copy icon in `Ink.ink3` (turning checkmark briefly on copy); keep `"预览网页"` pill subtle and clean for HTML/SVG.
   - **Math blocks (`MarkdownMathBlockView`)**: same neutral card styling with `Ink.line` border and `Ink.ink3` header/copy button.
   - **Blockquotes**: subtle `Ink.line` / `Ink.ink3.opacity(0.4)` vertical bar (`2.5pt`) instead of loud terracotta bar.
   - **Inline code**: subtle neutral `Ink.raised` pill with `Ink.ink` monospaced text (instead of bright terracotta text everywhere).
6. **Assistant Action Bar (`ContentView.swift`)**:
   - Slimmer, quieter icons (`14.5pt`, `.light` weight, `Ink.ink3.opacity(0.88)`, `spacing: 16`):
     - Copy: `doc.on.doc` (or `checkmark`)
     - Select text: replace crop-like `selection.pin.in.out` with clean `text.cursor` (or `text.viewfinder` / `character.cursor.ibeam` — `character.cursor.ibeam` or `text.quote` is unmistakably text selection, never confused with image cropping!)
     - Edit: `pencil`
     - Speech playback (when enabled): thin `play` / `stop` (`14.5pt` `.light`)
     - Regenerate (last message): `arrow.clockwise`
   - Keep Token/Cost label ultra-quiet (`11pt`, `Ink.ink3.opacity(0.75)`).
   - Hide the action bar on failed empty error-only assistant messages (like Screenshot 5 `"DeepSeek API 余额不足"` where 4 icons hovered awkwardly above an empty failed message — keep only a clean `"重试"` button on failed empty messages!).
7. **Composer (`ContentView.swift`)**:
   - Refined slimmer outer container (`cornerRadius: 24`, padding `.horizontal(14) .top(12) .bottom(10)`): soft translucent `Ink.card` / glass surface with delicate `0.8pt` `Ink.line` stroke and subtle lift shadow — matching Claude Screenshot 6's sleek low-profile floating input box.
   - Placeholder: `16pt` `Ink.ink3.opacity(0.75)` system sans-serif.
   - Bottom action row (`height: 34`):
     - `+` attachment button: `34×34` subtle circle (`Ink.raised`), thin `plus` (`15pt`, `.regular`, `Ink.ink2`).
     - Model + Effort pill: `height: 34`, `horizontal: 12`, `Ink.raised` capsule, `13.5pt` `.medium` `Ink.ink` model name + `13.5pt` `.regular` `Ink.ink3` effort label (identical proportion to Claude's `Opus 5.5 中等`).
     - Web search globe (per Xiaolong's preference A3: kept beside pill, slimmed & muted): `34×34` borderless hit target, thin `globe` (`15.5pt`, `.light`, `Ink.ink3` when off; `Ink.seal` + subtle `13pt` `"联网"` when on).
     - Right send / stop button (`34×34` circle):
       - **Idle (empty input, not generating)**: subtle neutral `Ink.raised` circle with muted `arrow.up` (`14pt`, `.medium`, `Ink.ink3.opacity(0.65)`) — **no more faded pink-orange blob!**
       - **Ready (has input or ghost reply)**: crisp `Ink.seal` terracotta circle with white `arrow.up` (`14pt`, `.semibold`).
       - **Generating (Stop)**: calm Claude-style `Ink.ink` circle (or `Ink.raised` circle with `Ink.ink` `stop.fill` square `11pt`, matching Screenshot 6's clean neutral circular stop button!).

---

### 5.4 Settings Home & All 12 Settings Sub-Pages (`SettingsView.swift`, `InterfaceStyle.swift`, `ColabSettingsView.swift`, `CompatibleEndpointSettingsView.swift`, `ProfileView.swift`, `UsageView.swift`, `FeatureOverviewView.swift`, `OperationManualView.swift`, `ToolSettingsSections.swift`, `SubscriptionSettingsSection.swift`, `ChatConnectionTestView.swift`)

1. **Settings Home (`SettingsView.swift`) — 1:1 Claude Layout**:
   - `.navigationTitle("设置")` with `.navigationBarTitleDisplayMode(.inline)` (compact centered title, eliminating the giant 32pt Songti `"设置"` header).
   - **Toolbar (**Builder-check resolution #3**)**:
     - Top-left: circular glass `×` button (`Image(systemName: "xmark")`, accessibilityLabel `"关闭"`).
     - Top-right: circular glass `i` button (`Image(systemName: "info")`, opens `aboutPage` via sheet or navigation — matching Claude Screenshot 3's exact top-right `i` circle!).
     - Remove top-level `"取消"` and `"保存"` buttons. Add a dedicated `store.saveDefaultProvider(_ provider: AIProvider)` helper on `AppStore` that persists ONLY `settings.provider` (and updates empty non-project threads) without touching `apiKey`, Keychain, or unsaved `draftSettings` in sub-pages; Settings Home's `"默认服务"` picker calls `store.saveDefaultProvider(newValue)` and mirrors `draftSettings.provider = newValue`. Sub-pages with editable credentials/prompts (`DeepSeek`, `Colab`, `其他模型`, `ChatGPT`, `聊天与指令`) keep their own explicit top-right `"保存"` button and shared draft safety (preserving `testFontChangeKeepsSettingsAndUnsavedPrompt`).
   - **Card 1 (Profile Card — inside crisp white rounded card!)**:
     - Remove `.listRowBackground(Color.clear)`! Place `ProfileAvatar(size: 46)` + `profile.name` (`16.5pt` `.semibold` `Ink.ink`) + subtitle (`ID：xiaolong` or status in `13pt` `Ink.ink3`) inside the first white rounded card, with a subtle trailing `chevron.right`.
   - **Card 2 (Appearance & Chat)**:
     - `个性化` (`paintpalette`)
     - `聊天与指令` (`bubble.left.and.text.bubble.right`)
   - **Card 3 (`模型与服务` section)**:
     - `DeepSeek` (`key`, trailing muted status `"已填写 Key"` / `"未填写"`)
     - `Colab` (`cloud`)
     - `其他模型（兼容端点）` (`server.rack`)
     - `ChatGPT 订阅与声音` (`waveform` or `person.crop.circle`)
     - `默认服务` (`slider.horizontal.3` — **adds the missing leading icon** so left alignment is 100% straight across all 5 rows!)
     - Footer text automatically renders in crisp iOS native `footnote` (`12.5pt` `Ink.ink3`) once `.font(TypeScale.body)` is removed from `Form`.
   - **Card 4 (`数据与连接` section)**:
     - `授权与连接` (`link`)
     - `用量与备份` (`chart.bar`)
     - `功能一览` (`book`) — note: `"关于 Sermo"` is now cleanly accessible via the top-right `i` glass button (and can also remain or be streamlined so the bottom stays airy like Claude!).
   - Every icon in Settings uses uniform `17pt` `.light` `Ink.ink2` in a fixed `24pt` leading frame (`ClaudeIconBadge`).
2. **All Settings Sub-Pages Unified**:
   - **`CompatibleEndpointSettingsView.swift`**: Apply `.claudeGroupedFormStyle()`! Instantly fixes the jarring stock-iOS grey/blue rupture when tapping `"其他模型（兼容端点）"`.
   - **`ColabSettingsView.swift`, `SettingsView.swift` (`deepSeekPage`, `chatGPTPage`, `chatPage`, `connectionsPage`, `dataPage`, `aboutPage`, `SystemPromptLibraryView`, `SystemPromptPickerSheet`, `LocalDataStatusView`)**: Remove `.font(TypeScale.body)` from `Form`, apply `.claudeGroupedFormStyle()`, ensure crisp white cards on `Ink.groupedBg` and proper footnote footers.
   - **`PersonalizationView` (`InterfaceStyle.swift`)**: Remove `.font(TypeScale.body)` from `Form`, apply `.claudeGroupedFormStyle()`, update preview card to reflect the calibrated neutral palette and crisp sans/serif preview, and update reset footer copy (`字号回到 17`).
   - **`ProfileEditor` (`ProfileView.swift`)**: Keep avatar header clean, place `名字` / `ID` inside white grouped card on `Ink.groupedBg`, replace `"取消"` with `×` (keep `"保存"` top-right).
   - **`FeatureOverviewView.swift` & `OperationManualView.swift` & `UsageView.swift`**: Switch from flat `.listRowBackground(Color.clear)` to `.insetGrouped` white cards on `Ink.groupedBg`, crisp sans-serif hierarchy, muted secondary copy.

---

### 5.5 Projects, Study Views, All Chats, Bookshelf & Secondary Modals (`ProjectsView.swift`, `StudyMemoryView.swift`, `StudyReviewView.swift`, `StudyBackupView.swift`, `BookshelfView.swift`, `BookDiscussionViews.swift`, `StoryPlayViews.swift`, `HistoryView.swift` Versions Sheet, `HTMLPreviewSheet.swift`)

To completely eliminate Xiaolong's pain point ("进不同项目感觉不像同一个软件"):
1. **Projects List (`ProjectsView.swift`)**:
   - Upgrade from flat `.listStyle(.plain)` + `.listRowBackground(Color.clear)` to `.listStyle(.insetGrouped)` with crisp white rounded cards (`Ink.card`) on `Ink.groupedBg`.
   - Top bar: inline centered `"项目"`, top-left circular glass `×` close button (with `.accessibilityLabel("完成")` so `NavigationUITests` stays green), top-right circular glass `+` menu.
   - Uniform thin icons (`folder`, `lock`, `graduationcap`) in `Ink.ink2` (subtle terracotta tint only for active badge if needed), clean `16pt` sans-serif title + `12.5pt` muted conversation count.
2. **Project Detail (`ProjectPageView` in `ProjectsView.swift`)**:
   - Replace the mismatched loose top pills + bare memory row + flat list + heavy solid black floating pill with a unified grouped Claude layout on `Ink.groupedBg`:
     - Top action cards/pills in crisp `Ink.card` with subtle `Ink.line` stroke and thin leading icons (`doc.text` for 文件, `text.alignleft` for 指令).
     - Memory / Study Archive entry cleanly styled inside a white grouped card row (with today's English words rendered as restrained neutral/soft-tinted mini chips instead of loud red pills).
     - Project conversation list rendered inside a clean white rounded grouped card section with thin circular chat bubble icons and muted dates.
     - Bottom-right `"+ 新建会话"` button aligned to the exact same light Claude pill style as the Sidebar (no harsh black block!).
   - All sub-sheets inside `ProjectsView.swift` (`ProjectFilesView`, `ProjectInstructionsSheet`, `ProjectMemoryView`, `ProjectServiceSheet`, `ProjectDesignerView`) adopt `.claudeGroupedFormStyle()` and consistent `×` / inline navigation headers.
3. **Study Views (`StudyMemoryView.swift`, `StudyReviewView.swift`, `StudyBackupView.swift`)**:
   - Remove `.font(TypeScale.body)` from all `Form` containers; apply `.claudeGroupedFormStyle()` everywhere (especially fixing `StudyReviewView`, which previously lacked `.scrollContentBackground(.hidden)`!).
   - Calm down excessive terracotta pills in `StudyMemoryView`: use neutral `Ink.raised` pills with `Ink.ink2` text for tags/words and reserve `Ink.seal` only for primary numeric highlights or action buttons.
4. **All Chats (`AllChatsView` in `ProjectsView.swift`)**:
   - Upgrade from flat `.plain` list to `.insetGrouped` white rounded card list on `Ink.groupedBg`, centered inline `"全部对话"`, circular glass `×` top-left (`.accessibilityLabel("完成")` for UITest compatibility), clean sans-serif titles + muted project/date metadata.
5. **Conversation Versions (`ConversationVersionsSheet` in `HistoryView.swift`) & HTML Preview (`HTMLPreviewSheet.swift`)**:
   - Align background (`Ink.groupedBg`), cards (`Ink.card`), `×` close button, and clean sans-serif labels.
6. **Bookshelf & Story/Book Discussion Modals (`BookshelfView.swift`, `BookDiscussionViews.swift`, `StoryPlayViews.swift`)**:
   - Preserve Bookshelf's signature `ShelfAtmosphere` blurred cover backdrop and Night-River book spines!
   - Align all Bookshelf/BookDetail/Persona/Story/Discussion modals and forms: remove `.font(TypeScale.body)` from forms, unify `×` circular glass close buttons, thin uniform toolbar icons, clean sans-serif UI labels (keeping novel titles/reading text cleanly readable), and white rounded cards on `Ink.groupedBg` for settings/memory/control sheets.

---

## 6. Decisions Left to the Builder

- Exact SwiftUI modifier factoring (e.g., whether `ClaudeChrome.swift` is added as a small helper file in `Views/` or placed in `AppTheme.swift` — keeping everything in `AppTheme.swift` avoids adding new files to `project.yml`/`generate-project.py` unless beneficial, though `preflight_sermo.py --sync` handles new files cleanly too).
- Exact SF Symbol choices where fine weight adjustments look cleanest on iOS 26 (e.g., `message` vs `bubble.left` for circular chat bubbles, `character.cursor.ibeam` vs `text.cursor` for select-text, `slider.horizontal.3` vs `cpu` for default provider).
- Exact spring/animation durations for `ClaudeThinkingDots` and bottom fade gradient stops in `HistorySidebar`.
- Exact concise formatting of `Pricing.compactStatusLabel()` so sidebar footer fits comfortably at 390pt width alongside avatar + `"+ 新建会话"`.

---

## 7. Verification Plan

1. **Zero Data / Schema Risk Check**: Confirm `git diff` has **zero changes** to `QingJian/DeepSeekPocket/Core/Models.swift` and `.github/workflows/`.
2. **Static Swift Sanity**: Verify balanced braces/parentheses and no duplicate symbol definitions across every modified `.swift` file.
3. **Sermo Preflight & Overlay Sync**: Run `preflight_sermo.py --sync` and confirm all 4 sync steps + read-only checks pass green.
4. **macOS CI Build & Core Tests**: After Xiaolong approves push/delivery, push to `main`, track GitHub Actions `build-ios.yml` to green Release `.ipa` build, inspect `Info.plist` (`com.xiaolong.qingjian`), and deliver the resulting `.ipa` to Downloads and Google Drive for on-device iPhone visual inspection.
