import SwiftUI
import UIKit

// Laid out like the Claude app's sidebar: wordmark and search on top, Projects,
// recent conversations with "查看全部", and at the bottom your avatar (settings)
// and a new-conversation button.
@MainActor
struct HistorySidebar: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var profile: ProfileStore
    let close: () -> Void
    let openSettings: () -> Void
    let openProjects: () -> Void
    let openAllChats: () -> Void
    var openBooks: () -> Void = {}
    @State private var searching = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var deleteTarget: ChatThread?
    // Pinned projects folded open in the sidebar.
    @State private var expanded: Set<UUID> = []
    private static let recentLimit = 12

    private var results: [ChatThread] {
        store.browsableThreads.filter { thread in
            thread.title.localizedCaseInsensitiveContains(search) ||
                thread.messages.contains(where: { $0.content.localizedCaseInsensitiveContains(search) })
        }
    }

    var body: some View {
        let night = InterfaceStyle.isNight
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: night ? .top : .center) {
                VStack(alignment: .leading, spacing: 6) {
                    // The wordmark is always the bundled serif, whatever font the app uses,
                    // like the serif title in the Claude app's sidebar.
                    Text("Sermo").font(.custom(InterfaceStyle.isSwiss ? "PingFangSC-Semibold" : "NotoSerifSC-Bold", size: 30, relativeTo: .largeTitle))
                        .foregroundStyle(Ink.ink)
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("history-title")
                    if night {
                        Text("千江有水千江月").font(TypeScale.serif(13)).tracking(3).foregroundStyle(Ink.ink3)
                    }
                }
                Spacer()
                GlassCircle(symbol: searching ? "xmark" : "magnifyingglass", label: searching ? "关闭搜索" : "搜索对话") {
                    withAnimation(.easeOut(duration: 0.2)) { searching.toggle() }
                    if searching { searchFocused = true } else { search = ""; searchFocused = false }
                }
            }
            .padding(.bottom, 18)
            if searching {
                TextField("搜索对话", text: $search).font(TypeScale.serif(17)).autocorrectionDisabled()
                    .focused($searchFocused)
                    .padding(.horizontal, 14).frame(height: 44).clearGlass(radius: 22)
                    .padding(.bottom, 12)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if searching && !search.isEmpty {
                        groupLabel(results.isEmpty ? "没有找到相关对话" : "搜索结果")
                        ForEach(results) { row($0) }
                    } else {
                        navRow("项目", symbol: "folder", identifier: "sidebar-projects") { openProjects() }
                        navRow("书架", symbol: "books.vertical", identifier: "sidebar-books") { openBooks() }
                        ForEach(store.projects.filter { $0.isPinned == true }) { projectGroup($0) }
                        groupLabel("最近")
                        let recent = store.recentThreads
                        if recent.isEmpty {
                            Text("还没有对话").font(TypeScale.serif(15)).foregroundStyle(Ink.ink3).padding(.vertical, 10)
                        }
                        ForEach(recent.prefix(Self.recentLimit)) { row($0) }
                        if night && !recent.isEmpty {
                            HStack(spacing: 8) {
                                MoonPhaseIcon(phase: 0.15, size: 13)
                                MoonPhaseIcon(phase: 0.5, size: 13)
                                MoonPhaseIcon(phase: 1, size: 13)
                                Text("月越圆，这局戏聊得越深").font(TypeScale.serif(13)).foregroundStyle(Ink.ink3)
                            }
                            .padding(.top, 10)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("对话前的月相表示聊了多久")
                        }
                        Button { openAllChats() } label: {
                            HStack(spacing: 6) {
                                Text("查看全部")
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                            }
                            .font(TypeScale.serif(17)).foregroundStyle(Ink.ink2)
                            .padding(.vertical, 14).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("sidebar-all-chats")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .contentMargins(.bottom, 90, for: .scrollContent)
            .contentMargins(.bottom, 90, for: .scrollIndicators)
            .overlay(alignment: .bottom) { footer }
        }
        .padding(.horizontal, 20).padding(.top, 16)
        .foregroundStyle(Ink.ink)
        .alert("重命名对话", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            TextField("对话名称", text: $renameText)
            Button("取消", role: .cancel) { renameID = nil }
            Button("保存") { if let id = renameID { store.renameThread(id, title: renameText) }; renameID = nil }
        }
        .alert("删除这个对话？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("删除", role: .destructive) { if let thread = deleteTarget { store.deleteThread(thread.id) }; deleteTarget = nil }
        } message: { Text("同时移除这个对话关联的旧版重试记录和附带的图片。已导出的备份和用量记录不受影响。") }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                openSettings()
            } label: {
                HStack(spacing: 10) {
                    ProfileAvatar(image: profile.avatar, size: 46, initial: profile.name.first.map(String.init))
                        .glassEffect(.regular.interactive(), in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        if let balance = store.balanceText {
                            Text("余额 \(balance)").font(TypeScale.serif(13)).monospacedDigit().foregroundStyle(Ink.ink2).lineLimit(1)
                        }
                        // DeepSeek's price band right now, so the cheaper hours are easy to remember.
                        Text(Pricing.statusLabel()).font(TypeScale.serif(11)).monospacedDigit().foregroundStyle(Ink.ink3).lineLimit(1)
                            .accessibilityIdentifier("sidebar-price-band")
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("个人资料与设置")
            .accessibilityIdentifier("sidebar-profile")
            Spacer(minLength: 8)
            Button { store.createNewChat(); finish() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 15, weight: .medium))
                    Text("新建会话").font(TypeScale.serif(17).weight(.semibold))
                }
                .foregroundStyle(InterfaceStyle.isNight ? Ink.onSeal : Ink.onSolid)
                .padding(.horizontal, 20).frame(height: 48)
                .background(InterfaceStyle.isNight ? Ink.seal : Ink.solid, in: InkCapsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-new-chat")
        }
        .padding(.bottom, 10)
    }

    private func groupLabel(_ title: String) -> some View {
        Text(title).font(TypeScale.serif(15)).foregroundStyle(Ink.ink3)
            .padding(.top, 22).padding(.bottom, 6)
    }

    private func navRow(_ title: String, symbol: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 18)).frame(width: 24)
                Text(title).font(TypeScale.serif(17))
            }
            .foregroundStyle(Ink.ink).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier(identifier)
    }

    // A pinned project: tap to fold its conversations out underneath, like a drawer.
    @ViewBuilder private func projectGroup(_ project: ChatProject) -> some View {
        let open = expanded.contains(project.id) && !store.isLocked(project.id)
        Button {
            if open { withAnimation(.easeOut(duration: 0.2)) { _ = expanded.remove(project.id) }; return }
            Task {
                if await ProjectLock.open(project.id, store: store) {
                    withAnimation(.easeOut(duration: 0.2)) { _ = expanded.insert(project.id) }
                }
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.ink3).frame(width: 24)
                Text(project.name).font(TypeScale.serif(17)).lineLimit(1)
                Spacer(minLength: 8)
                if project.isLocked { Image(systemName: "lock").font(.system(size: 12)).foregroundStyle(Ink.ink3) }
            }
            .foregroundStyle(Ink.ink).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-pinned-project")
        .accessibilityValue(open ? "展开" : "收起")
        if open {
            let members = store.threads(in: project.id)
            if members.isEmpty {
                Text("还没有对话").font(TypeScale.serif(15)).foregroundStyle(Ink.ink3)
                    .padding(.leading, 38).padding(.vertical, 6)
            }
            ForEach(members) { row($0, showProject: false).padding(.leading, 24) }
            Button { store.createThread(in: project.id); finish() } label: {
                Label("在此项目新建会话", systemImage: "plus").font(TypeScale.serif(15)).foregroundStyle(Ink.ink2)
                    .padding(.leading, 38).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func row(_ thread: ChatThread, showProject: Bool = true) -> some View {
        let active = thread.id == store.activeThreadID
        let night = InterfaceStyle.isNight
        return Button { store.select(thread.id); finish() } label: {
            HStack(spacing: 14) {
                Group {
                    // 夜江: each talk is a river with its own moon; the longer the talk, the fuller.
                    if night && thread.isPinned != true {
                        MoonPhaseIcon(phase: MoonPhaseIcon.phase(for: thread))
                    } else {
                        Image(systemName: thread.isPinned == true ? "pin" : "bubble.left")
                            .font(.system(size: 16)).foregroundStyle(Ink.ink2)
                    }
                }
                .frame(width: 24)
                .accessibilityHidden(true)
                // The open talk: semibold on a soft grey pill instead of a yellow marker stroke.
                Text(thread.title).font(TypeScale.serif(17)).fontWeight(active && !night ? .semibold : .regular).lineLimit(1)
                    .foregroundStyle(night && active ? Ink.seal : Ink.ink)
                Spacer(minLength: 8)
                if thread.id == store.generatingThreadID { PulseDot(size: 7) }
                else if showProject, let project = store.project(thread.projectID) {
                    Text(project.name).font(TypeScale.tiny).foregroundStyle(Ink.ink3).lineLimit(1)
                }
            }
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .background(active && !night ? Ink.line.opacity(0.7) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, -10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("history-thread-row")
        .accessibilityAddTraits(active ? .isSelected : [])
        .contextMenu {
            Button(thread.isPinned == true ? "取消置顶" : "置顶", systemImage: "pin") { store.togglePinned(thread.id) }
            Button("重命名", systemImage: "pencil") { renameText = thread.title; renameID = thread.id }
            Menu("移到项目", systemImage: "folder") {
                ForEach(store.projects.filter { !store.isLocked($0.id) }) { project in
                    Button(project.name) { store.moveThreads([thread.id], to: project.id) }
                }
                if thread.projectID != nil {
                    Button("移出项目", systemImage: "tray.and.arrow.up") { store.moveThreads([thread.id], to: nil) }
                }
            }
            Button("删除对话", systemImage: "trash", role: .destructive) { deleteTarget = thread }
                .disabled(thread.id == store.generatingThreadID)
        }
    }

    private func finish() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        searching = false; search = ""
        close()
    }
}

// Revisions share one sidebar entry but each keeps its own conversation path.
// Resolve the live family on every update so a locked/deleted project is hidden.
@MainActor
struct ConversationVersionsSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let threadID: UUID
    @State private var expanded: Set<UUID> = []
    @State private var selectionError: String?

    private var versions: [ChatThread] { store.conversationVersions(for: threadID) }

    var body: some View {
        NavigationStack {
            contents
                .navigationTitle("旧答案与版本")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
                }
        }
        .tint(Ink.seal)
        .preferredColorScheme(InterfaceStyle.isNight ? .dark : nil)
        .presentationBackground(Ink.paper)
    }

    @ViewBuilder private var contents: some View {
        if versions.isEmpty {
            ContentUnavailableView("暂时没有可查看的版本", systemImage: "lock",
                                   description: Text("对话可能已删除或项目已上锁，请返回原对话后再打开。"))
                .foregroundStyle(Ink.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppBackground())
        } else {
            versionList
        }
    }

    private var versionList: some View {
        let current = versions
        return List {
            Section {
                Text("重新生成或修改后重发会保留旧版本。切回不额外生成回答，你可以接着那个版本继续聊。")
                    .font(TypeScale.label).foregroundStyle(Ink.ink2)
                if current.count == 1 {
                    Text("目前只有这个版本；后续重新生成时，新旧版本都会显示在这里。")
                        .font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                }
                if store.isGenerating {
                    Label("回答正在生成，完成后可切换版本。", systemImage: "hourglass")
                        .font(TypeScale.label).foregroundStyle(Ink.ink3)
                }
                if let selectionError {
                    Text(selectionError).font(TypeScale.label).foregroundStyle(.red)
                }
            }.listRowBackground(Ink.raised)
            ForEach(Array(current.enumerated()), id: \.element.id) { index, version in
                Section {
                    versionRow(version, number: index + 1)
                }.listRowBackground(Ink.raised)
            }
            Section {
                Text("这里保留每个版本的整条对话路径，下面只预览最后一条回答。删除整条对话时，其关联的旧版本也会一并删除。")
                    .font(TypeScale.tiny).foregroundStyle(Ink.ink3)
            }.listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .foregroundStyle(Ink.ink)
        .background(AppBackground())
    }

    private func versionRow(_ version: ChatThread, number: Int) -> some View {
        let isCurrent = version.id == store.activeThreadID
        let isExpanded = expanded.contains(version.id)
        let answer = version.messages.last { $0.role == .assistant }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("版本 \(number)").font(TypeScale.serif(18).weight(.semibold))
                Spacer()
                if isCurrent {
                    Label("当前", systemImage: "checkmark.circle.fill")
                        .font(TypeScale.label).foregroundStyle(Ink.seal)
                }
            }
            Text("\(version.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(version.messages.count) 条消息")
                .font(TypeScale.tiny).foregroundStyle(Ink.ink3)
            if let answer {
                Text("最后一条回答").font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                if answer.state != .complete {
                    Text(answer.state == .streaming ? "正在生成" : (answer.state == .stopped ? "生成已停止" : "生成未完成"))
                        .font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                }
                if answer.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("这条回答还没有文字内容。").font(TypeScale.label).foregroundStyle(Ink.ink3)
                } else if isExpanded {
                    Text(String(answer.content.prefix(10_000)))
                        .font(TypeScale.serif(15)).foregroundStyle(Ink.ink)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if answer.content.count > 10_000 {
                        Text("此处预览前10,000字，切回这个版本可查看完整回答。")
                            .font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                    }
                } else {
                    Text(String(answer.content.prefix(400)))
                        .font(TypeScale.serif(15)).foregroundStyle(Ink.ink2).lineLimit(3)
                }
                if !answer.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(isExpanded ? "收起预览" : "展开回答预览") {
                        if isExpanded { expanded.remove(version.id) } else { expanded.insert(version.id) }
                    }
                    .font(TypeScale.label).buttonStyle(.borderless)
                    .accessibilityIdentifier("conversation-version-preview-\(version.id)")
                }
            } else {
                Text("这个版本尚没有文字回答。")
                    .font(TypeScale.label).foregroundStyle(Ink.ink3)
            }
            Button(isCurrent ? "正在使用这个版本" : "切回这个版本继续聊") { choose(version.id) }
                .font(TypeScale.label).buttonStyle(.borderless)
                .disabled(isCurrent || store.isGenerating || !store.canPersist)
                .accessibilityIdentifier("conversation-version-select-\(version.id)")
        }
        .padding(.vertical, 6)
    }

    private func choose(_ id: UUID) {
        guard !store.isGenerating, store.canPersist, versions.contains(where: { $0.id == id }) else {
            selectionError = "当前暂时无法切换，请在回答完成或重新打开对话后再试。"
            return
        }
        selectionError = nil
        if store.selectConversationVersion(id) { dismiss() }
        else { selectionError = store.errorMessage ?? "这个版本暂时无法打开，请稍后再试。" }
    }
}
