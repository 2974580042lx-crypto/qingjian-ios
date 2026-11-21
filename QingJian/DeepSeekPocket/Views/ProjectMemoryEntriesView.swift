import SwiftUI

// 1.46: the project's memory as entries — pinned ones first, then the rest — each with when it
// was written and which conversation it came from. Tap to correct, swipe to delete, and undo a
// whole update from 「最近的变化」.
@MainActor
struct ProjectMemoryEntriesView: View {
    @EnvironmentObject private var store: AppStore
    let projectID: UUID
    @State private var editing: ProjectMemoryEditTarget?

    private var project: ChatProject? { store.project(projectID) }
    private var items: [ProjectMemoryItem] { project?.currentMemoryItems ?? [] }

    /// The latest few updates, newest first: when, what kind of change, how many.
    private var recentBatches: [MemoryBatchSummary] {
        let log = project?.memoryLog ?? []
        var order: [UUID] = []
        var grouped: [UUID: [ProjectMemoryChange]] = [:]
        for change in log.reversed() {
            if grouped[change.batchID] == nil { order.append(change.batchID) }
            grouped[change.batchID, default: []].append(change)
        }
        return order.prefix(6).compactMap { id -> MemoryBatchSummary? in
            guard let changes = grouped[id], let first = changes.first else { return nil }
            let added = changes.filter { $0.kind == .add }.count
            let updated = changes.filter { $0.kind == .update }.count
            let deleted = changes.filter { $0.kind == .delete }.count
            let parts = [added > 0 ? "新增 \(added)" : nil, updated > 0 ? "修改 \(updated)" : nil, deleted > 0 ? "删除 \(deleted)" : nil]
                .compactMap { $0 }
            return MemoryBatchSummary(id: id, at: first.at, summary: parts.joined(separator: " · "), byUser: first.byUser)
        }
    }

    var body: some View {
        List {
            if items.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("暂无记忆")
                            .font(TypeScale.ui(16, weight: .medium))
                            .foregroundStyle(Ink.ink)
                        Text("在这个项目里聊几次，你说过、以后还用得上的事会记在这里。")
                            .font(TypeScale.ui(14))
                            .foregroundStyle(Ink.ink3)
                    }
                    .padding(.vertical, 6)
                }
                .claudeCardRow()
            } else {
                let pinned = items.filter(\.isPinned)
                let others = items.filter { !$0.isPinned }
                if !pinned.isEmpty {
                    Section {
                        ForEach(pinned) { row($0) }
                    } header: { header("置顶 · 每次都带上") }
                    .claudeCardRow()
                }
                if !others.isEmpty {
                    Section {
                        ForEach(others) { row($0) }
                    } header: { header(pinned.isEmpty ? "\(items.count) 条" : "其他 · \(others.count) 条") }
                    .claudeCardRow()
                }
            }

            Section {
                Button {
                    editing = ProjectMemoryEditTarget(item: nil)
                } label: {
                    Label("添加一条", systemImage: "plus")
                        .foregroundStyle(Ink.ink)
                }
                .disabled(items.count >= ProjectMemoryItem.countLimit || !store.canPersist)
            }
            .claudeCardRow()

            if !recentBatches.isEmpty {
                Section {
                    ForEach(recentBatches) { batch in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(batch.summary)
                                    .font(TypeScale.ui(14.5))
                                    .foregroundStyle(Ink.ink)
                                Text(batch.at.formatted(date: .abbreviated, time: .shortened) + (batch.byUser ? " · 你改的" : " · 自动整理"))
                                    .font(TypeScale.ui(12))
                                    .foregroundStyle(Ink.ink3)
                            }
                            Spacer(minLength: 8)
                            Button("撤回") { store.undoMemoryChange(batch.id, in: projectID) }
                                .font(TypeScale.ui(14))
                                .foregroundStyle(Ink.ink)
                                .buttonStyle(.borderless)
                        }
                    }
                } header: { header("最近的变化") }
                .claudeCardRow()
            }

            if let proj = project {
                Section {
                    Toggle("自动整理项目记忆", isOn: Binding(
                        get: { proj.remembers },
                        set: { value in
                            guard var updated = store.project(projectID) else { return }
                            updated.autoMemory = value
                            _ = store.updateProject(updated)
                        }
                    ))
                    .tint(Ink.seal)
                    Toggle("私人的事也记", isOn: Binding(
                        get: { proj.remembersPrivate },
                        set: { store.setMemoryKeepsPrivate($0, in: projectID) }
                    ))
                    .tint(Ink.seal)
                    NavigationLink("以文本方式编辑") { ProjectMemoryView(projectID: projectID) }
                    if let legacy = proj.memoryLegacyText, !legacy.isEmpty {
                        NavigationLink("1.45 的原始记忆") {
                            ScrollView {
                                Text(legacy)
                                    .font(TypeScale.ui(15))
                                    .foregroundStyle(Ink.ink)
                                    .lineSpacing(5)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(18)
                            }
                            .background(Ink.paper.ignoresSafeArea())
                            .navigationTitle("原始记忆")
                            .navigationBarTitleDisplayMode(.inline)
                        }
                    }
                } footer: {
                    Text("只记你说过、一个月后还用得上的事，只在这个项目里用。记忆不多时每次都带上；多了以后只带置顶的和与问题相关的几条。「这段对话不进记忆」的对话不会被记下。")
                }
                .claudeCardRow()
            }
        }
        .claudeGroupedListStyle()
        .onAppear { store.ensureMemoryEntries(projectID) }
        .sheet(item: $editing) { target in
            ProjectMemoryItemEditor(projectID: projectID, item: target.item).environmentObject(store)
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(TypeScale.ui(13)).foregroundStyle(Ink.ink3).textCase(nil)
    }

    private func row(_ item: ProjectMemoryItem) -> some View {
        let expired = item.isExpired()
        let source = item.sourceThreadID.flatMap { id in store.threads.first(where: { $0.id == id })?.title }
        var caption = item.updatedAt.formatted(.dateTime.month().day())
        if let source { caption += " · 来自「\(source)」" }
        if let end = item.expiresAt {
            let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: end) ?? end
            caption += expired ? " · 已过期" : " · 到 \(lastDay.formatted(.dateTime.month().day())) 为止"
        }
        return Button { editing = ProjectMemoryEditTarget(item: item) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .font(TypeScale.ui(15))
                    .foregroundStyle(expired ? Ink.ink3 : Ink.ink)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(caption)
                    .font(TypeScale.ui(12))
                    .foregroundStyle(Ink.ink3)
                    .lineLimit(1)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button("删除", role: .destructive) { store.changeMemory([.delete(id: item.id)], in: projectID) }
        }
        .swipeActions(edge: .leading) {
            Button(item.isPinned ? "取消置顶" : "置顶") {
                store.setMemoryPinned(!item.isPinned, itemID: item.id, in: projectID)
            }
            .tint(Ink.ink2)
        }
    }
}

