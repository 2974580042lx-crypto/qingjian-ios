import SwiftUI

@MainActor
struct StoryDirectionMenu: View {
    @EnvironmentObject private var store: AppStore
    let threadID: UUID
    private var direction: StoryDirection { store.threads.first { $0.id == threadID }?.story?.plotDirection ?? .free }
    var body: some View {
        Menu {
            ForEach(StoryDirection.allCases) { item in
                Button { store.changeStoryDirection(threadID, to: item) } label: {
                    if direction == item { Label(item.title, systemImage: "checkmark") } else { Text(item.title) }
                }
            }
            Text("从下一次回复生效，保留已发生的剧情")
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                Text(direction.title)
                Image(systemName: "chevron.down").font(.system(size: 9))
            }.font(TypeScale.label).foregroundStyle(Ink.seal)
        }
        .disabled(store.isGenerating)
        .accessibilityLabel("剧情走向")
        .accessibilityValue(direction.title)
    }
}

@MainActor
struct StoryPlaySheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let threadID: UUID
    @State private var scene = ""
    @State private var anchors = ""
    @State private var cast: [String] = []
    @State private var speaker = ""
    @State private var autoMemory = true
    @State private var loaded = false
    private var story: StorySession? { store.threads.first { $0.id == threadID }?.story }
    var body: some View {
        NavigationStack {
            Form {
                if let story {
                    Section {
                        StoryDirectionMenu(threadID: threadID)
                        Text(story.plotDirection.detail).font(TypeScale.label).foregroundStyle(Ink.ink2)
                    } header: { Text("剧情走向 · 随时可改") }
                    Section {
                        NavigationLink("本局记忆") { StoryMemoryView(threadID: threadID) }
                        NavigationLink("存档与分线") { StoryCheckpointsView(threadID: threadID) }
                        Toggle("自动整理本局记忆", isOn: $autoMemory)
                    } footer: {
                        Text("每约6轮用Flash整理一次新经历，费用计入用量。锁定的记忆不会被自动改写；每条分线独立保存。")
                    }
                    Section("当前场景") {
                        TextField("时间、地点、当前处境", text: $scene, axis: .vertical).lineLimit(3...8)
                    }
                    Section {
                        TextField("例如：保留时代背景，但允许改变某人的结局", text: $anchors, axis: .vertical).lineLimit(3...8)
                    } header: { Text("希望保留的大事件") } footer: { Text("配合“依托原著改写”使用；已经演出的经历仍然保留。") }
                    Section("在场人物") {
                        ForEach(store.storyCharacters(story), id: \.self) { name in
                            Toggle(name, isOn: Binding(get: { cast.contains(name) }, set: { on in
                                if on { if !cast.contains(name) { cast.append(name) } } else { cast.removeAll { $0 == name }; if speaker == name { speaker = "" } }
                            }))
                        }
                    }
                    Section {
                        Picker("下一次由谁回应", selection: $speaker) {
                            Text("自然回应").tag("")
                            Text("只写旁白").tag("旁白")
                            ForEach(cast, id: \.self) { Text($0).tag($0) }
                        }
                    } footer: { Text("点名只影响下一次回复；旁白也不会替你说话或做决定。保存后再发送消息。") }
                    Section {
                        director("继续场景", text: "（导演提示）请自然推进眼前的场景，写人物的回应与环境变化，不替我说话、行动或做决定。")
                        director("时间快进", text: "（导演提示）请将时间推进到次日，简短交代已经确定的变化，再停在需要我回应的地方；没有说过的决定不要替我做。")
                        director("只看他的反应", text: "（导演提示）这一条只写你扮演的人物对我上一句话的反应，不推进其他事件，不替我行动。")
                    } header: { Text("导演快捷动作") } footer: { Text("点选会填入输入框，你可以修改后发送。") }
                    Section {
                        Button(story.ended == true ? "重新继续这条故事线" : "将这条故事线标记为完结") {
                            store.finishStory(threadID, ended: story.ended != true); dismiss()
                        }
                    }
                }
            }
            .font(TypeScale.body).scrollContentBackground(.hidden).background(AppBackground())
            .navigationTitle("剧情控制").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("保存") { save(); dismiss() }.disabled(store.isGenerating) }
            }
            .onAppear {
                guard !loaded, let story else { return }
                scene = story.sceneNote ?? ""; anchors = story.fixedEvents ?? ""
                cast = story.presentCharacters ?? ([story.character] + (story.guests ?? []).map(\.character))
                speaker = story.nextSpeaker ?? ""; autoMemory = story.automaticMemory != false; loaded = true
            }
            .disabled(store.isGenerating)
        }.tint(Ink.seal)
    }
    private func save() { store.setStoryScene(threadID, scene: scene, cast: cast, speaker: speaker.isEmpty ? nil : speaker, fixedEvents: anchors, automaticMemory: autoMemory) }
    private func director(_ title: String, text: String) -> some View {
        Button(title) { save(); store.storyDirectorAction(text, threadID: threadID); dismiss() }
    }
}

