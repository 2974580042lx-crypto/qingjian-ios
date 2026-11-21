# Sermo

自用的 iOS 聊天 App（DeepSeek / ChatGPT 订阅通道 / 兼容端点），SwiftUI，自签安装。

- 当前版本：**1.46.0（build 89）**
- 源码：[`QingJian/`](QingJian/)（Xcode 工程由脚本生成，不手改）
- 旧的开发日志和审阅文档：[`docs/archive/`](docs/archive/)

## 改代码的流程

1. 改 `QingJian/DeepSeekPocket/` 下的源码。新增或删除 Swift 文件后，运行：
   ```
   python QingJian/scripts/generate-project.py
   python QingJian/scripts/check-project.py
   ```
2. 发版时在 `QingJian/scripts/generate-project.py` 里改 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`，再运行一次上面两条。
3. 推送到任意分支。只要改到了 `QingJian/`，GitHub Actions 的 **Build Sermo** 就会自动跑：
   - **ipa**：Release 编译，产物 `Sermo-版本-build号-unsigned-IPA`，在这次运行页面底部下载；
   - **tests**：离线单元测试（`swift test --skip StudyLiveModelTests`）。测试变红不会挡住 IPA，但装机前先看一眼。
4. 想在 main 以外的分支先试，推到 `sermo/xxx` 分支即可，同样会出 IPA。

不再需要 zip、overlay 和 manifest：源码就是仓库里的文件本身。

## 装机前检查（每次必做）

1. 设置里导出一份完整备份（.sermobackup）存到「文件」，并在「本机数据状态」截图记下对话数和项目数。
2. 装好后先打开「本机数据状态」对数字，再随便点开几个老对话确认内容都在。
3. 过一天确认自动备份文件夹里有当天的新备份。
