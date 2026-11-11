import SwiftUI
import UniformTypeIdentifiers
import UIKit
import ImageIO
import PhotosUI

private extension View {
    // Both stores report errors; show whichever has one.
    func bookAlerts(_ store: AppStore, _ books: BookStore) -> some View {
        alert("暂时没有完成", isPresented: Binding(get: { books.errorMessage != nil || store.errorMessage != nil },
                                              set: { if !$0 { books.errorMessage = nil; store.errorMessage = nil } })) {
            Button("知道了") { books.errorMessage = nil; store.errorMessage = nil }
        } message: { Text(books.errorMessage ?? store.errorMessage ?? "") }
    }
}

// The bookshelf: import a novel as TXT, let it be read once, then talk with its people.
@MainActor
struct BookshelfView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var books: BookStore
    @Environment(\.dismiss) private var dismiss
    let opened: () -> Void
    @State private var path: [UUID] = []
    @State private var shelfExport: URL?
    @State private var managingPersonas = false
    @State private var search = ""
    @State private var selectedCoverID: UUID?
    @AppStorage("qingjian.bookshelf.sort") private var sortPreference = ShelfSort.recentImport.rawValue

    private enum ShelfSort: String, CaseIterable {
        case recentRead, recentImport, title
        var label: String {
            switch self {
            case .recentRead: return "最近阅读"
            case .recentImport: return "最近导入"
            case .title: return "书名"
            }
        }
    }

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var sortOrder: ShelfSort { ShelfSort(rawValue: sortPreference) ?? .recentImport }
    private var visibleBooks: [Book] {
        books.books.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }.sorted { lhs, rhs in
            switch sortOrder {
            case .recentRead:
                // Old bookmarks may predate lastReadAt; unread books stay below books opened before.
                let left = lhs.lastReadAt ?? (lhs.bookmark == nil ? Date.distantPast : lhs.importedAt)
                let right = rhs.lastReadAt ?? (rhs.bookmark == nil ? Date.distantPast : rhs.importedAt)
                if left != right { return left > right }
            case .title:
                let order = lhs.title.localizedStandardCompare(rhs.title)
                if order != .orderedSame { return order == .orderedAscending }
            case .recentImport: break
            }
            if lhs.importedAt != rhs.importedAt { return lhs.importedAt > rhs.importedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                emptyShelf
                recentShelf
                shelfHeading
                emptySearch
                shelfBooks
            }
            .listStyle(.plain)
            .searchable(text: $search, prompt: "搜索书名")
            .scrollContentBackground(.hidden)
            .background {
                ShelfAtmosphere(book: visibleBooks.first(where: { $0.id == selectedCoverID }) ?? visibleBooks.first)
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .overlay {
                if books.isImporting {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在导入并分章…").font(TypeScale.label).foregroundStyle(Ink.ink2)
                    }
                    .padding(24)
                    .background(Ink.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .navigationTitle("书架")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("导出完整书架", systemImage: "square.and.arrow.up") {
                            Task { shelfExport = await store.exportShelfArchive() }
                        }
                        Button("恢复书架备份", systemImage: "square.and.arrow.down") {
                            DocumentPicker.present([.json], asCopy: false) { url in Task { await store.importShelfArchive(url) } }
                        }
                    } label: {
                        if store.shelfBackupBusy { ProgressView() } else { Image(systemName: "externaldrive") }
                    }.disabled(store.shelfBackupBusy || store.isGenerating)
                    .accessibilityLabel("完整书架备份")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { managingPersonas = true } label: { Image(systemName: "person.crop.square") }.accessibilityLabel("我的人物卡")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { pickBook() } label: { Image(systemName: "plus") }.accessibilityLabel("导入小说")
                        .disabled(books.isImporting)
                }
            }
            .sheet(isPresented: Binding(get: { shelfExport != nil }, set: { if !$0 { shelfExport = nil } })) {
                if let url = shelfExport { ShareSheet(items: [url]) }
            }
            .navigationDestination(for: UUID.self) { id in BookDetailView(bookID: id, opened: opened) }
            .bookAlerts(store, books)
            .sheet(isPresented: $managingPersonas) { PersonaListView().environmentObject(books) }
        }
        .tint(Ink.ink)
    }


    @ViewBuilder private var emptyShelf: some View {
                if books.books.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("导入一本小说的 TXT 或 EPUB 文件，Sermo 会分段读完全书，整理出人物档案、作者笔触和名场面。读完之后，选一个人物就能开聊。")
                            .font(TypeScale.serif(15)).foregroundStyle(Ink.ink3)
                        Button { pickBook() } label: { Label("导入 TXT 或 EPUB", systemImage: "doc.badge.plus") }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("book-import")
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }
    }

    @ViewBuilder private var recentShelf: some View {
                if !InterfaceStyle.isNight, query.isEmpty,
                   let recent = books.books.filter({ $0.bookmark != nil }).max(by: { ($0.lastReadAt ?? $0.importedAt) < ($1.lastReadAt ?? $1.importedAt) }),
                   let mark = recent.bookmark {
                    Section("最近阅读") {
                        NavigationLink(value: recent.id) {
                            HStack(spacing: 14) {
                                ShelfCover(book: recent).frame(width: 52, height: 78)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(recent.title).font(TypeScale.serif(19)).foregroundStyle(Ink.ink)
                                    Text(recent.chapterLabel(mark.chapter)).font(TypeScale.label).foregroundStyle(Ink.ink3).lineLimit(1)
                                    Label("进入书籍", systemImage: "book").font(TypeScale.label).foregroundStyle(Ink.seal)
                                }
                            }.padding(.vertical, 8)
                        }.listRowBackground(Color.clear)
                    }
                }
    }

    @ViewBuilder private var shelfHeading: some View {
                if !books.books.isEmpty {
                    HStack {
                        Text(query.isEmpty ? "全部图书 · \(visibleBooks.count)" : "搜索结果 · \(visibleBooks.count)")
                            .font(TypeScale.label).foregroundStyle(Ink.ink3)
                        Spacer()
                        Menu {
                            Picker("排序", selection: $sortPreference) {
                                ForEach(ShelfSort.allCases, id: \.rawValue) { order in
                                    Text(order.label).tag(order.rawValue)
                                }
                            }
                        } label: {
                            Label(sortOrder.label, systemImage: "arrow.up.arrow.down")
                                .font(TypeScale.label).foregroundStyle(Ink.ink2)
                        }
                        .accessibilityLabel("书架排序")
                        .accessibilityValue(sortOrder.label)
                        .accessibilityIdentifier("bookshelf-sort")
                    }
                    .listRowBackground(Color.clear)
                }
    }

    @ViewBuilder private var emptySearch: some View {
                if !query.isEmpty && visibleBooks.isEmpty && !books.books.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("没有找到匹配的书").font(TypeScale.body).foregroundStyle(Ink.ink)
                        Text("试试书名中的其他关键词。").font(TypeScale.label).foregroundStyle(Ink.ink3)
                        Button("清除搜索") { search = "" }.font(TypeScale.label)
                    }
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                }
    }

    @ViewBuilder private var shelfBooks: some View {
                if InterfaceStyle.isNight {
                    if !visibleBooks.isEmpty {
                        NightShelf(books: visibleBooks, readingID: books.readingBookID, picked: $selectedCoverID) { path.append($0) }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
                } else {
                ForEach(visibleBooks) { book in
                    NavigationLink(value: book.id) {
                        HStack(spacing: 14) {
                            ShelfCover(book: book).frame(width: 52, height: 78)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(book.title).font(TypeScale.serif(17)).foregroundStyle(Ink.ink).lineLimit(1)
                                Text(BookStatusText.short(book, reading: books.readingBookID == book.id))
                                    .font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                                if let mark = book.bookmark {
                                    Text("读到 · " + book.chapterLabel(mark.chapter)).font(TypeScale.tiny).foregroundStyle(Ink.seal).lineLimit(1)
                                    ProgressView(value: Double(mark.chapter + 1), total: Double(max(1, book.chapterTitles.count))).tint(Ink.seal)
                                }
                            }
                        }.padding(.vertical, 6)
                    }
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("book-row")
                }
                }
    }

    // SwiftUI's .fileImporter does not open from this sheet while the chat page
    // underneath has one of its own, so the system picker is presented directly.
    private func pickBook() {
        DocumentPicker.presentMany([.plainText, .text, UTType(filenameExtension: "txt") ?? .plainText, .epub], asCopy: true) { urls in
            Task {
                var imported: [UUID] = []
                for url in urls {
                    if let id = await books.importBook(from: url) { imported.append(id) }
                }
                // One book opens straight away; several stay on the shelf to choose from.
                if imported.count == 1, let id = imported.first { path.append(id) }
            }
        }
    }
}