@MainActor
struct StoryMemoryView: View {
    @EnvironmentObject private var store: AppStore
    let threadID: UUID
    @State private var editing: StoryFact?
    @State private var sourceFact: StoryFact?
    private var thread: ChatThread? { store.threads.first { $0.id == threadID } }
    private var facts: [StoryFact] { thread?.story?.memory?.facts ?? [] }
    var body: some View {
        List {
            Section {
                Button { store.refreshStoryMemory(threadID: threadID, force: true) } label: {
                    HStack { Text(store.memorizingStoryID == threadID ? "正在整理…" : "整理新发生的经历"); Spacer(); if store.memorizingStoryID == threadID { ProgressView() } }
                }.disabled(store.memorizingStoryID != nil || store.isGenerating || !store.hasKey)
                if let date = thread?.story?.memory?.updatedAt { Text("上次整理：\(date.formatted(date: .abbreviated, time: .shortened))").font(TypeScale.tiny).foregroundStyle(Ink.ink3) }
                if let issue = store.storyMemoryIssue { Text(issue).font(TypeScale.label).foregroundStyle(Ink.ink2) }
            } footer: { Text("只记录本局发生过的事。可以编辑或锁定；点“查看来源”核对实际对话。") }
            if facts.isEmpty { Text("还没有记忆。继续游玩后会自动整理，也可以手动添加。").foregroundStyle(Ink.ink3) }
            ForEach(facts) { fact in
                Button { editing = fact } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(fact.kind.title).font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                            if fact.locked { Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Ink.seal) }
                        }
                        Text(fact.text).font(TypeScale.body).foregroundStyle(Ink.ink).multilineTextAlignment(.leading)
                    }.padding(.vertical, 4)
                }
                .contextMenu {
                    Button(fact.locked ? "解除锁定" : "锁定这条") { var next = fact; next.locked.toggle(); _ = store.saveStoryFact(next, threadID: threadID) }
                    if !fact.sources.isEmpty { Button("查看来源", systemImage: "text.quote") { sourceFact = fact } }
                }
                .swipeActions { Button("删除", role: .destructive) { store.deleteStoryFact(fact.id, threadID: threadID) } }
            }
        }
        .scrollContentBackground(.hidden).background(AppBackground()).navigationTitle("本局记忆")
        .toolbar { Button { editing = StoryFact(kind: .event, text: "", locked: true) } label: { Image(systemName: "plus") }.disabled(store.isGenerating) }
        .sheet(item: $editing) { StoryFactEditor(threadID: threadID, fact: $0) }
        .sheet(item: $sourceFact) { fact in
            NavigationStack {
                List {
                    Text(fact.text).font(TypeScale.body)
                    ForEach((thread?.messages ?? []).filter { fact.sources.contains($0.id) }) { message in
                        Section(message.role == .user ? "你说的" : "人物的回应") { Text(message.content).textSelection(.enabled) }
                    }
                }.navigationTitle("记忆来源").toolbar { Button("完成") { sourceFact = nil } }
            }.tint(Ink.seal)
        }
    }
}

@MainActor
struct StoryFactEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let threadID: UUID
    @State var fact: StoryFact
    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $fact.kind) { ForEach(StoryFactKind.allCases) { Text($0.title).tag($0) } }
                TextField("已经发生的事实", text: $fact.text, axis: .vertical).lineLimit(4...14)
                Toggle("锁定，自动整理时保留", isOn: $fact.locked)
            }
            .font(TypeScale.body).scrollContentBackground(.hidden).background(AppBackground())
            .navigationTitle("编辑记忆").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { if store.saveStoryFact(fact, threadID: threadID) { dismiss() } }
                        .disabled(store.isGenerating || fact.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.tint(Ink.seal)
    }
}

