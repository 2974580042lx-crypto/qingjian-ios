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
    var initialProjectID: UUID? = nil
    @State private var path: [UUID] = []
    @State private var creating = false
    @State private var newName = ""
    @State private var designing = false

    init(opened: @escaping () -> Void, initialProjectID: UUID? = nil, initiallyUnlocked: Bool = false) {
        self.opened = opened
        self.initialProjectID = initialProjectID
        self._path = State(initialValue: (initiallyUnlocked && initialProjectID != nil) ? [initialProjectID!] : [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if store.projects.isEmpty {
                    Text("项目有自己的指令、资料和默认模型。项目里的对话只在项目中出现，不会进侧栏的「最近」。")
                        .font(TypeScale.ui(14.5)).foregroundStyle(Ink.ink3)
                        .listRowBackground(Ink.paper)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(store.projects) { project in
                        Button { open(project.id) } label: {
                            HStack(spacing: 14) {
                                ClaudeIconBadge(
                                    systemName: project.isLocked ? "lock" : (project.studySubject != nil ? "graduationcap" : "folder"),
                                    color: project.studySubject != nil ? Ink.seal : Ink.ink2,
                                    size: 18,
                                    weight: .regular
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(project.name).font(TypeScale.ui(16.5, weight: .regular)).foregroundStyle(Ink.ink)
                                    Text(project.isLocked && store.isLocked(project.id) ? "已上锁" : "\(store.threads(in: project.id).count) 个对话")
                                        .font(TypeScale.ui(13)).foregroundStyle(Ink.ink3)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.ink3.opacity(0.6))
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Ink.paper)
                        .listRowSeparatorTint(Ink.line.opacity(0.6))
                        .accessibilityIdentifier("project-row")
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle("项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ClaudeSheetCloseButton(label: "完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("让 AI 帮我建", systemImage: "sparkles") { designing = true }
                        Button("新建空白项目", systemImage: "folder.badge.plus") { newName = ""; creating = true }
                        Button("恢复学习项目", systemImage: "arrow.uturn.backward") {
                            archivedStudy = store.archivedStudyProjects(); restoringStudy = true
                        }
                    } label: { Image(systemName: "plus").font(.system(size: 15, weight: .regular)) }
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
                        Section {
                            if archivedStudy.isEmpty { Text("没有可恢复的学习项目").foregroundStyle(Ink.ink3) }
                            ForEach(archivedStudy) { item in
                                Button { if store.restoreStudyProject(item) { restoringStudy = false } } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.project.name).foregroundStyle(Ink.ink)
                                        Text("恢复项目指令、学习记录和仍保留的对话归属").font(TypeScale.caption).foregroundStyle(Ink.ink3)
                                    }
                                }
                            }
                        }
                        .claudeCardRow()
                    }
                    .claudeGroupedListStyle()
                    .navigationTitle("恢复学习项目")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarLeading) { ClaudeSheetCloseButton(label: "完成") { restoringStudy = false } } }
                }
                .tint(Ink.ink)
            }
        }
        .tint(Ink.ink)
        .onAppear {
            if let initialProjectID, path.isEmpty {
                if store.isLocked(initialProjectID) {
                    open(initialProjectID)
                } else if store.project(initialProjectID) != nil {
                    path = [initialProjectID]
                }
            } else if ProcessInfo.processInfo.arguments.contains("--preview-project"), let first = store.projects.first {
                path = [first.id]
            }
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

// 1:1 Claude iOS Project homepage: clean neutral canvas, three lightweight outlined
// capsules (添加文件 / 添加指令 / 查看记忆), natural un-boxed conversation rows, and
// bottom-right floating "+ 新建会话" pill.
@MainActor
struct ProjectPageView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let opened: () -> Void
    @State private var editingInstructions = false
    @State private var showingFiles = false
    @State private var showingMemory = false
    @State private var showingWorkspace = false
    @State private var editingDetails = false
    @State private var adjusting = false
    @State private var confirmDelete = false
    @State private var selectedDeliverable: ProjectDeliverable?
    private var project: ChatProject? { store.project(projectID) }

    var body: some View {
        let threads = store.threads(in: projectID)
        let libraryDocs = store.libraryDocuments(for: projectID)
        let projectDeliverables = store.workspaceDeliverables(projectID: projectID, threadID: nil)
        let totalFileCount = (project?.documents.count ?? 0) + libraryDocs.count
        let hasInstructions = !(project?.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        List {
            // 1. Three lightweight outlined horizontal capsules (1:1 Claude iOS)
            HStack(spacing: 8) {
                Button { showingFiles = true } label: {
                    claudeOutlineCapsule(totalFileCount == 0 ? "添加文件" : "文件 · \(totalFileCount)")
                }
                .accessibilityIdentifier("project-files")

                Button { editingInstructions = true } label: {
                    claudeOutlineCapsule(hasInstructions ? "编辑指令" : "添加指令")
                }
                .accessibilityIdentifier("project-instructions-button")

                Button { showingMemory = true } label: {
                    claudeOutlineCapsule(project?.studySubject != nil ? "学习档案" : "查看记忆")
                }
                .accessibilityIdentifier("project-memory")
            }
            .buttonStyle(.plain)
            .listRowBackground(Ink.paper)
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            .listRowSeparator(.hidden)

            // Study English daily words strip (kept lightweight, zero white card box)
            if project?.studySubject == .english,
               let todayList = (try? store.studyWordSummary(projectID: projectID))?.todayWordsList,
               !todayList.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("今日已聊")
                            .font(TypeScale.tiny.weight(.medium))
                            .foregroundStyle(Ink.ink3)
                        ForEach(todayList.prefix(16), id: \.word.id) { item in
                            Text(item.word.word)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(Ink.ink2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Ink.raised, in: Capsule())
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowBackground(Ink.paper)
                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 6, trailing: 16))
                .listRowSeparator(.hidden)
            }

            // 2. Deliverables section (only shown when real generated deliverables exist — single-column Claude rows, zero nested card box)
            if !projectDeliverables.isEmpty {
                Section {
                    ForEach(projectDeliverables.prefix(3)) { item in
                        DeliverableFileRow(item: item) {
                            selectedDeliverable = item
                        }
                        .listRowBackground(Ink.paper)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)
                    }
                    if projectDeliverables.count > 3 {
                        Button { showingWorkspace = true } label: {
                            HStack(spacing: 4) {
                                Text("查看全部 \(projectDeliverables.count) 份成果")
                                    .font(TypeScale.caption)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(Ink.ink3)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Ink.paper)
                        .listRowInsets(EdgeInsets(top: 2, leading: 18, bottom: 6, trailing: 16))
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    Text("项目成果")
                        .font(TypeScale.ui(13.5))
                        .foregroundStyle(Ink.ink3)
                        .textCase(nil)
                }
            }

            // 3. Natural un-boxed recent conversations list (1:1 Claude iOS)
            if threads.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(Ink.ink2)
                        .frame(width: 48, height: 48)
                        .background(Ink.raised, in: Circle())
                    Text("向 Sermo 提出任何问题")
                        .font(TypeScale.ui(15.5, weight: .medium))
                        .foregroundStyle(Ink.ink)
                    Text("此项目中的会话将显示在这里。")
                        .font(TypeScale.ui(13.5))
                        .foregroundStyle(Ink.ink3)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
                .listRowBackground(Ink.paper)
                .listRowSeparator(.hidden)
            } else {
                Section {
                    ForEach(threads) { thread in
                        Button { store.select(thread.id); opened() } label: {
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: "bubble.left")
                                    .font(.system(size: 18, weight: .light))
                                    .foregroundStyle(Ink.ink2)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(thread.title)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(Ink.ink)
                                        .lineLimit(1)
                                    Text(Self.friendlyRelativeDate(thread.updatedAt))
                                        .font(.system(size: 13.5, weight: .regular))
                                        .foregroundStyle(Ink.ink3)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Ink.paper)
                        .listRowInsets(EdgeInsets(top: 2, leading: 18, bottom: 2, trailing: 18))
                        .listRowSeparator(.hidden)
                        .swipeActions {
                            Button("移出") { store.moveThreads([thread.id], to: nil) }.tint(Ink.ink3)
                        }
                        .accessibilityIdentifier("project-thread-row")
                    }
                } header: {
                    Text("最近")
                        .font(TypeScale.ui(13.5))
                        .foregroundStyle(Ink.ink3)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Ink.paper.ignoresSafeArea())
        .contentMargins(.bottom, 92, for: .scrollContent)
        .overlay(alignment: .bottomTrailing) {
            Button { store.createThread(in: projectID); opened() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 13.5, weight: .medium))
                    Text("新建会话")
                }
            }
            .buttonStyle(.claudeSecondaryPill)
            .padding(.trailing, 20).padding(.bottom, 14)
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
        .sheet(isPresented: $showingFiles) {
            ProjectFilesSheet(projectID: projectID).environmentObject(store)
        }
        .sheet(isPresented: $showingMemory) {
            ProjectMemorySheet(projectID: projectID).environmentObject(store)
        }
        .sheet(isPresented: $showingWorkspace) {
            ProjectWorkspaceSheet(projectID: projectID, threadID: nil, initialTab: .deliverables)
                .environmentObject(store)
        }
        .sheet(isPresented: $editingInstructions) {
            ProjectInstructionsView(projectID: projectID).environmentObject(store)
        }
        .sheet(isPresented: $editingDetails) {
            ProjectDetailsEditSheet(projectID: projectID) {
                adjusting = true
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $adjusting) {
            ProjectDesignerView(projectID: projectID).environmentObject(store)
        }
        .sheet(item: $selectedDeliverable) { item in
            DeliverableDetailSheet(deliverable: item)
                .environmentObject(store)
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

    // 1:1 Claude iOS clean native floating menu: 编辑详情 / 项目成果与检索 / 删除
    private var optionsMenu: some View {
        Menu {
            Button("编辑详情", systemImage: "doc.badge.gearshape") {
                editingDetails = true
            }
            if project?.studySubject == nil {
                // 1.46: Claude's incognito chat — the project's memory never reads it and later
                // chats never find it.
                Button("新建无痕会话", systemImage: "eye.slash") {
                    store.createIncognitoThread(in: projectID)
                    opened()
                }
            }
            Button("项目成果与文献检索", systemImage: "archivebox") {
                showingWorkspace = true
            }
            Divider()
            Button("删除", systemImage: "trash", role: .destructive) {
                confirmDelete = true
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("项目选项")
        .accessibilityIdentifier("project-options")
    }

    private func claudeOutlineCapsule(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14.5, weight: .medium))
            .foregroundStyle(Ink.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.86)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Ink.paper, in: Capsule())
            .overlay(Capsule().stroke(Ink.line, lineWidth: 0.9))
            .contentShape(Capsule())
    }

    private static func friendlyRelativeDate(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 120 { return "此刻" }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return "今天 " + date.formatted(date: .omitted, time: .shortened)
        }
        if cal.isDateInYesterday(date) {
            return "昨天"
        }
        return date.formatted(.dateTime.month().day())
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
            Group {
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
            }.claudeCardRow()
        }
        .claudeGroupedFormStyle()
        .navigationTitle("项目备忘（跨对话）")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") {
                    guard project != nil, store.canPersist, !overLimit else { return }
                    if store.setMemory(draft, for: projectID) { dismiss() }
                }.fontWeight(.semibold).disabled(!changed || overLimit || project == nil || !store.canPersist)
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
            parts.append("离开对话、切到后台、长对话每聊约 20 条，或你说「记住……」「忘掉……」时，会把你说过、以后还用得上的事整理进来（默认用 DeepSeek Flash，没有余额时改用 ChatGPT 订阅）。每条一行，可以直接改；改动可以在记忆页「最近的变化」里撤回。")
        } else {
            parts.append("可以手动写下长期要求和已确认的结论。想让它自动整理，在项目设置里打开「跨对话记忆」。")
        }
        parts.append("最多 \(ProjectMemoryItem.countLimit) 条，每条 \(ProjectMemoryItem.textLimit) 字以内。")
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
    @State private var importingLibrary = false
    @State private var libraryProgress = ""
    @State private var libraryReport: String?
    @State private var libraryTask: Task<Void, Never>?
    @State private var previewingLibraryDoc: ProjectWorkspaceSheet.LibrarySectionPreview?
    private var project: ChatProject? { store.isLocked(projectID) ? nil : store.project(projectID) }
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var visibleLibraryDocuments: [ProjectLibraryDocument] {
        store.libraryDocuments(for: projectID).filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        }
    }
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
            Group {
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
                if visibleLibraryDocuments.isEmpty {
                    Text(query.isEmpty ? "还没有入库的大文献。把专著、史料 PDF、Word 或 EPUB 导入这里，AI 会按需秒级检索原文与页码，不占平时聊天上下文。" : "百万字文献库中没有匹配此关键词的文件名。")
                        .font(TypeScale.caption)
                        .foregroundStyle(Ink.ink3)
                } else {
                    ForEach(visibleLibraryDocuments) { doc in
                        Button {
                            let content = store.readLibrarySection(projectID: projectID, documentID: doc.id, chunkIndex: 0, window: 3)
                            previewingLibraryDoc = ProjectWorkspaceSheet.LibrarySectionPreview(id: doc.id, title: doc.name, content: content)
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(doc.name).foregroundStyle(Ink.ink).lineLimit(1)
                                    Text("\(doc.characterCount.formatted()) 字 · \(doc.chunkCount) 段全文索引 · \(doc.fileExtension.uppercased())")
                                        .font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right").font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        let targets = offsets.map { visibleLibraryDocuments[$0] }
                        for doc in targets {
                            store.deleteLibraryDocument(projectID: projectID, documentID: doc.id)
                        }
                    }
                }
                Button { chooseLibraryFiles() } label: {
                    Label(importingLibrary ? "正在建库导入…" : "导入大文献到按需检索库", systemImage: "books.vertical")
                }
                .disabled(project == nil || !store.canPersist || importingLibrary)
                if importingLibrary {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(libraryProgress).font(TypeScale.label).lineLimit(2)
                    }
                    Button("取消剩余建库", role: .cancel) { libraryTask?.cancel() }
                }
                if let libraryReport {
                    Text(libraryReport).font(TypeScale.label).textSelection(.enabled)
                    Button("收起结果") { self.libraryReport = nil }
                }
            } header: {
                Text("百万字按需检索文献库（推荐 · \(store.libraryDocuments(for: projectID).count) 份）")
            } footer: {
                Text("存在独立本地全文数据库里，不挤占聊天记录和每次提问额度。支持 PDF（最高 80 MB / 3000 页，保留物理页码）、Word、Excel、EPUB、ZIP 与纯文本。左滑可移除。")
            }
            Section {
                if visibleDocuments.isEmpty {
                    Text(query.isEmpty ? "还没有随提问整篇发送的资料，可以导入文件或粘贴文字。" : "没有匹配的资料，试试名称或正文中的其他关键词。")
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
                        .labelsHidden().fixedSize().tint(Ink.seal)
                        .accessibilityLabel("提问时引用《\(document.name)》")
                        .disabled(!store.canPersist)
                    }
                }
                .onDelete(perform: removeDocuments)
            } header: {
                Text(query.isEmpty ? "随提问整篇发送的资料 · \(project?.documents.count ?? 0) / 50" : "搜索结果 · \(visibleDocuments.count)")
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
            }.claudeCardRow()
        }
        .claudeGroupedFormStyle()
        .searchable(text: $search, prompt: "搜索资料名称或正文")
        .navigationTitle("项目资料")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingDocument) { document in
            ProjectDocumentEditor(projectID: projectID, document: document).environmentObject(store)
        }
        .sheet(item: $previewingLibraryDoc) { item in
            NavigationStack {
                ScrollView {
                    Text(item.content.isEmpty ? "（暂无内容）" : item.content)
                        .font(TypeScale.ui(14.5))
                        .foregroundStyle(Ink.ink)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .background(Ink.paper.ignoresSafeArea())
                .navigationTitle(item.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        ClaudeSheetCloseButton(label: "关闭") { previewingLibraryDoc = nil }
                    }
                }
            }
            .tint(Ink.ink)
        }
        .onDisappear {
            importTask?.cancel()
            libraryTask?.cancel()
        }
        .onChange(of: store.isLocked(projectID)) { _, locked in
            if locked {
                importTask?.cancel()
                libraryTask?.cancel()
            }
        }
        .errorAlert(store)
    }

    private func chooseLibraryFiles() {
        guard !importingLibrary, project != nil, store.canPersist else { return }
        libraryReport = nil
        DocumentPicker.presentMany(
            DocumentTextImporter.allowedContentTypes,
            asCopy: true,
            onError: { msg in libraryReport = msg }
        ) { urls in
            guard !urls.isEmpty else { return }
            importingLibrary = true
            libraryTask = Task { @MainActor in
                var importedCount = 0
                var lines: [String] = []
                defer {
                    importingLibrary = false
                    libraryTask = nil
                    libraryProgress = ""
                    libraryReport = "已建库导入 \(importedCount) / \(urls.count) 份大文献。\n\n" + lines.joined(separator: "\n")
                }
                for (index, url) in urls.enumerated() {
                    if Task.isCancelled { break }
                    libraryProgress = "\(index + 1) / \(urls.count) · 建库中：\(url.lastPathComponent)"
                    do {
                        let res = try await store.importLibraryDocument(projectID: projectID, url: url)
                        importedCount += 1
                        var note = "✓ \(res.doc.name) · \(res.doc.characterCount.formatted()) 字（\(res.doc.chunkCount) 段索引）"
                        if !res.warnings.isEmpty { note += "\n" + res.warnings.joined(separator: "\n") }
                        lines.append(note)
                    } catch is CancellationError {
                        lines.append("已取消剩余导入。")
                        break
                    } catch {
                        lines.append("× \(url.lastPathComponent)：\(error.localizedDescription)")
                    }
                }
            }
        }
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
                Group {
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
                        Toggle("提问时引用这份资料", isOn: $isIncluded).tint(Ink.seal)
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
                }.claudeCardRow()
            }
            .claudeGroupedFormStyle()
            .navigationTitle("查看与编辑资料").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ClaudeSheetCloseButton(label: "取消") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button("复制正文", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                        Button("分享文字文件", systemImage: "square.and.arrow.up") { shareDocument() }
                    } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("资料操作").disabled(project == nil)
                    Button("保存") { save() }.fontWeight(.semibold).disabled(!changed || validationMessage != nil)
                }
            }
        }
        .tint(Ink.ink)
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