enum BookStatusText {
    static func short(_ book: Book, reading: Bool) -> String {
        let size = "\(wan(book.characterCount)) · \(book.chapterTitles.count) 章"
        if reading { return size + " · 正在读 \(book.readCount)/\(book.segments.count)" }
        switch book.status {
        case .ready: return size + " · \(book.profile?.characters.count ?? 0) 个人物"
        case .failed: return size + " · 没有读完"
        case .reading, .imported:
            return size + (book.readCount == 0 ? " · 还没读" : " · 读到 \(book.readCount)/\(book.segments.count)")
        }
    }
    static func wan(_ count: Int) -> String {
        count >= 10000 ? String(format: "%.1f 万字", Double(count) / 10000) : "\(count) 字"
    }
}

@MainActor
struct BookDetailView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var books: BookStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    let opened: () -> Void
    @State private var starting = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmDelete = false
    @State private var confirmReset = false
    private var book: Book? { books.book(bookID) }
    private var isReading: Bool { books.readingBookID == bookID }

    var body: some View {
        Form {
            if let book {
                Section {
                    VStack(spacing: 14) {
                        ShelfCover(book: book).frame(width: 144, height: 216)
                            .shadow(color: .black.opacity(0.3), radius: 16, y: 10)
                        BookCoverMenu(book: book)
                        if books.designingCovers.contains(bookID) {
                            HStack { ProgressView(); Text("正在设计封面…") }.font(TypeScale.label)
                        } else if let note = book.coverNote {
                            Text(note).font(TypeScale.tiny).foregroundStyle(Ink.ink3).multilineTextAlignment(.center)
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 16)
                }.listRowBackground(Color.clear)
                Section {
                    LabeledContent("字数", value: BookStatusText.wan(book.characterCount))
                    LabeledContent("章节", value: "\(book.chapterTitles.count) 章，分 \(book.segments.count) 段读")
                    NavigationLink {
                        ChapterReaderView(bookID: bookID, chapter: book.bookmark?.chapter ?? 0, paragraph: book.bookmark?.paragraph, opened: opened)
                    } label: { Label(book.bookmark == nil ? "阅读原文" : "继续阅读原文", systemImage: "book") }
                        .accessibilityIdentifier("book-read-text")
                    Button {
                        if let latest = store.discussions(in: bookID).first { store.select(latest.id); opened() }
                        else if store.startBookDiscussion(bookID) { opened() }
                    } label: { Label("讨论这本书", systemImage: "text.bubble") }
                        .disabled(store.isGenerating)
                    if !store.discussions(in: bookID).isEmpty {
                        NavigationLink {
                            BookDiscussionsView(bookID: bookID, opened: opened).environmentObject(store)
                        } label: { Text("讨论记录 · \(store.discussions(in: bookID).count)") }
                    }
                    NavigationLink {
                        StoryArchiveView(bookID: bookID, opened: opened).environmentObject(store)
                    } label: { Label("故事档案 · \(store.stories(in: bookID).count)", systemImage: "books.vertical") }
                    if let cost = book.cost {
                        LabeledContent("已花费", value: Pricing.label(cost) + "（估算）")
                    }
                }
                readingSection(book)
                if let profile = book.profile, book.isReady { readySections(book, profile) }
            }
        }
        .font(TypeScale.body)
        .tint(Ink.seal)
        .scrollContentBackground(.hidden)
        .background { ShelfAtmosphere(book: book) }
        .navigationTitle(book?.title ?? "书")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("重命名", systemImage: "pencil") { renameText = book?.title ?? ""; renaming = true }
                    if book?.readCount == book?.segments.count && book?.segments.isEmpty == false {
                        Button("重新整理档案", systemImage: "arrow.triangle.2.circlepath") { books.rebuildProfile(bookID) }
                            .disabled(books.isReading)
                    }
                    if (book?.readCount ?? 0) > 0 {
                        Button("从头重读", systemImage: "arrow.counterclockwise") { confirmReset = true }.disabled(books.isReading)
                    }
                    Button("从书架删除", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("书的选项")
            }
        }
        .alert("重命名", isPresented: $renaming) {
            TextField("书名", text: $renameText)
            Button("取消", role: .cancel) { }
            Button("保存") { books.rename(bookID, to: renameText) }
        }
        .alert("从书架删除这本书？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) { books.delete(bookID); dismiss() }
        } message: { Text("会删除正文、读书笔记和人物档案。已经开始的对话会保留，但之后不再带档案。") }
        .alert("从头重读？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) { }
            Button("清空并重读", role: .destructive) { books.resetReading(bookID) }
        } message: { Text("会清空已有的读书笔记和人物档案（包括你手动改过的内容），之后需要重新阅读，会再次产生费用。") }
        .sheet(isPresented: $starting) {
            if let book, let profile = book.profile {
                StartStoryView(book: book, profile: profile) { opened() }
                    .environmentObject(store).environmentObject(books)
            }
        }
        .bookAlerts(store, books)
    }

    @ViewBuilder private func readingSection(_ book: Book) -> some View {
        let total = max(1, book.segments.count)
        if isReading {
            Section {
                ProgressView(value: Double(book.readCount), total: Double(total))
                Text(book.readCount == book.segments.count ? "全书读完了，正在整理人物档案…" : "正在读第 \(book.readCount + 1) 段，共 \(book.segments.count) 段")
                    .font(TypeScale.label).foregroundStyle(Ink.ink2)
                Button("暂停") { books.pause() }
            } footer: {
                Text("读的时候请让 Sermo 留在前台。切到后台一会儿后会暂停，读过的部分不会丢，回来点「继续阅读」即可。")
            }
        } else if !book.isReady {
            Section {
                if let issue = book.issue {
                    Text(issue).font(TypeScale.label).foregroundStyle(Ink.ink2)
                }
                if book.readCount > 0 {
                    ProgressView(value: Double(book.readCount), total: Double(total))
                }
                Picker("做笔记用", selection: Binding(get: { book.notesModel }, set: { books.setReadingModel($0, in: bookID) })) {
                    Text("Flash").tag(DeepSeekModel.flash)
                    Text("V4 Pro").tag(DeepSeekModel.pro)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("book-reading-model")
                Button(book.readCount == 0 ? "开始阅读" : "继续阅读") { books.startReading(bookID) }
                    .disabled(books.isReading)
                    .accessibilityIdentifier("book-start-reading")
            } header: {
                Text(book.readCount == 0 ? "还没读" : "读到 \(book.readCount)/\(book.segments.count) 段")
            } footer: {
                Text("用 \(book.notesModel.title) 每次读几章做笔记，最后用 V4 Pro 整理成档案。按这本书的长度，现在读完预计约 \(Pricing.label(books.estimatedCost(of: book)))，实际以用量记录为准。V4 Pro 做的笔记更细，人名、关系和台词更准，价格约为 Flash 的四倍。\n\n现在是\(Pricing.statusLabel())。空闲时段（工作日 9–12 点、14–18 点以外，以及周末）价格减半。" +
                     (books.isReading && !isReading ? "\n另一本书正在读，读完后再开始这本。" : ""))
            }
        }
    }

    @ViewBuilder private func readySections(_ book: Book, _ profile: BookProfile) -> some View {
        Section {
            Button { starting = true } label: {
                Label("选一个人物开聊", systemImage: "bubble.left.and.text.bubble.right")
            }
            .disabled(!store.hasKey || store.isGenerating)
            .accessibilityIdentifier("book-start-story")
        } footer: {
            if !profile.summary.isEmpty { Text(profile.summary) }
        }
        Section("人物") {
            ForEach(profile.characters) { character in
                NavigationLink {
                    CharacterEditView(bookID: bookID, character: character)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(character.name)
                        if !character.identity.isEmpty {
                            Text(character.identity).font(TypeScale.tiny).foregroundStyle(Ink.ink3).lineLimit(2)
                        }
                    }
                }
            }
        }
        Section {
            NavigationLink { StyleEditView(bookID: bookID, text: profile.style.description) } label: {
                Text(profile.style.description.isEmpty ? "还没有文风描述" : profile.style.description)
                    .font(TypeScale.label).foregroundStyle(Ink.ink2).lineLimit(4)
            }
            ForEach(Array(profile.style.excerpts.enumerated()), id: \.offset) { _, excerpt in
                Text(excerpt).font(TypeScale.label).foregroundStyle(Ink.ink3)
            }
        } header: { Text("作者笔触") } footer: { Text("聊天时会带上这段描述和几段原文，让回答更像原著。") }
        Section("名场面") {
            NavigationLink {
                SceneCatalogueView(bookID: bookID, opened: opened).environmentObject(store).environmentObject(books)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("浏览与补全名场面 · \(profile.scenes.count)")
                    Text("从事件发生前开始，可按人物或事件搜索。").font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                }
            }
        }
    }
}