@MainActor
struct StoryCheckpointsView: View {
    @EnvironmentObject private var store: AppStore
    let threadID: UUID
    @State private var name = ""
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var compare = false
    private var thread: ChatThread? { store.threads.first { $0.id == threadID } }
    var body: some View {
        List {
            Section {
                TextField("存档名称，例如：赴宴之前", text: $name)
                Button("保存当前进度") { if store.saveStoryCheckpoint(threadID: threadID, name: name) { name = "" } }
                Button("从当前进度开新分线") { _ = store.openStoryBranch(from: threadID, name: name) }
                if let id = thread?.story?.bookID, store.stories(in: id).count > 1 { Button("比较故事分线") { compare = true } }
            } footer: { Text("载入存档会开一条独立分线，当前故事保留。原著进度、人物设定、场景和记忆一起恢复。") }
            ForEach(thread?.storyCheckpoints ?? []) { checkpoint in
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(checkpoint.name).font(TypeScale.body)
                        Text(checkpoint.createdAt.formatted(date: .abbreviated, time: .shortened)).font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                        Text("\(checkpoint.session.plotDirection.title) · \(checkpoint.session.chapterTitle ?? "自由时间点")").font(TypeScale.tiny).foregroundStyle(Ink.ink2)
                    }
                    Button("从这里继续为新分线") { _ = store.openStoryBranch(from: threadID, checkpointID: checkpoint.id) }
                    Button("重命名") { renaming = checkpoint.id; renameText = checkpoint.name }
                }
                .swipeActions { Button("删除存档", role: .destructive) { store.deleteStoryCheckpoint(checkpoint.id, in: threadID) } }
            }
        }
        .scrollContentBackground(.hidden).background(AppBackground()).navigationTitle("存档与分线")
        .disabled(store.isGenerating)
        .alert("存档名称", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") { if let id = renaming { store.renameStoryCheckpoint(id, in: threadID, name: renameText) }; renaming = nil }
        }
        .sheet(isPresented: $compare) { if let id = thread?.story?.bookID { StoryCompareView(bookID: id) } }
    }
}

@MainActor
struct StoryArchiveView: View {
    @EnvironmentObject private var store: AppStore
    let bookID: UUID
    let opened: () -> Void
    @State private var search = ""
    @State private var compare = false
    private var stories: [ChatThread] {
        store.stories(in: bookID).filter { search.isEmpty || ($0.title + ($0.story?.userRole ?? "") + $0.preview).localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            ForEach([false, true], id: \.self) { ended in
                Section(ended ? "已完结" : "正在演") {
                    ForEach(stories.filter { ($0.story?.ended == true) == ended }) { thread in
                        Button { guard !store.isGenerating else { return }; store.select(thread.id); opened() } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(thread.title).font(TypeScale.serif(17)).foregroundStyle(Ink.ink)
                                Text("你是\(thread.story?.userRole.isEmpty == false ? thread.story!.userRole : "你自己") · \(thread.story?.plotDirection.title ?? "")")
                                    .font(TypeScale.tiny).foregroundStyle(Ink.ink2)
                                Text(thread.story?.chapterTitle ?? "自由时间点").font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                                Text(thread.preview).font(TypeScale.label).foregroundStyle(Ink.ink3).lineLimit(2)
                            }.multilineTextAlignment(.leading).padding(.vertical, 5)
                        }
                        .contextMenu {
                            Button("从这里开新分线") { if store.openStoryBranch(from: thread.id) { opened() } }
                            Button(ended ? "恢复为进行中" : "标记完结") { store.finishStory(thread.id, ended: !ended) }
                        }
                    }
                }
            }
            if stories.isEmpty { Text("这本书还没有开始的故事。选一个人物或名场面开局。").foregroundStyle(Ink.ink3) }
        }
        .searchable(text: $search, prompt: "找故事、人物或内容")
        .scrollContentBackground(.hidden).background(AppBackground()).navigationTitle("故事档案")
        .toolbar { Button("对比分线") { compare = true }.disabled(stories.count < 2) }
        .sheet(isPresented: $compare) { StoryCompareView(bookID: bookID) }
    }
}

