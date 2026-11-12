import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
struct SettingsView: View {
    var embedded = false
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var profile: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var draftSettings = AppSettings()
    @State private var draftKey = ""
    @State private var backupURL: URL?
    @State private var showShare = false
    @State private var showImporter = false
    @State private var checkingConnection = false
    @State private var checkedBalance: AccountBalance?
    @State private var connectionError: String?
    @State private var connectionTask: Task<Void, Never>?
    @State private var showKey = false
    // A long default instruction stays folded to two lines until opened.
    @State private var promptExpanded = false
    @State private var saved = false
    @State private var loadedSettings = false
    @State private var showProfile = ProcessInfo.processInfo.arguments.contains("--preview-profile")
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { showProfile = true } label: {
                    HStack(spacing: 14) {
                        ProfileAvatar(image: profile.avatar)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name).font(TypeScale.serif(20).weight(.semibold))
                            Text(profile.handle.isEmpty ? "编辑个人资料" : "ID：\(profile.handle)").font(TypeScale.caption).foregroundStyle(Ink.ink3)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Ink.ink3)
                    }.padding(.vertical, 6)
                    }.buttonStyle(.plain)
                }.listRowBackground(Color.clear)
                Section {
                    NavigationLink { PersonalizationView() } label: { Label("个性化", systemImage: "paintpalette") }
                        .accessibilityIdentifier("settings-personalization")
                    NavigationLink { chatPage } label: { Label("聊天与指令", systemImage: "text.bubble") }
                }
                Section {
                    NavigationLink { deepSeekPage } label: {
                        HStack {
                            Label("DeepSeek", systemImage: "key")
                            Spacer()
                            Text(draftKey.isEmpty ? "未填写" : "已填写 Key").font(TypeScale.caption).foregroundStyle(Ink.ink3)
                        }
                    }
                    NavigationLink { ColabSettingsView(colab: store.colab) } label: { Label("Colab", systemImage: "cloud") }
                    NavigationLink { chatGPTPage } label: { Label("ChatGPT 订阅与声音", systemImage: "person.crop.circle.badge.checkmark") }
                    Picker("默认服务", selection: Binding(get: { draftSettings.selectedProvider }, set: { draftSettings.provider = $0 })) {
                        ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                    }
                } header: { Text("模型与服务") } footer: {
                    Text("不在项目里的对话用这里选的服务。项目各用各的，在项目「⋯ → 服务」里改。")
                }
                Section {
                    NavigationLink { connectionsPage } label: { Label("授权与连接", systemImage: "link") }
                    NavigationLink { dataPage } label: { Label("用量与备份", systemImage: "chart.bar") }
                }
                Section {
                    NavigationLink { FeatureOverviewView() } label: { Label("功能一览", systemImage: "list.bullet.rectangle") }
                        .accessibilityIdentifier("feature-overview")
                    NavigationLink { aboutPage } label: {
                        HStack { Label("关于 Sermo", systemImage: "info.circle"); Spacer(); Text(installedVersion).font(TypeScale.caption).foregroundStyle(Ink.ink3) }
                    }
                }
            }
            .font(TypeScale.body)
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(Ink.line)
            .foregroundStyle(Ink.ink)
            .tint(Ink.ink)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)

            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saved ? "已保存" : "保存") {
                        if store.saveSettings(draftSettings, key: draftKey) {
                            if embedded { saved = true } else { dismiss() }
                        }
                    }.fontWeight(.semibold)
                }
            }
            .onAppear {
                guard !loadedSettings else { return }
                loadedSettings = true
                draftSettings = store.settings; draftKey = store.apiKey
            }
            .onChange(of: store.settings.colab) { _, value in draftSettings.colab = value }
            .onChange(of: draftKey) { _, _ in saved = false; resetConnectionCheck() }
            .onChange(of: draftSettings) { _, _ in saved = false }
            .onDisappear { resetConnectionCheck() }
            .sheet(isPresented: $showProfile) { ProfileEditor() }
            .alert("暂时没有完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("知道了") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
            .alert("备份导入", isPresented: Binding(get: { store.noticeMessage != nil }, set: { if !$0 { store.noticeMessage = nil } })) {
                Button("完成") { store.noticeMessage = nil }
            } message: { Text(store.noticeMessage ?? "") }
        }
    }

    // MARK: Sub-pages. Each keeps the same look; pages with edits to save carry 保存.

    private func page<Content: View>(_ title: String, saves: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            .font(TypeScale.body)
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .listRowSeparatorTint(Ink.line)
            .foregroundStyle(Ink.ink)
            .tint(Ink.ink)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if saves {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(saved ? "已保存" : "保存") { if store.saveSettings(draftSettings, key: draftKey) { saved = true } }
                            .fontWeight(.semibold)
                    }
                }
            }
    }

    private var deepSeekPage: some View {
        page("DeepSeek", saves: true) {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("API Key").font(TypeScale.caption).foregroundStyle(Ink.ink3)
                            HStack {
                                Group {
                                    if showKey { TextField("粘贴 DeepSeek API Key", text: $draftKey) }
                                    else { SecureField("粘贴 DeepSeek API Key", text: $draftKey) }
                                }.textInputAutocapitalization(.never).autocorrectionDisabled()
                                Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                                    .buttonStyle(.borderless).accessibilityLabel(showKey ? "隐藏密钥" : "显示密钥")
                            }
                        }
                        Button(action: testConnection) {
                            HStack {
                                Label(checkingConnection ? "正在验证…" : "检查密钥与余额", systemImage: "network")
                                Spacer()
                                if checkingConnection { ProgressView() }
                            }
                        }
                        .disabled(checkingConnection || draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let balance = checkedBalance {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(balance.isAvailable ? "密钥有效，账户余额可用" : "密钥有效，账户暂无可用余额",
                                      systemImage: balance.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(Ink.ink2)
                                if !balance.summary.isEmpty {
                                    Text("账户余额：\(balance.summary)").font(.caption).foregroundStyle(.secondary)
                                }
                                if !balance.isAvailable {
                                    Text("请到 DeepSeek 开放平台查看 API 余额。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if let error = connectionError {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(TypeScale.note).foregroundStyle(Ink.ink)
                        }
                        Link("打开 DeepSeek 开放平台", destination: URL(string: "https://platform.deepseek.com/")!)
                    } header: { Text("连接 DeepSeek") } footer: {
                        Text("测试连接只检查密钥和账户余额，不发送聊天内容。点右上角保存后，Key 才会保存在这台手机的钥匙串里，不随聊天备份导出。聊天时，消息及选定的历史上下文会传给 DeepSeek。")
                    }
                    Section("回答方式") {
                        Picker("模型", selection: $draftSettings.model) {
                            ForEach(DeepSeekModel.allCases) { model in Text(model.title).tag(model) }
                        }
                        Toggle("深度思考", isOn: $draftSettings.thinkingEnabled)
                        if draftSettings.thinkingEnabled {
                            Picker("思考程度", selection: $draftSettings.effort) {
                                ForEach(ThinkingEffort.allCases) { effort in Text(effort.title).tag(effort) }
                            }
                        }
                        DisclosureGroup("高级设置") {
                        Picker("每次输出上限", selection: $draftSettings.maxOutputTokens) {
                            ForEach([4096, 8192, 16384, 32768, 65536], id: \.self) { value in Text("\(value) tokens").tag(value) }
                        }
                        Picker("携带的历史消息", selection: $draftSettings.contextMessageLimit) {
                            ForEach([10, 20, 40, 80, 100, 200, 400], id: \.self) { value in Text("最近 \(value) 条").tag(value) }
                        }
                        }
                    }
                    Section("聊天连通性") {
                        ChatConnectionTestView(key: draftKey)
                    }
                    Section {
                        LabeledContent("累计用量", value: "\(store.usage.total.tokens.formatted()) tokens")
                        LabeledContent("累计估算花费", value: Pricing.label(store.usage.total.cost))
                        Link("查看官方模型价格", destination: URL(string: "https://api-docs.deepseek.com/zh-cn/quick_start/pricing/")!)
                        Text("花费按 2026 年 10 月的官方人民币价目估算，区分高峰与空闲时段和缓存命中；法定节假日无法识别，旧版本保存的回答不计入。中断时可能没有返回用量，实际扣费以 DeepSeek 开放平台为准。")
                            .font(.caption).foregroundStyle(.secondary)
                    } header: { Text("价目") }
        }
    }

    private var chatGPTPage: some View {
        page("ChatGPT 订阅与声音", saves: true) {
                    SubscriptionSettingsSection(connection: store.subscription, model: $draftSettings.subscriptionModelID,
                                                requestInProgress: store.isGenerating)
                    OpenAISpeechSettings(speech: store.speech)
        }
    }

    private var chatPage: some View {
        page("聊天与指令", saves: true) {
                    Section {
                        Picker("辅助调用", selection: Binding(get: { draftSettings.auxiliaryProviderPolicy ?? .follow }, set: { draftSettings.auxiliaryProviderPolicy = $0 })) {
                            ForEach(AuxiliaryProviderPolicy.allCases) { Text($0.title).tag($0) }
                        }
                        Toggle("猜你回复", isOn: Binding(get: { draftSettings.shouldSuggestReplies },
                            set: { draftSettings.replySuggestionsEnabled = $0 }))
                    } header: { Text("回复建议") } footer: {
                        Text("回答完成后，生成 1～3 条回复草稿。点选后可在输入框修改，再自己发送。使用 V4 Pro 关闭思考的额外短请求，已保存建议的用量计入花费；只参考当前对话。")
                    }
                    Section {
                        NavigationLink {
                            SystemPromptLibraryView(defaultContent: draftSettings.systemPrompt)
                        } label: {
                            Label("系统指令库 · \(store.systemPromptPresets.count)", systemImage: "text.book.closed")
                        }
                        Text("在库里保存多份指令，在聊天输入框的「+」→「指令」里选择。指令库内的修改会单独保存。")
                            .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                    } header: { Text("系统指令库") }
                    Section {
                        NavigationLink {
                            OperationManualView()
                        } label: {
                            Label("内置文档规范 · 已启用 \(store.operationManual.enabledCount) / \(store.operationManual.chapters.count) 章", systemImage: "book.pages")
                        }
                        Text("管理学习项目与外部工具的后台按需查阅规范。普通聊天不占字数，也不限制你的人设与语气；修改后自动随完整备份保存。")
                            .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                    } header: { Text("内置文档规范（按需查阅）") }
                    Section {
                        Button {
                            withAnimation(.snappy(duration: 0.25)) { promptExpanded.toggle() }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    if !promptExpanded {
                                        Text(draftSettings.systemPrompt.isEmpty ? "（空）" : draftSettings.systemPrompt)
                                            .font(TypeScale.serif(15)).foregroundStyle(Ink.ink2).lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                    }
                                    Text(promptExpanded ? "收起" : "\(draftSettings.systemPrompt.count) 字 · 点开编辑")
                                        .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Ink.ink3).rotationEffect(.degrees(promptExpanded ? 180 : 0))
                                    .padding(.top, 4)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(promptExpanded ? "收起全局默认指令" : "展开全局默认指令")
                        if promptExpanded {
                            TextEditor(text: $draftSettings.systemPrompt).frame(minHeight: 150).font(TypeScale.serif(15)).scrollContentBackground(.hidden)
                                .accessibilityIdentifier("system-prompt-editor")
                        }
                    } header: { Text("全局默认指令") } footer: {
                        Text("未选自定义指令、也不在项目里的聊天使用这里的内容；修改后点本页右上角保存。每个聊天可在输入框「+」→「指令」里选择自己的指令，项目默认使用项目指令。思考原文与译文不占用普通聊天上下文。")
                    }
        }
    }

    private var connectionsPage: some View {
        page("授权与连接") {
                    GoogleDriveSection(drive: store.drive)
                    GitHubSection(github: store.github)
        }
    }

    private var dataPage: some View {
        page("用量与备份") {
                    Section {
                        NavigationLink {
                            LocalDataStatusView()
                        } label: {
                            Label("本机数据状态与安全快照", systemImage: "externaldrive.badge.checkmark")
                        }
                    } header: { Text("数据安全") } footer: {
                        Text("查看本机聊天、项目、学习库、书架和图片的实时统计，以及防缩水保护留存的安全快照。")
                    }
                    StudyCloudBackupSection(cloud: store.studyCloud)
                    Section {
                        UsageCalendarView(ledger: store.usage)
                    } header: { Text("用量") } footer: {
                        Text("按天记录所有请求：回答、猜你回复、思考翻译和项目记忆。删除对话不会改变这里的记录。花费是按 DeepSeek 官方价目的估算，实际扣费以开放平台为准；ChatGPT 订阅只计 token，不算花费。")
                    }
                    Section {
                        Button {
                            Task {
                                backupURL = await store.exportUnifiedBackup()
                                showShare = backupURL != nil
                            }
                        } label: {
                            HStack {
                                Label("导出完整备份（.sermobackup）", systemImage: "externaldrive.fill.badge.arrow.up")
                                if store.unifiedBackupBusy { Spacer(); ProgressView().controlSize(.small) }
                            }
                        }
                        .disabled(store.isGenerating || !store.canPersist || store.unifiedBackupBusy)
                        Button {
                            let types = [UTType(filenameExtension: "sermobackup"), .json, .data].compactMap { $0 }
                            DocumentPicker.present(types, asCopy: true, onError: { store.errorMessage = $0 }) { url in
                                store.prepareBackupRestore(url, removeWhenDone: true)
                            }
                        } label: {
                            Label("从备份文件恢复…", systemImage: "arrow.down.doc.fill")
                        }
                        .disabled(!store.canRestoreStudyBackup)
                        DisclosureGroup("兼容旧版单独导出") {
                            Button {
                                backupURL = store.exportBackup()
                                showShare = backupURL != nil
                            } label: { Label("仅导出聊天与项目 JSON", systemImage: "square.and.arrow.up") }
                        }
                    } header: { Text("完整备份与恢复") } footer: {
                        Text("「导出完整备份」会将所有聊天、项目、资料、自定义指令、用量日历、学习数据库、聊天与学习图片、以及书架阅读进度与角色档案打包成单个 .sermobackup 文件（不含体积巨大的小说原文，小说原文可随时重新导入并自动关联回已有档案）。「从备份文件恢复」支持新版 .sermobackup，也自动兼容旧版聊天 JSON、学习备份 JSON 和书架备份 JSON；选择文件后会先展示内容清单供你核对。")
                    }
                AutoBackupSection()
        }
        .sheet(isPresented: $showShare) {
            if let url = backupURL { ShareSheet(items: [url]) }
        }
        .sheet(item: $store.unifiedRestorePreview) { preview in
            UnifiedRestorePreviewSheet(preview: preview)
                .environmentObject(store)
        }
    }

    private var aboutPage: some View {
        page("关于 Sermo") {
                    Section {
                        LabeledContent("Sermo", value: installedVersion)
                        Button {
                            UIPasteboard.general.string = "Sermo · \(installedVersion)"
                        } label: { Label("复制版本信息", systemImage: "doc.on.doc") }
                        Text("文字与图片聊天、项目（可选 DeepSeek 或 ChatGPT 订阅，ChatGPT 项目可自动整理记忆）、猜你回复、消息编辑、思考过程与翻译、用量日历与备份。图片 Flash 和 ChatGPT 能读，保存在这台手机上，不随聊天备份导出。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
        }
    }

    private var installedVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知版本"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        return "\(version)（build \(build)）"
    }

    private func resetConnectionCheck() {
        connectionTask?.cancel()
        connectionTask = nil
        checkingConnection = false
        checkedBalance = nil
        connectionError = nil
    }

    private func testConnection() {
        resetConnectionCheck()
        if store.isPreview { connectionError = "预览模式不连接网络。"; return }
        checkingConnection = true
        let keyToCheck = draftKey
        connectionTask = Task { @MainActor in
            do {
                let balance = try await DeepSeekClient().checkConnection(key: keyToCheck)
                try Task.checkCancellation()
                checkedBalance = balance
                checkingConnection = false
                connectionTask = nil
            } catch {
                guard !Task.isCancelled else { return }
                if let networkError = error as? URLError,
                   networkError.code == .notConnectedToInternet || networkError.code == .networkConnectionLost {
                    connectionError = "网络没有连通，请联网后再试。"
                } else if let networkError = error as? URLError, networkError.code == .timedOut {
                    connectionError = "验证超时，请检查网络后重试。"
                } else {
                    connectionError = error.localizedDescription
                }
                checkingConnection = false
                connectionTask = nil
            }
        }
    }
}

@MainActor
struct OpenAISpeechSettings: View {
    @ObservedObject var speech: OpenAISpeech
    @AppStorage(OpenAISpeech.autoKey) private var autoPlay = false
    @AppStorage(OpenAISpeech.voiceKey) private var voice = "marin"
    @State private var key = ""
    @State private var saved = false
    @State private var issue: String?
    @State private var loaded = false

    var body: some View {
        Section {
            SecureField("粘贴 OpenAI API Key", text: $key)
                .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
            Button(saved ? "语音密钥已保存" : "保存语音密钥") {
                do { try speech.saveKey(key); saved = true }
                catch { issue = error.localizedDescription }
            }
            Toggle("DeepSeek 回复后自动朗读", isOn: $autoPlay)
                .disabled(!speech.hasKey)
            Picker("声音", selection: $voice) {
                ForEach(OpenAISpeech.voices, id: \.self) { Text($0.capitalized).tag($0) }
            }
            HStack {
                SpeechPlaybackControl(speech: speech, text: "你好，这是一段声音试听。你可以继续用 DeepSeek 聊天，再让我把回复读出来。", messageID: OpenAISpeech.sampleID)
                Text(speech.isActive(OpenAISpeech.sampleID) ? speech.status : "试听当前声音")
                    .font(TypeScale.caption).foregroundStyle(Ink.ink3)
            }
            Link("领取 API 额度", destination: URL(string: "https://chatgpt.com/settings/billing")!)
            Link("管理 OpenAI API Key", destination: URL(string: "https://platform.openai.com/api-keys")!)
            Link("查看 API 余额和用量", destination: URL(string: "https://platform.openai.com/settings/organization/billing/overview")!)
            Link("查看 OpenAI 语音价格", destination: URL(string: "https://developers.openai.com/api/docs/pricing")!)
        } header: { Text("GPT 声音") } footer: {
            Text("先领取额度并绑定 API 组织，再到 OpenAI 平台创建该组织的 API Key，粘贴并保存。DeepSeek 继续负责回答；朗读或试听会把文字发送给 OpenAI，使用 OpenAI API 额度。按 2026 年 10 月价格估算，语音输出约 $0.024/分钟，另有少量文字费用；每次重新生成都计费，实际以 OpenAI 账单为准。自动朗读默认关闭；开关和音色立即生效。声音为 AI 生成，可能与原文略有不同，请以文字为准。密钥只保存在本机钥匙串，不随聊天备份导出。")
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            do { key = try speech.storedKey() } catch { issue = error.localizedDescription }
        }
        .onChange(of: key) { _, _ in saved = false }
        .onChange(of: voice) { _, _ in speech.stop() }
        .onChange(of: autoPlay) { _, enabled in if !enabled { speech.stop() } }
        .alert("语音密钥未保存", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("知道了") { issue = nil }
        } message: { Text(issue ?? "") }
    }
}

@MainActor
struct SpeechPlaybackControl: View {
    @ObservedObject var speech: OpenAISpeech
    let text: String
    let messageID: UUID

    var body: some View {
        Button {
            if speech.isActive(messageID) { speech.stop() }
            else { speech.speak(text, messageID: messageID) }
        } label: {
            Image(systemName: speech.isActive(messageID) ? "stop.circle" : "speaker.wave.2")
                .frame(minWidth: 24, minHeight: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(speech.isActive(messageID) ? "停止朗读" : "用 GPT 声音朗读")
        .alert("声音暂时没播放", isPresented: Binding(
            get: { speech.errorMessageID == messageID && speech.errorMessage != nil },
            set: { if !$0 { speech.errorMessage = nil } }
        )) {
            Button("知道了") { speech.errorMessage = nil }
        } message: { Text(speech.errorMessage ?? "") }
    }
}

@MainActor
struct SystemPromptLibraryView: View {
    @EnvironmentObject private var store: AppStore
    var defaultContent: String? = nil
    @State private var editing: SystemPromptPreset?
    @State private var deleting: SystemPromptPreset?
    @State private var issue: String?
    private var presets: [SystemPromptPreset] {
        store.systemPromptPresets.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    private var atLimit: Bool { store.systemPromptPresets.count >= 100 }

    var body: some View {
        List {
            Section {
                Button {
                    editing = SystemPromptPreset(name: "", content: "")
                } label: { Label("新建系统指令", systemImage: "plus") }
                    .disabled(!store.canPersist || atLimit)
                    .accessibilityIdentifier("system-prompt-create")
                Button {
                    editing = SystemPromptPreset(name: "原默认指令", content: defaultContent ?? store.settings.systemPrompt)
                } label: { Label("把默认指令另存为一份", systemImage: "doc.on.doc") }
                    .disabled(!store.canPersist || atLimit)
            } footer: {
                Text(atLimit ? "已达到100份指令上限，可编辑或删除已有指令。" : "自己起名字并填写内容，不会自动添加模板。每份最多2万字，最多保存100份。")
            }
            Section {
                if presets.isEmpty {
                    Text("还没有保存的指令。可以先把现在的默认指令另存下来，再添加其他说话方式。")
                        .font(TypeScale.label).foregroundStyle(Ink.ink3)
                }
                ForEach(presets) { preset in
                    Button { editing = preset } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(preset.name).font(TypeScale.body).foregroundStyle(Ink.ink)
                            Text(preset.content).font(TypeScale.label).foregroundStyle(Ink.ink3).lineLimit(2)
                            Text("\(preset.content.count.formatted()) 字")
                                .font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                        }.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain).disabled(!store.canPersist)
                    .swipeActions {
                        Button("删除", role: .destructive) { deleting = preset }.disabled(!store.canPersist)
                    }
                }
            } header: { Text("我的指令 · \(presets.count)") } footer: {
                Text("聊天会保存选择时的指令副本。修改或删除库内指令不会改动已经选用它的聊天；要使用新版，请在对应聊天里重新选择。")
            }
            if let issue {
                Text(issue).font(TypeScale.label).foregroundStyle(.red)
            }
        }
        .font(TypeScale.body).scrollContentBackground(.hidden).background(AppBackground())
        .foregroundStyle(Ink.ink).tint(Ink.seal)
        .navigationTitle("系统指令库").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { preset in
            SystemPromptPresetEditor(preset: preset).environmentObject(store)
        }
        .confirmationDialog("从指令库删除这份指令？", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    guard let preset = deleting else { return }
                    if !store.deleteSystemPromptPreset(preset.id) { issue = store.errorMessage ?? "指令没有删除成功，请稍后重试。" }
                    deleting = nil
                }
                Button("取消", role: .cancel) { deleting = nil }
            } message: { Text("已经选择它的聊天会保留自己的副本。") }
    }
}

@MainActor
private struct SystemPromptPresetEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let preset: SystemPromptPreset
    @State private var name: String
    @State private var content: String
    @State private var issue: String?
    init(preset: SystemPromptPreset) {
        self.preset = preset
        _name = State(initialValue: preset.name)
        _content = State(initialValue: preset.content)
    }
    private var changed: Bool { name != preset.name || content != preset.content }
    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanContent: String { content.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validation: String? {
        if cleanName.isEmpty { return "给这份指令起一个容易认出的名字。" }
        if cleanName.count > 60 { return "名字最多60字。" }
        if cleanContent.isEmpty { return "请填写这份指令的内容。" }
        if content.count > 20_000 { return "内容超过2万字，请缩短后保存；不会自动截断。" }
        if !store.canPersist { return "当前暂时不能保存，请稍后重试。" }
        return nil
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("名字 · \(name.count) / 60") {
                    TextField("例如：随便聊聊、简洁一点、角色名字", text: $name)
                        .accessibilityIdentifier("system-prompt-name")
                }
                Section {
                    TextEditor(text: $content).frame(minHeight: 280).scrollContentBackground(.hidden)
                        .font(TypeScale.serif(17)).accessibilityIdentifier("system-prompt-content")
                } header: { Text("指令内容 · \(content.count.formatted()) / 20,000 字") } footer: {
                    Text("写下你想要的人设、语气或回答方式。支持已有的提示词变量，例如 {{名字}} 和 {{时间}}。")
                }
                if let validation { Text(validation).font(TypeScale.label).foregroundStyle(Ink.ink3) }
                if let issue { Text(issue).font(TypeScale.label).foregroundStyle(.red) }
            }
            .font(TypeScale.body).scrollContentBackground(.hidden).background(AppBackground())
            .navigationTitle(preset.name.isEmpty ? "新建系统指令" : "编辑系统指令")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard validation == nil else { return }
                        var next = preset
                        next.name = cleanName; next.content = content; next.updatedAt = Date()
                        if store.upsertSystemPromptPreset(next) { dismiss() }
                        else { issue = store.errorMessage ?? "指令没有保存成功，请稍后重试。" }
                    }.disabled(validation != nil || (!changed && store.systemPromptPresets.contains(where: { $0.id == preset.id })))
                }
            }
        }
        .tint(Ink.seal).interactiveDismissDisabled(changed)
    }
}