// One character's card, editable. Changes apply to conversations from the next answer on.
@MainActor
struct CharacterEditView: View {
    @EnvironmentObject private var books: BookStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    let originalName: String
    @State private var draft: BookCharacter

    init(bookID: UUID, character: BookCharacter) {
        self.bookID = bookID
        self.originalName = character.name
        _draft = State(initialValue: character)
    }

    private var reading: Bool { books.isDeepReading(originalName, in: bookID) }

    var body: some View {
        Form {
            Section {
                Button {
                    Task {
                        if await books.deepReadCharacter(originalName, in: bookID),
                           let fresh = books.book(bookID)?.profile?.characters.first(where: { $0.name == originalName }) {
                            draft = fresh
                        }
                    }
                } label: {
                    HStack {
                        Label(draft.deepReadAt == nil ? "精读这个人物" : "重新精读", systemImage: "text.magnifyingglass")
                        Spacer()
                        if reading { ProgressView() }
                    }
                }
                .disabled(books.deepReading != nil)
            } footer: {
                Text((draft.deepReadAt.map { "已精读：\($0.formatted(date: .abbreviated, time: .shortened))。" } ?? "") +
                     "用 V4 Pro 把这个人物的全部笔记、台词和原文片段再读一遍，写出更细的人物卡：不同情境下的反应、对不同人的态度、绝不会说或做的事。大约几毛钱，只需做一次。现在是\(Pricing.statusLabel())。")
            }
            Section("名字") {
                TextField("名字", text: $draft.name)
                TextField("其他称呼，用顿号隔开", text: Binding(
                    get: { draft.aliases.joined(separator: "、") },
                    set: { draft.aliases = $0.components(separatedBy: CharacterSet(charactersIn: "、,，")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
            }
            field("身份", $draft.identity)
            field("性格", $draft.personality)
            field("说话方式", $draft.speech)
            field("不同情境下的反应", optional($draft.behavior))
            field("对不同人的态度", optional($draft.attitudes))
            field("绝不会说或做的事", optional($draft.taboos))
            field("人物关系", $draft.relationships)
            Section {
                TextField("经历", text: $draft.arc, axis: .vertical).lineLimit(3...12)
            } header: { Text("经历") } footer: { Text("不选时间点开聊时会带上；选了时间点就改用前情提要，不带这段。") }
            if let corrections = draft.corrections, !corrections.isEmpty {
                Section {
                    ForEach(Array(corrections.enumerated()), id: \.offset) { _, line in
                        Text(line).font(TypeScale.label).foregroundStyle(Ink.ink2)
                    }
                    .onDelete { offsets in
                        var list = draft.corrections ?? []
                        list.remove(atOffsets: offsets)
                        draft.corrections = list.isEmpty ? nil : list
                    }
                } header: { Text("你纠正过的地方") } footer: { Text("在聊天里长按回答选「这里不像」加上的，每局都会带着。左滑可删除。") }
            }
            if !draft.quotes.isEmpty {
                Section("原著台词") {
                    ForEach(Array(draft.quotes.enumerated()), id: \.offset) { _, quote in
                        Text("「\(quote.text)」").font(TypeScale.label).foregroundStyle(Ink.ink2)
                    }
                    .onDelete { draft.quotes.remove(atOffsets: $0) }
                }
            }
        }
        .font(TypeScale.body)
        .tint(Ink.seal)
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .disabled(reading)
        .navigationTitle(originalName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { books.updateCharacter(draft, originalName: originalName, in: bookID); dismiss() }
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || reading)
            }
        }
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        Section(title) { TextField(title, text: text, axis: .vertical).lineLimit(2...10) }
    }

    private func optional(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

@MainActor
struct StyleEditView: View {
    @EnvironmentObject private var books: BookStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    @State var text: String
    private var style: BookStyle? { books.book(bookID)?.profile?.style }
    private var reading: Bool { books.isDeepReading("文风", in: bookID) }

    var body: some View {
        Form {
            Section {
                Button {
                    Task {
                        if await books.deepReadStyle(in: bookID), let fresh = style?.description { text = fresh }
                    }
                } label: {
                    HStack {
                        Label(style?.deepReadAt == nil ? "精读文风" : "重新精读", systemImage: "text.magnifyingglass")
                        Spacer()
                        if reading { ProgressView() }
                    }
                }
                .disabled(books.deepReading != nil)
            } footer: {
                Text("用 V4 Pro 读全书各处约 30 段原文，写出更具体的文风规则、标志性写法和「原著不会这样写」的清单，并挑出最有代表性的原文片段。大约几毛钱，只需做一次。现在是\(Pricing.statusLabel())。")
            }
            Section {
                TextField("作者笔触", text: $text, axis: .vertical).lineLimit(6...20)
            } header: { Text("文风描述") } footer: { Text("写成可以照着写的要求，例如叙述视角、句子长短、对白的写法。") }
            if let signatures = style?.signatures, !signatures.isEmpty {
                Section("标志性写法") { ForEach(signatures, id: \.self) { Text($0).font(TypeScale.label).foregroundStyle(Ink.ink2) } }
            }
            if let avoid = style?.avoid, !avoid.isEmpty {
                Section("原著不会这样写") { ForEach(avoid, id: \.self) { Text($0).font(TypeScale.label).foregroundStyle(Ink.ink2) } }
            }
        }
        .font(TypeScale.body)
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .disabled(reading)
        .navigationTitle("作者笔触")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { books.updateStyle(text, in: bookID); dismiss() }.disabled(reading)
            }
        }
    }
}

// Pick who to talk with, who you are, where it starts and how to play.
@MainActor
struct StartStoryView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var books: BookStore
    @Environment(\.dismiss) private var dismiss
    let book: Book
    let profile: BookProfile
    var initialChapter: Int? = nil
    var initialOpening = ""
    var initialScene: BookScene? = nil
    let opened: () -> Void
    @State private var character = ""
    @State private var userRole = ""
    @State private var personaID: UUID?
    @State private var opening = ""
    @State private var chapter: Int?
    @State private var instruction = ""
    @State private var guests: [StoryGuest] = []
    @State private var direction: StoryDirection = .free
    private var followsBook: Bool { direction != .free }
    @State private var canonMode: CanonMode = .involve
    @State private var managingPersonas = false
    @State private var starting = false
    @State private var prepared = false
    @State private var sceneStart: StorySceneStart?
    @State private var choosingScene = false
    @State private var locatingScene = false

    private var playsBookCharacter: Bool {
        let role = userRole.trimmingCharacters(in: .whitespacesAndNewlines)
        return !role.isEmpty && profile.characters.contains { $0.name != character && $0.allNames.contains(role) }
    }
    private var plotFooter: String {
        if direction == .adapted { return direction.detail + " 游玩中可以随时切换。" }
        guard followsBook else { return "开局之后剧情完全跟着你的选择走，会慢慢变成 if 线。游玩中可以随时切换。" }
        var text = "按原著的剧情一段一段往前走：你的选择会改变细节，但大事照原著发生，演完一段自动进入下一段。"
        text += playsBookCharacter ? "原著里没有你的段落，可以把你卷进去当旁观者或知情人，或者用一段旁白跳到下一个有你的地方。"
                                   : "原著里没有你的段落，会把你卷进去当旁观者或知情人。"
        if chapter == nil { text += "没选时间点就从第一章开始。" }
        return text
    }
    private var otherBooks: [Book] { books.books.filter { $0.id != book.id && $0.isReady } }
    private var chosenPersona: PersonaCard? {
        guard let personaID, let card = books.personas.first(where: { $0.id == personaID }),
              card.name == userRole.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return card
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("和谁聊") {
                    Picker("人物", selection: $character) {
                        ForEach(profile.characters) { Text($0.name).tag($0.name) }
                    }
                    .accessibilityIdentifier("story-character")
                }
                Section {
                    Picker("从哪里开始", selection: $chapter) {
                        Text("不限定").tag(Int?.none)
                        ForEach(book.chapterTitles.indices, id: \.self) { index in
                            Text(book.chapterTitles[index]).tag(Optional(index))
                        }
                    }
                    .pickerStyle(.navigationLink)
                    if !profile.scenes.isEmpty { Button("从名场面之前开始") { choosingScene = true } }
                    if let point = sceneStart {
                        Text("起点：\(point.title)发生之前").font(TypeScale.label).foregroundStyle(Ink.seal)
                        if !point.located { Text("开聊前会先定位这场戏的原文起点，再生成只包含此前经历的前情提要。").font(TypeScale.tiny).foregroundStyle(Ink.ink3) }
                        Button("取消场景起点") { sceneStart = nil; opening = "" }
                    }
                } header: { Text("时间点") } footer: {
                    Text(chapter == nil ? "不限定时，人物知道全书发生的事。" :
                            "开聊前先写一段到这一章为止的前情提要，放在对话最上面给你看；人物只知道这之前的事，不会说漏后面的剧情。")
                }
                Section {
                    Picker("剧情", selection: $direction) {
                        ForEach(StoryDirection.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("story-follow-book")
                    if followsBook && playsBookCharacter {
                        Picker("原著里没有你的段落", selection: $canonMode) {
                            ForEach(CanonMode.allCases) { Text($0.title).tag($0) }
                        }
                    }
                } header: { Text("剧情走向") } footer: {
                    Text(plotFooter)
                }
                Section {
                    TextField("例如：贾宝玉，或「一个刚进府的小丫鬟」", text: $userRole, axis: .vertical).lineLimit(1...3)
                    Menu("从书中人物里选") {
                        ForEach(profile.characters.filter { $0.name != character }) { person in
                            Button(person.name) { userRole = person.name; personaID = nil }
                        }
                    }
                    Menu("我的人物卡") {
                        ForEach(books.personas) { card in
                            Button(card.name) { userRole = card.name; personaID = card.id }
                        }
                        Divider()
                        Button("管理人物卡…", systemImage: "person.crop.square") { managingPersonas = true }
                    }
                } header: { Text("你扮演谁") } footer: {
                    if let card = chosenPersona { Text(card.detail).lineLimit(4) } else { Text("留空就是你自己。") }
                }
                Section {
                    TextField("例如：元宵节夜里，在大观园", text: $opening, axis: .vertical).lineLimit(2...6)
                } header: { Text("开场（可选）") } footer: { Text("写时间、地点或发生了什么。留空就由人物自己开场。") }
                Section {
                    ForEach(guests, id: \.self) { guest in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(guest.character)
                            Text("来自《\(guest.bookTitle)》").font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                        }
                    }
                    .onDelete { guests.remove(atOffsets: $0) }
                    Menu("加一位客串人物") {
                        ForEach(otherBooks) { other in
                            Menu("《\(other.title)》") {
                                ForEach(other.profile?.characters ?? []) { person in
                                    Button(person.name) { addGuest(person.name, from: other) }
                                }
                            }
                        }
                    }
                    .disabled(otherBooks.isEmpty || guests.count >= 3)
                } header: { Text("客串人物（可选）") } footer: {
                    Text(otherBooks.isEmpty ? "书架上再读完一本书，就能把那本书里的人物带进来。" : "从别的书里请人物过来，由模型一起扮演，最多 3 位。左滑可移除。")
                }
                Section {
                    TextField("例如：用小说的笔法写，多写环境和心理描写；每次回复末尾加一行状态：时间 / 地点 / 好感度", text: $instruction, axis: .vertical)
                        .lineLimit(3...10)
                } header: { Text("本局玩法（可选）") } footer: { Text("写给模型的规矩，这一局一直有效，优先于其他设定。聊天时可以在标题旁的「⋯ → 本局设定」里修改。") }
            }
            .font(TypeScale.body)
            .tint(Ink.seal)
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .disabled(starting)
            .overlay {
                if starting {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(locatingScene ? "正在定位名场面发生前的段落…" : (chapter == nil && !followsBook ? "正在开局…" : "正在写前情提要…")).font(TypeScale.label).foregroundStyle(Ink.ink2)
                    }
                    .padding(24)
                    .background(Ink.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .navigationTitle("《\(book.title)》")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() }.disabled(starting) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("开聊") { start() }
                        .disabled(character.isEmpty || store.isGenerating || starting)
                }
            }
            .sheet(isPresented: $managingPersonas) {
                PersonaListView().environmentObject(books)
            }
            .sheet(isPresented: $choosingScene) {
                ScenePickerSheet(book: book) { chooseScene($0) }
            }
            .onChange(of: chapter) { _, value in
                if let start = sceneStart, value != start.chapter { sceneStart = nil }
            }
            .bookAlerts(store, books)
        }
        .tint(Ink.ink)
        .onAppear {
            guard !prepared else { return }
            prepared = true
            character = profile.characters.first?.name ?? ""
            chapter = initialChapter
            opening = initialOpening
            if let initialScene { chooseScene(initialScene) }
        }
    }

    private func chooseScene(_ scene: BookScene) {
        let point = BookScenes.start(scene, chapters: books.chapters(of: book.id))
        sceneStart = point
        chapter = point.chapter
        opening = "从「\(point.title)」发生前开始，这个事件还没有发生。先写触发前的局面，把选择和行动留给我。" + (point.before.isEmpty ? "" : "\n触发前的处境：" + point.before)
    }

    private func addGuest(_ name: String, from other: Book) {
        let guest = StoryGuest(bookID: other.id, bookTitle: other.title, character: name)
        if !guests.contains(guest) && guests.count < 3 { guests.append(guest) }
    }

    private func start() {
        starting = true
        Task {
            var point = sceneStart
            if let initial = point, !initial.located {
                locatingScene = true
                point = await books.locateSceneStart(initial, in: book.id)
                locatingScene = false
                guard point != nil else { starting = false; return }
            }
            let setup = AppStore.StorySetup(bookID: book.id, character: character, userRole: userRole,
                                            userCard: chosenPersona?.detail, opening: opening, chapter: chapter,
                                            instruction: instruction, guests: guests,
                                            canon: followsBook ? (playsBookCharacter ? canonMode : .involve) : nil,
                                            direction: direction, sceneStart: point)
            let ok = await store.startStory(setup)
            starting = false
            if ok { dismiss(); opened() }
        }
    }
}

