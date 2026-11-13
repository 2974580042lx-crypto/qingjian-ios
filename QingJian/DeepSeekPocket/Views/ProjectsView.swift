import SwiftUI
import UIKit
import LocalAuthentication
import UniformTypeIdentifiers

enum ProjectLock {
    // Face ID, falling back to the phone passcode. Unlocks for this session only.
    @MainActor static func open(_ id: UUID, store: AppStore) async -> Bool {
        guard store.isLocked(id) else { return true }
        if store.isPreview { store.unlock(id); return true }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            store.errorMessage = "这台手机没有设置面容 ID 或锁屏密码，暂时打不开上锁的项目。"
            return false
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "打开上锁的项目")
            if ok { store.unlock(id) }
            return ok
        } catch { return false }
    }
}

private extension View {
    func errorAlert(_ store: AppStore) -> some View {
        alert("暂时没有完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

@MainActor
struct ProjectsView: View {
    @State private var restoringStudy = false
    @State private var archivedStudy: [StudyArchivedProject] = []
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    // Called after a conversation was opened, so the sheet and the sidebar can close.
    let opened: () -> Void
    @State private var path: [UUID] = []
    @State private var creating = false
    @State private var newName = ""
    @State private var designing = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if store.projects.isEmpty {
                    Text("项目有自己的指令、资料和默认模型。项目里的对话只在项目中出现，不会进侧栏的「最近」。")
                        .font(TypeScale.serif(15)).foregroundStyle(Ink.ink3).listRowBackground(Color.clear)
                }
                ForEach(store.projects) { project in
                    Button { open(project.id) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: project.isLocked ? "lock" : (project.studySubject != nil ? "graduationcap.fill" : "folder"))
                                .font(.system(size: 17))
                                .foregroundStyle(project.studySubject != nil ? Ink.seal : Ink.ink2)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(project.name).font(TypeScale.serif(17)).foregroundStyle(Ink.ink)
                                Text(project.isLocked && store.isLocked(project.id) ? "已上锁" : "\(store.threads(in: project.id).count) 个对话")
                                    .font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Ink.ink3)
                        }.padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("project-row")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("项目")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("让 AI 帮我建", systemImage: "sparkles") { designing = true }
                        Button("新建空白项目", systemImage: "folder.badge.plus") { newName = ""; creating = true }
                        Button("恢复学习项目", systemImage: "arrow.uturn.backward") {
                            archivedStudy = store.archivedStudyProjects(); restoringStudy = true
                        }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新建项目")
                }
            }
            .navigationDestination(for: UUID.self) { id in ProjectPageView(projectID: id, opened: opened) }
            .alert("新建项目", isPresented: $creating) {
                TextField("项目名称", text: $newName)
                Button("取消", role: .cancel) { }
                Button("创建") { if let id = store.createProject(name: newName) { path.append(id) } }
            }
            .sheet(isPresented: $designing) {
                ProjectDesignerView(projectID: nil) { id in path.append(id) }.environmentObject(store)
            }
            .errorAlert(store)
            .sheet(isPresented: $restoringStudy) {
                NavigationStack {
                    List {
                        if archivedStudy.isEmpty { Text("没有可恢复的学习项目") }
                        ForEach(archivedStudy) { item in
                            Button { if store.restoreStudyProject(item) { restoringStudy = false } } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.project.name)
                                    Text("恢复项目指令、学习记录和仍保留的对话归属").font(TypeScale.caption).foregroundStyle(Ink.ink3)
                                }
                            }
                        }
                    }
                    .font(TypeScale.body).scrollContentBackground(.hidden).background(AppBackground()).tint(Ink.ink)
                    .navigationTitle("恢复学习项目")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { restoringStudy = false } } }
                }
            }
        }
        .tint(Ink.ink)
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--preview-project"), let first = store.projects.first { path = [first.id] }
        }
    }

    private func open(_ id: UUID) {
        Task { if await ProjectLock.open(id, store: store) { path.append(id) } }
    }
}

// Changes one stored project in place; the small project screens all save straight away.
@MainActor private func editProject(_ store: AppStore, _ id: UUID, _ change: (inout ChatProject) -> Void) {
    guard var project = store.project(id) else { return }
    change(&project)
    _ = store.updateProject(project)
}

