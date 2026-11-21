import SwiftUI
import UIKit

/// Unified workspace sheet implementing Sermo's 5-Concept Separation:
/// 1. 项目成果 (Deliverables — multi-version DOCX/XLSX/PDF/HTML/MD outputs)
/// 2. 文献资料库 (Million-character local SQLite FTS5 reference library — searched on demand)
/// 3. 记忆与指令 (Project long-term memory + instructions, completely separate from raw source docs & outputs)
@MainActor
struct ProjectWorkspaceSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let projectID: UUID?
    let threadID: UUID?
    var initialTab: WorkspaceTab = .deliverables
    var onReviseDeliverable: ((ProjectDeliverable) -> Void)? = nil

    enum WorkspaceTab: String, CaseIterable, Identifiable {
        case deliverables = "项目成果"
        case library = "文献资料库"
        case memory = "记忆与指令"
        var id: String { rawValue }
    }

    @State private var activeTab: WorkspaceTab
    @State private var selectedDeliverable: ProjectDeliverable?
    @State private var searchQuery = ""
    @State private var searchHits: [ProjectLibraryHit] = []
    @State private var importing = false
    @State private var importProgress = ""
    @State private var importNotice: String?
    @State private var importTask: Task<Void, Never>?
    @State private var previewingLibraryDoc: LibrarySectionPreview?
    @State private var editingInstructions = false

    struct LibrarySectionPreview: Identifiable {
        let id: String
        let title: String
        let content: String
    }

    init(
        projectID: UUID?,
        threadID: UUID?,
        initialTab: WorkspaceTab = .deliverables,
        onReviseDeliverable: ((ProjectDeliverable) -> Void)? = nil
    ) {
        self.projectID = projectID
        self.threadID = threadID
        self.initialTab = initialTab
        self.onReviseDeliverable = onReviseDeliverable
        _activeTab = State(initialValue: projectID == nil ? .deliverables : initialTab)
    }

    private var project: ChatProject? {
        guard let projectID, !store.isLocked(projectID) else { return nil }
        return store.project(projectID)
    }

    private var deliverables: [ProjectDeliverable] {
        store.workspaceDeliverables(projectID: projectID, threadID: threadID)
    }

    private var libraryDocs: [ProjectLibraryDocument] {
        guard let projectID else { return [] }
        return store.libraryDocuments(for: projectID)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if project != nil {
                    Picker("", selection: $activeTab) {
                        ForEach(WorkspaceTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                    .background(Ink.groupedBg)
                }

                Group {
                    switch activeTab {
                    case .deliverables:
                        deliverablesTab
                    case .library:
                        libraryTab
                    case .memory:
                        memoryTab
                    }
                }
            }
            .background(Ink.groupedBg.ignoresSafeArea())
            .navigationTitle(project?.name ?? "对话成果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ClaudeSheetCloseButton(label: "完成") { dismiss() }
                }
                if activeTab == .library, let pid = project?.id {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            chooseLibraryFiles(projectID: pid)
                        } label: {
                            Image(systemName: "doc.badge.plus")
                                .font(.system(size: 15, weight: .regular))
                        }
                        .disabled(importing)
                        .accessibilityLabel("导入文献到检索库")
                    }
                }
            }
            .sheet(item: $selectedDeliverable) { item in
                DeliverableDetailSheet(deliverable: item) { target in
                    selectedDeliverable = nil
                    dismiss()
                    onReviseDeliverable?(target)
                }
                .environmentObject(store)
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
            .sheet(isPresented: $editingInstructions) {
                if let pid = project?.id {
                    ProjectInstructionsView(projectID: pid).environmentObject(store)
                }
            }
            .onDisappear { importTask?.cancel() }
        }
        .tint(Ink.ink)
    }

    // MARK: Tab 1 — Deliverables

    private var deliverablesTab: some View {
        List {
            if deliverables.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(Ink.ink2)
                            .frame(width: 52, height: 52)
                            .background(Ink.raised, in: Circle())
                        Text("还没有生成的文件成果")
                            .font(TypeScale.ui(15.5, weight: .medium))
                            .foregroundStyle(Ink.ink)
                        Text("聊天时只要让 Sermo 输出 Word（含真实圆圈页下注）、Excel 表格、排版 PDF、交互网页或 Markdown 稿件，都会自动归档在这里，并保留 v1 / v2 / v3 历史版本。")
                            .font(TypeScale.ui(13.5))
                            .foregroundStyle(Ink.ink3)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(deliverables) { item in
                        DeliverableFileRow(item: item) {
                            selectedDeliverable = item
                        }
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing) {
                            Button("删除", role: .destructive) {
                                store.deleteDeliverable(item.id)
                            }
                        }
                    }
                } header: {
                    Text("已交付文件 · \(deliverables.count) 份")
                } footer: {
                    Text("点开任意文件可直接预览、切换历史版本（v1 / v2）、存入系统「文件」或用 Word / WPS 打开。原文献资料库绝不会被覆盖。")
                }
            }
        }
        .claudeGroupedListStyle()
    }

    // MARK: Tab 2 — Million-Character Literature Warehouse

    private var libraryTab: some View {
        List {
            if let pid = project?.id {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Ink.ink3)
                        TextField("即时全文检索项目文献（支持精确词句）", text: $searchQuery)
                            .font(TypeScale.ui(15))
                            .submitLabel(.search)
                            .onChange(of: searchQuery) { _, value in
                                runSearch(projectID: pid, query: value)
                            }
                        if !searchQuery.isEmpty {
                            Button {
                                searchQuery = ""
                                searchHits = []
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Ink.ink3)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .claudeCardRow()

                if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("检索命中 · \(searchHits.count) 处") {
                        if searchHits.isEmpty {
                            Text("没有在项目文献库中找到“\(searchQuery)”，换个关键词或检查是否已导入对应书籍。")
                                .font(TypeScale.caption)
                                .foregroundStyle(Ink.ink3)
                        } else {
                            ForEach(searchHits) { hit in
                                Button {
                                    let excerpt = store.readLibrarySection(
                                        projectID: pid,
                                        documentID: hit.documentID,
                                        chunkIndex: hit.chunkIndex,
                                        window: 2
                                    )
                                    previewingLibraryDoc = LibrarySectionPreview(
                                        id: hit.id,
                                        title: "\(hit.documentName) · \(hit.pageLabel)",
                                        content: excerpt
                                    )
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 6) {
                                            Text(hit.documentName)
                                                .font(TypeScale.ui(13.5, weight: .medium))
                                                .foregroundStyle(Ink.ink)
                                                .lineLimit(1)
                                            Spacer(minLength: 4)
                                            Text(hit.pageLabel)
                                                .font(TypeScale.tiny)
                                                .foregroundStyle(Ink.seal)
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 2)
                                                .background(Ink.raised, in: Capsule())
                                        }
                                        Text(hit.excerpt)
                                            .font(TypeScale.caption)
                                            .foregroundStyle(Ink.ink2)
                                            .lineLimit(3)
                                            .multilineTextAlignment(.leading)
                                    }
                                    .padding(.vertical, 3)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .claudeCardRow()
                }

                Section {
                    Button {
                        chooseLibraryFiles(projectID: pid)
                    } label: {
                        Label(importing ? "正在建库导入…" : "导入大文献到按需检索库", systemImage: "books.vertical.fill")
                            .font(TypeScale.ui(15, weight: .medium))
                            .foregroundStyle(Ink.ink)
                    }
                    .disabled(importing)

                    if importing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(importProgress)
                                .font(TypeScale.caption)
                                .foregroundStyle(Ink.ink2)
                                .lineLimit(2)
                            Spacer()
                            Button("取消") { importTask?.cancel() }
                                .font(TypeScale.caption)
                        }
                    }

                    if let importNotice {
                        Text(importNotice)
                            .font(TypeScale.caption)
                            .foregroundStyle(Ink.ink2)
                    }
                } header: {
                    Text("百万字本地全文检索库（按需调阅，不占对话额度）")
                } footer: {
                    Text("支持 PDF（最高 80 MB / 3000 页，自动保留物理页码）、Word、Excel、EPUB、ZIP 与纯文本。AI 聊天时会自动按需查关键词和精确页码，不拖慢聊天记录加载。")
                }
                .claudeCardRow()

                Section("已入库文献 · \(libraryDocs.count) 份") {
                    if libraryDocs.isEmpty {
                        Text("还没有入库的大文献。把论文专著、史料点校本或整套参考书导入这里，AI 就能秒级检索原文与页码。")
                            .font(TypeScale.caption)
                            .foregroundStyle(Ink.ink3)
                    } else {
                        ForEach(libraryDocs) { doc in
                            Button {
                                let preview = store.readLibrarySection(projectID: pid, documentID: doc.id, chunkIndex: 0, window: 3)
                                previewingLibraryDoc = LibrarySectionPreview(id: doc.id, title: doc.name, content: preview)
                            } label: {
                                HStack(spacing: 12) {
                                    ClaudeIconBadge(systemName: "book.closed", color: Ink.ink2, size: 16)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(doc.name)
                                            .font(TypeScale.ui(15, weight: .medium))
                                            .foregroundStyle(Ink.ink)
                                            .lineLimit(1)
                                        Text("\(doc.characterCount.formatted()) 字 · \(doc.chunkCount) 段索引 · \(doc.fileExtension.uppercased())")
                                            .font(TypeScale.tiny)
                                            .foregroundStyle(Ink.ink3)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Ink.ink3.opacity(0.65))
                                }
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button("移除", role: .destructive) {
                                    store.deleteLibraryDocument(projectID: pid, documentID: doc.id)
                                }
                            }
                        }
                    }
                }
                .claudeCardRow()

                if let inlineCount = project?.documents.count, inlineCount > 0 {
                    Section {
                        NavigationLink {
                            ProjectFilesView(projectID: pid)
                        } label: {
                            HStack {
                                Label("随每次提问整篇发送的资料", systemImage: "doc.text")
                                    .foregroundStyle(Ink.ink)
                                Spacer()
                                Text("\(inlineCount) 份")
                                    .font(TypeScale.caption)
                                    .foregroundStyle(Ink.ink3)
                            }
                        }
                    } footer: {
                        Text("与上方百万字按需检索库分开存放；适合几千字的核心大纲或模板。")
                    }
                    .claudeCardRow()
                }
            }
        }
        .claudeGroupedListStyle()
    }

    // MARK: Tab 3 — Memory & Instructions

    private var memoryTab: some View {
        List {
            if let proj = project {
                Section("工作指令") {
                    Button {
                        editingInstructions = true
                    } label: {
                        HStack(spacing: 12) {
                            ClaudeIconBadge(systemName: "text.alignleft", color: Ink.ink2, size: 16)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("项目工作指令")
                                    .font(TypeScale.ui(15.5))
                                    .foregroundStyle(Ink.ink)
                                let trimmed = proj.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                                Text(trimmed.isEmpty ? "未填写 · 点击设定文风、格式与固定要求" : String(trimmed.prefix(48)))
                                    .font(TypeScale.tiny)
                                    .foregroundStyle(Ink.ink3)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Ink.ink3.opacity(0.65))
                        }
                    }
                    .buttonStyle(.plain)
                }
                .claudeCardRow()

                Section("长期记忆与档案") {
                    NavigationLink {
                        if proj.studySubject != nil {
                            StudyMemoryView(projectID: proj.id)
                        } else {
                            ProjectMemoryView(projectID: proj.id)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            ClaudeIconBadge(
                                systemName: proj.studySubject != nil ? "graduationcap" : "brain",
                                color: proj.studySubject != nil ? Ink.seal : Ink.ink2,
                                size: 16
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(proj.studySubject != nil ? "学习档案与进度" : "项目跨对话备忘")
                                    .font(TypeScale.ui(15.5))
                                    .foregroundStyle(Ink.ink)
                                Text("你说过、以后还用得上的事")
                                    .font(TypeScale.tiny)
                                    .foregroundStyle(Ink.ink3)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .claudeCardRow()
            }
        }
        .claudeGroupedListStyle()
    }

    // MARK: Actions

    private func runSearch(projectID: UUID, query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchHits = []
            return
        }
        searchHits = store.searchLibraryDocuments(projectID: projectID, query: trimmed, limit: 12)
    }

    private func chooseLibraryFiles(projectID: UUID) {
        guard !importing else { return }
        importNotice = nil
        DocumentPicker.presentMany(
            DocumentTextImporter.allowedContentTypes,
            asCopy: true,
            onError: { msg in importNotice = msg }
        ) { urls in
            guard !urls.isEmpty else { return }
            importing = true
            importTask = Task { @MainActor in
                var okCount = 0
                var messages: [String] = []
                defer {
                    importing = false
                    importProgress = ""
                    importTask = nil
                    importNotice = "已完成入库 \(okCount)/\(urls.count) 份。\n" + messages.joined(separator: "\n")
                }
                for (index, url) in urls.enumerated() {
                    if Task.isCancelled { break }
                    importProgress = "\(index + 1)/\(urls.count) · 正在解析并建立全文索引：\(url.lastPathComponent)"
                    do {
                        let result = try await store.importLibraryDocument(projectID: projectID, url: url)
                        okCount += 1
                        messages.append("✓ \(result.doc.name)（\(result.doc.characterCount.formatted()) 字，\(result.doc.chunkCount) 段）")
                    } catch is CancellationError {
                        messages.append("已取消剩余文件。")
                        break
                    } catch {
                        messages.append("× \(url.lastPathComponent)：\(error.localizedDescription)")
                    }
                }
            }
        }
    }
}