// MARK: Your own characters

@MainActor
struct PersonaListView: View {
    @EnvironmentObject private var books: BookStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if books.personas.isEmpty {
                    Text("把你常用的原创人物存在这里：名字、外貌、身份、性格、说话方式。开局时在「你扮演谁 → 我的人物卡」里一点就带上，任何一本书都能用。")
                        .font(TypeScale.serif(15)).foregroundStyle(Ink.ink3).listRowBackground(Color.clear)
                }
                ForEach(books.personas) { card in
                    NavigationLink {
                        PersonaEditView(card: card)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(card.name).font(TypeScale.serif(17)).foregroundStyle(Ink.ink)
                            Text(card.detail).font(TypeScale.tiny).foregroundStyle(Ink.ink3).lineLimit(2)
                        }.padding(.vertical, 4)
                    }
                    .listRowBackground(Color.clear)
                }
                .onDelete { books.deletePersonas(at: $0) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("我的人物卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { PersonaEditView(card: PersonaCard(name: "", detail: "")) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("新建人物卡")
                }
            }
        }
        .tint(Ink.ink)
    }
}

@MainActor
struct PersonaEditView: View {
    @EnvironmentObject private var books: BookStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PersonaCard

    init(card: PersonaCard) { _draft = State(initialValue: card) }

