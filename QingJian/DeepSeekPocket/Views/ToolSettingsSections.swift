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
    @StateObject private var systemPickers = DocumentPicker()
    @EnvironmentObject private var store: AppStore
    @State private var exportingToFolder = false
    var body: some View { pickerContent.systemPickerHost(systemPickers) }

    @ViewBuilder private var pickerContent: some View {
        Section {
            LabeledContent("备份到", value: BackupFolder.localLocation)
            LabeledContent("上次备份", value: store.lastAutoBackup.map {
                $0.formatted(date: .abbreviated, time: .shortened)
            } ?? "尚未备份")
            Button("立即备份") { store.autoBackupIfNeeded(force: true) }
                .disabled(!store.canPersist)
            Button {
                exportBackupToFolder()
            } label: {
                HStack {
                    Label("立即备份并另存到文件夹…", systemImage: "square.and.arrow.down.on.square")
                    if exportingToFolder {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(!store.canPersist || exportingToFolder || store.unifiedBackupBusy)
            if let name = store.backupFolderName {
                LabeledContent("额外存一份到", value: name)
                Button("更换额外文件夹") { chooseFolder() }
                Button("不再额外存一份", role: .destructive) { store.clearBackupFolder() }
            } else {
                Button { chooseFolder() } label: { Label("额外存一份到其他文件夹（左侧勾选后点打开）", systemImage: "folder.badge.plus") }
            }
            if let issue = store.backupIssue { Text(issue).font(TypeScale.serif(13)).foregroundStyle(.secondary) }
        } header: { Text("本机自动备份") } footer: {
            Text("每天第一次打开 Sermo 时自动生成一份完整备份（.sermobackup，包含聊天、项目、指令库、内置文档规范与学习进度），存进「文件」App 的「我的 iPhone › Sermo › 自动备份」。\n• 想手动把备份存进任意目录：点「立即备份并另存到文件夹…」，直接点进目标文件夹后按右上角「存储」。\n• 想设置每日自动同步目录：点「额外存一份到其他文件夹」，在列表中勾选文件夹左侧圆圈（不要点进文件夹内部），再点右上角「打开」。按时间戳保存最近 7 份版本；不含 API Key 和登录凭证。")
        }
    }
    private func chooseFolder() {
        systemPickers.presentFolder(onError: { store.errorMessage = $0 }) { url in store.setBackupFolder(url) }
    }
    private func exportBackupToFolder() {
        guard !exportingToFolder else { return }
        exportingToFolder = true
        Task { @MainActor in
            let url = await store.exportUnifiedBackup()
            exportingToFolder = false
            guard let url else { return }
            let cleanupTemp: () -> Void = {
                if url.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            systemPickers.presentExport(
                url,
                onCancel: cleanupTemp,
                onError: { err in cleanupTemp(); store.errorMessage = err },
                onSaved: { savedURL in
                    cleanupTemp()
                    store.noticeMessage = "已将完整备份存入「\(savedURL.deletingLastPathComponent().lastPathComponent)」。"
                }
            )
        }
    }
}

@MainActor
struct DriveFullBackupSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var backup: DriveFullBackupController
    @ObservedObject var drive: GoogleDriveStore

    var body: some View {
        Section {
            LabeledContent("状态", value: backup.statusSummary)
            LabeledContent("云盘目录", value: drive.connected ? "/\(DriveFullBackupClient.folderName)/" : "登录后自动建立")
            if drive.connected {
                Toggle(
                    "每日自动备份到 Google 云盘",
                    isOn: Binding(get: { backup.state.enabled }, set: { backup.setEnabled($0) })
                )
                .tint(Ink.seal)

                Button {
                    backup.checkDailyBackupIfNeeded(force: true)
                } label: {
                    HStack {
                        Label("立即备份到 Google 云盘", systemImage: "icloud.and.arrow.up")
                        if backup.busy {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(backup.busy || !store.canPersist || store.unifiedBackupBusy)

                NavigationLink {
                    DriveBackupHistoryView(backup: backup)
                } label: {
                    HStack {
                        Label("云盘历史备份与恢复", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        if !backup.files.isEmpty {
                            Text("\(backup.files.count) 份")
                                .font(TypeScale.caption)
                                .foregroundStyle(Ink.ink3)
                                .monospacedDigit()
                        }
                    }
                }
            } else {
                Button("登录 Google 云盘开启自动备份") { drive.signIn() }
            }
            if let err = backup.issue ?? backup.state.lastError, !err.isEmpty {
                Text(err)
                    .font(TypeScale.ui(13))
                    .foregroundStyle(Ink.seal)
            }
        } header: {
            Text("Google 云盘每日自动全量备份")
        } footer: {
            Text("每天打开或回到 Sermo 时自动检查并上传一份带时间戳的完整备份（覆盖聊天、历史分支、项目、长期记忆、学习数据库、个人资料与设置），默认永久保留全部成功历史版本，绝不自动删除旧备份。\n• 隐私与恢复说明：采用免恢复密码直存标准包，重装、重签或换新手机后登录同一 Google 账号即可直接校验并恢复（恢复前自动留存本机快照，失败自动回滚）。API Key 与各类登录令牌绝不写入备份包；因备份文件未另设独立加密密码，请妥善开启 Google 账号两步验证，切勿对外共享 /Sermo Backups/ 文件夹。")
        }
    }
}

@MainActor
struct DriveBackupHistoryView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var backup: DriveFullBackupController
    @State private var confirmTrashTarget: StudyDriveFile?

    var body: some View {
        List {
            if backup.busy && backup.files.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在读取 Google 云盘历史备份…").foregroundStyle(Ink.ink2)
                    }
                }
                .claudeCardRow()
            } else if backup.files.isEmpty {
                Section {
                    Text("当前云盘 /Sermo Backups/ 目录下还没有完整备份记录。返回上一页点击「立即备份到 Google 云盘」即可生成第一份。")
                        .font(TypeScale.ui(14))
                        .foregroundStyle(Ink.ink3)
                        .padding(.vertical, 6)
                }
                .claudeCardRow()
            } else {
                Section {
                    ForEach(backup.files) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.name)
                                .font(TypeScale.ui(15, weight: .medium))
                                .foregroundStyle(Ink.ink)
                            HStack(spacing: 10) {
                                if let sizeBytes = item.size.flatMap(Int64.init) {
                                    Text(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
                                }
                                if let threads = item.appProperties?["threads"] {
                                    Text("\(threads) 条对话")
                                }
                                if let projects = item.appProperties?["projects"] {
                                    Text("\(projects) 个项目")
                                }
                                if item.appProperties?["complete"] == "0" {
                                    Text("部分超额图省略").foregroundStyle(Ink.seal)
                                }
                            }
                            .font(TypeScale.ui(12.5))
                            .foregroundStyle(Ink.ink3)

                            HStack(spacing: 16) {
                                Button {
                                    backup.prepareCloudRestore(item)
                                } label: {
                                    Text("校验并预览恢复")
                                        .font(TypeScale.ui(13.5, weight: .medium))
                                        .foregroundStyle(Ink.seal)
                                }
                                .buttonStyle(.plain)
                                .disabled(backup.busy || !store.canRestoreStudyBackup)

                                Spacer()

                                Button(role: .destructive) {
                                    confirmTrashTarget = item
                                } label: {
                                    Text("移入云盘回收站")
                                        .font(TypeScale.ui(13))
                                        .foregroundStyle(Ink.ink3)
                                }
                                .buttonStyle(.plain)
                                .disabled(backup.busy)
                            }
                            .padding(.top, 2)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("全部历史版本（默认永久保留，共 \(backup.files.count) 份）")
                } footer: {
                    Text("点击「校验并预览恢复」会先验证文件大小与 SHA-256 完整性，再弹出内容明细让你选择「合并恢复」或「完整覆盖恢复」。")
                }
                .claudeCardRow()
            }

            if let err = backup.issue, !err.isEmpty {
                Section {
                    Text(err).font(TypeScale.ui(13)).foregroundStyle(Ink.seal)
                }
                .claudeCardRow()
            }
        }
        .claudeGroupedListStyle()
        .navigationTitle("云盘历史备份")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    backup.refreshHistory()
                } label: {
                    if backup.busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(backup.busy)
            }
        }
        .onAppear {
            if backup.files.isEmpty { backup.refreshHistory() }
        }
        .confirmationDialog(
            "将这份旧备份移入 Google 云盘回收站？",
            isPresented: Binding(get: { confirmTrashTarget != nil }, set: { if !$0 { confirmTrashTarget = nil } }),
            titleVisibility: .visible
        ) {
            if let target = confirmTrashTarget {
                Button("移入回收站（30 天内可找回）", role: .destructive) {
                    backup.moveCloudBackupToTrash(target)
                    confirmTrashTarget = nil
                }
            }
            Button("取消", role: .cancel) { confirmTrashTarget = nil }
        } message: {
            Text(confirmTrashTarget?.name ?? "")
        }
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
    @StateObject private var systemPickers = DocumentPicker()
    @EnvironmentObject private var store: AppStore
    @AppStorage(FontLibrary.choiceKey) private var choice = ""
    @AppStorage(FontLibrary.revisionKey) private var revision = 0
    private var current: FontChoice { _ = (choice, revision); return FontLibrary.choice }
    var body: some View { pickerContent.systemPickerHost(systemPickers) }

    @ViewBuilder private var pickerContent: some View {
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
        Text("所选字体只作用于聊天正文，菜单、侧栏和设置界面始终保持清爽的系统字体。「内置宋体」将 Georgia 与思源宋体混排；导入的字体只保存在本机，不进备份。")
            .font(TypeScale.caption).foregroundStyle(.secondary)
    }
    private func importFont(bold: Bool) {
        let types = [UTType.font] + ["ttf", "otf"].compactMap { UTType(filenameExtension: $0) }
        // Tick a font, then 「打开」: a single tap on a font file previews it instead of picking it.
        // The picker hands over a private copy, removed once it has been read.
        systemPickers.presentMany(types, asCopy: true, onError: { store.errorMessage = $0 }) { urls in
            guard let url = urls.first else { return }
            defer { for copy in urls { try? FileManager.default.removeItem(at: copy) } }
            do {
                try FontLibrary.importFont(from: url, bold: bold)
            } catch { store.errorMessage = "无法导入字体：\(error.localizedDescription)" }
        }
    }
}