// 1:1 Claude iOS「指令」editor sheet: circular X close, centered title, circular solid checkmark confirm,
// clean rounded multiline text box with placeholder and short guidance underneath, iPhone Air keyboard-safe.
@MainActor
struct ProjectInstructionsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var projectName: String {
        store.project(projectID)?.name ?? "本项目"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $text)
                            .font(TypeScale.ui(15.5))
                            .foregroundStyle(Ink.ink)
                            .scrollContentBackground(.hidden)
                            .focused($isFocused)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .accessibilityIdentifier("project-instructions")
                        if text.isEmpty {
                            Text("使用专业的语气、使用简洁易懂的措辞、您是某领域专家等。")
                                .font(TypeScale.ui(15.5))
                                .foregroundStyle(Ink.ink3.opacity(0.85))
                                .padding(.horizontal, 17)
                                .padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 168, maxHeight: 280)
                    .background(Ink.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Ink.line, lineWidth: 0.85)
                    )

                    HStack(alignment: .firstTextBaseline) {
                        Text("指示 Sermo 在「\(projectName)」中应如何表现和回应。")
                            .font(TypeScale.caption)
                            .foregroundStyle(Ink.ink3)
                        Spacer(minLength: 8)
                        Text("\(text.count.formatted()) / 20,000")
                            .font(TypeScale.tiny)
                            .foregroundStyle(text.count > 20_000 ? Color.red : Ink.ink3)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle("指令")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ClaudeSheetCloseButton(label: "关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard var project = store.project(projectID) else { dismiss(); return }
                        project.instructions = text
                        if store.updateProject(project) { dismiss() }
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Ink.solid)
                    .disabled(text.count > 20_000)
                    .accessibilityLabel("保存指令")
                }
            }
            .errorAlert(store)
        }
        .tint(Ink.ink)
        .presentationDragIndicator(.visible)
        .onAppear {
            text = store.project(projectID)?.instructions ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                isFocused = true
            }
        }
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

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                ForEach(shown) { thread in
                    Group {
                        if editing {
                            rowLabel(thread).tag(thread.id)
                        } else {
                            Button { store.select(thread.id); opened() } label: { rowLabel(thread) }
                                .buttonStyle(.plain).tag(thread.id)
                        }
                    }
                    .listRowBackground(Ink.paper)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 18, bottom: 2, trailing: 18))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Ink.paper.ignoresSafeArea())
            .contentMargins(.bottom, editing ? 24 : 90, for: .scrollContent)
            .overlay(alignment: .bottomTrailing) {
                if !editing {
                    Button {
                        store.createNewChat()
                        opened()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                            Text("新建会话")
                        }
                    }
                    .buttonStyle(.claudeSecondaryPill)
                    .padding(.trailing, 20)
                    .padding(.bottom, 16)
                    .accessibilityIdentifier("all-chats-new-chat")
                }
            }
            .environment(\.editMode, $editMode)
            .searchable(text: $search, prompt: "搜索对话")
            .navigationTitle("全部对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ClaudeSheetCloseButton(label: "完成") { dismiss() } }
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
                    let deletable = selection.filter { $0 != store.generatingThreadID }
                    store.deleteThreads(deletable)
                    selection = []; editMode = .inactive
                }
            } message: { Text("附带的图片会一起删除，用量记录不受影响。") }
            .errorAlert(store)
        }
        .tint(Ink.ink)
    }

    private func rowLabel(_ thread: ChatThread) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: thread.isPinned == true ? "pin" : "message")
                .font(.system(size: 17.5, weight: .regular))
                .foregroundStyle(Ink.ink2)
                .frame(width: 24, height: 24, alignment: .center)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3.5) {
                Text(thread.title)
                    .font(TypeScale.ui(16.5, weight: .regular))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let project = store.project(thread.projectID) {
                        Text(project.name)
                        Text("·")
                    }
                    Text(Self.relativeDateFormatter.localizedString(for: thread.updatedAt, relativeTo: Date()))
                }
                .font(TypeScale.ui(13))
                .foregroundStyle(Ink.ink3)
            }
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
            .background(Ink.groupedBg.ignoresSafeArea())
            .navigationTitle(adjusting ? "让 AI 调整项目" : "让 AI 帮我建项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ClaudeSheetCloseButton(label: "取消") { task?.cancel(); dismiss() } }
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
                .font(TypeScale.ui(15.5)).scrollContentBackground(.hidden)
                .frame(minHeight: 96)
                .padding(12).background(Ink.card, in: InkRounded(radius: 16))
                .overlay(InkRounded(radius: 16).stroke(Ink.line, lineWidth: 0.7))
                .accessibilityIdentifier("project-designer-wish")
            Button { generate() } label: {
                HStack(spacing: 8) {
                    if working { ProgressView() } else { Image(systemName: "sparkles") }
                    Text(working ? "正在生成…" : buttonTitle)
                }
                .font(TypeScale.ui(15.5, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(Ink.card, in: InkCapsule())
                .overlay(InkCapsule().stroke(Ink.line, lineWidth: 0.8))
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