    var body: some View {
        Form {
            Section("名字") { TextField("名字", text: $draft.name) }
            Section {
                TextField("外貌、身份、性格、说话方式，和这个世界有什么关系…", text: $draft.detail, axis: .vertical).lineLimit(5...16)
            } header: { Text("人物卡") } footer: { Text("开局时会作为「你扮演的人物」一起发给模型。") }
        }
        .font(TypeScale.body)
        .tint(Ink.seal)
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle(draft.name.isEmpty ? "新人物卡" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { books.savePersona(draft); dismiss() }
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: Reading the text

private struct StartPoint: Identifiable {
    let id = UUID()
    let chapter: Int
    let opening: String
}

@MainActor
struct ChapterListView: View {
    @EnvironmentObject private var books: BookStore
    let bookID: UUID
    let opened: () -> Void

    var body: some View {
        let book = books.book(bookID)
        let titles = book?.chapterTitles ?? []
        List {
            if let mark = book?.bookmark, titles.indices.contains(mark.chapter) {
                NavigationLink {
                    ChapterReaderView(bookID: bookID, chapter: mark.chapter, paragraph: mark.paragraph, opened: opened)
                } label: {
                    Label("继续阅读 · \(titles[mark.chapter])", systemImage: "bookmark.fill").foregroundStyle(Ink.ink)
                }
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("book-continue-reading")
            }
            ForEach(titles.indices, id: \.self) { index in
                NavigationLink {
                    ChapterReaderView(bookID: bookID, chapter: index, opened: opened)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)").font(TypeScale.tiny).monospacedDigit().foregroundStyle(Ink.ink3).frame(minWidth: 28, alignment: .trailing)
                        Text(titles[index]).font(TypeScale.serif(16)).foregroundStyle(Ink.ink).lineLimit(1)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle("目录")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// One chapter of the original. Long-press a paragraph to start a story there or
// leave a bookmark; opening a chapter also moves the bookmark to it.
@MainActor
struct ChapterReaderView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var books: BookStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    let chapter: Int
    let paragraph: Int?
    let opened: () -> Void
    @State private var visible = false
    @State private var launched = false
    init(bookID: UUID, chapter: Int, paragraph: Int? = nil, opened: @escaping () -> Void) {
        self.bookID = bookID; self.chapter = chapter; self.paragraph = paragraph; self.opened = opened
    }
    var body: some View {
        AppBackground()
            .onAppear { if !launched { launched = true; visible = true } }
            .fullScreenCover(isPresented: $visible, onDismiss: { dismiss() }) {
                LocalNovelReader(bookID: bookID, initialChapter: chapter, initialParagraph: paragraph,
                                 close: { visible = false }, opened: opened)
                    .environmentObject(store).environmentObject(books)
            }
    }
}

// 「这里不像」: what the character would really say or do, kept on their card.
@MainActor
struct StoryCorrectionSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let threadID: UUID
    let answer: String
    @State private var character = ""
    @State private var note = ""
    private var session: StorySession? { store.threads.first(where: { $0.id == threadID })?.story }
    private var names: [String] { session.map { [$0.character] + ($0.guests ?? []).map(\.character) } ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                if names.count > 1 {
                    Picker("哪个人物", selection: $character) { ForEach(names, id: \.self) { Text($0).tag($0) } }
                }
                Section {
                    Text(String(answer.prefix(160)) + (answer.count > 160 ? "…" : "")).font(TypeScale.label).foregroundStyle(Ink.ink3)
                } header: { Text("这条回答") }
                Section {
                    TextField("例如：她不会这么直白地说喜欢，只会拐着弯刺一句", text: $note, axis: .vertical).lineLimit(3...8)
                } header: { Text("哪里不像，他会怎样") } footer: {
                    Text("会记进这个人物的人物卡，之后每一局都会带上；在书页的人物卡里可以查看和删除。想让这一条也改过来，可以接着点重新生成。")
                }
            }
            .font(TypeScale.body)
            .tint(Ink.seal)
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("这里不像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("记下") {
                        if store.correctStory(threadID: threadID, character: character, note: note, answer: answer) { dismiss() }
                    }
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || character.isEmpty)
                }
            }
        }
        .tint(Ink.ink)
        .onAppear { if character.isEmpty { character = names.first ?? "" } }
    }
}

