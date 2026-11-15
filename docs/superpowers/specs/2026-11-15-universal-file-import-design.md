# Sermo 通用文件导入与 IPA 体检设计方案

**日期**：2026-11-15  
**适用分支**：`cleanup-1.37`（`Sermo 1.37.0`）  
**状态**：待用户审批

---

## 1. 目标与核心原则

解决当前 Sermo 仅支持少量纯文本和 PDF、无法传 `.ipa` / `.zip` / 常用代码与办公文档、外部打开文件劫持到备份或书架、以及文件内容塞爆打字框的问题。

**核心交互铁律**：「不管发什么，都不能抢占说话的那个窗」
- 导入的任何文件不往打字框里灌几万字正文，统一以**待发送文件胶囊卡片**挂在输入框上方（与待发送图片缩略图同级），打字框始终干净。
- 从微信 /「文件」App 用 Sermo 打开文件时，除 `.sermobackup` 专属备份外，**不弹选择菜单、不强行跳书架**，直接安静挂进当前对话的待发送区。
- 发出后在消息气泡内自动折叠为可点击展开/收起的文件卡片，**不修改 `ChatMessage` 持久化字段结构**，100% 兼容覆盖升级与旧备份。

---

## 2. 非目标（本次不做）

- 不引入任何第三方 Swift Package 或 C/C++ 解压库（全部基于苹果原生 `Foundation`、`Compression`、`PDFKit`、`ImageIO` 实现）。
- 不支持上古二进制格式（`.doc` / `.xls` / `.ppt` 97-2003）、`.rar` / `.7z`、音视频大文件解封装。
- 不改动书架独立导入小说（`.txt` / `.epub`）的现有体验（书架内「+」仍按原逻辑导入书籍）。

---

## 3. 方案设计与模块拆分

### 3.1 流式低内存 ZIP 读取器（`StreamZipReader`）
- 改造现有一次性读入 `[UInt8]` 的 `ZipArchive`，改为基于 `FileHandle` 按偏移定位文件末尾 Central Directory（支持标准 ZIP 及 ZIP64），仅按需解压被读取的单个条目。
- 安全限制：单个压缩包上限 **500 MB**（用于 `.ipa`），单个解压条目上限 **32 MB**，防止 Zip Bomb 导致手机内存溢出。

### 3.2 `.ipa` 端侧深度体检器（`IPAAnalyzer`）
选入 `.ipa` 后自动在本地生成结构化《IPA 包体分析报告》（纯文本 Markdown）：
1. **包体与体积分布**：压缩包大小、解压总大小、主程序 / `Frameworks` / 资源目录占比、Top 25 最大文件排行。
2. **`Info.plist` 完整解码**：使用 `PropertyListSerialization` 自动解码二进制 `bplist00`，输出 Bundle ID、版本、Build、最低 iOS 系统要求、URL Schemes、隐私权限描述、后台模式、支持文档类型等关键字段。
3. **签名与权限（`embedded.mobileprovision`）**：提取嵌入式描述文件中的 Team 名称、证书信息、过期时间、测试设备数与 `Entitlements` 权限字典；若为未签名包（如 `unsigned.ipa`）则明确标注。
4. **Mach-O 二进制与依赖分析**：解析主可执行文件及 `Frameworks/*.framework` 的 Mach-O 头（含 Fat Binary 切片），列出支持的 CPU 架构（如 `arm64`）、是否加密加壳（`cryptid`）以及链接的系统库与三方动态库清单。

### 3.3 `.zip` 源码/资料包智能提取
- 上限 **100 MB**，自动过滤 `.git/`、`node_modules/`、`Pods/`、`DerivedData/`、`build/`、`__pycache__/`、`.DS_Store` 及二进制媒体文件。
- 先输出**完整目录树（含文件大小）**，再按配置文件（`Package.swift`、`package.json`、`Podfile`、`README` 等）→ 源码的顺序拼入正文；超出 10 万字预算时保留完整目录树并列出未展开文件清单，不粗暴整包拒收。

### 3.4 开发者文件、日志与办公文档扩展
- **开发者与日志全量放开**：选择器放行常见源码（`.swift`、`.py`、`.js`、`.ts`、`.tsx`、`.jsx`、`.vue`、`.go`、`.rs`、`.c`/`.cpp`/`.h`/`.m`/`.mm`、`.java`、`.kt`、`.cs`、`.rb`、`.php`、`.sh`、`.ps1`、`.sql` 等）、配置与工程文件（`.plist`、`.entitlements`、`.pbxproj`、`.xcconfig`、`.strings`、`.xcstrings`、`.yaml`/`.yml`/`.toml`/`.ini`/`.env`、`.patch`/`.diff`、`Dockerfile`/`Makefile`）以及真机崩溃日志（`.ips` / `.crash` / `.log`）。
- **二进制 `.plist` 自动转文本**；单文本/日志上限从 2 MB 提至 **15 MB**，超长日志超过单份 10 万字上限时自动保留头尾关键错误段并提示。
- **办公与电子书文档直读**：
  - `.docx`（Word 正文与表格）、`.xlsx`（工作表单元格文本）、`.pptx`（幻灯片正文与备注）：基于 `StreamZipReader` + `XMLParser` 提取纯文本；
  - `.rtf`：基于系统 `NSAttributedString` 提取纯文本；
  - `.epub`：复用现有 `EpubBook.pages(from:)` 提取章节文本，开放给聊天与项目资料导入。

### 3.5 不抢占输入框的交互与入口修复
1. **待发送文件胶囊卡片（`PendingDocument`）**：
   - 在 `ContentView` 输入框上方增加水平待发送文件卡片区（最多 5 份），显示文件名与字数，点击可预览提取出的全文/报告，点 `×` 移除；**完全不占打字框**。
   - 发送消息时将文件文本以标准标记块拼入发送内容，消息气泡渲染层识别后**自动折叠为文件卡片**，点击展开阅读；**`ChatMessage` 数据模型与 `conversations.json` 零字段变更**。
2. **修复外部「用 Sermo 打开」（`.onOpenURL`）**：
   - 仅 `.sermobackup` 走全量备份恢复弹窗；
   - 其余所有文件（`.json`、`.ipa`、`.zip`、`.pdf`、代码、`.docx` 等）直接读取并静默挂入当前活跃对话的待发送文件卡片区，不弹窗、不跳书架。
3. **修复「+ → 粘贴」**：
   - 剪贴板里有图片时直接加入待发送图片栏；有文字时照常粘贴。

---

## 4. 风险与验证

- **兼容性风险极低**：不新增 `ChatMessage` 必填字段，覆盖安装旧版聊天记录与备份 100% 安全。
- **内存与稳定性**：大包走 `FileHandle` 流式读取 + 条目上限校验，避免 OOM。
- **验证方式**：针对 `StreamZipReader`、`IPAAnalyzer`（构造合成测试 IPA/Mach-O/bplist）、`.zip` 过滤、`.docx`/`.xlsx`/`.pptx` 解析和外部 URL 路由补充完整单元测试，并在 GitHub Actions `study-step7.yml` 运行全量 `swift test --skip StudyLiveModelTests` 与 Release 打包验证。