@MainActor
struct SystemPromptPickerSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let threadID: UUID
    @State private var issue: String?
    private var thread: ChatThread? {
        guard let value = store.threads.first(where: { $0.id == threadID }), !store.isHidden(value) else { return nil }
        return value
    }
    private var selection: SystemPromptPreset? { thread?.systemPromptPreset }
    private var canSelect: Bool { store.canPersist && !store.isGenerating && store.canChooseSystemPrompt(for: thread) }
    private var defaultTitle: String { thread?.projectID == nil ? "全局默认指令" : "跟随项目指令" }
    private var defaultContent: String {
        guard let thread else { return "" }
        return store.project(thread.projectID)?.instructions ?? store.settings.systemPrompt
    }
    private var copyStatus: String? {
        guard let selected = selection else { return nil }
        guard let stored = store.systemPromptPresets.first(where: { $0.id == selected.id }) else {
            return "这份指令已从库中删除；当前聊天仍使用当时保存的副本。"
        }
        if stored.name != selected.name || stored.content != selected.content {
            return "指令库中的这一份已更新；当前聊天仍使用旧副本，重新选择可换成新版。"
        }
        return nil
    }
    var body: some View {
        NavigationStack {
            List {
                if let thread, store.canChooseSystemPrompt(for: thread) {
                    currentSection(thread)
                    Section {
                        Button { choose(nil) } label: {
                            choiceLabel(defaultTitle, detail: thread.projectID == nil ? "使用设置里的全局默认内容" : "使用项目自己的指令", selected: selection == nil)
                        }.buttonStyle(.plain).disabled(!canSelect)
                        DisclosureGroup("预览默认内容") {
                            promptPreview(defaultContent.isEmpty ? "未填写指令。" : defaultContent)
                        }
                    } header: { Text("默认") }
                    Section {
                        if store.systemPromptPresets.isEmpty {
                            Text("指令库还是空的。先进入下方管理页，保存几份你想切换使用的指令。")
                                .font(TypeScale.label).foregroundStyle(Ink.ink3)
                        }
                        ForEach(store.systemPromptPresets) { preset in
                            Button { choose(preset.id) } label: {
                                choiceLabel(preset.name, detail: String(preset.content.prefix(90)), selected: isSelected(preset))
                            }.buttonStyle(.plain).disabled(!canSelect)
                            DisclosureGroup("预览「\(preset.name)」") { promptPreview(preset.content) }
                        }
                    } header: { Text("我的指令") }
                } else {
                    ContentUnavailableView("当前对话无法切换指令", systemImage: "text.book.closed",
                        description: Text("对话可能已删除或上锁；书架角色扮演和本书讨论使用各自的专用指令。"))
                }
                Section {
                    NavigationLink { SystemPromptLibraryView() } label: {
                        Label("管理系统指令库", systemImage: "slider.horizontal.3")
                    }
                }
                if let issue { Text(issue).font(TypeScale.label).foregroundStyle(.red) }
            }
            .font(TypeScale.body).scrollContentBackground(.hidden).background(AppBackground())
            .foregroundStyle(Ink.ink).tint(Ink.seal)
            .navigationTitle("选择系统指令").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
    private func currentSection(_ thread: ChatThread) -> some View {
        Section {
            LabeledContent("当前使用", value: store.systemPromptTitle(for: thread))
            if let selected = selection {
                DisclosureGroup("查看当前内容") { promptPreview(selected.content) }
            }
            if let copyStatus { Text(copyStatus).font(TypeScale.label).foregroundStyle(Ink.ink3) }
            if store.isGenerating {
                Text("回答正在生成，完成后可切换；已经发出的请求不会中途改变。")
                    .font(TypeScale.label).foregroundStyle(Ink.ink3)
            }
        } header: { Text("这条聊天 · \(thread.title)") } footer: {
            Text("选择只作用于这条聊天，从下一次发送或重新生成起生效，历史消息不改写。项目里的资料与记忆仍保留。每次选择保存一份副本，修改指令库后需重新选择。")
        }
    }
    private func isSelected(_ preset: SystemPromptPreset) -> Bool {
        guard let selected = selection else { return false }
        return selected.id == preset.id && selected.name == preset.name && selected.content == preset.content
    }
    private func choiceLabel(_ title: String, detail: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(TypeScale.body).foregroundStyle(Ink.ink)
                Text(detail).font(TypeScale.label).foregroundStyle(Ink.ink3).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Ink.seal : Ink.ink3)
        }.multilineTextAlignment(.leading).padding(.vertical, 4).contentShape(Rectangle())
    }
    private func promptPreview(_ content: String) -> some View {
        ScrollView {
            Text(content).font(TypeScale.serif(15)).foregroundStyle(Ink.ink2).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 220)
    }
    private func choose(_ id: UUID?) {
        guard canSelect else { return }
        if store.selectSystemPromptPreset(id, in: threadID) { dismiss() }
        else { issue = store.errorMessage ?? "没有切换成功，请稍后重试。" }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

@MainActor
struct LocalDataStatusView: View {
    @EnvironmentObject private var store: AppStore
    @State private var shareURL: URL?
    @State private var safetyList: [SafetySnapshotInfo] = []
    @State private var autoBackups: [(name: String, size: Int64, date: Date, url: URL)] = []

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        let stats = store.localDataDiagnostics()
        List {
            Section("运行与存储状态") {
                LabeledContent("主记录保存权限", value: store.canPersist ? "正常" : "只读保护中")
                LabeledContent("书架保存权限", value: store.books.canPersist ? "正常" : "只读保护中")
                LabeledContent("主文件体积", value: formatBytes(stats.conversationsBytes))
                LabeledContent("最近写入时间", value: stats.conversationsModified?.formatted(date: .abbreviated, time: .shortened) ?? "尚未落盘")
            }
            Section("聊天与项目") {
                LabeledContent("可见对话数", value: "\(stats.visibleThreads) 条")
                LabeledContent("含重试分支总对话", value: "\(stats.totalThreads) 条")
                LabeledContent("总消息数", value: "\(stats.totalMessages) 条")
                LabeledContent("项目数量", value: "\(stats.projectCount) 个（资料 \(stats.documentCount) 份）")
                LabeledContent("自定义指令库", value: "\(stats.presetCount) 份")
                LabeledContent("用量记录天数", value: "\(stats.usageDays) 天")
            }
            Section("学习数据库、图片与书架") {
                LabeledContent("学习数据库体积", value: formatBytes(stats.studyBytes))
                LabeledContent("学习数据总行数", value: "\(stats.studyRows) 行")
                LabeledContent("本机保存图片", value: "\(stats.imageCount) 张 · \(formatBytes(stats.imageBytes))")
                LabeledContent("书架小说与档案", value: "\(stats.bookCount) 本 · 人物卡 \(stats.personaCount) 张 · \(formatBytes(stats.bookBytes))")
            }
            Section {
                Button("立即创建一份安全快照") {
                    if store.createManualSafetySnapshot() { reloadLists() }
                }.disabled(!store.canPersist)
                if safetyList.isEmpty {
                    Text("尚无安全快照。当检测到异常缩水、恢复备份前或手动点上方按钮时，会自动保留最近 5 份。")
                        .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                } else {
                    ForEach(safetyList) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).font(TypeScale.caption).lineLimit(1)
                                Text("\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(formatBytes(item.size))")
                                    .font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                            }
                            Spacer()
                            Button("导出") { shareURL = item.url }.buttonStyle(.borderless)
                            Button("恢复") { store.prepareBackupRestore(item.url) }.buttonStyle(.borderless)
                        }
                    }
                }
            } header: { Text("Safety 保护快照（最近 \(safetyList.count) 份）") }
            Section {
                if autoBackups.isEmpty {
                    Text("自动备份目录暂无文件。")
                        .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                } else {
                    ForEach(autoBackups, id: \.url.path) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).font(TypeScale.caption).lineLimit(1)
                                Text("\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(formatBytes(item.size))")
                                    .font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                            }
                            Spacer()
                            Button("导出") { shareURL = item.url }.buttonStyle(.borderless)
                            Button("恢复") { store.prepareBackupRestore(item.url) }.buttonStyle(.borderless)
                        }
                    }
                }
            } header: { Text("Documents/自动备份（最近 \(autoBackups.count) 份）") }
        }
        .font(TypeScale.body)
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .foregroundStyle(Ink.ink)
        .tint(Ink.seal)
        .navigationTitle("本机数据状态")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reloadLists)
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let url = shareURL { ShareSheet(items: [url]) }
        }
        .sheet(item: $store.unifiedRestorePreview) { preview in
            UnifiedRestorePreviewSheet(preview: preview)
                .environmentObject(store)
        }
    }

    private func reloadLists() {
        safetyList = store.safetySnapshots()
        autoBackups = store.localAutoBackupFiles()
    }
}