// MARK: This game's settings, while playing

@MainActor
struct StorySettingsSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let threadID: UUID
    @State private var instruction = ""
    @State private var briefing = ""
    @State private var loaded = false
    private var session: StorySession? { store.threads.first(where: { $0.id == threadID })?.story }

    private func canonProgress(_ session: StorySession, _ book: Book) -> String {
        guard let index = session.canonSegment else { return "—" }
        guard book.segments.indices.contains(index) else { return "原著已走完" }
        let segment = book.segments[index]
        return "第 \(segment.first + 1)–\(segment.last + 1) 章（\(index + 1)/\(book.segments.count) 段）"
    }

    var body: some View {
        NavigationStack {
            Form {
                if let session {
                    Section {
                        LabeledContent("书", value: "《\(session.bookTitle)》")
                        LabeledContent("人物", value: ([session.character] + (session.guests ?? []).map(\.character)).joined(separator: "、"))
                        LabeledContent("你扮演", value: session.userRole.isEmpty ? "你自己" : session.userRole)
                        LabeledContent("时间点", value: session.chapterTitle ?? "不限定")
                    }
                    if session.canon != nil, let book = store.books.book(session.bookID) {
                        Section {
                            LabeledContent("原著进度", value: canonProgress(session, book))
                            Button("推进到下一段原著", systemImage: "forward") { store.moveCanon(threadID: threadID, by: 1) }
                                .disabled((session.canonSegment ?? 0) >= book.segments.count || store.isGenerating)
                            Button("回到上一段", systemImage: "backward") { store.moveCanon(threadID: threadID, by: -1) }
                                .disabled((session.canonSegment ?? 0) <= 0 || store.isGenerating)
                        } header: { Text("跟着原著走") } footer: {
                            Text("一段演完会自动往下走。觉得卡住了可以手动推进；跳过的那段会在下一条回答开头用旁白交代。")
                        }
                    }
                    Section {
                        TextField("例如：用小说的笔法写；每次回复末尾加一行状态栏", text: $instruction, axis: .vertical).lineLimit(3...12)
                    } header: { Text("本局玩法") } footer: { Text("保存后从下一条回答开始生效。") }
                    if session.briefing != nil {
                        Section {
                            TextField("前情提要", text: $briefing, axis: .vertical).lineLimit(4...20)
                        } header: { Text("前情提要") } footer: { Text("模型按这段理解人物此刻的处境，可以手动修正。对话顶部显示的是开局时的版本。") }
                    }
                }
            }
            .font(TypeScale.body)
            .tint(Ink.seal)
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("本局设定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        store.updateStory(threadID: threadID, instruction: instruction, briefing: session?.briefing == nil ? nil : briefing)
                        dismiss()
                    }
                }
            }
        }
        .tint(Ink.ink)
        .onAppear {
            guard !loaded, let session else { return }
            loaded = true
            instruction = session.instruction ?? ""
            briefing = session.briefing ?? ""
        }
    }
}

// A literary inner-voice supplement generated from the selected conversation.
// It is cached on the answer and is never fed back into the conversation.
@MainActor
struct InnerThoughtsSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let threadID: UUID
    let messageID: UUID
    @State private var requestedInitial = false
    private var thread: ChatThread? {
        guard let value = store.threads.first(where: { $0.id == threadID }), !store.isHidden(value) else { return nil }
        return value
    }
    private var message: ChatMessage? { thread?.messages.first(where: { $0.id == messageID }) }
    private var character: String { thread?.story?.character ?? "对话中的回答者" }
    private var writing: Bool { store.thoughtsThreadID == threadID && store.thoughtsMessageID == messageID }
    private var available: Bool {
        guard let message else { return false }
        return message.role == .assistant && message.state == .complete && message.directive == nil
            && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var savedThoughts: String? {
        guard let text = message?.innerThoughts, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
    private var contextDescription: String {
        if let name = thread?.story?.character { return "为\(name)补写这条回答时的心声。" }
        if let project = store.project(thread?.projectID) { return "沿用「\(project.name)」的项目设定与语气。" }
        return "沿用当前对话的设定与语气。"
    }
    private var title: String {
        guard available else { return "心声补写" }
        if let name = thread?.story?.character { return "\(name)在想什么" }
        return "他在想什么"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if available {
                        Text(contextDescription).font(TypeScale.label).foregroundStyle(Ink.ink2)
                        if let said = message?.content {
                            Text(String(said.prefix(120)) + (said.count > 120 ? "…" : ""))
                                .font(TypeScale.label).foregroundStyle(Ink.ink3)
                        }
                        if writing {
                            if store.thoughtsDraft.isEmpty {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("正在补写这条回复的心声…").font(TypeScale.label).foregroundStyle(Ink.ink3)
                                }
                            } else {
                                Text(store.thoughtsDraft).font(TypeScale.answer).foregroundStyle(Ink.ink).lineSpacing(7)
                            }
                        } else if let thoughts = savedThoughts {
                            Text(thoughts).font(TypeScale.answer).foregroundStyle(Ink.ink).lineSpacing(7).textSelection(.enabled)
                        } else {
                            Text("还没有生成这条回答的心声。").font(TypeScale.label).foregroundStyle(Ink.ink3)
                        }
                        Text("根据对话生成的心声补写，不是原始思考过程，不会发回聊天。首次生成和重写计入用量。")
                            .font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                    } else {
                        ContentUnavailableView("这条回答暂不可查看", systemImage: "lock",
                                               description: Text("原对话已删除、项目已上锁，或消息状态已改变。请返回原对话后再打开。"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .background(AppBackground())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(writing && available ? "停止" : "完成") {
                        if writing && available { store.cancelThoughts() }
                        else {
                            if writing { store.cancelThoughts() }
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(savedThoughts == nil ? "生成" : "重写", action: generate)
                        .disabled(!available || !store.canPersist || writing || store.thoughtsMessageID != nil)
                }
            }
            .bookAlerts(store, store.books)
        }
        .tint(Ink.ink)
        .onAppear {
            if !requestedInitial, available, savedThoughts == nil, store.canPersist, store.thoughtsMessageID == nil {
                requestedInitial = true
                generate()
            }
        }
        .onChange(of: available) { _, value in
            if !value && writing { store.cancelThoughts() }
        }
    }

    private func generate() {
        guard available, store.canPersist, store.thoughtsMessageID == nil else { return }
        store.revealThoughts(threadID: threadID, messageID: messageID, character: character)
    }
}

// MARK: - 夜江 bookshelf

/// Spines standing on a water line, each mirrored faintly in the river below, and
/// the moon over them. Tap a spine to lift it; the panel underneath shows that book.
@MainActor
struct NightShelf: View {
    let books: [Book]
    let readingID: UUID?
    @Binding var picked: UUID?
    let open: (UUID) -> Void

    private var selected: Book? { books.first { $0.id == picked } ?? books.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text("\(books.count) 册 · 点一本书脊").font(TypeScale.serif(13)).foregroundStyle(Ink.ink3)
                Spacer()
                MoonDisc(size: 30)
            }
            .padding(.horizontal, 24).padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    spineRow(reflection: false).frame(height: 252, alignment: .bottom)
                    Rectangle().fill(Ink.ink.opacity(0.35)).frame(height: 1)
                    spineRow(reflection: true)
                        .scaleEffect(x: 1, y: -1)
                        .frame(height: 96, alignment: .top)
                        .clipped()
                        .opacity(0.3).blur(radius: 1.2)
                        .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 24)
                .frame(minWidth: 0)
            }
            .overlay(alignment: .bottomTrailing) {
                // The moon's broken reflection on the water.
                VStack(spacing: 6) {
                    Capsule().fill(Ink.seal).frame(width: 30, height: 1.5)
                    Capsule().fill(Ink.seal).frame(width: 20, height: 1.5)
                    Capsule().fill(Ink.seal).frame(width: 10, height: 1.5)
                }
                .opacity(0.55).padding(.trailing, 30).padding(.bottom, 64)
                .allowsHitTesting(false).accessibilityHidden(true)
            }

            if let book = selected { panel(book).padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 24) }
        }
        .padding(.vertical, 8)
    }

    private func spineRow(reflection: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(books) { book in
                let lifted = !reflection && book.id == selected?.id
                Button { withAnimation(.snappy(duration: 0.25)) { picked = book.id } } label: {
                    Spine(book: book)
                }
                .contextMenu { BookCoverActions(book: book) }
                .buttonStyle(.plain)
                .offset(y: lifted ? -12 : 0)
                .disabled(reflection)
                .accessibilityLabel(book.title)
                .accessibilityAddTraits(lifted ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private func panel(_ book: Book) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 22) {
                ShelfCover(book: book).frame(width: 104, height: 156)
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text(book.title).font(TypeScale.heavy(24, relativeTo: .title)).foregroundStyle(Ink.ink).lineLimit(3)
                    BookCoverMenu(book: book)
                }
            }.padding(.bottom, 18)
            Text(BookStatusText.short(book, reading: readingID == book.id))
                .font(TypeScale.serif(12)).tracking(1.5).foregroundStyle(Ink.ink3).lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Ink.line)
                    Rectangle().fill(Ink.seal).frame(width: proxy.size.width * Self.progress(book))
                }
            }
            .frame(height: 2).padding(.top, 14)
            if let mark = book.bookmark {
                Text("读到 · " + book.chapterLabel(mark.chapter)).font(TypeScale.serif(12)).foregroundStyle(Ink.ink3)
                    .lineLimit(1).padding(.top, 6)
            }
            Button { open(book.id) } label: {
                Text("进入书籍").font(TypeScale.serif(16).weight(.semibold)).foregroundStyle(Ink.onSeal)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(Ink.seal, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain).padding(.top, 20)
            .accessibilityIdentifier("night-shelf-open")
        }
    }

    /// Reading position when there is one, otherwise how much of the book Sermo has read.
    static func progress(_ book: Book) -> Double {
        if let mark = book.bookmark, !book.chapterTitles.isEmpty {
            return min(1, Double(mark.chapter + 1) / Double(book.chapterTitles.count))
        }
        guard !book.segments.isEmpty else { return 0 }
        return min(1, Double(book.readCount) / Double(book.segments.count))
    }
}

