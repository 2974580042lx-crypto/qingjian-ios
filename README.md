# 青笺 1.2.0 · 个人聊天客户端

版本 1.2.0，build 7。最低 iOS 26；Bundle ID 保持 com.xiaolong.qingjian。

- 底部仅聊天和设置，两处浮动控件共用原生 clear Liquid Glass 材质。
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