struct MemoryBatchSummary: Identifiable {
    let id: UUID
    let at: Date
    let summary: String
    let byUser: Bool
}

struct ProjectMemoryEditTarget: Identifiable {
    let item: ProjectMemoryItem?
    let id = UUID()
}

@MainActor
struct ProjectMemoryItemEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let item: ProjectMemoryItem?
    @State private var text = ""
    @State private var pinned = false
    @State private var hasEnd = false
    @State private var lastDay = Date()
    @State private var loaded = false

    private var clean: String { ProjectMemoryBook.clean(text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如：在准备 12 月的考研，目标是历史学", text: $text, axis: .vertical)
                        .lineLimit(2...6)
                } footer: {
                    Text("一句话，\(ProjectMemoryItem.textLimit) 字以内。")
                }
                .claudeCardRow()
                Section {
                    Toggle("置顶（每次都带上）", isOn: $pinned).tint(Ink.seal)
                    Toggle("有截止日期", isOn: $hasEnd).tint(Ink.seal)
                    if hasEnd {
                        DatePicker("用到这天为止", selection: $lastDay, displayedComponents: .date)
                    }
                }
                .claudeCardRow()
                if let item, let quote = item.sourceQuote, !quote.isEmpty {
                    Section("你当时说的") {
                        Text(quote).font(TypeScale.ui(14)).foregroundStyle(Ink.ink2)
                    }
                    .claudeCardRow()
                }
                if let item {
                    Section {
                        Button("删除这条", role: .destructive) {
                            store.changeMemory([.delete(id: item.id)], in: projectID)
                            dismiss()
                        }
                    }
                    .claudeCardRow()
                }
            }
            .claudeGroupedFormStyle()
            .navigationTitle(item == nil ? "添加记忆" : "修改记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ClaudeSheetCloseButton(label: "取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                        .disabled(clean.isEmpty)
                }
            }
        }
        .tint(Ink.ink)
        .presentationDetents([.medium, .large])
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = item?.text ?? ""
            pinned = item?.isPinned ?? false
            if let end = item?.expiresAt {
                hasEnd = true
                lastDay = Calendar.current.date(byAdding: .day, value: -1, to: end) ?? end
            }
        }
    }

    private func save() {
        let end = hasEnd ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: lastDay)) : nil
        if let item {
            if clean != item.text || end != item.expiresAt {
                store.changeMemory([.update(id: item.id, text: clean, quote: nil, expires: end)], in: projectID)
            }
            if pinned != item.isPinned { store.setMemoryPinned(pinned, itemID: item.id, in: projectID) }
        } else {
            let before = Set(store.project(projectID)?.currentMemoryItems.map(\.id) ?? [])
            store.changeMemory([.add(text: clean, quote: nil, expires: end)], in: projectID)
            if pinned, let added = store.project(projectID)?.memoryItems?.first(where: { !before.contains($0.id) }) {
                store.setMemoryPinned(true, itemID: added.id, in: projectID)
            }
        }
        dismiss()
    }
}
