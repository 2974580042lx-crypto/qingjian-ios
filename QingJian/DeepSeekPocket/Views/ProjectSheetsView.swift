import SwiftUI
import UIKit

/// 1:1 Claude iOS「项目文件」bottom sheet with drag indicator, centered empty state,
/// flat file rows (supporting instant SQLite FTS5 search & preview), and pinned dark
/// bottom "添加文件" capsule that adds real files straight into the project's library.
@MainActor
struct ProjectFilesSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let projectID: UUID

    @State private var searchText = ""
    @State private var searchHits: [ProjectLibraryHit] = []
    @State private var importing = false
    @State private var importProgress = ""
    @State private var importNotice: String?
    @State private var importTask: Task<Void, Never>?
    @State private var previewingLibrary: ProjectWorkspaceSheet.LibrarySectionPreview?
    @State private var editingInlineDoc: ProjectDocument?
    @State private var showAddModeDialog = false

    private var project: ChatProject? {
        store.isLocked(projectID) ? nil : store.project(projectID)
    }

    private var libraryDocs: [ProjectLibraryDocument] {
        store.libraryDocuments(for: projectID)
    }

    private var inlineDocs: [ProjectDocument] {
        project?.documents ?? []
    }

    private var isEmpty: Bool {
        libraryDocs.isEmpty && inlineDocs.isEmpty
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if project == nil {
                    Spacer()
                    Text("项目已上锁或不存在，请返回后重新打开。")
                        .font(TypeScale.ui(14.5))
                        .foregroundStyle(Ink.ink3)
                    Spacer()
                } else if isEmpty && !importing && importNotice == nil {
                    emptyState
                } else {
                    filesContentList
                }

                if project != nil {
                    bottomAddBar
                }
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle("项目文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ClaudeSheetCloseButton(label: "关闭") { dismiss() }
                }
                if project != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("导入到百万字检索库（推荐）", systemImage: "books.vertical") {
                                chooseFiles(intoLibrary: true)
                            }
                            Button("导入为随提问整篇附带资料", systemImage: "doc.text") {
                                chooseFiles(intoLibrary: false)
                            }
                            Button("粘贴剪贴板文字入库", systemImage: "doc.on.clipboard") {
                                pasteIntoLibrary()
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 15, weight: .regular))
                        }
                        .accessibilityLabel("更多文件导入方式")
                    }
                }
            }
        }
        .tint(Ink.ink)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(item: $previewingLibrary) { item in
            NavigationStack {
                ScrollView {
                    Text(item.content.isEmpty ? "（暂无内容）" : item.content)
                        .font(TypeScale.ui(14.5))
                        .foregroundStyle(Ink.ink)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                }
                .background(Ink.paper.ignoresSafeArea())
                .navigationTitle(item.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        ClaudeSheetCloseButton(label: "关闭") { previewingLibrary = nil }
                    }
                }
            }
            .tint(Ink.ink)
        }
        .sheet(item: $editingInlineDoc) { doc in
            ProjectFilesInlineEditorBridge(projectID: projectID, document: doc)
                .environmentObject(store)
        }
        .onDisappear { importTask?.cancel() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Circle()
                .fill(Ink.raised)
                .frame(width: 54, height: 54)
                .overlay {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 21, weight: .light))
                        .foregroundStyle(Ink.ink2)
                }
            Text("暂无文件")
                .font(TypeScale.ui(16, weight: .medium))
                .foregroundStyle(Ink.ink)
            Text("添加供 Sermo 在「\(project?.name ?? "本项目")」中使用的文件。")
                .font(TypeScale.ui(14))
                .foregroundStyle(Ink.ink3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Text("自动存入百万字本地按需检索库，不占平时对话额度。")
                .font(TypeScale.tiny)
                .foregroundStyle(Ink.ink3.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var filesContentList: some View {
        List {
            if !libraryDocs.isEmpty || !inlineDocs.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundStyle(Ink.ink3)
                    TextField("搜索项目文献关键词或文件名", text: $searchText)
                        .font(TypeScale.ui(15))
                        .submitLabel(.search)
                        .onChange(of: searchText) { _, val in
                            let q = val.trimmingCharacters(in: .whitespacesAndNewlines)
                            searchHits = q.isEmpty ? [] : store.searchLibraryDocuments(projectID: projectID, query: q, limit: 10)
                        }
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            searchHits = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Ink.ink3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Ink.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Ink.paper)
                .listRowSeparator(.hidden)
            }

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
                .listRowBackground(Ink.paper)
                .listRowSeparator(.hidden)
            }

            if let importNotice {
                VStack(alignment: .leading, spacing: 6) {
                    Text(importNotice)
                        .font(TypeScale.caption)
                        .foregroundStyle(Ink.ink2)
                    Button("知道了") { self.importNotice = nil }
                        .font(TypeScale.tiny.weight(.medium))
                        .foregroundStyle(Ink.seal)
                        .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
                .listRowBackground(Ink.paper)
                .listRowSeparator(.hidden)
            }

            if !trimmedQuery.isEmpty {
                Section {
                    if searchHits.isEmpty {
                        Text("文献全文索引中未命中“\(trimmedQuery)”。")
                            .font(TypeScale.caption)
                            .foregroundStyle(Ink.ink3)
                            .listRowBackground(Ink.paper)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(searchHits) { hit in
                            Button {
                                let text = store.readLibrarySection(
                                    projectID: projectID,
                                    documentID: hit.documentID,
                                    chunkIndex: hit.chunkIndex,
                                    window: 2
                                )
                                previewingLibrary = ProjectWorkspaceSheet.LibrarySectionPreview(
                                    id: hit.id,
                                    title: "\(hit.documentName) · \(hit.pageLabel)",
                                    content: text
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(hit.documentName)
                                            .font(TypeScale.ui(14, weight: .medium))
                                            .foregroundStyle(Ink.ink)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(hit.pageLabel)
                                            .font(TypeScale.tiny)
                                            .foregroundStyle(Ink.seal)
                                    }
                                    Text(hit.excerpt)
                                        .font(TypeScale.caption)
                                        .foregroundStyle(Ink.ink2)
                                        .lineLimit(3)
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Ink.paper)
                            .listRowSeparatorTint(Ink.line.opacity(0.6))
                        }
                    }
                } header: {
                    Text("全文检索命中 · \(searchHits.count)")
                        .font(TypeScale.tiny)
                        .foregroundStyle(Ink.ink3)
                        .textCase(nil)
                }
            }

            let filteredLib = libraryDocs.filter {
                trimmedQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmedQuery)
            }
            if !filteredLib.isEmpty {
                Section {
                    ForEach(filteredLib) { doc in
                        Button {
                            let content = store.readLibrarySection(projectID: projectID, documentID: doc.id, chunkIndex: 0, window: 3)
                            previewingLibrary = ProjectWorkspaceSheet.LibrarySectionPreview(id: doc.id, title: doc.name, content: content)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 17, weight: .light))
                                    .foregroundStyle(Ink.ink2)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2.5) {
                                    Text(doc.name)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Ink.ink)
                                        .lineLimit(1)
                                    Text("\(doc.characterCount.formatted()) 字 · \(doc.chunkCount) 段按需检索 · \(doc.fileExtension.uppercased())")
                                        .font(TypeScale.tiny)
                                        .foregroundStyle(Ink.ink3)
                                }
                                Spacer(minLength: 6)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Ink.ink3.opacity(0.6))
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Ink.paper)
                        .listRowSeparatorTint(Ink.line.opacity(0.5))
                        .swipeActions(edge: .trailing) {
                            Button("移除", role: .destructive) {
                                store.deleteLibraryDocument(projectID: projectID, documentID: doc.id)
                            }
                        }
                    }
                } header: {
                    Text("文献检索库（按需调阅 · \(libraryDocs.count) 份）")
                        .font(TypeScale.tiny)
                        .foregroundStyle(Ink.ink3)
                        .textCase(nil)
                }
            }

            let filteredInline = inlineDocs.filter {
                trimmedQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmedQuery) || $0.text.localizedCaseInsensitiveContains(trimmedQuery)
            }
            if !filteredInline.isEmpty {
                Section {
                    ForEach(filteredInline) { doc in
                        HStack(spacing: 12) {
                            Button { editingInlineDoc = doc } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.plaintext")
                                        .font(.system(size: 16, weight: .light))
                                        .foregroundStyle(Ink.ink2)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2.5) {
                                        Text(doc.name)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(Ink.ink)
                                            .lineLimit(1)
                                        Text("\(doc.text.count.formatted()) 字 · 随提问附带")
                                            .font(TypeScale.tiny)
                                            .foregroundStyle(Ink.ink3)
                                    }
                                    Spacer(minLength: 4)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Toggle("引用", isOn: Binding(get: { doc.isIncluded }, set: { value in
                                toggleInlineDocument(doc.id, included: value)
                            }))
                            .labelsHidden()
                            .fixedSize()
                            .tint(Ink.seal)
                        }
                        .padding(.vertical, 3)
                        .listRowBackground(Ink.paper)
                        .listRowSeparatorTint(Ink.line.opacity(0.5))
                        .swipeActions(edge: .trailing) {
                            Button("删除", role: .destructive) {
                                removeInlineDocument(doc.id)
                            }
                        }
                    }
                } header: {
                    Text("随提问整篇附带（\(inlineDocs.count) 份）")
                        .font(TypeScale.tiny)
                        .foregroundStyle(Ink.ink3)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Ink.paper)
    }

    private var bottomAddBar: some View {
        VStack(spacing: 0) {
            Button {
                Haptic.tap()
                chooseFiles(intoLibrary: true)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15, weight: .medium))
                    Text(importing ? "正在导入建库…" : "添加文件")
                        .font(TypeScale.ui(15.5, weight: .medium))
                }
                .foregroundStyle(Ink.onSolid)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Ink.solid, in: Capsule())
            }
            .buttonStyle(.pressFeedback)
            .disabled(importing || !store.canPersist)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 16)
        }
        .background(Ink.paper)
    }

    private func chooseFiles(intoLibrary: Bool) {
        guard !importing, project != nil, store.canPersist else { return }
        importNotice = nil
        DocumentPicker.presentMany(
            DocumentTextImporter.allowedContentTypes,
            asCopy: true,
            onError: { msg in importNotice = msg }
        ) { urls in
            guard !urls.isEmpty else { return }
            importing = true
            importTask = Task { @MainActor in
                var ok = 0
                var lines: [String] = []
                defer {
                    importing = false
                    importTask = nil
                    importProgress = ""
                    importNotice = "已处理 \(ok) / \(urls.count) 份文件。\n" + lines.joined(separator: "\n")
                }
                for (idx, url) in urls.enumerated() {
                    if Task.isCancelled { break }
                    importProgress = "\(idx + 1)/\(urls.count) · \(url.lastPathComponent)"
                    do {
                        if url.pathExtension.lowercased() == "json",
                           let studyNotice = await tryImportStudyJSONIfRecognized(url) {
                            ok += 1
                            lines.append(studyNotice)
                            continue
                        }
                        if intoLibrary {
                            let res = try await store.importLibraryDocument(projectID: projectID, url: url)
                            ok += 1
                            lines.append("✓ \(res.doc.name)（\(res.doc.characterCount.formatted()) 字，已建全文索引）")
                        } else {
                            let imported = try await DocumentTextImporter.load(url, apiKey: store.apiKey)
                            guard var latest = store.project(projectID) else { continue }
                            var doc = ProjectDocument(name: imported.name, text: imported.text)
                            doc.isIncluded = latest.studySubject == nil && (latest.includedCharacters + doc.text.count <= ChatProject.documentCharacterLimit)
                            latest.documents.append(doc)
                            if store.updateProject(latest) {
                                ok += 1
                                lines.append("✓ \(imported.name)（\(imported.text.count.formatted()) 字，随提问附带）")
                            }
                        }
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

    private func pasteIntoLibrary() {
        guard let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            importNotice = "剪贴板里没有可导入的文字。"
            return
        }
        do {
            let name = "粘贴文献 \(libraryDocs.count + 1)"
            let doc = try store.importLibraryText(projectID: projectID, name: name, text: raw)
            importNotice = "已存入文献检索库：《\(doc.name)》（\(doc.characterCount.formatted()) 字）。"
        } catch {
            importNotice = "入库失败：\(error.localizedDescription)"
        }
    }

    private func toggleInlineDocument(_ id: UUID, included: Bool) {
        guard var latest = store.project(projectID),
              let idx = latest.documents.firstIndex(where: { $0.id == id }) else { return }
        latest.documents[idx].isIncluded = included
        _ = store.updateProject(latest)
    }

    private func removeInlineDocument(_ id: UUID) {
        guard var latest = store.project(projectID) else { return }
        latest.documents.removeAll { $0.id == id }
        _ = store.updateProject(latest)
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
            if project?.studySubject != .english, var p = store.project(projectID) {
                p.studySubject = .english; p.autoMemory = true; _ = store.updateProject(p)
            }
            if await store.importStudyVocabulary(projectID: projectID, url: url) {
                let count = (try? store.studyVocabularyCount(projectID: projectID)) ?? 0
                return "✓ \(url.lastPathComponent)（已导入英语词库，当前共 \(count) 词）"
            }
        }
        if (try? StudyReadingPack.decode(data)) != nil {
            if project?.studySubject != .english, var p = store.project(projectID) {
                p.studySubject = .english; p.autoMemory = true; _ = store.updateProject(p)
            }
            if await store.importStudyReadings(projectID: projectID, url: url) {
                let count = (try? store.studyReadingCount(projectID: projectID)) ?? 0
                return "✓ \(url.lastPathComponent)（已导入英语阅读，当前共 \(count) 篇）"
            }
        }
        if let pack = try? StudyHistoryPack.decode(data) {
            if project?.studySubject != .history, var p = store.project(projectID) {
                p.studySubject = .history; p.autoMemory = true; _ = store.updateProject(p)
            }
            if store.importHistoryPack(projectID: projectID, pack: pack, confirmed: pack.kind == "outline") {
                return "✓ \(url.lastPathComponent)（已导入 313 历史资料 \(pack.entries.count) 条）"
            }
        }
        if (try? StudyTemporaryMap.decode(data)) != nil {
            if project?.studySubject != .history, var p = store.project(projectID) {
                p.studySubject = .history; p.autoMemory = true; _ = store.updateProject(p)
            }
            if await store.importTemporaryHistoryMap(projectID: projectID, url: url) {
                return "✓ \(url.lastPathComponent)（已导入 313 历史学习地图）"
            }
        }
        return nil
    }
}

/// Thin internal bridge reusing inline document editing cleanly inside `ProjectFilesSheet`.
@MainActor
private struct ProjectFilesInlineEditorBridge: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let document: ProjectDocument
    @State private var name: String
    @State private var text: String
    @State private var isIncluded: Bool

    init(projectID: UUID, document: ProjectDocument) {
        self.projectID = projectID
        self.document = document
        _name = State(initialValue: document.name)
        _text = State(initialValue: document.text)
        _isIncluded = State(initialValue: document.isIncluded)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("资料名称") {
                    TextField("名称", text: $name)
                }
                Section("正文 · \(text.count.formatted()) 字") {
                    TextEditor(text: $text)
                        .frame(minHeight: 260)
                        .font(TypeScale.ui(15))
                        .scrollContentBackground(.hidden)
                }
                Section {
                    Toggle("提问时整篇附带", isOn: $isIncluded).tint(Ink.seal)
                }
            }
            .claudeGroupedFormStyle()
            .navigationTitle("查看与编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ClaudeSheetCloseButton(label: "取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        guard var latest = store.project(projectID),
                              let idx = latest.documents.firstIndex(where: { $0.id == document.id }) else { dismiss(); return }
                        latest.documents[idx].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        latest.documents[idx].text = text
                        latest.documents[idx].isIncluded = isIncluded
                        if store.updateProject(latest) { dismiss() }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .tint(Ink.ink)
    }
}

/// 1:1 Claude iOS「记忆」bottom sheet.
/// Shows real project-scoped memory (or StudyMemoryView for study projects) with zero fake toggles.
@MainActor
struct ProjectMemorySheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let projectID: UUID

    private var project: ChatProject? {
        store.isLocked(projectID) ? nil : store.project(projectID)
    }

    private var memoryLines: [String] {
        (project?.memory ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let proj = project {
                    if proj.studySubject != nil {
                        StudyMemoryView(projectID: projectID)
                    } else {
                        ordinaryMemoryBody(proj)
                    }
                } else {
                    Text("项目已上锁或不存在，请返回后重新打开。")
                        .font(TypeScale.ui(14.5))
                        .foregroundStyle(Ink.ink3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Ink.paper.ignoresSafeArea())
                }
            }
            .navigationTitle(project?.studySubject != nil ? "学习档案" : "记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ClaudeSheetCloseButton(label: "关闭") { dismiss() }
                }
            }
        }
        .tint(Ink.ink)
        .presentationDetents(project?.studySubject != nil ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func ordinaryMemoryBody(_ proj: ChatProject) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                if memoryLines.isEmpty {
                    VStack(spacing: 10) {
                        Circle()
                            .fill(Ink.raised)
                            .frame(width: 52, height: 52)
                            .overlay {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 19, weight: .light))
                                    .foregroundStyle(Ink.ink2)
                            }
                        Text("暂无记忆")
                            .font(TypeScale.ui(16, weight: .medium))
                            .foregroundStyle(Ink.ink)
                        Text("进行几次会话后，项目记忆将显示在这里。")
                            .font(TypeScale.ui(14))
                            .foregroundStyle(Ink.ink3)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 26)
                    .padding(.bottom, 6)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("项目记忆 · \(memoryLines.count) 条")
                                .font(TypeScale.tiny)
                                .foregroundStyle(Ink.ink3)
                            Spacer()
                            if let updated = proj.memoryUpdatedAt {
                                Text("更新于 \(updated.formatted(date: .abbreviated, time: .shortened))")
                                    .font(TypeScale.tiny)
                                    .foregroundStyle(Ink.ink3)
                            }
                        }
                        ForEach(Array(memoryLines.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•")
                                    .foregroundStyle(Ink.ink3)
                                Text(line.trimmingCharacters(in: CharacterSet(charactersIn: "-• ")))
                                    .font(TypeScale.ui(14.5))
                                    .foregroundStyle(Ink.ink)
                                    .lineSpacing(4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
                }

                // Single clean card matching Claude's memory settings layout (wired to 100% real Sermo features)
                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自动整理项目记忆")
                                .font(TypeScale.ui(15.5, weight: .medium))
                                .foregroundStyle(Ink.ink)
                            Text("允许 Sermo 在「\(proj.name)」的不同对话间自动沉淀与共享长期要点。")
                                .font(TypeScale.caption)
                                .foregroundStyle(Ink.ink3)
                                .lineSpacing(3)
                        }
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(
                            get: { proj.remembers },
                            set: { value in
                                guard var updated = store.project(projectID) else { return }
                                updated.autoMemory = value
                                _ = store.updateProject(updated)
                            }
                        ))
                        .labelsHidden()
                        .tint(Ink.seal)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    Divider()
                        .overlay(Ink.line)
                        .padding(.leading, 16)

                    NavigationLink {
                        ProjectMemoryView(projectID: projectID)
                    } label: {
                        HStack {
                            Text(memoryLines.isEmpty ? "手动填写项目记忆" : "查看与编辑全部记忆")
                                .font(TypeScale.ui(15.5, weight: .medium))
                                .foregroundStyle(Ink.ink)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Ink.ink3.opacity(0.75))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(Ink.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Ink.line, lineWidth: 0.7))

                Text("项目记忆仅在当前项目内共享，与原始文献库和生成的文件成果彼此独立。")
                    .font(TypeScale.tiny)
                    .foregroundStyle(Ink.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
        .background(Ink.paper.ignoresSafeArea())
    }
}