@MainActor
struct StoryCompareView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    @State private var left: UUID?
    @State private var right: UUID?
    private var stories: [ChatThread] { store.stories(in: bookID) }
    var body: some View {
        NavigationStack {
            Form {
                Section("选择两条故事线") {
                    Picker("第一条", selection: $left) { ForEach(stories) { Text($0.title).tag(Optional($0.id)) } }
                    Picker("第二条", selection: $right) { ForEach(stories) { Text($0.title).tag(Optional($0.id)) } }
                }
                if let a = stories.first(where: { $0.id == left }), let b = stories.first(where: { $0.id == right }) {
                    comparison(a, other: b)
                    comparison(b, other: a)
                }
            }
            .font(TypeScale.body).scrollContentBackground(.hidden).background(AppBackground())
            .navigationTitle("分线对比").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
            .onAppear { left = stories.first?.id; right = stories.dropFirst().first?.id }
        }.tint(Ink.seal)
    }
    private func comparison(_ thread: ChatThread, other: ChatThread) -> some View {
        let otherFacts = Set((other.story?.memory?.facts ?? []).map(\.text))
        let different = (thread.story?.memory?.facts ?? []).filter { !otherFacts.contains($0.text) }
        return Section(thread.title) {
            LabeledContent("走向", value: thread.story?.plotDirection.title ?? "")
            LabeledContent("进度", value: thread.story?.chapterTitle ?? "自由时间点")
            if let scene = thread.story?.sceneNote, !scene.isEmpty { Text(scene) }
            if different.isEmpty { Text("没有已整理出的不同经历。可先到各自的“本局记忆”整理。").font(TypeScale.label).foregroundStyle(Ink.ink3) }
            ForEach(different) { fact in
                VStack(alignment: .leading, spacing: 4) { Text(fact.kind.title).font(TypeScale.tiny).foregroundStyle(Ink.ink3); Text(fact.text) }
            }
        }
    }
}

@MainActor
struct ScenePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let book: Book
    let select: (BookScene) -> Void
    @State private var search = ""
    private var scenes: [BookScene] {
        (book.profile?.scenes ?? []).filter { search.isEmpty || ($0.title + $0.summary + $0.characters.joined()).localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        NavigationStack {
            List(scenes) { scene in
                Button { select(scene); dismiss() } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(scene.title).font(TypeScale.serif(17)).foregroundStyle(Ink.ink)
                        Text(book.chapterLabel(scene.chapter)).font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                        Text(scene.before ?? "从事件发生前开场；可补全名场面以定位到具体段落。").font(TypeScale.label).foregroundStyle(Ink.ink2)
                    }.multilineTextAlignment(.leading).padding(.vertical, 4)
                }
            }
            .searchable(text: $search, prompt: "搜场景、人物或事件")
            .scrollContentBackground(.hidden).background(AppBackground()).navigationTitle("从名场面之前开始")
            .toolbar { Button("取消") { dismiss() } }
        }.tint(Ink.seal)
    }
}

@MainActor
struct SceneCatalogueView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var books: BookStore
    let bookID: UUID
    let opened: () -> Void
    @State private var search = ""
    @State private var selected: BookScene?
    @State private var confirm = false
    private var book: Book? { books.book(bookID) }
    private var scenes: [BookScene] {
        (book?.profile?.scenes ?? []).filter { search.isEmpty || ($0.title + $0.summary + $0.characters.joined()).localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            Section {
                if books.sceneScanBookID == bookID {
                    HStack { ProgressView(); Text("补全中 \(books.sceneScanProgress)") }
                    Button("暂停，保留当前进度") { books.pauseSceneRefinement() }
                } else {
                    Button("补全与细化名场面") { confirm = true }.disabled(books.sceneScanBookID != nil || books.isReading || books.deepReading != nil)
                }
                Text("按原文拆出见面、试探、冲突、选择与转折，并定位事件触发前的段落。已读过的书也可以补全。")
                    .font(TypeScale.label).foregroundStyle(Ink.ink3)
            }
            ForEach(scenes) { scene in
                Button { selected = scene } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(scene.title).font(TypeScale.serif(17)).foregroundStyle(Ink.ink)
                        Text(book?.chapterLabel(scene.chapter) ?? "").font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                        Text(scene.before ?? "进入事件发生之前，保留你的选择。").font(TypeScale.label).foregroundStyle(Ink.ink2)
                        if scene.paragraph != nil { Label("已定位原文起点", systemImage: "text.book.closed").font(TypeScale.tiny).foregroundStyle(Ink.seal) }
                    }.multilineTextAlignment(.leading).padding(.vertical, 5)
                }
            }
        }
        .searchable(text: $search, prompt: "搜名场面、人物或事件")
        .scrollContentBackground(.hidden).background(AppBackground()).navigationTitle("名场面 · \(scenes.count)")
        .sheet(item: $selected) { scene in
            if let book, let profile = book.profile { StartStoryView(book: book, profile: profile, initialScene: scene, opened: opened).environmentObject(store).environmentObject(books) }
        }
        .alert("补全名场面", isPresented: $confirm) {
            Button("取消", role: .cancel) { }
            Button("开始或继续") { books.refineScenes(bookID) }
        } message: { Text("将用Flash按原文逐段提取，会产生阅读费用并计入用量。每段完成立即保存，暂停后可继续；不会清空人物卡或文风精读。") }
    }
}