// After the Claude app's project screen: files and instructions on top, the
// project's conversations below, and a new-conversation button at the bottom right.
@MainActor
struct ProjectPageView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let opened: () -> Void
    @State private var editingInstructions = false
    @State private var adjusting = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmDelete = false
    private var project: ChatProject? { store.project(projectID) }

    var body: some View {
        let threads = store.threads(in: projectID)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                NavigationLink { ProjectFilesView(projectID: projectID) } label: {
                    pill((project?.documents.isEmpty ?? true) ? "添加文件" : "文件 · \(project?.documents.count ?? 0)")
                }
                .accessibilityIdentifier("project-files")
                Button { editingInstructions = true } label: {
                    pill((project?.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? "添加指令" : "编辑指令")
                }
                .accessibilityIdentifier("project-instructions-button")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
            // Every service can use manually written project memory.
            if project != nil {
                NavigationLink {
                    if project?.studySubject != nil { StudyMemoryView(projectID: projectID) }
                    else { ProjectMemoryView(projectID: projectID) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: project?.studySubject != nil ? "graduationcap.fill" : "brain")
                            .font(.system(size: 15))
                            .foregroundStyle(project?.studySubject != nil ? Ink.seal : Ink.ink2)
                            .frame(width: 24)
                        Text(project?.studySubject != nil ? "学习档案与进度" : "项目备忘（跨对话）")
                            .font(TypeScale.serif(17))
                            .foregroundStyle(Ink.ink)
                        Spacer()
                        Text(memorySummary)
                            .font(TypeScale.tiny.weight(project?.studySubject != nil ? .medium : .regular))
                            .foregroundStyle(project?.studySubject != nil ? Ink.seal : Ink.ink3)
                        Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Ink.ink3)
                    }
                    .padding(.horizontal, 20).frame(height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("project-memory")
                if project?.studySubject == .english,
                   let todayList = (try? store.studyWordSummary(projectID: projectID))?.todayWordsList,
                   !todayList.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Text("今日各窗口已聊")
                                .font(TypeScale.tiny.weight(.medium))
                                .foregroundStyle(Ink.ink3)
                            ForEach(todayList.prefix(16), id: \.word.id) { item in
                                Text(item.word.word)
                                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Ink.seal)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Ink.seal.opacity(0.12), in: Capsule())
                            }
                        }
                        .padding(.horizontal, 20).padding(.bottom, 6)
                    }
                }
            }
            if threads.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 21)).foregroundStyle(Ink.ink2)
                        .frame(width: 56, height: 56).background(Ink.raised, in: Circle())
                    Text("向 Sermo 提出任何问题").font(TypeScale.serif(17)).foregroundStyle(Ink.ink2)
                    Text("此项目中的会话将显示在这里。").font(TypeScale.serif(15)).foregroundStyle(Ink.ink3)
                }
                Spacer(); Spacer()
            } else {
                List {
                    ForEach(threads) { thread in
                        Button { store.select(thread.id); opened() } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "bubble.left").font(.system(size: 16)).foregroundStyle(Ink.ink2).frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(thread.title).font(TypeScale.serif(17)).foregroundStyle(Ink.ink).lineLimit(1)
                                    Text(thread.updatedAt.formatted(date: .abbreviated, time: .omitted)).font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                                }
                            }
                            .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .swipeActions { Button("移出") { store.moveThreads([thread.id], to: nil) }.tint(Ink.ink3) }
                        .accessibilityIdentifier("project-thread-row")
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.bottom, 90, for: .scrollContent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppBackground())
        .overlay(alignment: .bottomTrailing) {
            Button { store.createThread(in: projectID); opened() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 15, weight: .medium))
                    Text("新建会话").font(TypeScale.serif(17).weight(.semibold))
                }
                .foregroundStyle(Ink.onSolid).padding(.horizontal, 20).frame(height: 48)
                .background(Ink.solid, in: InkCapsule()).contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 20).padding(.bottom, 12)
            .accessibilityIdentifier("project-new-chat")
        }
        .navigationTitle(project?.name ?? "项目")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { store.togglePinnedProject(projectID) } label: {
                    Image(systemName: project?.isPinned == true ? "pin.fill" : "pin")
                }
                .accessibilityLabel(project?.isPinned == true ? "从侧栏取消固定" : "固定到侧栏")
                .accessibilityIdentifier("project-pin")
                optionsMenu
            }
        }
        .sheet(isPresented: $editingInstructions) {
            ProjectInstructionsView(projectID: projectID).environmentObject(store)
        }
        .sheet(isPresented: $adjusting) {
            ProjectDesignerView(projectID: projectID).environmentObject(store)
        }
        .alert("重命名项目", isPresented: $renaming) {
            TextField("项目名称", text: $renameText)
            Button("取消", role: .cancel) { }
            Button("保存") { editProject(store, projectID) { $0.name = renameText } }
        }
        .confirmationDialog("删除「\(project?.name ?? "")」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除项目，对话移回「最近」") { store.deleteProject(projectID, keepConversations: true); dismiss() }
            Button("连同里面的对话一起删除", role: .destructive) { store.deleteProject(projectID, keepConversations: false); dismiss() }
        } message: {
            if project?.studySubject != nil {
                Text("学习记录、词库和修改历史会保留在本机，可从项目列表的“恢复学习项目”找回。选择同时删除的对话不会随项目恢复。")
            }
        }
        .errorAlert(store)
    }

    private var optionsMenu: some View {
        Menu {
            Button("让 AI 调整项目", systemImage: "sparkles") { adjusting = true }
            Button("重命名", systemImage: "pencil") { renameText = project?.name ?? ""; renaming = true }
            Menu("学习科目", systemImage: "graduationcap") {
                Picker("学习科目", selection: Binding(
                    get: { project?.studySubject?.rawValue ?? "none" },
                    set: { value in
                        editProject(store, projectID) { proj in
                            proj.studySubject = StudySubject(rawValue: value)
                            if proj.studySubject != nil { proj.autoMemory = true }
                        }
                    }
                )) {
                    Text("普通项目（无）").tag("none")
                    ForEach(StudySubject.allCases, id: \.rawValue) { subj in
                        Text(subj.title).tag(subj.rawValue)
                    }
                }
            }
            Menu("服务", systemImage: "server.rack") {
                Picker("服务", selection: Binding(get: { project?.service ?? .deepSeek },
                                                set: { value in editProject(store, projectID) { $0.provider = value } })) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                }
            }
            if project?.service == .chatGPT {
                Menu("默认模型", systemImage: "cpu") {
                    Picker("默认模型", selection: Binding(get: { project?.subscriptionModel ?? "follow" },
                                                      set: { value in editProject(store, projectID) { $0.subscriptionModel = value == "follow" ? nil : value } })) {
                        Text("跟随当前").tag("follow")
                        ForEach(store.subscription.models) { Text($0.displayName).tag($0.slug) }
                    }
                }
                Menu("默认思考", systemImage: "sparkle") {
                    Picker("默认思考", selection: Binding(get: { project?.subscriptionEffort?.rawValue ?? "follow" },
                                                      set: { value in editProject(store, projectID) { $0.subscriptionEffort = SubscriptionEffort(rawValue: value) } })) {
                        Text("跟随当前").tag("follow")
                        ForEach(SubscriptionEffort.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
                if project?.studySubject == nil {
                    Toggle(isOn: Binding(get: { project?.autoMemory != false },
                                         set: { value in editProject(store, projectID) { $0.autoMemory = value } })) {
                        Label("自动整理备忘", systemImage: "brain")
                    }
                }
            } else {
            if project?.service == .deepSeek {
            Menu("默认模型", systemImage: "cpu") {
                Picker("默认模型", selection: Binding(get: { project?.model?.rawValue ?? "follow" },
                                                  set: { value in editProject(store, projectID) { $0.model = DeepSeekModel(rawValue: value) } })) {
                    Text("跟随当前").tag("follow")
                    ForEach(DeepSeekModel.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Menu("默认思考", systemImage: "sparkle") {
                Picker("默认思考", selection: Binding(get: {
                    guard let thinking = project?.thinkingEnabled else { return "follow" }
                    return thinking ? (project?.effort ?? .high).rawValue : "off"
                }, set: { value in
                    editProject(store, projectID) { project in
                        switch value {
                        case "follow": project.thinkingEnabled = nil; project.effort = nil
                        case "off": project.thinkingEnabled = false
                        default: project.thinkingEnabled = true; project.effort = ThinkingEffort(rawValue: value)
                        }
                    }
                })) {
                    Text("跟随当前").tag("follow")
                    Text("Off").tag("off")
                    ForEach(ThinkingEffort.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            } else {
                Text("Colab 模型与思考在 Colab 设置页配置")
            }
            if project?.studySubject == nil {
                // Off by default, so one-scene role-play projects never carry anything across chats.
                Toggle(isOn: Binding(get: { project?.autoMemory == true },
                                     set: { value in editProject(store, projectID) { $0.autoMemory = value } })) {
                    Label("跨对话备忘", systemImage: "brain")
                }
            }
            }
            if store.canUsePureRoleplay(project) {
                Toggle(isOn: Binding(get: { project?.isPureRoleplay == true },
                                     set: { value in editProject(store, projectID) { $0.pureRoleplay = value } })) {
                    Label("纯角色扮演模式", systemImage: "theatermasks")
                }
            }
            if project?.isPureRoleplay != true {
                Toggle(isOn: Binding(get: { project?.driveTools ?? store.drive.connected },
                                     set: { value in editProject(store, projectID) { $0.driveTools = value } })) {
                    Label("谷歌云盘工具", systemImage: "externaldrive")
                }
                Toggle(isOn: Binding(get: { project?.githubTools ?? store.github.connected },
                                     set: { value in editProject(store, projectID) { $0.githubTools = value } })) {
                    Label("GitHub 工具", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Toggle(isOn: Binding(get: { project?.webTools != false },
                                     set: { value in editProject(store, projectID) { $0.webTools = value } })) {
                    Label("联网工具", systemImage: "globe")
                }
            }
            // Enabled by default across all projects and chats unless explicitly switched off.
            Toggle(isOn: Binding(get: { project?.timeAwareness != false },
                                 set: { value in editProject(store, projectID) { $0.timeAwareness = value } })) {
                Label("告诉角色时间流逝", systemImage: "clock")
            }
            Toggle(isOn: Binding(get: { project?.isLocked == true },
                                 set: { value in editProject(store, projectID) { $0.isLocked = value } })) {
                Label("面容 ID 锁", systemImage: "faceid")
            }
            Divider()
            Button("删除项目", systemImage: "trash", role: .destructive) { confirmDelete = true }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("项目选项")
        .accessibilityIdentifier("project-options")
    }

    private var memorySummary: String {
        _ = store.studyRevision
        if let subject = project?.studySubject {
            guard let noteCount = try? store.studyRecords(for: projectID).count else { return "暂时无法读取" }
            if subject == .english {
                let wordSum = try? store.studyWordSummary(projectID: projectID)
                let learned = wordSum?.learnedWords ?? 0
                let today = wordSum?.todayWords ?? 0
                let totalWords = wordSum?.totalWords ?? 0
                let answeredReadings = (try? store.studyReadingAnsweredCount(projectID: projectID)) ?? 0
                let totalReadings = (try? store.studyReadingCount(projectID: projectID)) ?? 0
                if learned > 0 || answeredReadings > 0 || noteCount > 0 {
                    let wordPart = today > 0 ? "已背 \(learned) 词(今\(today))" : "已背 \(learned) 词"
                    return "\(wordPart) · 阅读 \(answeredReadings) 题 · \(noteCount) 笔记"
                } else if totalWords > 0 || totalReadings > 0 {
                    return "词库 \(totalWords) 词 · 阅读 \(totalReadings) 篇"
                } else {
                    return "点击导入词库 / 真题包"
                }
            } else {
                let topicCount = (try? store.studyTopics(projectID: projectID).count) ?? 0
                let practiceCount = (try? store.studyPractices(projectID: projectID).count) ?? 0
                if topicCount > 0 || practiceCount > 0 || noteCount > 0 {
                    return "专题 \(topicCount) · 练习 \(practiceCount) 题 · \(noteCount) 笔记"
                } else {
                    return "0 条学习记录"
                }
            }
        }
        if store.memorizingProjectID == projectID { return "正在整理…" }
        let count = (project?.memory ?? "").components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if count == 0 { return project?.remembers == true ? "离开对话后自动整理" : "手动填写" }
        return "\(count) 条"
    }

    private func pill(_ title: String) -> some View {
        Text(title).font(TypeScale.serif(17).weight(.semibold)).foregroundStyle(Ink.ink)
            .frame(maxWidth: .infinity).frame(height: 50)
            .overlay(InkCapsule().stroke(Ink.line, lineWidth: 1))
            .contentShape(Capsule())
    }
}

// What the project remembers across conversations; yours to read, correct or clear.
@MainActor
struct ProjectMemoryView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    @State private var draft = ""
    @State private var confirmClear = false
    private var project: ChatProject? { store.isLocked(projectID) ? nil : store.project(projectID) }
    private var changed: Bool { draft != (project?.memory ?? "") }
    private var overLimit: Bool { draft.count > ChatProject.memoryCharacterLimit }

    var body: some View {
        Form {
            if project == nil {
                Text("项目已上锁或不存在，请返回后重新打开。").foregroundStyle(Ink.ink3)
            } else {
            Section {
                TextEditor(text: $draft).frame(minHeight: 260).font(TypeScale.serif(15)).scrollContentBackground(.hidden)
                    .accessibilityIdentifier("project-memory-editor")
                Text("\(draft.count.formatted()) / \(ChatProject.memoryCharacterLimit.formatted()) 字")
                    .font(TypeScale.tiny).foregroundStyle(overLimit ? Color.red : Ink.ink3)
                if overLimit {
                    Text("请删减到 4,000 字以内再保存，超出的内容不会被自动截断。")
                        .font(TypeScale.label).foregroundStyle(.red)
                }
            } footer: {
                Text(footer)
            }
            Section {
                Button("清空记忆", role: .destructive) { confirmClear = true }
                    .disabled((project?.memory ?? "").isEmpty || !store.canPersist)
            }
            }
        }
        .font(TypeScale.body)
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle("项目备忘（跨对话）")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") {
                    guard project != nil, store.canPersist, !overLimit else { return }
                    if store.setMemory(draft, for: projectID) { dismiss() }
                }.disabled(!changed || overLimit || project == nil || !store.canPersist)
            }
        }
        .confirmationDialog("清空这个项目的记忆？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                guard project != nil, store.canPersist else { return }
                if store.setMemory(nil, for: projectID) { draft = "" }
            }
        } message: { Text("已经整理过的对话不会再被重新记一遍。") }
        .onAppear { draft = project?.memory ?? "" }
        .onChange(of: project?.memory) { old, new in
            // A background update landed; take it unless you are mid-edit.
            if draft == (old ?? "") { draft = new ?? "" }
        }
        .interactiveDismissDisabled(changed)
        .errorAlert(store)
    }

    private var footer: String {
        var parts: [String] = []
        if store.memorizingProjectID == projectID { parts.append("正在整理刚才的对话…") }
        if let date = project?.memoryUpdatedAt { parts.append("上次更新：\(date.formatted(date: .abbreviated, time: .shortened))。") }
        if project?.remembers == true {
            parts.append(project?.service == .chatGPT ?
                "离开这个项目里的对话时，ChatGPT 会把新内容整理进来，用的是订阅额度。每条一行，可以直接改。" :
                "离开对话、切到后台、长对话每聊约20条，或你说「记住……」「忘掉……」时，DeepSeek Flash 会把新内容整理进来，每次花费很少。本项目新开的对话都会带上这些记忆。每条一行，可以直接改。")
        } else {
            parts.append(project?.service == .chatGPT ?
                "可以手动写下长期要求和已确认的结论。这里不自动整理，记忆会随本项目的每次提问发给模型。" :
                "可以手动写下长期要求和已确认的结论，记忆会随本项目的每次提问发给模型。想让它自动整理，在项目选项里打开「跨对话记忆」。")
        }
        parts.append("上限 \(ChatProject.memoryCharacterLimit) 字。")
        return parts.joined(separator: " ")
    }
}

// The project's documents: each sent with every request while switched on.
@MainActor
struct ProjectFilesView: View {
    @EnvironmentObject private var store: AppStore
    let projectID: UUID
    @State private var importing = false
    @State private var choosingFiles = false
    @State private var importTask: Task<Void, Never>?
    @State private var importProgress = ""
    @State private var importReport: String?
    @State private var search = ""
    @State private var editingDocument: ProjectDocument?
    private var project: ChatProject? { store.isLocked(projectID) ? nil : store.project(projectID) }
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var visibleDocuments: [ProjectDocument] {
        (project?.documents ?? []).filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query)
        }
    }
    private var cannotAdd: Bool {
        project == nil || !store.canPersist || (project?.documents.count ?? 0) >= 50 || importing || choosingFiles
    }

    var body: some View {
        Form {
            if project == nil {
                Text("项目已上锁或不存在，请返回后重新打开。").foregroundStyle(Ink.ink3)
            } else {
            if project?.studySubject != nil {
                Section {
                    NavigationLink { StudyMemoryView(projectID: projectID) } label: {
                        Label("词库、阅读真题包与学习进度请点此管理（或在下方直接选 JSON 自动识别导入）", systemImage: "graduationcap.fill")
                            .font(TypeScale.caption.weight(.medium))
                            .foregroundStyle(Ink.seal)
                    }
                }
            }
            Section {
                if visibleDocuments.isEmpty {
                    Text(query.isEmpty ? "还没有资料，可以导入文件或粘贴文字。" : "没有匹配的资料，试试名称或正文中的其他关键词。")
                        .foregroundStyle(Ink.ink3)
                }
                ForEach(visibleDocuments) { document in
                    HStack(spacing: 14) {
                        Button { editingDocument = document } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(document.name).foregroundStyle(Ink.ink).lineLimit(1)
                                    Text("\(document.text.count.formatted()) 字 · 点开查看与编辑")
                                        .font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Toggle("提问时引用", isOn: Binding(get: { document.isIncluded }, set: { value in
                            updateDocuments { documents in
                                if let i = documents.firstIndex(where: { $0.id == document.id }) { documents[i].isIncluded = value }
                            }
                        }))
                        .labelsHidden().fixedSize()
                        .accessibilityLabel("提问时引用《\(document.name)》")
                        .disabled(!store.canPersist)
                    }
                }
                .onDelete(perform: removeDocuments)
            } header: {
                Text(query.isEmpty ? "资料 · \(project?.documents.count ?? 0) / 50" : "搜索结果 · \(visibleDocuments.count)")
            } footer: {
                Text("启用的资料每次提问都会发给模型，会增加 token 用量。已启用 \((project?.includedCharacters ?? 0).formatted()) / \(ChatProject.documentCharacterLimit.formatted()) 字。左滑可删除。")
            }
            Section {
                Button { chooseFiles() } label: { Label(choosingFiles ? "正在打开文件…" : "导入 PDF / 文字文件", systemImage: "doc.badge.plus") }
                    .disabled(cannotAdd)
                Button { pasteDocument() } label: { Label("粘贴文字作为资料", systemImage: "doc.on.clipboard") }
                    .disabled(cannotAdd)
            } footer: {
                if (project?.documents.count ?? 0) >= 50 {
                    Text("已达到 50 份资料上限，可以编辑已有资料或删除不再需要的资料。")
                } else if (project?.includedCharacters ?? 0) >= ChatProject.documentCharacterLimit {
                    Text("启用资料已达到10万字，新资料仍可导入，引用开关会先关闭。可稍后选择需要一起提问的资料。")
                } else {
                    Text("支持带文字层的PDF、TXT和Markdown。PDF最多30 MB、1000页；文字文件最多2 MB，每份提取内容最多10万字。PDF保留文件物理页码；扫描件请先做文字识别。")
                }
            }
            if importing {
                Section {
                    HStack(spacing: 12) { ProgressView(); Text(importProgress).font(TypeScale.label).lineLimit(2) }
                    Button("取消剩余导入", role: .cancel) { importTask?.cancel() }
                } footer: { Text("文件逐份读取并保存；取消时已导入的资料会保留。") }
            }
            if let importReport {
                Section("导入结果") {
                    Text(importReport).font(TypeScale.label).textSelection(.enabled)
                    Button("收起结果") { self.importReport = nil }
                }
            }
            }
        }
        .font(TypeScale.body)
        .tint(Ink.seal)
        .searchable(text: $search, prompt: "搜索资料名称或正文")
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle("项目资料")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingDocument) { document in
            ProjectDocumentEditor(projectID: projectID, document: document).environmentObject(store)
        }
        .onDisappear { importTask?.cancel() }
        .onChange(of: store.isLocked(projectID)) { _, locked in if locked { importTask?.cancel() } }
        .errorAlert(store)
    }

    private func chooseFiles() {
        guard !cannotAdd else { return }
        importReport = nil; choosingFiles = true
        let opened = DocumentPicker.presentMany(DocumentTextImporter.allowedContentTypes, asCopy: true,
            onCancel: { choosingFiles = false; importReport = "已取消选择文件。" },
            onError: { message in choosingFiles = false; importReport = message }) { urls in
                choosingFiles = false
                beginImport(urls)
            }
        if !opened { choosingFiles = false }
    }

    private func beginImport(_ urls: [URL]) {
        guard !urls.isEmpty, !importing else { return }
        importing = true; importReport = nil
        importTask = Task { @MainActor in
            var imported = 0
            var lines: [String] = []
            defer {
                importing = false; importTask = nil; importProgress = ""
                importReport = "已导入 \(imported) / \(urls.count) 份资料。\n\n" + lines.joined(separator: "\n\n")
            }
            for (index, url) in urls.enumerated() {
                if Task.isCancelled {
                    lines.append("已取消，余下\(urls.count - index)份未导入；此前成功的资料已保留。")
                    break
                }
                importProgress = "\(index + 1) / \(urls.count) · \(url.lastPathComponent)"
                do {
                    guard project != nil, store.canPersist else { throw ChatError.server("项目已上锁、被删除或暂时不能保存，请重新打开后导入。") }
                    if url.pathExtension.lowercased() == "json",
                       let studyNotice = await tryImportStudyJSONIfRecognized(url) {
                        imported += 1
                        lines.append(studyNotice)
                        continue
                    }
                    guard (project?.documents.count ?? 0) < 50 else { throw ChatError.server("项目已达到50份资料上限，这份文件没有导入。") }
                    let content = try await DocumentTextImporter.load(url, apiKey: store.apiKey)
                    try Task.checkCancellation()
                    let included = try saveImported(content)
                    imported += 1
                    var result = "✓ \(url.lastPathComponent) · \(content.text.count.formatted())字"
                    if !included {
                        result += project?.studySubject != nil
                            ? "\n已保存：学习项目默认由工具按需查阅资料，不随每次提问整篇发送。"
                            : "\n已保存，引用开关先关闭：启用资料合计会超过10万字。"
                    }
                    if !content.warnings.isEmpty { result += "\n" + content.warnings.joined(separator: "\n") }
                    lines.append(result)
                } catch is CancellationError {
                    lines.append("已取消，当前及余下\(urls.count - index)份未导入；此前成功的资料已保留。")
                    break
                } catch {
                    lines.append("未导入 \(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
        }
    }

    private func tryImportStudyJSONIfRecognized(_ url: URL) async -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 32 * 1024 * 1024,
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        if (try? StudyWordPack.decode(data)) != nil {
            if project?.studySubject != .english {
                editProject(store, projectID) { $0.studySubject = .english; $0.autoMemory = true }
            }
            if await store.importStudyVocabulary(projectID: projectID, url: url) {
                let count = (try? store.studyVocabularyCount(projectID: projectID)) ?? 0
                return "✓ \(url.lastPathComponent)\n已自动识别为【英语词库】并导入学习数据库（当前词库共 \(count) 词，可在「学习档案与进度」查看或在聊天中直接说“开始背单词”）。"
            }
        }
        if (try? StudyReadingPack.decode(data)) != nil {
            if project?.studySubject != .english {
                editProject(store, projectID) { $0.studySubject = .english; $0.autoMemory = true }
            }
            if await store.importStudyReadings(projectID: projectID, url: url) {
                let count = (try? store.studyReadingCount(projectID: projectID)) ?? 0
                return "✓ \(url.lastPathComponent)\n已自动识别为【英语阅读资料】并导入学习数据库（当前共 \(count) 篇，可在聊天中直接说年份和 Text 编号开始精读）。"
            }
        }
        if let pack = try? StudyHistoryPack.decode(data) {
            if project?.studySubject != .history {
                editProject(store, projectID) { $0.studySubject = .history; $0.autoMemory = true }
            }
            if store.importHistoryPack(projectID: projectID, pack: pack, confirmed: pack.kind == "outline") {
                return "✓ \(url.lastPathComponent)\n已自动识别为【313 历史资料（\(pack.entries.count) 条）】并导入学习数据库。"
            }
        }
        if (try? StudyTemporaryMap.decode(data)) != nil {
            if project?.studySubject != .history {
                editProject(store, projectID) { $0.studySubject = .history; $0.autoMemory = true }
            }
            if await store.importTemporaryHistoryMap(projectID: projectID, url: url) {
                return "✓ \(url.lastPathComponent)\n已自动识别为【313 历史网络临时学习地图】并导入学习数据库。"
            }
        }
        return nil
    }

    // Resolve the current project after each await, preserving new memory and concurrent edits.
    private func saveImported(_ imported: ImportedTextDocument) throws -> Bool {
        guard !store.isLocked(projectID), store.canPersist, var latest = store.project(projectID) else {
            throw ChatError.server("项目暂时无法保存，请重新打开后导入。")
        }
        guard latest.documents.count < 50 else { throw ChatError.server("项目已达到50份资料上限，这份文件没有导入。") }
        var document = ProjectDocument(name: imported.name, text: imported.text)
        if latest.studySubject != nil {
            document.isIncluded = false
        } else {
            document.isIncluded = latest.includedCharacters + document.text.count <= ChatProject.documentCharacterLimit
        }
        latest.documents.append(document)
        guard store.updateProject(latest) else { throw ChatError.server(store.errorMessage ?? "资料没有保存成功，请稍后重试。") }
        return document.isIncluded
    }

    private func updateDocuments(_ change: (inout [ProjectDocument]) -> Void) {
        guard !store.isLocked(projectID), store.canPersist, var latest = store.project(projectID) else {
            store.errorMessage = "项目暂时无法修改，请返回后重新打开。"
            return
        }
        change(&latest.documents)
        guard latest.documents.count <= 50 else {
            store.errorMessage = "每个项目最多保存 50 份资料，请减少本次导入数量或先删除部分资料。"
            return
        }
        _ = store.updateProject(latest)
    }

    private func removeDocuments(_ offsets: IndexSet) {
        let shown = visibleDocuments
        let ids = Set(offsets.compactMap { shown.indices.contains($0) ? shown[$0].id : nil })
        updateDocuments { $0.removeAll { ids.contains($0.id) } }
    }

    private func pasteDocument() {
        guard let text = UIPasteboard.general.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            store.errorMessage = "剪贴板里没有可导入的文字。"
            return
        }
        guard text.count <= ChatProject.documentCharacterLimit else {
            store.errorMessage = "这份资料超过 10 万字，请拆开再粘贴；内容没有被截断。"
            return
        }
        do {
            let imported = ImportedTextDocument(name: "粘贴的资料 \((project?.documents.count ?? 0) + 1)", text: text, warnings: [])
            let included = try saveImported(imported)
            importReport = included ? "已粘贴并保存资料。" : "已粘贴并保存资料；启用合计会超过10万字，引用开关先关闭。"
        } catch { store.errorMessage = error.localizedDescription }
    }
}

@MainActor
private struct ProjectDocumentEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let document: ProjectDocument
    @State private var name: String
    @State private var text: String
    @State private var isIncluded: Bool
    @State private var saveError: String?
    @State private var shareURL: URL?

    init(projectID: UUID, document: ProjectDocument) {
        self.projectID = projectID; self.document = document
        _name = State(initialValue: document.name)
        _text = State(initialValue: document.text)
        _isIncluded = State(initialValue: document.isIncluded)
    }

    private var project: ChatProject? { store.isLocked(projectID) ? nil : store.project(projectID) }
    private var changed: Bool { name != document.name || text != document.text || isIncluded != document.isIncluded }
    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var includedCharacters: Int {
        let other = (project?.documents ?? []).filter { $0.id != document.id && $0.isIncluded }.reduce(0) { $0 + $1.text.count }
        return other + (isIncluded ? text.count : 0)
    }
    private var validationMessage: String? {
        guard let project, project.documents.contains(where: { $0.id == document.id }) else { return "资料已不存在或项目已上锁，请返回后重新打开。" }
        guard store.canPersist else { return "当前暂时不能保存，请稍后重试。" }
        guard !cleanName.isEmpty else { return "请填写资料名称。" }
        guard cleanName.count <= 200 else { return "资料名称最多 200 字。" }
        guard text.count <= ChatProject.documentCharacterLimit else { return "正文最多 10 万字，请删减或拆成多份资料；保存不会截断内容。" }
        guard includedCharacters <= ChatProject.documentCharacterLimit else { return "启用的资料合计超过 10 万字，请关闭这份资料的引用开关或缩短正文后保存。" }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if project == nil {
                    Text("项目已上锁或不存在，请返回后重新打开。").foregroundStyle(Ink.ink3)
                } else {
                    Section("资料名称") {
                        TextField("名称", text: $name).accessibilityIdentifier("project-document-name")
                    }
                    Section {
                        TextEditor(text: $text).frame(minHeight: 300).font(TypeScale.serif(15)).scrollContentBackground(.hidden)
                            .accessibilityIdentifier("project-document-text")
                    } header: { Text("正文 · \(text.count.formatted()) / \(ChatProject.documentCharacterLimit.formatted()) 字") }
                    Section {
                        Toggle("提问时引用这份资料", isOn: $isIncluded)
                    } footer: {
                        Text("保存后启用资料合计：\(includedCharacters.formatted()) / \(ChatProject.documentCharacterLimit.formatted()) 字。关闭引用仍会保留资料。")
                    }
                    if let validationMessage {
                        Text(validationMessage).font(TypeScale.label).foregroundStyle(.red)
                    }
                    if let saveError {
                        Text(saveError).font(TypeScale.label).foregroundStyle(.red)
                    }
                }
            }
            .font(TypeScale.body).scrollContentBackground(.hidden).background(AppBackground())
            .navigationTitle("查看与编辑资料").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button("复制正文", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                        Button("分享文字文件", systemImage: "square.and.arrow.up") { shareDocument() }
                    } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("资料操作").disabled(project == nil)
                    Button("保存") { save() }.disabled(!changed || validationMessage != nil)
                }
            }
        }
        .tint(Ink.seal)
        .interactiveDismissDisabled(changed)
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let url = shareURL { ShareSheet(items: [url]) }
        }
    }

    private func save() {
        guard validationMessage == nil, !store.isLocked(projectID), var latest = store.project(projectID),
              let index = latest.documents.firstIndex(where: { $0.id == document.id }) else {
            saveError = validationMessage ?? "资料暂时无法保存，请重新打开后再试。"
            return
        }
        // Merge only this document into the latest project, preserving newer memory and other files.
        latest.documents[index].name = cleanName
        latest.documents[index].text = text
        latest.documents[index].isIncluded = isIncluded
        if store.updateProject(latest) { dismiss() }
        else { saveError = store.errorMessage ?? "资料未能保存，请稍后再试。" }
    }

    private func shareDocument() {
        guard project != nil else { return }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sermo-Document-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let banned = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r")
            let base = cleanName.components(separatedBy: banned).joined()
            let fileName = String((base.isEmpty ? "项目资料" : base).prefix(80)) + ".md"
            let url = directory.appendingPathComponent(fileName)
            try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            shareURL = url
        } catch {
            saveError = "文字文件没能导出：\(error.localizedDescription)"
        }
    }
}

