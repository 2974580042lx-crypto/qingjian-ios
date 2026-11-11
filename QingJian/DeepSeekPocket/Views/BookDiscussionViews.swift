import SwiftUI

@MainActor
struct BookDiscussionVoiceControl: View {
    @EnvironmentObject private var store: AppStore
    let threadID: UUID
    let open: () -> Void
    @State private var choosing = false
    private var selected: String? {
        store.threads.first(where: { $0.id == threadID })?.discussionDraftCharacter
    }
    var body: some View {
        HStack(spacing: 10) {
            Button {
                open()
                choosing = true
            } label: {
                Label(selected.map { "问：\($0)" } ?? "问角色", systemImage: "person.bubble")
                    .font(TypeScale.caption).lineLimit(1)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Ink.raised, in: InkRounded(radius: 10))
            }
            .accessibilityIdentifier("book-discussion-character")
            .accessibilityValue(selected ?? "普通讨论")
            if selected != nil {
                Text("仅这一问").font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                Button {
                    _ = store.setDiscussionCharacter(nil, threadID: threadID)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12)).frame(width: 32, height: 32)
                }.accessibilityLabel("取消问角色，恢复普通讨论")
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Ink.seal).buttonStyle(.plain)
        .disabled(store.isGenerating || !store.canPersist)
        .sheet(isPresented: $choosing) {
            BookDiscussionCharacterPicker(threadID: threadID)
                .environmentObject(store).environmentObject(store.books)
        }
    }
}

@MainActor
struct BookDiscussionCharacterPicker: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var books: BookStore
    @Environment(\.dismiss) private var dismiss
    let threadID: UUID
    @State private var search = ""
    private var characters: [BookCharacter] {
        guard let session = store.threads.first(where: { $0.id == threadID })?.bookDiscussion,
              let book = books.book(session.bookID) else { return [] }
        return BookDiscussion.characters(in: book)
    }
    private var filtered: [BookCharacter] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return characters.filter { query.isEmpty || $0.allNames.contains { $0.localizedCaseInsensitiveContains(query) } }
    }
    private var typedName: String? { BookDiscussion.cleanCharacter(search) }
    private func choose(_ name: String?) {
        if store.setDiscussionCharacter(name, threadID: threadID) { dismiss() }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("选一位人物，让他用自己的口吻回答这一问。发送后自动回到普通讨论。")
                        .font(TypeScale.body).foregroundStyle(Ink.ink2)
                    Button("普通讨论", systemImage: "text.bubble") { choose(nil) }
                }
                Section("书中人物") {
                    ForEach(filtered) { person in
                        Button { choose(person.name) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(person.name).font(TypeScale.body).foregroundStyle(Ink.ink)
                                if !person.identity.isEmpty {
                                    Text(person.identity).font(TypeScale.caption).foregroundStyle(Ink.ink3).lineLimit(2)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if filtered.isEmpty {
                        Text("也可以在搜索框输入书中人物的名字。")
                            .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                    }
                }
                if let name = typedName,
                   !characters.contains(where: { $0.allNames.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame } }) {
                    Section {
                        Button("问「\(name)」", systemImage: "person.bubble") { choose(name) }
                    } footer: {
                        Text("没有人物档案也能提问，回答时会查找这个人物的原文。")
                    }
                }
            }
            .disabled(store.isGenerating || !store.canPersist)
            .searchable(text: $search, prompt: "搜索或输入书中角色名")
            .scrollContentBackground(.hidden).background(AppBackground())
            .navigationTitle("问角色").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }.tint(Ink.seal)
    }
}

