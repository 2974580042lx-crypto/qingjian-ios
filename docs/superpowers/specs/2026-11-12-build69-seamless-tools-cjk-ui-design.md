# Sermo 1.37.0 (build 69) — Cross-Window Word Sync, Universal Default Tools, Smart URL/GitHub Reading & CJK Markdown/Font Polish Design

## 1. Goal & Scope
Upgrade Sermo (`1.37.0 build 69`, Bundle ID `com.xiaolong.qingjian`) to eliminate the remaining friction in cross-window study memory, universal tool availability (including ChatGPT Subscription and non-project chats), URL/GitHub link reading, and CJK Markdown bold/font rendering:

1. **Cross-Window Today/Weak Word Sync & Casual Word Auto-Capture (`StudyVocabulary.swift`, `StudyToolExecutor.swift`, `StudyWordTools.swift`, `OperationManual.swift`)**:
   - In `StudyToolExecutor.context(query:)`, include today's practiced words across all chat windows (`今日已聊单词：adapt(熟)、radical(熟)…`) and recent weak words (`近期薄弱词：…`) directly in `[学习账本概况]` (~30 tokens), so any newly opened window immediately knows which words were discussed today.
   - In `gradeWordsFree`, write `StudyWordEvent` (`kind: "word_event"`) on every grading action and mark `undone = true` on `undo`, so **今日语音复习提示词** and **本周学习周报** (`StudyReview.swift`) automatically include all words graded via `study_grade_word`.
   - When `study_grade_word` is called with an English word that is NOT in the 4,356-word pack (an out-of-pack/casual word), instead of throwing an error, automatically save or update it in the project's `生词` memory notebook (`saveMemoryFree`) and return a friendly receipt.
   - Update `StudyWordTools.note` and `OperationManual.defaultChapters` (`version: 4`) so that whenever the user casually asks about or discusses any word in any window, the AI automatically records it via `study_grade_word`.

2. **Universal Time Awareness & Default-On Tool Loop Across All Models & Chats (`Projects.swift`, `ToolCalling.swift`, `AppStore.swift`)**:
   - **Time & Elapsed Awareness everywhere**: Default `timeAwareness` to active (`chatProject?.timeAwareness != false`) for **all** conversations (both inside projects and in ordinary sidebar chats, excluding book discussions/story mode). Always include the current local date, weekday, and `HH:mm` time on the first message or in the system prompt, plus elapsed time when returning after a gap.
   - **Unlock Drive, GitHub, and Web tools for ChatGPT Subscription (`.chatGPT`) and Ordinary Chats (`project == nil`)**:
     - Remove the `service != .chatGPT` and `service == .deepSeek` blocks in `Projects.swift`, `ToolCalling.swift`, and `AppStore.swift`.
     - Enable `web_read` / `web_search`, `github_*` (when GitHub token is connected or `project?.githubTools == true`), and `drive_*` (when Google Drive is connected or `project?.driveTools == true`) by default across projects and ordinary chats unless explicitly disabled (`project?.webTools == false`, `project?.githubTools == false`, `project?.driveTools == false`), while keeping `AppManual.newProject()` explicit `false` flags intact for existing unit tests.

3. **Smart URL / GitHub Link Direct Reading & Context-Aware Web Search (`WebSearch.swift`, `WebPages.swift`, `AppStore.swift`)**:
   - When the user triggers web search (`searchRequested`) or when the message contains explicit `http://` / `https://` URLs (especially GitHub repository/file URLs like `https://github.com/owner/repo`):
     - Extract any URLs from the user's message and read their content directly via `WebPageReader` (with a built-in GitHub repository/file reader that fetches repo metadata + `README` from GitHub API / raw content when given a `github.com` URL!) instead of blindly feeding the raw URL into keyword search.
     - Raise `WebSearchProtocol` source limit from 5 to 8 (`max_uses: 2`) and include recent conversation context when searching follow-up questions.

4. **Project Page Today's Word Pills & CJK Markdown `**` + Fuller CC Font (`HighlightMarker.swift`, `ContentView.swift`, `AppTheme.swift`, `ProjectsView.swift`, `StudyMemoryView.swift`)**:
   - **CJK Markdown `**...**` Normalizer**: Before `AttributedString(markdown:)` parses inline text, normalize `**...**` spans that border full-width CJK punctuation (`。，、；：？！“”‘’（）《》【】—…`) so cases like `**1914年9月，第一次马恩河战役。**英法` or `在**“坦嫩堡”**中` always render as bold terracotta without leaving literal `**` asterisks.
   - **Fuller CC Font Weight**: Default `Personal.mediumBody` (`正文稍粗`) to `true` when unset (`stored(mediumKey) != "0"`), and upgrade `**bold**` emphasis weight in `MarkdownParagraph` from `.semibold` to `.bold`.
   - **Today's Word Pills on Project Page & Memory View**: Display a row of terracotta word pills for today's practiced words right on the English Project Page (`ProjectsView.swift`) and in `StudyMemoryView.swift`.
