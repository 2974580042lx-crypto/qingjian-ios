import SwiftUI
import UniformTypeIdentifiers

// Google account for the Drive tools. Sign-in acts at once, like the ChatGPT section.
@MainActor
struct GoogleDriveSection: View {
    @ObservedObject var drive: GoogleDriveStore
    var body: some View {
        Section {
            LabeledContent("账号", value: drive.accountLabel)
                .accessibilityIdentifier("google-account")
            if drive.signingIn {
                HStack { ProgressView(); Text("请在谷歌页面登录并允许访问云盘").font(TypeScale.serif(17)) }
                Button("取消登录") { drive.cancelSignIn() }
            } else {
                Button(drive.connected ? "重新登录谷歌" : "用 Google 登录") { drive.signIn() }
                    .accessibilityIdentifier("google-sign-in")
            }
            if drive.needsSignIn && !drive.connected {
                Text("登录已过期，请重新登录。测试状态的谷歌应用大约每 7 天需要登录一次。")
                    .font(TypeScale.serif(13)).foregroundStyle(.secondary)
            }
            if let issue = drive.issue { Text(issue).font(TypeScale.serif(15)) }
            if drive.connected {
                Button("退出谷歌账号", role: .destructive) { drive.signOut() }
            }
        } header: { Text("谷歌云盘") } footer: {
            Text("在项目「⋯」里打开「谷歌云盘工具」后，这个项目里的对话可以搜索、读取和整理你的云盘。新建、改写、改名、移动和移到回收站都会先请你确认；不会永久删除文件。登录凭证保存在本机钥匙串，不进入聊天备份。")
        }
    }
}

// Daily backup into the app's own folder, plus an optional extra copy in a picked folder.
@MainActor
struct AutoBackupSection: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Section {
            LabeledContent("备份到", value: BackupFolder.localLocation)
            LabeledContent("上次备份", value: store.lastAutoBackup.map {
                $0.formatted(date: .abbreviated, time: .shortened)
            } ?? "尚未备份")
            Button("立即备份") { store.autoBackupIfNeeded(force: true) }
                .disabled(!store.canPersist)
            if let name = store.backupFolderName {
                LabeledContent("额外存一份到", value: name)
                Button("更换额外文件夹") { chooseFolder() }
                Button("不再额外存一份", role: .destructive) { store.clearBackupFolder() }
            } else {
                Button { chooseFolder() } label: { Label("额外存一份到其他文件夹", systemImage: "folder.badge.plus") }
            }
            if let issue = store.backupIssue { Text(issue).font(TypeScale.serif(13)).foregroundStyle(.secondary) }
        } header: { Text("自动备份") } footer: {
            Text("每天第一次打开 Sermo 时自动生成一份完整备份（.sermobackup，包含聊天、项目、指令库、学习进度、书架档案与人物卡，不含小说正文），存进「文件」App 的「我的 iPhone › Sermo › 自动备份」。想在 iCloud 云盘等地方再存一份，可另选一个文件夹。自动保留最近 7 份；不含 API Key 和登录凭证。")
        }
    }
    private func chooseFolder() {
        DocumentPicker.presentFolder(onError: { store.errorMessage = $0 }) { url in store.setBackupFolder(url) }
    }
}

// A fine-grained personal access token for the GitHub tools.
@MainActor
struct GitHubSection: View {
    @ObservedObject var github: GitHubClient
    @State private var draft = ""
    var body: some View {
        Section {
            LabeledContent("账号", value: github.accountLabel)
            if !github.connected {
                SecureField("粘贴 GitHub 令牌", text: $draft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("github-token")
                Button(github.checking ? "正在核对…" : "连接 GitHub") {
                    Task { await github.connect(token: draft); if github.connected { draft = "" } }
                }
                .disabled(github.checking || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Link("在 GitHub 生成令牌", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
            } else {
                Button("断开 GitHub", role: .destructive) { github.disconnect() }
            }
            if let issue = github.issue { Text(issue).font(TypeScale.serif(15)) }
        } header: { Text("GitHub") } footer: {
            Text("生成「细粒度令牌」（Fine-grained token）时，只选需要的仓库，权限勾选 Contents、Pull requests 为读写，Actions 为只读。在项目「⋯」里打开「GitHub 工具」后，模型可以读代码、在 sermo/ 开头的分支上提交、开 PR、看编译结果；不会改动默认分支，提交和开 PR 前都会请你确认。令牌只存在本机钥匙串。")
        }
    }
}

// Font for the whole app: built-in serif, system PingFang, or an imported .ttf/.otf.
@MainActor
struct FontSettingsRows: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage(FontLibrary.choiceKey) private var choice = ""
    @AppStorage(FontLibrary.revisionKey) private var revision = 0
    private var current: FontChoice { _ = (choice, revision); return FontLibrary.choice }
    var body: some View {
        Picker("字体", selection: Binding(get: { current }, set: { value in
            if value == .custom && FontLibrary.regularName == nil { importFont(bold: false); return }
            choice = value.rawValue
        })) {
            ForEach(FontChoice.allCases) { Text($0.title).tag($0) }
        }
        .accessibilityIdentifier("font-choice")
        .accessibilityValue(current.title)
        if current == .custom || FontLibrary.regularName != nil {
            if let name = FontLibrary.regularName { LabeledContent("常规", value: name) }
            if let name = FontLibrary.boldName { LabeledContent("粗体", value: name) }
            Button("导入常规字体") { importFont(bold: false) }
            Button(FontLibrary.boldName == nil ? "导入粗体（可选）" : "更换粗体") { importFont(bold: true) }
                .disabled(FontLibrary.regularName == nil)
            Button("删除导入的字体", role: .destructive) { FontLibrary.removeCustomFonts() }
                .disabled(FontLibrary.regularName == nil)
        }
        Text("切换或导入后界面会刷新一次。导入的字体只保存在这台手机上，不进备份。瑞士风格下固定用系统黑体，换回纸笺后恢复这里选的字体。")
            .font(TypeScale.serif(13)).foregroundStyle(.secondary)
    }
    private func importFont(bold: Bool) {
        let types = [UTType.font] + ["ttf", "otf"].compactMap { UTType(filenameExtension: $0) }
        // Tick a font, then 「打开」: a single tap on a font file previews it instead of picking it.
        // The picker hands over a private copy, removed once it has been read.
        DocumentPicker.presentMany(types, asCopy: true, onError: { store.errorMessage = $0 }) { urls in
            guard let url = urls.first else { return }
            defer { for copy in urls { try? FileManager.default.removeItem(at: copy) } }
            do {
                try FontLibrary.importFont(from: url, bold: bold)
            } catch { store.errorMessage = "无法导入字体：\(error.localizedDescription)" }
        }
    }
}