/// Clean native grouped Form sheet opened from the Project `⋯ → 编辑详情` menu.
/// Houses project name, model/service defaults, tool switches, Face ID lock, and AI designer
/// without cluttering the lightweight 3-item native floating menu.
@MainActor
struct ProjectDetailsEditSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let projectID: UUID
    let onOpenAIDesigner: () -> Void

    @State private var nameDraft = ""

    private var project: ChatProject? {
        store.isLocked(projectID) ? nil : store.project(projectID)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let proj = project {
                    Section("基本信息") {
                        TextField("项目名称", text: $nameDraft)
                        Button {
                            dismiss()
                            onOpenAIDesigner()
                        } label: {
                            Label("让 AI 帮我调整项目设定", systemImage: "sparkles")
                        }
                    }
                    .claudeCardRow()

                    Section("默认模型与思考") {
                        Picker("服务", selection: Binding(
                            get: { proj.service },
                            set: { value in mutate { $0.provider = value } }
                        )) {
                            ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                        }

                        if proj.service == .chatGPT {
                            Picker("默认模型", selection: Binding(
                                get: { proj.subscriptionModel ?? "follow" },
                                set: { value in mutate { $0.subscriptionModel = value == "follow" ? nil : value } }
                            )) {
                                Text("跟随当前").tag("follow")
                                ForEach(store.subscription.models) { Text($0.displayName).tag($0.slug) }
                            }
                            let targetSlug = proj.subscriptionModel ?? store.activeChatSettings.subscriptionModel
                            Picker("默认思考", selection: Binding(
                                get: { proj.subscriptionEffort?.rawValue ?? "follow" },
                                set: { value in mutate { $0.subscriptionEffort = SubscriptionEffort(rawValue: value) } }
                            )) {
                                Text("跟随当前").tag("follow")
                                ForEach(store.subscription.availableEfforts(for: targetSlug)) { Text($0.menuLabel).tag($0.rawValue) }
                            }
                        } else if proj.service == .deepSeek {
                            Picker("默认模型", selection: Binding(
                                get: { proj.model?.rawValue ?? "follow" },
                                set: { value in mutate { $0.model = DeepSeekModel(rawValue: value) } }
                            )) {
                                Text("跟随当前").tag("follow")
                                ForEach(DeepSeekModel.allCases) { Text($0.title).tag($0.rawValue) }
                            }
                            Picker("默认思考", selection: Binding(
                                get: {
                                    guard let thinking = proj.thinkingEnabled else { return "follow" }
                                    return thinking ? (proj.effort ?? .high).rawValue : "off"
                                },
                                set: { value in
                                    mutate { p in
                                        switch value {
                                        case "follow": p.thinkingEnabled = nil; p.effort = nil
                                        case "off": p.thinkingEnabled = false
                                        default: p.thinkingEnabled = true; p.effort = ThinkingEffort(rawValue: value)
                                        }
                                    }
                                }
                            )) {
                                Text("跟随当前").tag("follow")
                                Text("Off").tag("off")
                                ForEach(ThinkingEffort.allCases) { Text($0.title).tag($0.rawValue) }
                            }
                        }

                        Picker("学习科目", selection: Binding(
                            get: { proj.studySubject?.rawValue ?? "none" },
                            set: { value in
                                mutate { p in
                                    p.studySubject = StudySubject(rawValue: value)
                                    if p.studySubject != nil { p.autoMemory = true }
                                }
                            }
                        )) {
                            Text("普通项目").tag("none")
                            ForEach(StudySubject.allCases, id: \.rawValue) { subj in
                                Text(subj.title).tag(subj.rawValue)
                            }
                        }
                    }
                    .claudeCardRow()

                    Section {
                        if store.canUsePureRoleplay(proj) {
                            Toggle("纯角色扮演模式", isOn: Binding(
                                get: { proj.isPureRoleplay },
                                set: { value in mutate { $0.pureRoleplay = value } }
                            ))
                            .tint(Ink.seal)
                        }
                        if !proj.isPureRoleplay {
                            Toggle("联网工具", isOn: Binding(
                                get: { proj.webTools != false },
                                set: { value in mutate { $0.webTools = value } }
                            ))
                            .tint(Ink.seal)
                            Toggle("谷歌云盘工具", isOn: Binding(
                                get: { proj.driveTools ?? store.drive.connected },
                                set: { value in mutate { $0.driveTools = value } }
                            ))
                            .tint(Ink.seal)
                            Toggle("GitHub 工具", isOn: Binding(
                                get: { proj.githubTools ?? store.github.connected },
                                set: { value in mutate { $0.githubTools = value } }
                            ))
                            .tint(Ink.seal)
                        }
                        Toggle("告诉角色时间流逝", isOn: Binding(
                            get: { proj.timeAwareness != false },
                            set: { value in mutate { $0.timeAwareness = value } }
                        ))
                        .tint(Ink.seal)
                        Toggle("面容 ID 锁", isOn: Binding(
                            get: { proj.isLocked },
                            set: { value in mutate { $0.isLocked = value } }
                        ))
                        .tint(Ink.seal)
                    } header: { Text("工具与隐私") } footer: {
                        if proj.isPureRoleplay {
                            Text("纯角色扮演模式会屏蔽文档生成与外部工具；如需让 AI 生成 Word / Excel / PDF，请关闭此开关。")
                        }
                    }
                    .claudeCardRow()
                }
            }
            .claudeGroupedFormStyle()
            .navigationTitle("编辑详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ClaudeSheetCloseButton(label: "完成") {
                        saveNameIfNeeded()
                        dismiss()
                    }
                }
            }
        }
        .tint(Ink.ink)
        .onAppear { nameDraft = project?.name ?? "" }
        .onDisappear { saveNameIfNeeded() }
    }

    private func mutate(_ change: (inout ChatProject) -> Void) {
        guard var p = store.project(projectID) else { return }
        change(&p)
        _ = store.updateProject(p)
    }

    private func saveNameIfNeeded() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let current = project, trimmed != current.name else { return }
        mutate { $0.name = trimmed }
    }
}