/// One spine: a dark cloth colour chosen from the title, a pale title slip set vertically.
private struct Spine: View {
    let book: Book
    private static let cloths: [UInt32] = [0x22323C, 0x1C2C2A, 0x252B3A, 0x2E3236, 0x2A2633, 0x1F2E35]
    private var cloth: Color {
        let seed = book.title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let hex = Self.cloths[seed % Self.cloths.count]
        return Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
    // Longer books stand taller: 180 pt for a novella up to 240 pt for a long novel.
    private var height: CGFloat {
        let wan = Double(book.characterCount) / 10000
        return CGFloat(180 + min(60, max(0, log2(max(1, wan)) * 9)))
    }
    private var width: CGFloat { book.characterCount > 400_000 ? 58 : (book.characterCount > 150_000 ? 52 : 46) }
    private var letters: [String] { Array(book.title.prefix(7)).map(String.init) }

    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2, style: .continuous)
                .fill(cloth)
                .overlay { Image(uiImage: BookCoverArt.image(book)).resizable().scaledToFill().frame(width: width, height: height).clipped().opacity(0.8) }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2))
                .overlay(alignment: .trailing) { Rectangle().fill(Color.black.opacity(0.18)).frame(width: 3) }
            VStack(spacing: 2) {
                ForEach(Array(letters.enumerated()), id: \.offset) { _, letter in
                    Text(letter).font(TypeScale.serif(15).weight(.semibold))
                }
            }
            .foregroundStyle(Color(red: 0.02, green: 0.07, blue: 0.09))
            .padding(.vertical, 10).frame(width: 28)
            .background(Color(red: 0.86, green: 0.92, blue: 0.94))
            .padding(.top, 16)
        }
        .frame(width: width, height: height)
    }
}


// Shared by shelf rows, the selected book, detail, and its full-screen backdrop.
@MainActor
struct ShelfCover: View {
    let book: Book
    var body: some View {
        Image(uiImage: BookCoverArt.image(book)).resizable().scaledToFill()
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay(alignment: .leading) {
                LinearGradient(colors: [.black.opacity(0.35), .white.opacity(0.09), .clear], startPoint: .leading, endPoint: .trailing).frame(width: 9)
            }
            .accessibilityLabel(book.title + "封面")
    }
}

@MainActor
private struct ShelfAtmosphere: View {
    let book: Book?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Ink.paper
                if let book {
                    Image(uiImage: BookCoverArt.image(book)).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                        .scaleEffect(1.2).blur(radius: 64)
                        .id(book.id.uuidString + (book.coverRevision?.uuidString ?? ""))
                        .transition(.opacity)
                    Ink.paper.opacity(InterfaceStyle.isNight ? 0.66 : (scheme == .dark ? 0.76 : 0.88))
                }
            }.frame(width: geo.size.width, height: geo.size.height).clipped()
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: book?.id)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: book?.coverRevision)
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

@MainActor
private struct BookCoverMenu: View {
    @EnvironmentObject private var books: BookStore
    let book: Book
    var body: some View {
        Menu { BookCoverActions(book: book) } label: {
            Label(books.designingCovers.contains(book.id) ? "设计中…" : "换封面", systemImage: "paintbrush.pointed")
                .font(TypeScale.label).foregroundStyle(Ink.seal)
        }.accessibilityLabel("更换《\(book.title)》的封面")
    }
}

@MainActor
private struct BookCoverActions: View {
    @EnvironmentObject private var books: BookStore
    let book: Book
    var body: some View {
        Button("GPT 重新设计花纹", systemImage: "sparkles") { books.requestCover(book.id) }
            .disabled(books.designingCovers.contains(book.id))
        Button("换一张本地花纹", systemImage: "shuffle") { books.localCover(book.id) }
        Button("从相册选择封面", systemImage: "photo") {
            ChatPhotoPicker.present(limit: 1, onError: { books.errorMessage = $0 }) { results in
                guard let result = results.first else { return }
                Task {
                    do { try await install(ChatPhotoPicker.loadData(result.itemProvider)) }
                    catch { books.errorMessage = error.localizedDescription }
                }
            }
        }
        Button("从文件选择封面", systemImage: "folder") {
            DocumentPicker.present([.image], asCopy: true) { url in
                Task {
                    do {
                        let data = try await Task.detached(priority: .userInitiated) {
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 40 * 1024 * 1024 else { throw ChatError.server("封面图片不能超过 40 MB。") }
                            return try Data(contentsOf: url)
                        }.value
                        try await install(data)
                    } catch { books.errorMessage = error.localizedDescription }
                }
            }
        }
    }
    private func install(_ data: Data) async throws {
        let jpeg = try await Task.detached(priority: .userInitiated) { try BookCoverArt.importJPEG(data) }.value
        books.setCoverJPEG(jpeg, for: book.id)
    }
}

