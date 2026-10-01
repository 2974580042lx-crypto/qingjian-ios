# 青笺 1.3.0 · 个人聊天客户端

版本 1.3.0，build 14。最低 iOS 26；Bundle ID 保持 com.xiaolong.qingjian。

- 侧栏与聊天页采用两层整页连续圆角，边界涵盖安全区，随拖动渐变；侧栏为图标列表，按置顶和最近分组，并提供个人资料与设置入口。
- 玻璃控件直接使用系统 Liquid Glass，移除人工叠加的黑色衬底；输入框和底栏继续悬浮在整屏内容之上。
- 聊天列表延伸到屏幕底部，输入框与底栏采用悬浮覆盖；通过内容边距保留最后一行的阅读空间。
- 聊天内容区从任意横向位置右滑可展开侧栏，左滑收起，滑动过程跟手；区分横向拖动与纵向滚动，输入控件区保留自身手势。
- 展开和收起侧栏触发轻微触感反馈，可在设置中关闭；模拟器不能验证实际马达手感。
- 相册图片上传尚未接入聊天，加号仍为文字相关操作。
- 空白首页只保留居中英文时间问候：05:00–11:59 Good morning，12:00–17:59 Good afternoon，其余时间 Good evening。按手机本地时间每分钟刷新；无引导文案、图标或推荐问题按钮。
- 输入框提示改为“输入消息…”，侧栏与空对话不再使用抒情文案。
- 底部仅聊天和设置，底栏恢复系统原生 TabView，保留系统按住拖动选择行为；输入框使用原生 regular Liquid Glass 材质。
- 聊天顶部显示 DeepSeek；侧栏新建对话使用简洁文字按钮。
- 设置顶部显示自己的头像、名字和 ID，支持系统照片选择器；资料只存本机。
- 输入框思考菜单可开关思考，并直接选择轻量、标准、深入。
- 每条回答只展示服务端返回的本次总 Token；不存在用字符数冒充 Token。
- 默认上下文 200 条，最高 400 条，超长时保留最近完整消息；UTF-8 请求正文采用保守容量限制，不冒充精确 Token 计算。
- 思考过程等回答结束后再按需翻译，支持原文、中文、双语；缓存译文随对话备份保存。
- 翻译使用当前 Key 和 Flash 模型，关闭思考；单独请求会产生额外 API 用量。译文不进入正式聊天上下文。
- 保留宋体、消息编辑、重新回答、历史搜索、置顶、改名与备份。
- 收藏界面已移除，旧备份中的收藏标记仍保留；头像资料不包含在聊天备份中。

源码未包含 API Key 或签名材料。运行 scripts/build-ipa.sh 会检查结构、运行测试、使用 Xcode 26 编译并生成未签名 IPA。设置 QINGJIAN_CAPTURE_PREVIEWS=1 时从实际模拟器捕获界面，预览模式只使用虚构数据且不联网。

已有用户先导出重要聊天记录，再沿用原证书和 Bundle ID 签名覆盖安装。云端测试与模拟器截图不等同于手机上的真实 API 调用验证。

历史验证材料只描述相应旧版本。当前验证以本次 Actions 日志和安装包核验为准。

参考：
- DeepSeek 思考参数：https://api-docs.deepseek.com/zh-cn/guides/thinking_mode/
- DeepSeek 上下文能力：https://api-docs.deepseek.com/zh-cn/quick_start/pricing/
- Apple Liquid Glass：https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views

界面回归验证：UITests/NavigationUITests.swift 使用真实模拟器触摸事件检查右半屏起滑、全高纵向滚动、最后一行可读性及键盘布局。截图脚本同时导出测试附件与 xcresult 摘要。

交互回归还验证了发送新消息后的自动滚动位置。侧栏显示状态以实际可操作性判定，隐藏但留在可访问性树中的按钮不算可见侧栏。

长对话自动跟随使用系统 ScrollPosition 的底部定位，避免按末尾虚拟占位元素定位时跳入懒加载估算的空白区域。

聊天列表按实际高度布局，默认显示最近 100 条，顶部可继续查看更早消息；此显示分页不影响记录保存和 API 上下文数量。侧栏使用系统水平拖动识别器，在开始识别前排除纵向手势，避免移动页面时取消正在进行的侧栏拖动。


本轮连接与交互修复：
- 恢复真正的系统 TabView，移除替代它的自绘底部按钮；侧栏手势不截获 UITabBar 的触摸。
- 聊天区区分正在连接、等待模型、正在思考、正在回答，并显示耗时和实际收到的思考字数。
- 请求和会话均显式设置 600 秒无数据超时、1800 秒总时限；支持 DeepSeek 等待期间的 SSE keep-alive。不自动重试或降低用户的思考档位。
- 设置页增加实际对话测试：当前 Key、Flash、关闭思考、独立小请求，不发送历史聊天，会产生少量 API 用量。
- 可复制不含 Key 和正文的连接诊断，包含模型、请求参数、阶段、字节数和错误码。余额查询成功不等于实际对话已经验证。
- 从设置返回聊天不再每次强制跳到最后，保留当前阅读位置。
- 网络回归使用 URLSession + URLProtocol 固定数据验证等待、思考、输出、取消、鉴权与中断；不使用真实 Key。
- UI 回归新增实际按住并拖动原生 TabBar 在聊天和设置之间切换。

Telegram iOS 交互参考（独立实现，没有复制其框架代码）：
- 输入框、键盘与内容区域统一计算：https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Sources/ChatControllerNode.swift#L2287-L2308
- 阅读位置与返回底部控件：https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Sources/ChatControllerNode.swift#L2654-L2674
- 编辑状态包括光标选择范围：https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/AccountContext/Sources/ChatController.swift#L425-L465
后续适合补齐草稿光标位置、加载更早记录时的阅读锚点；不引入 Telegram 的社交功能或大型自绘 UI 框架。

等待期间 keep-alive 依据：https://api-docs.deepseek.com/zh-cn/quick_start/rate_limit/
本版不能仅凭模拟测试断言手机与服务商之间的真实对话已恢复；安装后使用实际对话测试确认。
