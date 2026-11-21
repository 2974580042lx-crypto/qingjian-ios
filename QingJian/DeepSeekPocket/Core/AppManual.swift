import Foundation

// What Sermo can do and where to find it. One source for both the built-in
// "Sermo 说明书" project (as its document) and the feature overview in Settings.
// Update it with every feature, and bump `revision` so the project refreshes.
enum AppManual {
    static let revision = 25
    static let projectID = UUID(uuidString: "5E2B0D6A-3C1F-4A7E-9B21-5E5E2B0D6A01")!
    static let projectName = "Sermo 说明书"
    static let documentName = "Sermo 使用说明"

    struct Item: Sendable { let name: String; let how: String }
    struct Section: Sendable { let title: String; let items: [Item] }

    static let sections: [Section] = [
        Section(title: "核心新能力 · 1.44 正式版", items: [
            Item(name: "项目百万字本地文献库（按需检索）", how: "在项目主页点「添加文件」导入 Word、PDF、TXT、Markdown、EPUB 或代码资料，默认写入该项目专属的本地 SQLite 全文索引库（支持百万字规模与中文精准短语定位、保留 PDF 页码与 Word 章节锚点），不占用平时聊天额度；在文件抽屉里可即时搜索并预览原文，学习类 JSON 词库/阅读/313 历史资料也会自动识别入库。"),
            Item(name: "真实 Word / Excel / PDF 文档生成与版本管理", how: "在普通聊天或项目聊天里直接要求生成可下载的 .docx（含规范标题、表格与真实学术页下注）、.xlsx（多工作表）或 .pdf 文件，Sermo 会调用本地编译引擎生成真实附件条挂在回答上方，点击即可原生预览、分享或保存到「文件」；项目内生成的文件自动归档为「项目成果」，后续跨对话修改自动生成 v1 → v2 → v3 版本，绝不覆盖你导入的原始文献。"),
            Item(name: "工作过程时间线与中途插话", how: "AI 执行联网搜索、项目文献检索、沙盒自检或生成文档时，聊天正文只保留一行清爽的灰色进度摘要；点一下滑出底部「工作过程」抽屉，以连续时间线展示每一步工具调用与详情。运行期间可直接在输入框发消息插话补充要求，也可在抽屉顶部暂停或停止。"),
            Item(name: "受控 JS 与网页沙盒自检", how: "AI 编写 HTML/SVG 交互页或做结构化计算时，可先在独立安全沙盒中运行验证并捕获脚本错误，自动修好后再把网页预览卡片交付给你，超时会自动熔断保护主界面不卡死。"),
            Item(name: "Google 云盘每日自动全量历史备份", how: "在「设置 → 备份与数据 → 谷歌云盘全量备份」中登录 Google 账号即可开启。每日自动将全部对话、项目指令/记忆/文献库、项目成果、考研学习库、书架与偏好按时间戳完整上传至 Google Drive 的 /Sermo Backups/ 目录，默认永不自动删除历史版本；换机或重装后登录同一 Google 账号即可一键恢复。所有 API Key 与登录令牌均绝不写入备份包。"),
            Item(name: "系统分享一键入库与快捷指令", how: "在微信、Safari、备忘录或「文件」中点系统共享选择 Sermo（或使用系统快捷指令动作），会弹出轻量收纳卡，一键把网页链接、文字、文档或图片放进当前对话待发送，或直接存入指定项目的文献检索库。"),
            Item(name: "免费系统中文朗读兜底与口述抽背", how: "点回答下方小喇叭即可朗读：已配置付费语音 Key 时走高拟真 AI 语音；未配置或离线时自动无缝使用苹果原生免费中文语音朗读（优先本机增强音色，且不再压低其他 App 的音乐音量）。输入框支持语音口述转文字，313 历史与考研政治项目支持直接口述抽背判分。"),
            Item(name: "全新 Claude 风格项目主页与顶栏导航", how: "项目主页采用极简浅纸灰画布、三枚轻描边横向胶囊（添加文件 / 添加指令 / 查看记忆）、无框自然「最近」对话列表与右下角独立深色「+ 新建会话」胶囊；进入项目对话后，左上角显示「<」和项目名称双液态玻璃按钮，一眼区分所属项目并一键直返项目主页。"),
            Item(name: "百轮长对话流畅度与 iPhone Air 适配", how: "输入区、流式输出与历史消息列表彻底解耦，百轮长对话打字、滚底与切换流畅不卡顿；完整适配 iPhone Air 安全区与底部输入框间距，并在「用量明细」中同时保留统计总览与每日活跃方格子热力图。"),
        ]),
        Section(title: "模型、联网与统一工具", items: [
            Item(name: "多服务统一工具与识图底座", how: "DeepSeek、ChatGPT 订阅、Colab 与「其他模型（兼容端点）」已统一接入工具调度与识图能力。Flash、ChatGPT 订阅、Colab 与兼容模型支持直接看图；DeepSeek V4 Pro 发图时会自动通过 OCR 提字并缓存记忆，后续追问不失忆。"),
            Item(name: "ChatGPT 订阅完整思考档位", how: "支持自动（Auto）、不思考（None）、极轻（Minimal）、低（Low）、中（Medium）、高（High）、超高（XHigh）、极限（Max），自动按 OpenAI 返回的真实清单列出当前模型支持的档位。"),
            Item(name: "分模型联网通道与来源抽屉", how: "在「设置 → 工具与联网 → 联网通道」可为各服务分别指定联网方式：ChatGPT 订阅默认走 OpenAI 原生联网（不消耗 DeepSeek 余额），DeepSeek 走多轮自适应深度搜索（Explore），其他模型默认直读你发的链接也可借用已配置的搜索通道。带引用的回答下方会显示「N 个来源 ›」，点开以底部抽屉列出站点标题与摘要并可直达原网页。"),
            Item(name: "Artifacts 独立预览卡片", how: "AI 写出 HTML / SVG 网页或长代码块时，聊天流里默认收起为精致的圆角预览卡片；点开可全屏查看、一键切换「预览 / 代码」、复制源码或导出文件。长文字回答也可点「独立文稿预览」沉浸阅读。"),
            Item(name: "谷歌云盘工具与 GitHub 工具", how: "在「设置 → 授权与连接」登录 Google 云盘或粘贴 GitHub 细粒度令牌后，可在项目「⋯ → 编辑详情」中按需开启。支持搜索/读写云盘文档、检索代码仓库、在 sermo/ 分支提交、开 PR 及查询 GitHub Actions 编译状态（不碰默认分支）。"),
            Item(name: "写入前确认与切后台保活", how: "所有对云盘或 GitHub 的新建、修改、移动、移到回收站、提交或开 PR 操作都会先在对话内弹出审批卡片，点「允许」才执行，没有永久删除。回答生成或执行工具期间临时切去其他 App 时会自动向系统申请后台保活，减少中途断连。"),
        ]),
        Section(title: "聊天与效率", items: [
            Item(name: "指令优先级契约", how: "Sermo 严格按三级优先级决定说话规则：① 当前对话单独选用的系统指令、书架「本局玩法」或讨论页「问角色」最高；② 所属项目的「指令与记忆」次之（项目内对话不叠加全局默认提示词）；③ 普通独立对话使用「全局默认提示词」。"),
            Item(name: "斜杠「/」快捷指令与上下文水位", how: "输入框开头打「/」会浮出快捷胶囊（/深搜、/浓缩、/做梦、/考词、/周报、/指令），点一下立即触发。输入框上方实时显示上下文水位百分比、预估 Token 与缓存命中率；输入 /浓缩 可无损提炼长对话前情提要（不丢早期消息、不重复算尾部对话），大幅省额度。"),
            Item(name: "添加内容与多格式文件解析", how: "点输入框左下角「+」展开指令、图片、文件、粘贴、权限与语音输入。纯本地解析器直接支持 Word（.docx，精准保留毕业论文页下注并剔除修订删除线废稿）、Excel（.xlsx）、PPT（.pptx）、PDF（扫描件可用 DeepSeek OCR 识字）、EPUB、RTF、TXT、Markdown、代码、ZIP 与 IPA 包，以及最多 4 张图片。"),
            Item(name: "模型药丸、手动联网与停止", how: "输入框下方药丸切换模型与思考深度；旁边的地球图标一键开关手动联网；生成期间发送键变为停止键，向上翻看历史消息时正上方浮出液态玻璃向下箭头一键回底。"),
            Item(name: "消息操作与左滑看时间", how: "回答下方提供复制、朗读、编辑、重新生成等常用图标，长按任意消息可复制、选择部分文字、收藏、编辑或生成「他在想什么」第一人称心声。轻轻把消息往左一拖，右侧丝滑浮现发送/回复时间，松手自动回弹。"),
            Item(name: "旧答案版本、搜索、收藏与导出", how: "普通聊天重试或改问题重发都会保留旧路径，点右上角「⋯ → 旧答案」可随时切回；「⋯」里还可搜索本对话、查看本对话收藏、重命名、置顶、移到项目、切换排版样式或导出为 Markdown。"),
            Item(name: "猜你想说与思考过程", how: "答完后输入框会以灰字给出一条回复建议（直接发送、点一下编辑、或点上方「换一条」），可在「设置 → 聊天与指令」里开关。回答上方的思考行可点开查看完整推理，并支持切换原文、中文或双语。"),
        ]),
        Section(title: "项目与纯角色扮演", items: [
            Item(name: "项目主页三入口", how: "侧栏进入「项目」可新建或固定项目到侧栏。项目主页顶部保留返回、项目名、图钉与「⋯」，下方三枚轻描边胶囊分别为「添加文件」（管理文献检索库与随提问附带资料）、「添加指令」（独立圆角多行编辑页，右上角深色 ✓ 保存）与「查看记忆」（查看项目跨对话记忆与自动整理开关；学习项目进入学习档案）。"),
            Item(name: "项目内聊天导航与成果管理", how: "在项目内打开或新建会话后，顶栏左上角固定显示「<」与「项目名」双液态玻璃按钮，点任一个都能直接返回该项目主页；当本对话或项目已产出 Word/Excel/PDF 成果时，右上角会显示文档图标，且随时可从「⋯ → 项目成果与文献库」查看所有历史版本与检索原文。"),
            Item(name: "项目右上角「⋯」菜单", how: "精简为三项原生选项：①「编辑详情」（集中管理项目改名、AI 调整项目设定、默认服务/模型/思考档位、学习科目、纯角色扮演模式、联网/云盘/GitHub 工具开关、时间流逝感知与面容 ID 锁）；②「项目成果与文献检索」；③ 带二次确认的「删除」。"),
            Item(name: "纯角色扮演模式（注意工具开关）", how: "在对话右上角「⋯」或项目「⋯ → 编辑详情」中打开后，系统会主动屏蔽 Word/Excel/PDF 文档生成、联网、云盘、GitHub 与内置规范，也不回传旧思考过程，只保留人设指令、资料、记忆与时间流逝感知以专注沉浸演绎。如果需要在该对话里生成可下载的 Word / Excel / PDF 文件，只需在右上角「⋯」或项目「编辑详情」关闭「纯角色扮演模式」即可立即恢复。"),
            Item(name: "让 AI 帮我建 / 调整项目", how: "项目列表右上角「+ → 让 AI 帮我建」用一句话生成项目名称、指令与记忆设定，确认后创建；已有项目在「⋯ → 编辑详情 → 让 AI 帮我调整项目设定」中局部修改，不动原有资料与记忆。"),
            Item(name: "项目记忆与 Auto-Dream 整理", how: "在项目主页点「查看记忆」可开关「自动整理项目记忆」或手动增删改（最多 4000 字），也可在聊天里发 /做梦 触发 Auto-Dream 合并重复条目、清理过时状态并优先保留你手改的内容。项目记忆与原始文献库、生成的文件成果彼此独立。"),
            Item(name: "面容 ID 锁与提示词变量", how: "在项目「编辑详情」可开启面容 ID 锁，切后台自动重新上锁。指令里支持 {{时间}}、{{日期}}、{{星期}}、{{名字}}、{{模型}} 变量，开启「告诉角色时间流逝」后会在新开场或隔两小时以上时悄悄提示间隔时长。"),
        ]),
        Section(title: "考研学习（英语 / 313 历史 / 政治）", items: [
            Item(name: "三个专属学习项目", how: "侧栏项目中进入考研英语、313 历史或考研政治即可在聊天里开始学习。各科学习数据独立存储，项目内多个对话窗口和不同模型共用同一份进度与薄弱点记录。"),
            Item(name: "导入私人词库与复习资料", how: "在学习项目的「添加文件」或「学习档案」里直接导入英语词库 JSON、阅读 JSON、313 历史参考资料或临时学习地图（自动识别格式入库），政治可直接拍纸质题发送。相同 ID 同内容可重复导入，不同内容防误覆盖。"),
            Item(name: "背词、精读、口述抽背与周报", how: "英语支持按单元背词与逐篇阅读精读（进度与纠错按工具回执落盘）；313 历史与政治支持专题梳理、语音口述抽背、错题与薄弱点追踪；在「学习档案」中可随时生成本周学习周报与今日语音复习提示词。删除学习项目时本地学习记录会自动归档，可在项目列表右上角「+ → 恢复学习项目」找回。"),
        ]),
        Section(title: "数据安全与备份", items: [
            Item(name: "Google 云盘每日全量自动备份（首选）", how: "在「设置 → 备份与数据 → 谷歌云盘全量备份」登录 Google 账号后自动按天留存历史版本到 /Sermo Backups/，覆盖聊天、项目、文献库、项目成果、学习库、书架与设置，默认永久保留历史包不覆盖，上传与恢复均做 SHA-256 完整性校验，恢复前先自动保留本机应急快照。不含 API Key 与登录凭证。"),
            Item(name: "本机自动备份与手动 .sermobackup", how: "每天首次打开自动存一份带时间戳的备份到「文件 → 我的 iPhone → Sermo → 自动备份」，也可另选同步文件夹额外存一份；在「设置 → 备份与数据」随时手动导出或导入 .sermobackup 全量包，备份完整保留所有界面与模型偏好键（不含 API Key、登录凭证和自定义字体）。"),
            Item(name: "考研学习专项备份", how: "设置 → 备份与数据 → 学习备份可单独管理学习库与关联题目图片的 Drive 版本；图片自动按长边 1280px 压缩，恢复前可预览项目、记录与图片数量并先保留本机旧版。"),
        ]),
        Section(title: "侧栏、用量与个性化设置", items: [
            Item(name: "侧栏与全部对话管理", how: "普通聊天点左上角按钮或从屏幕左边缘向右滑打开侧栏；项目聊天也可从左边缘右滑或点右上角「⋯ → 打开历史侧栏」。侧栏置顶对话常驻顶部，「查看全部」支持多选批量移入项目或删除，左下角头像直达设置。"),
            Item(name: "用量明细与每日方格子热力图", how: "「设置 → 用量明细」支持切换「近7天 / 本月 / 近30天 / 全部」，展示全平台总览、专属 ChatGPT 订阅明细（对话次数、新输入、缓存命中与命中率、实际输出及等效参考量）、每日用量方格子热力图（用得越多颜色越深）以及 DeepSeek 高峰/空闲时段估价，支持导出 CSV。"),
            Item(name: "三套主题、字体与外观精调", how: "「设置 → 个性化」支持一键切换纸笺（支持跟随系统/浅色/深色）、瑞士和夜江三套主题，可细调字号、正文加粗、行距、留白、气泡与配色，并支持导入本地 .ttf / .otf 自定义字体（字体不进备份）。"),
            Item(name: "系统指令库、功能搜索与关于", how: "「设置 → 聊天与指令 → 系统指令库」可保存最多 100 份常用指令并随备份同步；「设置 → 功能一览」支持关键词秒搜全部功能；设置右上角「i」可查看并复制当前版本号与构建号。"),
        ]),
        Section(title: "本地书架与小说阅读", items: [
            Item(name: "导入小说与全屏本地阅读", how: "侧栏「书架」点右上角「+」（或在「文件」共享给 Sermo）导入未加密 TXT / EPUB（自动识别 UTF-8/GBK/Big5，最大 40 MB 并自动分章，正文存本机不进聊天备份）。点书进详情再点「阅读原文」进入全屏阅读器，全文搜索完全在本地完成。"),
            Item(name: "阅读排版、翻页、书签与音量键", how: "轻点屏幕中间呼出菜单，可调字体、字号、行距、纸色与亮度，支持横竖屏锁定、滚动或左右翻页、音量键翻页、目录/进度跳转后「回到刚才」返回原位、长按加书签写备注并导出 Markdown，以及长按任意段落点「问问这一段」直接带原文发起讨论。"),
            Item(name: "AI 读书精读与完整书架备份", how: "在书籍详情点「开始阅读」让 AI 分章梳理人物档案、作者笔触、原文片段与名场面，支持中途暂停续读、单个人物精读、文风精读与本地免费台词库提取；书架右上角硬盘图标可随时导出或恢复含正文、笔记、故事线与图片的完整书架备份。"),
        ]),
        Section(title: "原著讨论与角色扮演", items: [
            Item(name: "讨论这本书与讨论里问角色", how: "在书页点「讨论这本书」可围绕整本书的人物、伏笔和主题展开讨论（自动检索本地完整原文并在下方附「本次书内依据」供核对，不影响任何角色扮演进度）。点输入框上方「问角色」可指定某位人物以第一人称只回答这一问，发完自动恢复普通讨论。"),
            Item(name: "选人物开聊、剧情走向与导演控制", how: "在书页点「选一个人物开聊」选定角色、时间点（章节或名场面）、你扮演的身份（支持「我的人物卡」）以及最多 3 位跨书客串人物；开聊后顶部可随时切换「遵从原著 / 依托原著改写 / 自由发挥」，「⋯ → 剧情控制、记忆与存档」管理本局记忆、命名存档、开平行分线、群像点名与故事档案对比。"),
            Item(name: "原著演出微调", how: "长按人物回答可查看「他在想什么」第一人称内心独白（不写进剧情），或点「这里不像…」把你的纠正记进人物卡，后续每局自动生效；「⋯ → 本局设定」随时微调本局玩法与前情提要。"),
        ]),
    ]