// Render once per revision, not once per animation frame. No remote URLs or script execution.
private enum BookCoverArt {
    @MainActor private static let cache: NSCache<NSString, UIImage> = {
        let value = NSCache<NSString, UIImage>(); value.totalCostLimit = 32 * 1024 * 1024; return value
    }()
    @MainActor static func image(_ book: Book) -> UIImage {
        let key = (book.id.uuidString + (book.coverRevision?.uuidString ?? "") + book.title) as NSString
        if let image = cache.object(forKey: key) { return image }
        let image = book.coverJPEG.flatMap(UIImage.init(data:)) ?? render(title: book.title, design: book.coverDesign ?? .local(title: book.title))
        cache.setObject(image, forKey: key, cost: 600 * 900 * 4)
        return image
    }

    static func importJPEG(_ data: Data) throws -> Data {
        guard data.count <= 40 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1400] as CFDictionary) else {
            throw ChatError.server("无法读取这张封面，请换一张 JPEG、PNG 或 HEIC 图片。")
        }
        let image = UIImage(cgImage: cg)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let result = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 900), format: format).image { _ in
            UIColor.black.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 600, height: 900))
            let scale = max(600 / image.size.width, 900 / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (600 - size.width) / 2, y: (900 - size.height) / 2, width: size.width, height: size.height))
        }
        for quality in [0.85, 0.65, 0.45, 0.25] {
            if let jpeg = result.jpegData(compressionQuality: quality), jpeg.count <= 500_000 { return jpeg }
        }
        throw ChatError.server("封面压缩未完成，请换一张图片。")
    }

    @MainActor private static func render(title: String, design: BookCoverDesign) -> UIImage {
        let spec = design.validated()
        func color(_ hex: String, dark: Bool) -> UIColor {
            let n = UInt32(hex, radix: 16) ?? 0
            var r = CGFloat((n >> 16) & 255) / 255, g = CGFloat((n >> 8) & 255) / 255, b = CGFloat(n & 255) / 255
            if dark { let scale = min(1, 0.32 / max(0.01, max(r, max(g, b)))); r *= scale; g *= scale; b *= scale }
            else { r = 0.45 + r * 0.55; g = 0.45 + g * 0.55; b = 0.45 + b * 0.55 }
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        }
        let base = color(spec.background, dark: true), foil = color(spec.accent, dark: false)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 900), format: format).image { renderer in
            let c = renderer.cgContext
            base.setFill(); c.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
            // Fine woven cloth; stable across launches and independent of device scale.
            for x in stride(from: 0, through: 600, by: 3) {
                c.setStrokeColor(UIColor.white.withAlphaComponent(x % 9 == 0 ? 0.035 : 0.015).cgColor)
                c.setLineWidth(0.5); c.move(to: CGPoint(x: x, y: 0)); c.addLine(to: CGPoint(x: x, y: 900)); c.strokePath()
            }
            for y in stride(from: 0, through: 900, by: 4) {
                c.setStrokeColor(UIColor.black.withAlphaComponent(0.07).cgColor)
                c.move(to: CGPoint(x: 0, y: y)); c.addLine(to: CGPoint(x: 600, y: y)); c.strokePath()
            }
            let step = 600.0 / CGFloat(spec.density)
            c.setStrokeColor(foil.withAlphaComponent(0.32).cgColor); c.setLineWidth(1.3)
            for row in -1...Int(900 / step) + 1 {
                for col in -1...spec.density + 1 {
                    let x = CGFloat(col) * step + (row % 2 == 0 ? 0 : step / 2)
                    let y = CGFloat(row) * step + CGFloat(spec.seed % 23)
                    c.saveGState(); c.translateBy(x: x, y: y)
                    let r = step * 0.38
                    switch spec.motif {
                    case .waves:
                        for inset in [CGFloat(0), 9, 18] { c.addArc(center: .zero, radius: r + inset, startAngle: .pi, endAngle: 2 * .pi, clockwise: false); c.strokePath() }
                    case .diamonds:
                        c.move(to: CGPoint(x: 0, y: -r)); c.addLines(between: [CGPoint(x: r * 0.65, y: 0), CGPoint(x: 0, y: r), CGPoint(x: -r * 0.65, y: 0)]); c.closePath(); c.strokePath()
                        c.strokeEllipse(in: CGRect(x: -3, y: -3, width: 6, height: 6))
                    case .stars:
                        for arm in 0..<8 { let a = CGFloat(arm) * .pi / 4; let length = arm % 2 == 0 ? r : r * 0.38
                            c.move(to: CGPoint(x: cos(a) * 5, y: sin(a) * 5)); c.addLine(to: CGPoint(x: cos(a) * length, y: sin(a) * length)); c.strokePath() }
                        c.strokeEllipse(in: CGRect(x: -3, y: -3, width: 6, height: 6))
                    case .orbits:
                        c.rotate(by: .pi / 4); c.strokeEllipse(in: CGRect(x: -r, y: -r * 0.45, width: r * 2, height: r * 0.9))
                        c.rotate(by: .pi / 2); c.strokeEllipse(in: CGRect(x: -r, y: -r * 0.45, width: r * 2, height: r * 0.9))
                    case .vines:
                        c.move(to: CGPoint(x: 0, y: -step / 2)); c.addCurve(to: CGPoint(x: 0, y: step / 2), control1: CGPoint(x: r, y: -r), control2: CGPoint(x: -r, y: r)); c.strokePath()
                        for sign in [CGFloat(-1), 1] {
                            c.move(to: .zero); c.addQuadCurve(to: CGPoint(x: sign * r * 0.8, y: -r * 0.65), control: CGPoint(x: sign * r, y: 5))
                            c.addQuadCurve(to: .zero, control: CGPoint(x: 0, y: -r)); c.strokePath()
                        }
                    }
                    c.restoreGState()
                }
            }
            foil.withAlphaComponent(0.7).setStroke()
            for inset in [CGFloat(28), 35] { c.setLineWidth(inset == 28 ? 1.4 : 0.6); c.stroke(CGRect(x: inset, y: inset, width: 600 - inset * 2, height: 900 - inset * 2)) }
            // A quiet cloth title panel with local typesetting: no AI-rendered Chinese glyphs.
            base.withAlphaComponent(0.96).setFill(); c.fill(CGRect(x: 93, y: 310, width: 414, height: 270))
            c.setStrokeColor(foil.withAlphaComponent(0.65).cgColor)
            c.move(to: CGPoint(x: 128, y: 326)); c.addLine(to: CGPoint(x: 472, y: 326)); c.strokePath()
            c.move(to: CGPoint(x: 128, y: 564)); c.addLine(to: CGPoint(x: 472, y: 564)); c.strokePath()
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byCharWrapping; paragraph.lineSpacing = 8
            let clean = String(title.prefix(60)) as NSString
            let size: CGFloat = title.count > 22 ? 28 : (title.count > 12 ? 35 : 46)
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont(name: "SongtiSC-Regular", size: size) ?? UIFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: foil, .paragraphStyle: paragraph, .kern: 3]
            let bounds = clean.boundingRect(with: CGSize(width: 340, height: 220), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
            clean.draw(in: CGRect(x: 130, y: 445 - min(220, bounds.height) / 2, width: 340, height: 220), withAttributes: attrs)
        }
    }
}