@MainActor
struct ProjectInstructionsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("这个项目里的对话只用这段指令，不叠加设置里的系统提示词。可以写身份、语气和规矩，比如「你是一位研究明史的老教授……」。")
                    .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                TextEditor(text: $text).font(TypeScale.serif(17)).scrollContentBackground(.hidden)
                    .padding(12).background(Ink.raised, in: InkRounded(radius: 20))
                    .accessibilityIdentifier("project-instructions")
            }
            .padding(20).background(Ink.paper)
            .navigationTitle("指令").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        guard var project = store.project(projectID) else { dismiss(); return }
                        project.instructions = text
                        if store.updateProject(project) { dismiss() }
                    }.fontWeight(.semibold)
                }
            }
            .errorAlert(store)
        }
        .tint(Ink.ink)
        .onAppear { text = store.project(projectID)?.instructions ?? "" }
    }
}
// "查看全部": every conversation that may be shown, with multi-select to move or delete in bulk.
@MainActor
struct AllChatsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let opened: () -> Void
    @State private var search = ""
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<UUID>()
    @State private var naming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    private var editing: Bool { editMode.isEditing }
    private var shown: [ChatThread] {
        store.browsableThreads.filter { thread in
            search.isEmpty || thread.title.localizedCaseInsensitiveContains(search) ||
                thread.messages.contains(where: { $0.content.localizedCaseInsensitiveContains(search) })
        }
    }

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                ForEach(shown) { thread in
                    if editing { rowLabel(thread).tag(thread.id) }
                    else {
                        Button { store.select(thread.id); opened() } label: { rowLabel(thread) }
                            .buttonStyle(.plain).tag(thread.id)
                    }
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .environment(\.editMode, $editMode)
            .searchable(text: $search, prompt: "搜索对话")
            .navigationTitle("全部对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editing ? "取消" : "选择") {
                        withAnimation { editMode = editing ? .inactive : .active }
                        selection = []
                    }.accessibilityIdentifier("all-chats-select")
                }
                if editing {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button(selection.count == shown.count && !shown.isEmpty ? "全不选" : "全选") {
                            selection = selection.count == shown.count ? [] : Set(shown.map(\.id))
                        }.accessibilityIdentifier("all-chats-select-all")
                        Spacer()
                        Menu("移到项目") {
                            ForEach(store.projects.filter { !store.isLocked($0.id) }) { project in
                                Button(project.name) { move(to: project.id) }
                            }
                            Button("新建项目…", systemImage: "folder.badge.plus") { newName = ""; naming = true }
                            Button("移出项目", systemImage: "tray.and.arrow.up") { move(to: nil) }
                        }
                        .disabled(selection.isEmpty)
                        .accessibilityIdentifier("all-chats-move")
                        Spacer()
                        Button("删除", role: .destructive) { confirmDelete = true }.disabled(selection.isEmpty)
                    }
                }
            }
            .alert("新建项目", isPresented: $naming) {
                TextField("项目名称", text: $newName)
                Button("取消", role: .cancel) { }
                Button("创建并移入") { if let id = store.createProject(name: newName) { move(to: id) } }
            }
            .confirmationDialog("删除选中的 \(selection.count) 个对话？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    for id in selection where id != store.generatingThreadID { store.deleteThread(id) }
                    selection = []; editMode = .inactive
                }
            } message: { Text("附带的图片会一起删除，用量记录不受影响。") }
            .errorAlert(store)
        }
        .tint(Ink.ink)
    }

    private func rowLabel(_ thread: ChatThread) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(thread.title).font(TypeScale.serif(17)).foregroundStyle(Ink.ink).lineLimit(1)
            HStack(spacing: 6) {
                if let project = store.project(thread.projectID) { Text(project.name) }
                Text(thread.updatedAt.formatted(date: .abbreviated, time: .omitted))
            }.font(TypeScale.tiny).foregroundStyle(Ink.ink3)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        .accessibilityIdentifier("all-chats-row")
    }

    private func move(to projectID: UUID?) {
        store.moveThreads(selection, to: projectID)
        selection = []
        withAnimation { editMode = .inactive }
    }
}