@MainActor
struct BookDiscussionWelcome: View {
    @EnvironmentObject private var store: AppStore
    let session: BookDiscussionSession
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "text.bubble").font(.system(size: 30)).foregroundStyle(Ink.seal)
            Text("聊聊《\(session.bookTitle)》").font(TypeScale.heavy(27, relativeTo: .title)).foregroundStyle(Ink.ink)
            Text("像普通聊天一样提问。回答会参考已有读书笔记，并从完整原文中查找依据。讨论范围是全书，可能涉及结局。")
                .font(TypeScale.body).foregroundStyle(Ink.ink2).lineSpacing(5)
            Text("想听人物自己怎么说，可以点输入框里的「问角色」，再问他当时的想法。")
                .font(TypeScale.caption).foregroundStyle(Ink.ink2)
            VStack(alignment: .leading, spacing: 12) {
                prompt("讨论主题与结局", "这本书的主要矛盾和结局之间有什么联系？请结合原文讨论。")
                prompt("分析人物", "我想结合原文分析一个人物：")
                prompt("寻找伏笔", "挑几处重要的前后呼应或伏笔，说明对应章节和原文依据。")
                prompt("核对原句", "帮我在这本书里核对这段话，找到出处并解释上下文：")
            }
            Text("全书可检索，不等于每次回答都不会遗漏；可打开回答下方的书内依据核对。检索与回答的用量会计入用量日历。")
                .font(TypeScale.tiny).foregroundStyle(Ink.ink3).lineSpacing(3)
        }.frame(maxWidth: 600, alignment: .leading).padding(26)
        }
    }
    private func prompt(_ title: String, _ text: String) -> some View {
        Button { store.setDraft(text) } label: {
            HStack { Text(title); Spacer(); Image(systemName: "arrow.up.left") }
                .font(TypeScale.body).foregroundStyle(Ink.ink)
                .padding(14).background(Ink.raised, in: InkRounded(radius: 12))
        }
    }
}

@MainActor
struct BookDiscussionsView: View {
    @EnvironmentObject private var store: AppStore
    let bookID: UUID
    let opened: () -> Void
    @State private var search = ""
    private var discussions: [ChatThread] {
        store.discussions(in: bookID).filter { search.isEmpty || ($0.title + $0.preview).localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            Button {
                if store.startBookDiscussion(bookID) { opened() }
            } label: { Label("新建一个讨论", systemImage: "plus.bubble") }
                .disabled(store.isGenerating)
            if discussions.isEmpty { Text("人物、情节、主题或原句，都可以另开话题讨论。").font(TypeScale.body).foregroundStyle(Ink.ink3) }
            ForEach(discussions) { thread in
                Button {
                    guard !store.isGenerating else { return }
                    store.select(thread.id); opened()
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(thread.title).font(TypeScale.serif(17)).foregroundStyle(Ink.ink)
                        Text(thread.preview).font(TypeScale.label).foregroundStyle(Ink.ink2).lineLimit(3)
                        Text(thread.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                    }.multilineTextAlignment(.leading).padding(.vertical, 5)
                }.disabled(store.isGenerating)
            }
        }
        .searchable(text: $search, prompt: "搜索本书讨论")
        .scrollContentBackground(.hidden).background(AppBackground()).navigationTitle("本书讨论")
    }
}

@MainActor
struct BookReferencesView: View {
    @EnvironmentObject private var books: BookStore
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let references: [BookReference]
    @State private var reading: BookReference?
    var body: some View {
        NavigationStack {
            List {
                Text("这里保留了本次发给模型参考的原文，可对照回答核对。").font(TypeScale.label).foregroundStyle(Ink.ink3)
                ForEach(Array(references.enumerated()), id: \.element.id) { index, ref in
                    Section("原文\(index + 1) · 第\(ref.chapter + 1)章") {
                        Text(ref.chapterTitle).font(TypeScale.body).foregroundStyle(Ink.seal)
                        Text("第\(ref.paragraph + 1)段 · 原文节选").font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                        Text(ref.text).font(TypeScale.body).lineSpacing(6).textSelection(.enabled)
                        if books.book(ref.bookID) != nil {
                            Button("打开原文，查看上下文", systemImage: "book") { reading = ref }
                        } else {
                            Text("原书已从书架移除，保留的节选仍可查看。").font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(AppBackground()).navigationTitle("书内依据")
            .navigationBarTitleDisplayMode(.inline).toolbar { Button("完成") { dismiss() } }
            .sheet(item: $reading) { ref in
                NavigationStack {
                    ChapterReaderView(bookID: ref.bookID, chapter: ref.chapter, paragraph: ref.paragraph, opened: { reading = nil; dismiss() })
                        .environmentObject(store).environmentObject(books)
                }
            }
        }.tint(Ink.seal)
    }
}

