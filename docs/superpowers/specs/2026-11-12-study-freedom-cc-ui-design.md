# Sermo 学习系统高自由度去状态机重构与 Claude Code (CC) 暖糯 UI 设计书

## 1. 背景与核心目标（Intent & Why）

Sermo 的核心定位是**强情感连接、高人设自由度的 AI 陪伴软件**，学习功能（考研英语、313 历史、考研政治）应当是用户在与 AI 日常陪伴、撒娇、闲聊过程中**自然顺手发生的事**，而不是把对话变成机械死板的“闯关答题机”。

此前版本在底层采用了“防幻觉单步状态机”设计，导致：
1. **Token 消耗巨大**：每次聊天请求自动注入 68 篇阅读目录（68 行）、20 多个碎工具 Schema 及 4 大段警告规则，纯闲聊也白白消耗数千输入 Token。
2. **思考卡顿与报错死锁**：所有写入工具强制核对 `evidence_quote`（必须精确匹配最新一条用户消息子串）、`expected_revision`（版本号锁）、出题时间戳锁与严格字段白名单锁，一旦跨轮补记分或中途要求乱序，模型被迫思考 70+ 秒仍被报错驳回。
3. **教学与查词能力受限**：抽词只向模型暴露当前第 1 个词（隐藏后 9 个），无法一次展示多个词、无法自由打乱、无法搜索形近词；提示词束缚了语义灵活判分（如词库写“阳光”，用户答“光线”理应算懂）与词根串讲；`StudyOutputGuard` 甚至用正则强行篡改 AI 回复。
4. **UI 偏严肃老气**：`ContentView` 外层 `.foregroundStyle(Ink.ink)` 覆盖了部分加粗强调色；默认启用严肃的古籍宋体、冷白纸面与冷灰气泡，行内 `` `word` `` 缺少 CC 标志性的圆润 SF Mono 暖陶土胶囊质感，工具与思考状态栏偏粗大。

## 2. 目标、非目标与反目标（Goals, Non-Goals & Anti-Goals）

- **Goals**:
  1. **零包袱待机省 Token**：移除每轮自动注入的 68 篇阅读完整目录与冗长禁令，仅附带 2～3 行极简学习概况。
  2. **开放词篮 + 真随机乱序 + 形近词搜索 + 无锁语义记分**：
     - `study_draw_words` 支持 `smart`、`shuffle`（Fisher-Yates 真随机洗牌）、`review`、`unit`、`units_overview`，一次性向 AI 返回整批词（1～30 词完整信息）；
     - `study_find_word` 支持英文/中文、词根前后缀及拼写编辑距离（Levenshtein）形近词检索（最多返回 15 词）；
     - `study_grade_word` 支持单条或批量无锁记分（按单词拼写或 ID 直接写入 FSRS v6 遗忘曲线，支持 `undo`，无 `session_id` / `expected_revision` / `evidence_quote` / 时间锁）。
  3. **阅读、政史与记忆全面拆锁精简**：合并精简阅读工具（`study_reading_catalog`、`study_read_passage`、`study_answer_reading`）及政史/记忆工具，全面移除 `evidence_quote` 字面锁、`expected_revision` 锁、暂停锁与严格字段洁癖锁。
  4. **拆除隐形禁锢**：移除 `AppStore` 对 `StudyOutputGuard` 的输出篡改拦截；清空后台教条式 `note`；升级内置《操作与运行规范》（v3）明确语义理解判分（如“阳光”答“光线”即算掌握）与词根串讲自由。
  5. **正宗 CC 暖糯可爱 UI**：修复 `AttributedString` 陶土色粗体被外层覆盖的问题；行内 `` `code/word` `` 采用 SF Mono 圆润等宽体 + 暖陶土字色 + 14% 暖陶土底衬；升级默认暖羊皮奶油底（`#FAF9F5`）、暖燕麦气泡（`#EFECE4`）、温润深炭棕字色（`#1F1E1B`），新装/未手动指定字体时默认采用现代无衬线系统字体；精致化工具调用与思考胶囊条。
- **Non-Goals**:
  - 不改动 SQLite 底层 `study_data` 表结构，不破坏已有词库、阅读包、FSRS 复习记录及 Google Drive 备份恢复兼容性。
  - 不改动 Bundle ID（保持 `com.xiaolong.qingjian`）。
- **Anti-Goals**:
  - 绝不因为参数缺少可选空字段或跨轮聊天而向模型抛出工具校验报错。
  - 绝不拦截或篡改模型发给用户的自然语言回复。

## 3. 架构方案选择（Approaches）

- **方案 A（已选定）：AI 工具层彻底去状态机化 + SQLite 存储层原地兼容**
  - 向模型暴露精简后的 ~12 个无锁高自由度工具，底层直接读写既有 SQLite `word_progress` / `reading_answer` / `memory` / `topic` / `practice` 记录，既彻底解放 AI 自由度并省下大量 Token，又 100% 兼容历史数据与备份。
- **方案 B（放弃）：仅在旧 28 个工具上关闭校验报错**
  - 无法解决单步游标隐藏后 9 词、形近词缺失及 28 个工具 Schema 持续消耗 Token 的问题。
