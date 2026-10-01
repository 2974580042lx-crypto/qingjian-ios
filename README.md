# 青笺 · 个人 DeepSeek iPhone 客户端

这个私有仓库存放青笺的完整源码与 iPhone 云端编译流程。

2026-10-01 已完成 **1.0.1（build 2）** 云端构建：[成功的运行记录](https://github.com/2974580042lx-crypto/qingjian-ios/actions/runs/36877133795)。工作流运行核心测试并使用 Xcode 编译，已生成可供自行签名的 IPA。

下载后的安装包已通过 ZIP 完整性与 GitHub artifact 摘要核对，包含 iPhone arm64 可执行文件、应用资源，Bundle ID 为 `com.xiaolong.qingjian`。第一版已经在用户的 iPhone 上安装；新版安装及实际 DeepSeek API 调用需要在自己的设备上验证。

1.0.1 在设置页增加 **测试连接**：使用官方账户余额接口检查密钥，显示密钥有效、余额不足、密钥错误或网络问题。此操作不发送聊天内容；修改 Key 后会清除旧的验证结果。

## 下载与安装

1. 打开本仓库的 **Actions → Build iPhone IPA**。
2. 进入成功的运行记录，在 **Artifacts** 下载 **QingJian-unsigned-IPA**。
3. 解压后得到 `QingJian-unsigned.ipa`，使用自己的适用证书和描述文件签名安装。
4. 已安装第一版时，沿用原来的证书和 Bundle ID 覆盖安装；需要保留的聊天记录可先导出备份。
5. 打开青笺的设置，在手机上填写 DeepSeek API Key，点击 **测试连接** 查看结果，再点右上角 **保存**。
6. 回到聊天界面发送一条消息，验证实际聊天调用。

最低系统版本是 iOS 17。云端构建生成未签名 IPA；仓库与工作流都不需要 API Key、签名证书或证书密码。

## 源码位置

`QingJian-iOS-source.zip` 包含完整 Xcode 项目、SwiftUI 源码、图标、核心测试、构建脚本和详细说明。解压得到 `QingJian` 文件夹，可以打开其中的 `QingJian.xcodeproj`。

压缩包内的验证说明记录了上传前的本地检查；最新的云端构建结果以本仓库 Actions 运行记录为准。

根目录的 `.github/workflows/build-ios.yml` 会先解压源码，再运行 `QingJian/scripts/build-ipa.sh`。更新源码压缩包会自动启动新一次编译；也可以在 Actions 中手动运行工作流。构建日志作为 **QingJian-build-log** 保留七天。

## 功能

流式聊天、深度思考、停止与重新生成、自定义系统提示词、对话历史与搜索、JSON 备份和导入、设备钥匙串保存 API Key、密钥与余额验证，以及服务端返回的 tokens 用量。

当前以文字聊天为主。测试连接用于验证密钥和账户余额，实际模型回答仍需通过发送消息确认。