    /// The document text the manual project hands to the model.
    static var document: String {
        var lines = ["以下是 Sermo 这个 App 的使用说明。用户问怎么用时，根据它回答：说清入口在哪、按什么顺序操作，尽量简短。说明里没有的功能，直接说目前没有，不要编造。", ""]
        for section in sections {
            lines.append("【\(section.title)】")
            for item in section.items { lines.append("- \(item.name)：\(item.how)") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// The project as it is first created; later only its document is kept current.
    static func newProject() -> ChatProject {
        var project = ChatProject(id: projectID, name: projectName)
        project.instructions = "你是 Sermo 的使用向导，回答用户关于这个 App 怎么用的问题。"
        project.documents = [ProjectDocument(name: documentName, text: document)]
        project.model = .flash
        project.thinkingEnabled = false
        project.isPinned = true
        return project
    }

    /// Brings the manual document of an existing project up to date, keeping the
    /// user's own instructions and other documents. Nil when nothing changed.
    static func refreshed(_ project: ChatProject) -> ChatProject? {
        var next = project
        if let index = next.documents.firstIndex(where: { $0.name == documentName }) {
            guard next.documents[index].text != document else { return nil }
            next.documents[index].text = document
        } else {
            next.documents.insert(ProjectDocument(name: documentName, text: document), at: 0)
        }
        while next.includedCharacters > ChatProject.documentCharacterLimit {
            if let extraIndex = next.documents.lastIndex(where: { $0.name != documentName && $0.isIncluded }) {
                next.documents[extraIndex].isIncluded = false
            } else if let manualIndex = next.documents.firstIndex(where: { $0.name == documentName && $0.isIncluded }) {
                next.documents[manualIndex].isIncluded = false
            } else {
                break
            }
        }
        next.updatedAt = Date()
        return next
    }
}