@MainActor
struct UnifiedRestorePreviewSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let preview: UnifiedRestorePreview
    @State private var mode: UnifiedRestoreMode = .merge
    @State private var confirming = false

    private var supportsModeChoice: Bool {
        switch preview.package {
        case .unified, .legacyChat: return true
        case .legacyStudy, .legacyShelf: return false
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("已核验的备份文件") {
                    LabeledContent("文件名", value: preview.fileName)
                    LabeledContent("格式类型", value: preview.package.formatTitle)
                    LabeledContent("文件体积", value: ByteCountFormatter.string(fromByteCount: preview.fileSize, countStyle: .file))
                    if let created = preview.package.createdAt {
                        LabeledContent("备份时间", value: created.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                Section("备份内容明细") {
                    LabeledContent("对话数量", value: "\(preview.package.threadCount) 条")
                    LabeledContent("项目数量", value: "\(preview.package.projectCount) 个")
                    if preview.package.presetCount > 0 {
                        LabeledContent("自定义指令库", value: "\(preview.package.presetCount) 份")
                    }
                    if preview.package.manualChapterCount > 0 {
                        LabeledContent("内置文档规范", value: "\(preview.package.manualChapterCount) 章")
                    }
                    if preview.package.studyRowCount > 0 {
                        LabeledContent("学习数据库记录", value: "\(preview.package.studyRowCount) 行")
                    }
                    if preview.package.bookCount > 0 || preview.package.personaCount > 0 {
                        LabeledContent("书架档案与进度", value: "\(preview.package.bookCount) 本 · 人物卡 \(preview.package.personaCount) 张")
                    }
                    if preview.package.imageCount > 0 || preview.package.omittedImageCount > 0 {
                        LabeledContent("图片实体", value: "\(preview.package.imageCount) 张已校验")
                    }
                    if preview.package.omittedImageCount > 0 {
                        Text("注：该备份包有 \(preview.package.omittedImageCount) 张图片因体积预算未包含在包内；本机已有同名原图会自动保留。")
                            .font(TypeScale.caption).foregroundStyle(.orange)
                    }
                }
                if supportsModeChoice {
                    Section {
                        Picker("恢复方式", selection: $mode) {
                            ForEach(UnifiedRestoreMode.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(mode.summary)
                            .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                    } header: { Text("恢复方式") }
                }
                Section {
                    Button {
                        confirming = true
                    } label: {
                        Label("先存本机安全快照并开始恢复", systemImage: "arrow.clockwise.circle.fill")
                            .fontWeight(.semibold)
                    }
                } footer: {
                    Text("无论选择哪种方式，恢复开始前都会先把本机当前记录另存一份到「Safety 保护快照」，确保不会丢失现有数据。")
                }
            }
            .font(TypeScale.body)
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .foregroundStyle(Ink.ink)
            .tint(Ink.seal)
            .navigationTitle("核对备份内容")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        store.unifiedRestorePreview = nil
                        dismiss()
                    }
                }
            }
            .confirmationDialog("确认执行恢复？", isPresented: $confirming, titleVisibility: .visible) {
                Button(supportsModeChoice ? mode.title : "确认恢复", role: mode == .replace ? .destructive : nil) {
                    store.confirmUnifiedRestore(preview, mode: mode)
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("恢复前会自动保存一份当前本机安全快照。")
            }
        }
    }
}