// 「让 AI 帮我建项目」 and 「让 AI 调整项目」: describe it, review the result, then save.
struct ProjectDesignerView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    /// nil: a new project. Otherwise the project being adjusted.
    let projectID: UUID?
    var created: (UUID) -> Void = { _ in }

    @State private var wish = ""
    @State private var draft: ProjectDraft?
    @State private var working = false
    @State private var issue: String?
    @State private var task: Task<Void, Never>?

    private var adjusting: Bool { projectID != nil }
    private var original: ProjectDraft? { projectID.flatMap { store.project($0) }.map(ProjectDraft.init) }
    private var usesChatGPT: Bool { projectID.flatMap { store.project($0) }?.service == .chatGPT }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    askSection
                    if let issue {
                        Text(issue).font(TypeScale.caption).foregroundStyle(.red)
                    }
                    if draft != nil { previewSection }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Ink.paper)
            .navigationTitle(adjusting ? "让 AI 调整项目" : "让 AI 帮我建项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { task?.cancel(); dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(adjusting ? "应用" : "创建") { save() }
                        .fontWeight(.semibold)
                        .disabled(draft?.isValid != true || working || !store.canPersist)
                }
            }
            .errorAlert(store)
        }
        .tint(Ink.ink)
        .interactiveDismissDisabled(draft != nil || working)
        .onDisappear { task?.cancel() }
    }

    private var askSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(prompt).font(TypeScale.caption).foregroundStyle(Ink.ink3)
            TextEditor(text: $wish)
                .font(TypeScale.serif(17)).scrollContentBackground(.hidden)
                .frame(minHeight: 96)
                .padding(12).background(Ink.raised, in: InkRounded(radius: 20))
                .accessibilityIdentifier("project-designer-wish")
            Button { generate() } label: {
                HStack(spacing: 8) {
                    if working { ProgressView() } else { Image(systemName: "sparkles") }
                    Text(working ? "正在生成…" : buttonTitle)
                }
                .font(TypeScale.serif(17).weight(.semibold))
                .frame(maxWidth: .infinity).frame(height: 46)
                .overlay(InkCapsule().stroke(Ink.line, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(working || wish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("project-designer-generate")
        }
    }

    private var prompt: String {
        if draft != nil { return "不满意的地方直接说，比如「批改再严一点」「别那么啰嗦」，会在下面的结果上修改。也可以直接改下面的内容。" }
        if adjusting { return "说说这个项目要怎么改，比如「加上每次先抽查上次的错题」。只改你提到的部分，改完先给你看，确认后才保存。" }
        return "用一两句话描述想要的项目，比如「313历史学考研，每天抽查名词解释，按得分点严格批改」或「在家健身教练，没有器械，每次根据我的状态调整」。生成后先给你看，确认后才创建。"
    }

    private var buttonTitle: String {
        if draft != nil { return "按这个要求再改" }
        return adjusting ? "生成修改" : "生成项目"
    }

    @ViewBuilder private var previewSection: some View {
        if let binding = Binding($draft) {
            VStack(alignment: .leading, spacing: 14) {
                if !binding.wrappedValue.summary.isEmpty {
                    Text(binding.wrappedValue.summary).font(TypeScale.serif(15)).foregroundStyle(Ink.ink2)
                }
                field("名称") {
                    TextField("项目名称", text: binding.name).font(TypeScale.serif(17))
                        .padding(12).background(Ink.raised, in: InkRounded(radius: 16))
                }
                VStack(alignment: .leading, spacing: 4) {
                    if store.canUsePureRoleplay(projectID.flatMap { store.project($0) }) {
                        Toggle("纯角色扮演模式", isOn: binding.pureRoleplay)
                        Toggle("跨对话备忘", isOn: binding.autoMemory)
                        if usesChatGPT {
                            Text("ChatGPT 项目关掉这里即停止自动整理。").font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                        }
                    }
                    Toggle("告诉角色时间流逝", isOn: binding.timeAwareness)
                }
                .font(TypeScale.serif(17)).tint(Ink.seal)
                field("指令（\(binding.wrappedValue.instructions.count) 字）") {
                    TextEditor(text: binding.instructions)
                        .font(TypeScale.serif(15)).scrollContentBackground(.hidden)
                        .frame(minHeight: 280)
                        .padding(12).background(Ink.raised, in: InkRounded(radius: 16))
                        .accessibilityIdentifier("project-designer-instructions")
                }
                if !adjusting {
                    field("初始记忆") {
                        TextEditor(text: binding.memory)
                            .font(TypeScale.serif(15)).scrollContentBackground(.hidden)
                            .frame(minHeight: 100)
                            .padding(12).background(Ink.raised, in: InkRounded(radius: 16))
                    }
                } else {
                    Text("项目记忆和资料不会被修改。").font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                }
                if !binding.wrappedValue.isValid {
                    Text("请填写名称（80字内），并检查指令和记忆的长度。").font(TypeScale.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(TypeScale.caption).foregroundStyle(Ink.ink3)
            content()
        }
    }

    private func generate() {
        let request = wish
        let base = draft ?? original
        issue = nil
        working = true
        task = Task {
            defer { working = false; task = nil }
            do {
                var result = try await store.designProject(request, base: base)
                try Task.checkCancellation()
                // Adjusting never rewrites the project's saved memory.
                if adjusting, let original { result.memory = original.memory }
                draft = result
                wish = ""
            } catch is CancellationError {
            } catch {
                issue = "没能生成：\(error.localizedDescription)"
            }
        }
    }

    private func save() {
        guard let draft, draft.isValid else { return }
        if let projectID {
            if store.applyDraft(draft, to: projectID, includingMemory: false) { dismiss() }
        } else if let id = store.createProject(from: draft) {
            dismiss()
            created(id)
        }
    }
}
