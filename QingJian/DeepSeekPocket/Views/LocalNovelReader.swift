import SwiftUI
import UIKit

@MainActor
struct LocalNovelReader: View {
    @EnvironmentObject private var books: BookStore
    @EnvironmentObject private var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    let bookID: UUID
    let initialChapter: Int
    let initialParagraph: Int?
    let close: () -> Void
    let opened: () -> Void
    @AppStorage("sermo.reader.font") private var fontChoice = "follow"
    @AppStorage("sermo.reader.size") private var fontSize = 21.0
    @AppStorage("sermo.reader.line") private var lineGap = 8.0
    @AppStorage("sermo.reader.paragraph") private var paragraphGap = 8.0
    @AppStorage("sermo.reader.margin") private var margin = 28.0
    @AppStorage("sermo.reader.palette") private var palette = "follow"
    @AppStorage("sermo.reader.mode") private var mode = "scroll"
    @AppStorage("sermo.reader.spread") private var spread = true
    @AppStorage("sermo.reader.indent") private var indent = true
    @AppStorage("sermo.reader.orientation") private var orientation = "device"
    @StateObject private var volumeKeys = ReaderVolumeKeys()
    @AppStorage("sermo.reader.volumeKeys") private var volumeEnabled = false
    @AppStorage("sermo.reader.volumeReverse") private var volumeReverse = false
    @State private var chapter = 0
    @State private var currentOffset = 0
    @State private var jump = ReaderJump(offset: 0)
    @State private var chrome = false
    @State private var sheet: ReaderPanel?
    @State private var prepared = false
    @State private var saveTask: Task<Void, Never>?
    @State private var originalBrightness: CGFloat?
    @State private var slider = 0.0
    @State private var sliding = false
    @State private var page = 1
    @State private var pageCount = 1
    @State private var markToast = false
    @State private var passage: ReaderPassage?
    @State private var passageIssue: String?
    @State private var playScene: BookScene?
    @State private var returnPoint: ReaderReturnPoint?
    @State private var searchQuery = ""
    private var book: Book? { books.book(bookID) }
    private var chapters: [BookChapter] { books.chapters(of: bookID) }
    private var document: NovelDocument {
        NovelDocument(chapter: chapter, text: chapters.indices.contains(chapter) ? chapters[chapter].text : "")
    }
    private var totalCharacters: Double { Double(max(1, chapters.reduce(0) { $0 + ($1.text as NSString).length })) }
    private var progress: Double {
        let before = chapters.prefix(chapter).reduce(0) { $0 + ($1.text as NSString).length }
        let local = Double(currentOffset) / Double(max(1, document.length))
        let length = chapters.indices.contains(chapter) ? (chapters[chapter].text as NSString).length : 0
        return min(1, (Double(before) + local * Double(length)) / totalCharacters)
    }
    private var appearance: ReaderAppearance {
        ReaderAppearance.resolve(palette, dark: colorScheme == .dark, swiss: InterfaceStyle.isSwiss, night: InterfaceStyle.isNight)
    }
    private var readerFont: String {
        switch fontChoice {
        case "song": return "NotoSerifSC-Regular"
        case "sans": return "PingFangSC-Regular"
        case "custom": return FontLibrary.regularName ?? "NotoSerifSC-Regular"
        default: return FontLibrary.regularFace
        }
    }
    private var style: ReaderPageStyle {
        ReaderPageStyle(fontName: readerFont, size: fontSize, lineGap: lineGap, paragraphGap: paragraphGap, margin: margin,
                        paged: mode == "pages", spreads: spread, background: appearance.paperHex, foreground: appearance.inkHex, firstLineIndent: indent, accent: appearance.accentHex)
    }
    private var ink: Color { appearance.ink }
    var body: some View {
        ZStack {
            appearance.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(book?.title ?? "阅读").lineLimit(1)
                    Spacer(minLength: 12)
                    Text(String(format: "%02d", chapter + 1)).monospacedDigit()
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(appearance.secondary)
                .padding(.horizontal, max(22, margin)).padding(.top, 8).frame(height: 30)
                ReaderCanvas(document: document, style: style, jump: jump, chapterTitle: book?.chapterLabel(chapter) ?? "",
                    tapped: { withAnimation(.easeOut(duration: 0.18)) { chrome.toggle() } },
                    moved: { offset, p, count in
                        currentOffset = offset; page = p; pageCount = count
                        if !sliding { slider = progress }
                        scheduleSave()
                    },
                    chapterStep: { step in navigate(chapter + step, offset: step < 0 ? Int.max : 0) },
                    paragraphAction: { index in
                        guard document.paragraphs.indices.contains(index) else { return }
                        chrome = false; passageIssue = nil
                        withAnimation(.easeOut(duration: 0.2)) { passage = ReaderPassage(paragraph: index, text: document.paragraphs[index]) }
                    }, pageCommand: volumeKeys.command)
                HStack {
                    if mode == "pages" { Text("本章 \(page) / \(pageCount)") }
                    else { Text(book?.chapterLabel(chapter) ?? "").lineLimit(1) }
                    Spacer()
                    Text(String(format: "%.1f%%", progress * 100)).monospacedDigit()
                }
                .font(.system(size: 10)).foregroundStyle(appearance.secondary)
                .padding(.horizontal, max(22, margin)).frame(height: 29)
            }
            .accessibilityHidden(passage != nil)
            if returnPoint != nil && !chrome && passage == nil {
                VStack {
                    Spacer()
                    returnControl.padding(.bottom, 40)
                }.padding(.horizontal, 22)
            }
            if chrome { controls.transition(.opacity).accessibilityHidden(passage != nil) }
            if let selected = passage {
                appearance.scrim.ignoresSafeArea().onTapGesture { dismissPassage() }
                VStack {
                    Spacer(minLength: 30)
                    ReaderPassageCard(passage: selected, chapter: book?.chapterLabel(chapter) ?? "",
                                      canPlay: book?.isReady == true, canDiscuss: !store.isGenerating,
                                      issue: passageIssue, dismiss: dismissPassage,
                                      bookmark: { addMark(selected.paragraph); dismissPassage() },
                                      copy: { UIPasteboard.general.string = selected.text; dismissPassage() },
                                      play: { dismissPassage(); startPlaying(selected.paragraph) },
                                      discuss: { discuss(selected) })
                        .frame(maxWidth: 540)
                }.padding(.horizontal, 14).padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if markToast {
                Text("书签已保存").font(TypeScale.label).padding(.horizontal, 20).padding(.vertical, 12)
                    .background(appearance.surface, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(ink)
                    .allowsHitTesting(false)
            }
        }
        .environment(\.readerAppearance, appearance)
        .statusBarHidden(true)
        .preferredColorScheme(palette == "follow" ? (InterfaceStyle.isNight ? .dark : nil) : (appearance.isDark ? .dark : .light))
        .onAppear {
            guard !prepared else { return }
            prepared = true; originalBrightness = UIScreen.main.brightness
            chapter = min(max(0, initialChapter), max(0, chapters.count - 1))
            let mark = book?.bookmark
            let doc = NovelDocument(chapter: chapter, text: chapters.indices.contains(chapter) ? chapters[chapter].text : "")
            let paragraph = initialParagraph ?? 0
            let offset = mark?.chapter == chapter && mark?.paragraph == paragraph ? mark?.characterOffset : nil
            currentOffset = offset ?? (doc.starts.indices.contains(paragraph) ? doc.starts[paragraph] : 0)
            jump = ReaderJump(offset: currentOffset)
            ReaderAppDelegate.setReaderOrientation(orientation)
            volumeKeys.configure(enabled: volumeEnabled, reverse: volumeReverse)
        }
        .onDisappear {
            saveTask?.cancel(); savePosition()
            volumeKeys.stop()
            ReaderAppDelegate.setReaderOrientation(nil)
            if let brightness = originalBrightness { UIScreen.main.brightness = brightness }
        }
        .onChange(of: orientation) { _, value in ReaderAppDelegate.setReaderOrientation(value) }
        .onChange(of: scenePhase) { _, value in
            if value != .active { saveTask?.cancel(); savePosition(); volumeKeys.stop() }
            else { volumeKeys.configure(enabled: volumeEnabled, reverse: volumeReverse) }
        }
        .onChange(of: volumeEnabled) { _, value in volumeKeys.configure(enabled: value, reverse: volumeReverse) }
        .onChange(of: volumeReverse) { _, value in volumeKeys.configure(enabled: volumeEnabled, reverse: value) }
        .onChange(of: sheet?.rawValue) { _, _ in volumeKeys.suspended = sheet != nil || playScene != nil || passage != nil }
        .onChange(of: playScene?.id) { _, _ in volumeKeys.suspended = sheet != nil || playScene != nil || passage != nil }
        .onChange(of: passage?.id) { _, _ in volumeKeys.suspended = sheet != nil || playScene != nil || passage != nil }
        .sheet(item: $sheet) { panel in
            Group {
                switch panel {
                case .settings: ReaderSettingsView().environmentObject(volumeKeys)
                case .contents: ReaderContentsView(bookID: bookID, selected: chapter) { c, p in navigate(c, paragraph: p, rememberingOrigin: true); sheet = nil }
                case .bookmarks: ReaderBookmarksView(bookID: bookID) { c, p in navigate(c, paragraph: p, rememberingOrigin: true); sheet = nil }
                case .search: ReaderSearchView(bookID: bookID, query: $searchQuery) { c, p in navigate(c, paragraph: p, rememberingOrigin: true); sheet = nil }
                }
            }.environment(\.readerAppearance, appearance)
        }
        .sheet(item: $playScene) { scene in
            if let book, let profile = book.profile {
                StartStoryView(book: book, profile: profile, initialScene: scene) {
                    savePosition(); ReaderAppDelegate.setReaderOrientation(nil); close(); opened()
                }.environmentObject(store).environmentObject(books)
            }
        }
    }
    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { savePosition(); close() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44)
                }.accessibilityLabel("退出阅读")
                VStack(alignment: .leading, spacing: 4) {
                    Text(book?.title ?? "阅读").font(.system(size: 15, weight: .medium)).lineLimit(1)
                    Text(book?.chapterLabel(chapter) ?? "").font(.system(size: 11)).foregroundStyle(appearance.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { addMark(document.paragraph(at: currentOffset)) } label: {
                    Image(systemName: "bookmark").font(.system(size: 18)).frame(width: 44, height: 44)
                }.accessibilityLabel("添加书签")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(appearance.paper.opacity(0.97))
            Rectangle().fill(appearance.line).frame(height: 0.5)
            Spacer()
            VStack(spacing: 14) {
                if returnPoint != nil { returnControl }
                HStack {
                    Text(book?.chapterLabel(chapter) ?? "").lineLimit(1)
                    Spacer(minLength: 12)
                    Text(String(format: "%.1f%%", sliding ? slider * 100 : progress * 100)).monospacedDigit()
                }.font(.system(size: 11)).foregroundStyle(appearance.secondary)
                HStack(spacing: 12) {
                    Button { navigate(chapter - 1) } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }.disabled(chapter <= 0).accessibilityLabel("上一章")
                    Slider(value: $slider, in: 0...1, onEditingChanged: { value in
                        sliding = value
                        if !value { seek(slider) }
                    }).accessibilityLabel("全书阅读进度")
                    Button { navigate(chapter + 1) } label: {
                        Image(systemName: "chevron.right").frame(width: 44, height: 44)
                    }.disabled(chapter + 1 >= chapters.count).accessibilityLabel("下一章")
                }.font(.system(size: 13, weight: .medium))
                Rectangle().fill(appearance.line).frame(height: 0.5)
                HStack(spacing: 0) {
                    panelButton("目录", icon: "list.bullet", panel: .contents)
                    panelButton("书签", icon: "bookmark", panel: .bookmarks)
                    panelButton("搜索", icon: "magnifyingglass", panel: .search)
                    panelButton("排版", icon: "textformat.size", panel: .settings)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
            .background(appearance.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(appearance.line, lineWidth: 0.5))
            .shadow(color: .black.opacity(appearance.isDark ? 0.18 : 0.05), radius: 18, y: 5)
            .frame(maxWidth: 540).padding(.horizontal, 12).padding(.bottom, 8)
        }.foregroundStyle(ink).tint(appearance.accent)
    }
    private var returnControl: some View {
        HStack(spacing: 0) {
            Button {
                guard let point = returnPoint else { return }
                returnPoint = nil
                navigate(point.chapter, offset: point.offset)
                chrome = false
            } label: {
                Label("回到刚才", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .medium)).padding(.leading, 15).padding(.trailing, 10).frame(minHeight: 44)
            }.accessibilityHint("返回查找或跳转前的阅读位置")
            Rectangle().fill(appearance.line).frame(width: 0.5, height: 16)
            Button { returnPoint = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).frame(width: 44, height: 44)
            }.accessibilityLabel("清除返回位置")
        }
        .buttonStyle(.plain).foregroundStyle(appearance.accent)
        .background(appearance.surface, in: Capsule())
        .overlay(Capsule().stroke(appearance.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(appearance.isDark ? 0.15 : 0.05), radius: 8, y: 3)
        .fixedSize(horizontal: true, vertical: false)
    }
    private func panelButton(_ title: String, icon: String, panel: ReaderPanel) -> some View {
        Button { sheet = panel } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 18, weight: .regular))
                Text(title).font(.system(size: 11))
            }.frame(maxWidth: .infinity).frame(minHeight: 52)
        }.buttonStyle(.plain)
    }
    private func dismissPassage() {
        withAnimation(.easeOut(duration: 0.18)) { passage = nil }
    }
    private func discuss(_ selected: ReaderPassage) {
        guard store.startBookDiscussion(bookID) else {
            passageIssue = "暂时无法开启讨论，请稍后再试。"
            return
        }
        let excerpt = String(selected.text.prefix(1500))
        store.setDraft("请结合《\(book?.title ?? "这本书")》的\(book?.chapterLabel(chapter) ?? "这一章")，解释下面这段原文：\n\n\(excerpt)")
        savePosition(); passage = nil
        ReaderAppDelegate.setReaderOrientation(nil); close(); opened()
    }
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 850_000_000) } catch { return }
            savePosition()
        }
    }
    private func savePosition() {
        guard prepared, chapters.indices.contains(chapter) else { return }
        books.setBookmark(BookBookmark(chapter: chapter, paragraph: document.paragraph(at: currentOffset), characterOffset: currentOffset), in: bookID)
    }
    private func navigate(_ value: Int, offset: Int = 0, paragraph: Int? = nil, rememberingOrigin: Bool = false) {
        guard chapters.indices.contains(value) else { return }
        let doc = NovelDocument(chapter: value, text: chapters[value].text)
        let target = paragraph.flatMap { doc.starts.indices.contains($0) ? doc.starts[$0] : nil } ?? offset
        let targetOffset = min(max(0, target), max(0, doc.length - 1))
        // Keep the first reading location while the reader follows several results.
        if rememberingOrigin, returnPoint == nil, value != chapter || targetOffset != currentOffset {
            returnPoint = ReaderReturnPoint(chapter: chapter, offset: currentOffset)
        }
        saveTask?.cancel(); savePosition()
        chapter = value; currentOffset = targetOffset
        jump = ReaderJump(offset: currentOffset); slider = progress
        savePosition()
    }
    private func seek(_ fraction: Double) {
        let target = fraction * totalCharacters
        var cursor = 0
        for (index, value) in chapters.enumerated() {
            let size = (value.text as NSString).length
            if Double(cursor + size) >= target || index == chapters.count - 1 {
                let ratio = max(0, min(1, (target - Double(cursor)) / Double(max(1, size))))
                let doc = NovelDocument(chapter: index, text: value.text)
                navigate(index, offset: Int(ratio * Double(max(0, doc.length - 1))), rememberingOrigin: true)
                return
            }
            cursor += size
        }
    }
    private func addMark(_ paragraph: Int) {
        guard document.paragraphs.indices.contains(paragraph) else { return }
        books.addReaderMark(chapter: chapter, paragraph: paragraph, excerpt: String(document.paragraphs[paragraph].prefix(150)), in: bookID)
        markToast = true
        Task { @MainActor in try? await Task.sleep(nanoseconds: 1_200_000_000); markToast = false }
    }
    private func startPlaying(_ paragraph: Int) {
        guard document.paragraphs.indices.contains(paragraph) else { return }
        var scene = BookScene(title: "原文选段", chapter: chapter, summary: "", characters: [])
        scene.paragraph = paragraph
        scene.anchor = String(document.paragraphs[paragraph].prefix(60))
        playScene = scene
    }
}

private struct ReaderReturnPoint {
    var chapter: Int
    var offset: Int
}

enum ReaderPanel: String, Identifiable { case settings, contents, bookmarks, search; var id: String { rawValue } }

@MainActor
struct ReaderSettingsView: View {
    @Environment(\.readerAppearance) private var appearance
    @EnvironmentObject private var volumeKeys: ReaderVolumeKeys
    @AppStorage("sermo.reader.volumeKeys") private var volumeEnabled = false
    @AppStorage("sermo.reader.volumeReverse") private var volumeReverse = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sermo.reader.font") private var font = "follow"
    @AppStorage("sermo.reader.size") private var size = 21.0
    @AppStorage("sermo.reader.line") private var line = 8.0
    @AppStorage("sermo.reader.paragraph") private var paragraph = 8.0
    @AppStorage("sermo.reader.margin") private var margin = 28.0
    @AppStorage("sermo.reader.palette") private var palette = "follow"
    @AppStorage("sermo.reader.mode") private var mode = "scroll"
    @AppStorage("sermo.reader.spread") private var spread = true
    @AppStorage("sermo.reader.indent") private var indent = true
    @AppStorage("sermo.reader.orientation") private var orientation = "device"
    @State private var brightness = Double(UIScreen.main.brightness)
    var body: some View {
        NavigationStack {
            Form {
                Section("阅读方式") {
                    Picker("翻页方式", selection: $mode) { Text("上下滚动").tag("scroll"); Text("左右翻页").tag("pages") }
                    Picker("屏幕方向", selection: $orientation) {
                        Text("跟随设备").tag("device"); Text("锁定竖屏").tag("portrait"); Text("锁定横屏").tag("landscape")
                    }
                    if UIDevice.current.userInterfaceIdiom == .pad {
                        Toggle("横屏宽屏时双页显示", isOn: $spread).disabled(mode != "pages")
                    }
                }
                Section {
                    Toggle("音量键翻页（兼容模式）", isOn: $volumeEnabled)
                    if volumeEnabled { Toggle("反转上下键", isOn: $volumeReverse) }
                    if let issue = volumeKeys.issue { Text(issue).font(TypeScale.tiny).foregroundStyle(appearance.secondary) }
                } header: { Text("音量键") } footer: {
                    Text("默认音量＋上一页、音量－下一页；滚动模式翻动一屏。只在阅读正文时生效。系统音量也会随按键变化，到最大或最小时继续按同一键可能无法翻页。")
                }
                Section("正文排版") {
                    Picker("字体", selection: $font) {
                        Text("跟随界面主题").tag("follow"); Text("宋体").tag("song"); Text("黑体").tag("sans")
                        if FontLibrary.regularName != nil { Text("已导入的字体").tag("custom") }
                    }
                    slider("字号", value: $size, range: 15...34)
                    slider("行距", value: $line, range: 0...20)
                    slider("段间距", value: $paragraph, range: 0...30)
                    slider("左右留白", value: $margin, range: 16...60)
                    Toggle("首行缩进两字", isOn: $indent)
                }
                Section("阅读纸色") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            paperChoice("跟随", key: "follow")
                            paperChoice("纯白", key: "white")
                            paperChoice("暖纸", key: "warm")
                            paperChoice("青灰", key: "green")
                            paperChoice("夜读", key: "night")
                        }.padding(.vertical, 4)
                    }
                }
                Section {
                    HStack { Image(systemName: "sun.min"); Slider(value: $brightness, in: 0.05...1); Image(systemName: "sun.max") }
                        .onChange(of: brightness) { _, value in UIScreen.main.brightness = CGFloat(value) }
                } header: { Text("阅读亮度") } footer: { Text("退出阅读时恢复原来的亮度。正文、菜单和阅读面板使用相同的纸色。") }
            }
            .font(TypeScale.body).scrollContentBackground(.hidden).background(appearance.paper)
            .navigationTitle("阅读设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
        }.tint(appearance.accent).preferredColorScheme(appearance.isDark ? .dark : .light)
            .presentationBackground(appearance.paper).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private func paperChoice(_ title: String, key: String) -> some View {
        let sample = ReaderAppearance.resolve(key, dark: appearance.isDark, swiss: InterfaceStyle.isSwiss, night: InterfaceStyle.isNight)
        return Button { palette = key } label: {
            VStack(spacing: 10) {
                Text("阅").font(.custom("NotoSerifSC-Regular", size: 23)).foregroundStyle(sample.ink)
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 11))
                    if palette == key { Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)) }
                }.foregroundStyle(sample.ink)
            }.frame(width: 66, height: 82)
                .background(sample.paper, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette == key ? appearance.accent : appearance.line, lineWidth: palette == key ? 1.5 : 0.5))
        }.buttonStyle(.plain).accessibilityLabel(title + (palette == key ? "，已选择" : ""))
    }
    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(label); Spacer(); Text("\(Int(value.wrappedValue))").monospacedDigit().foregroundStyle(appearance.secondary) }
            Slider(value: value, in: range, step: 1).accessibilityLabel(label)
        }
    }
}

@MainActor
struct ReaderContentsView: View {
    @Environment(\.readerAppearance) private var appearance
    @EnvironmentObject private var books: BookStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    let selected: Int
    let jump: (Int, Int) -> Void
    @State private var search = ""
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array((books.book(bookID)?.chapterTitles ?? []).enumerated()), id: \.offset) { index, title in
                        if search.isEmpty || title.localizedCaseInsensitiveContains(search) {
                            Button { jump(index, 0) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(String(format: "%03d", index + 1)).monospaced().font(TypeScale.tiny).foregroundStyle(appearance.secondary)
                                    Text(title).font(TypeScale.body).foregroundStyle(index == selected ? appearance.accent : appearance.ink)
                                    Spacer()
                                    if index == selected { Image(systemName: "speaker.wave.1").foregroundStyle(appearance.accent) }
                                }
                            }.id(index)
                        }
                    }
                }.onAppear { proxy.scrollTo(selected, anchor: .center) }
            }
            .searchable(text: $search, prompt: "搜索章节")
            .scrollContentBackground(.hidden).background(appearance.paper).navigationTitle("目录")
            .toolbar { Button("完成") { dismiss() } }
        }.tint(appearance.accent).preferredColorScheme(appearance.isDark ? .dark : .light)
            .presentationBackground(appearance.paper)
    }
}

@MainActor
struct ReaderBookmarksView: View {
    @Environment(\.readerAppearance) private var appearance
    @EnvironmentObject private var books: BookStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    let jump: (Int, Int) -> Void
    @State private var search = ""
    @State private var editingMark: ReaderSavedMark?
    @State private var exportURL: URL?
    @State private var exportError: String?
    private var book: Book? { books.book(bookID) }
    private var allMarks: [ReaderSavedMark] { book?.readerMarks ?? [] }
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var visibleMarks: [ReaderSavedMark] {
        allMarks.filter { mark in
            query.isEmpty || mark.excerpt.localizedCaseInsensitiveContains(query)
                || (mark.note ?? "").localizedCaseInsensitiveContains(query)
                || (book?.chapterLabel(mark.chapter) ?? "").localizedCaseInsensitiveContains(query)
        }.sorted { $0.createdAt > $1.createdAt }
    }
    var body: some View {
        NavigationStack {
            List {
                if allMarks.isEmpty {
                    Text("轻点阅读菜单的书签按钮，或长按一段原文添加书签。").foregroundStyle(appearance.secondary).listRowBackground(appearance.surface)
                } else {
                    Section {
                        if visibleMarks.isEmpty {
                            Text("没有匹配的书签，试试摘录、备注或章节中的其他关键词。").foregroundStyle(appearance.secondary)
                        }
                        ForEach(visibleMarks) { mark in
                            VStack(alignment: .leading, spacing: 10) {
                                Button { jump(mark.chapter, mark.paragraph) } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(book?.chapterLabel(mark.chapter) ?? "").font(TypeScale.body).foregroundStyle(appearance.ink)
                                        Text(mark.excerpt).font(TypeScale.label).foregroundStyle(appearance.secondary).lineLimit(3)
                                        if let note = mark.note, !note.isEmpty {
                                            Label { Text(note).lineLimit(3) } icon: { Image(systemName: "square.and.pencil") }
                                                .font(TypeScale.label).foregroundStyle(appearance.accent)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                                }.buttonStyle(.plain)
                                HStack {
                                    Text(mark.createdAt.formatted(date: .abbreviated, time: .shortened)).font(TypeScale.tiny).foregroundStyle(appearance.secondary)
                                    Spacer(minLength: 12)
                                    Button(mark.note?.isEmpty == false ? "编辑备注" : "写备注") { editingMark = mark }
                                        .font(TypeScale.label).buttonStyle(.borderless).foregroundStyle(appearance.accent)
                                }
                            }
                            .padding(.vertical, 4)
                            .contextMenu { Button("编辑备注", systemImage: "square.and.pencil") { editingMark = mark } }
                            .swipeActions { Button("删除", role: .destructive) { books.deleteReaderMark(mark.id, in: bookID) } }
                        }
                    } header: {
                        Text(query.isEmpty ? "全部书签 · \(allMarks.count)" : "匹配书签 · \(visibleMarks.count)")
                    } footer: {
                        Text("导出全部会包含本书的 \(allMarks.count) 条书签和备注，按章节、段落排序。摘录为保存书签时保留的短摘录。")
                    }.listRowBackground(appearance.surface)
                }
                if let exportError {
                    Text(exportError).font(TypeScale.label).foregroundStyle(.red).listRowBackground(appearance.surface)
                }
            }
            .searchable(text: $search, prompt: "搜索摘录、备注或章节")
            .scrollContentBackground(.hidden).background(appearance.paper).navigationTitle("书签")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { exportAllMarks() } label: { Label("导出全部", systemImage: "square.and.arrow.up") }
                        .disabled(allMarks.isEmpty).accessibilityLabel("导出本书全部书签和备注")
                }
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
        }.tint(appearance.accent).preferredColorScheme(appearance.isDark ? .dark : .light)
            .presentationBackground(appearance.paper)
            .sheet(item: $editingMark) { mark in
                ReaderBookmarkNoteEditor(bookID: bookID, mark: mark).environment(\.readerAppearance, appearance)
            }
            .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
                if let url = exportURL { ShareSheet(items: [url]) }
            }
    }
    private func exportAllMarks() {
        guard let book, !allMarks.isEmpty else { return }
        exportError = nil
        let marks = allMarks.sorted {
            if $0.chapter != $1.chapter { return $0.chapter < $1.chapter }
            if $0.paragraph != $1.paragraph { return $0.paragraph < $1.paragraph }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        var sections = [
            "# 《\(markdownLiteral(book.title))》书签笔记",
            "导出时间：\(date.string(from: Date()))\n\n共 \(marks.count) 条书签，按章节和段落排序。下列原文是保存书签时保留的短摘录，不是完整段落；章节和段落位置对应当前导入版本。"
        ]
        for (index, mark) in marks.enumerated() {
            let note = mark.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            sections.append("""
            ## \(index + 1). \(markdownLiteral(book.chapterLabel(mark.chapter)))

            位置：第 \(mark.chapter + 1) 章 · 第 \(mark.paragraph + 1) 段

            书签保存时间：\(date.string(from: mark.createdAt))

            ### 原文短摘录

            \(markdownQuote(mark.excerpt))

            ### 我的备注

            \(note.isEmpty ? "未填写。" : markdownQuote(note))
            """)
        }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sermo-Bookmarks-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("Sermo-书签笔记.md")
            try (sections.joined(separator: "\n\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            exportURL = url
        } catch {
            exportError = "书签笔记没能导出：\(error.localizedDescription)"
        }
    }
    private func markdownLiteral(_ value: String) -> String {
        let special = Set("\\`*_{}[]<>#+-.!|")
        return value.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
    }
    private func markdownQuote(_ value: String) -> String {
        value.components(separatedBy: .newlines).map { "> " + markdownLiteral($0) }.joined(separator: "\n")
    }
}

@MainActor
private struct ReaderBookmarkNoteEditor: View {
    @Environment(\.readerAppearance) private var appearance
    @EnvironmentObject private var books: BookStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    let mark: ReaderSavedMark
    @State private var note: String
    @State private var saveError: String?
    init(bookID: UUID, mark: ReaderSavedMark) {
        self.bookID = bookID; self.mark = mark
        _note = State(initialValue: mark.note ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("原文短摘录") {
                    Text(books.book(bookID)?.chapterLabel(mark.chapter) ?? "").font(TypeScale.tiny).foregroundStyle(appearance.accent)
                    Text(mark.excerpt).font(TypeScale.body).foregroundStyle(appearance.secondary)
                }.listRowBackground(appearance.surface)
                Section {
                    TextEditor(text: $note).font(TypeScale.body).foregroundStyle(appearance.ink)
                        .frame(minHeight: 180).scrollContentBackground(.hidden).accessibilityLabel("书签备注")
                } header: { Text("我的备注") }
                footer: { Text("可以记下理解、疑问或待核对的地方；清空后保存可移除备注。") }
                    .listRowBackground(appearance.surface)
                if let saveError {
                    Text(saveError).font(TypeScale.label).foregroundStyle(.red).listRowBackground(appearance.surface)
                }
            }
            .scrollContentBackground(.hidden).background(appearance.paper).navigationTitle("书签备注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if books.updateReaderMarkNote(note, markID: mark.id, in: bookID) { dismiss() }
                        else { saveError = books.errorMessage ?? "备注没能保存，请稍后再试。" }
                    }
                }
            }
        }.tint(appearance.accent).preferredColorScheme(appearance.isDark ? .dark : .light)
            .presentationBackground(appearance.paper)
            .interactiveDismissDisabled(note != (mark.note ?? ""))
    }
}

struct ReaderSearchHit: Identifiable, Sendable {
    var id: String
    var chapter: Int
    var paragraph: Int
    var excerpt: String
}

private struct ReaderSearchResults: Sendable {
    var hits: [ReaderSearchHit] = []
    var hasMore = false
}

@MainActor
struct ReaderSearchView: View {
    @Environment(\.readerAppearance) private var appearance
    @EnvironmentObject private var books: BookStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    @Binding var query: String
    let jump: (Int, Int) -> Void
    @State private var results: [ReaderSearchHit] = []
    @State private var searching = false
    @State private var hasMore = false
    var body: some View {
        NavigationStack {
            List {
                if searching { ProgressView("正在本地查找…") }
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text("输入人名、句子或关键词，搜索整本原文。").foregroundStyle(appearance.secondary) }
                else if !searching && results.isEmpty { Text("没有找到匹配的原文。").foregroundStyle(appearance.secondary) }
                if !searching && !results.isEmpty {
                    Text(hasMore ? "找到超过 200 个匹配段落，显示前 200 个。" : "找到 \(results.count) 个匹配段落。")
                        .font(TypeScale.tiny).foregroundStyle(appearance.secondary)
                }
                ForEach(results) { hit in
                    Button { jump(hit.chapter, hit.paragraph) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(books.book(bookID)?.chapterLabel(hit.chapter) ?? "").font(TypeScale.tiny).foregroundStyle(appearance.accent)
                            Text(highlighted(hit.excerpt)).font(TypeScale.body).foregroundStyle(appearance.ink).lineLimit(4)
                        }.multilineTextAlignment(.leading)
                    }
                }
                if hasMore { Text("可以输入更完整的关键词来缩小范围；同一段内的多次命中合并为一条结果。").font(TypeScale.tiny).foregroundStyle(appearance.secondary) }
            }
            .listRowBackground(appearance.surface)
            .searchable(text: $query, prompt: "搜索整本原文")
            .scrollContentBackground(.hidden).background(appearance.paper).navigationTitle("全文搜索")
            .toolbar { Button("完成") { dismiss() } }
            .task(id: query) {
                let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
                results = []; hasMore = false
                guard !term.isEmpty else { searching = false; return }
                searching = true
                do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
                let chapters = books.chapters(of: bookID)
                let work = Task.detached(priority: .userInitiated) { () -> ReaderSearchResults in
                    var found: [ReaderSearchHit] = []
                    for (chapter, value) in chapters.enumerated() {
                        if Task.isCancelled { return ReaderSearchResults() }
                        for (paragraph, line) in BookScenes.paragraphs(value.text).enumerated() where line.localizedCaseInsensitiveContains(term) {
                            let source = line as NSString
                            let match = source.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
                            let start = max(0, match.location == NSNotFound ? 0 : match.location - 35)
                            let proposed = NSRange(location: start, length: min(180, source.length - start))
                            let safeRange = source.rangeOfComposedCharacterSequences(for: proposed)
                            let snippet = (safeRange.location > 0 ? "…" : "") + source.substring(with: safeRange)
                                + (NSMaxRange(safeRange) < source.length ? "…" : "")
                            found.append(ReaderSearchHit(id: "\(chapter):\(paragraph)", chapter: chapter, paragraph: paragraph, excerpt: snippet))
                            if found.count > 200 { return ReaderSearchResults(hits: Array(found.prefix(200)), hasMore: true) }
                        }
                    }
                    return ReaderSearchResults(hits: found)
                }
                let found = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
                guard !Task.isCancelled else { return }
                results = found.hits; hasMore = found.hasMore; searching = false
            }
        }.tint(appearance.accent).preferredColorScheme(appearance.isDark ? .dark : .light)
            .presentationBackground(appearance.paper)
    }
    private func highlighted(_ excerpt: String) -> AttributedString {
        var text = AttributedString(excerpt)
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return text }
        let source = excerpt as NSString
        var cursor = 0
        while cursor < source.length {
            let match = source.range(of: term, options: [.caseInsensitive, .diacriticInsensitive],
                                     range: NSRange(location: cursor, length: source.length - cursor))
            guard match.location != NSNotFound, match.length > 0 else { break }
            // Convert Foundation's UTF-16 offsets before indexing the Swift attributed text.
            if let range = Range(match, in: excerpt),
               let lower = AttributedString.Index(range.lowerBound, within: text),
               let upper = AttributedString.Index(range.upperBound, within: text) {
                text[lower..<upper].foregroundColor = appearance.accent
                text[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            }
            cursor = NSMaxRange(match)
        }
        return text
    }
}

struct ReaderBookCover: View {
    let title: String
    var body: some View {
        ZStack(alignment: .leading) {
            Ink.raised
            Rectangle().fill(Ink.seal.opacity(0.7)).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(TypeScale.serif(12)).lineLimit(3).foregroundStyle(Ink.ink)
                Spacer(minLength: 0)
                Text(InterfaceStyle.isSwiss ? "BOOK" : "藏书").font(TypeScale.mono(8)).foregroundStyle(Ink.seal)
            }.padding(8)
        }.frame(width: 52, height: 74).clipShape(InkRounded(radius: 5))
            .overlay(InkRounded(radius: 5).stroke(Ink.line, lineWidth: 0.5))
    }
}



// One reading palette for the page, controls, passage card and presented panels.
struct ReaderAppearance {
    var paperHex: UInt32
    var inkHex: UInt32
    var surfaceHex: UInt32
    var accentHex: UInt32
    var isDark: Bool = false
    var paper: Color { Color(ReaderPageStyle.color(paperHex)) }
    var ink: Color { Color(ReaderPageStyle.color(inkHex)) }
    var surface: Color { Color(ReaderPageStyle.color(surfaceHex)) }
    var accent: Color { Color(ReaderPageStyle.color(accentHex)) }
    var secondary: Color { ink.opacity(0.56) }
    var line: Color { ink.opacity(isDark ? 0.16 : 0.12) }
    var scrim: Color { .black.opacity(isDark ? 0.44 : 0.20) }
    static let paperDefault = ReaderAppearance(paperHex: 0xF7F3EA, inkHex: 0x292A25, surfaceHex: 0xFEFCF7, accentHex: 0x9A563F)
    static func resolve(_ choice: String, dark: Bool, swiss: Bool, night: Bool = false) -> ReaderAppearance {
        switch choice {
        case "white": return .init(paperHex: 0xFFFFFF, inkHex: 0x272925, surfaceHex: 0xF8F9F6, accentHex: 0x785844)
        case "warm": return .init(paperHex: 0xF3E9D6, inkHex: 0x3E352A, surfaceHex: 0xFAF2E4, accentHex: 0x986244)
        case "green": return .init(paperHex: 0xE8EDE2, inkHex: 0x2C362C, surfaceHex: 0xF1F4EC, accentHex: 0x586B4D)
        case "night": return .init(paperHex: 0x1B1D1B, inkHex: 0xD0D0C5, surfaceHex: 0x262925, accentHex: 0xC5A07A, isDark: true)
        default:
            if night { return .init(paperHex: 0x051117, inkHex: 0xDBEBEF, surfaceHex: 0x0F1D24, accentHex: 0xECD59F, isDark: true) }
            if dark { return .init(paperHex: 0x1B1D1B, inkHex: 0xD0D0C5, surfaceHex: 0x262925, accentHex: swiss ? 0x9AAFF0 : 0xC5A07A, isDark: true) }
            if swiss { return .init(paperHex: 0xF2F2EF, inkHex: 0x181B18, surfaceHex: 0xFFFFFF, accentHex: 0x3554A4) }
            return paperDefault
        }
    }
}
private struct ReaderAppearanceKey: EnvironmentKey { static let defaultValue = ReaderAppearance.paperDefault }
extension EnvironmentValues {
    var readerAppearance: ReaderAppearance {
        get { self[ReaderAppearanceKey.self] }
        set { self[ReaderAppearanceKey.self] = newValue }
    }
}
struct ReaderPassage: Identifiable {
    let id = UUID()
    var paragraph: Int
    var text: String
}
@MainActor
private struct ReaderPassageCard: View {
    @Environment(\.readerAppearance) private var appearance
    let passage: ReaderPassage
    let chapter: String
    let canPlay: Bool
    let canDiscuss: Bool
    let issue: String?
    let dismiss: () -> Void
    let bookmark: () -> Void
    let copy: () -> Void
    let play: () -> Void
    let discuss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("原文选段").font(.custom("NotoSerifSC-Regular", size: 22))
                    Text(chapter).font(.system(size: 11)).foregroundStyle(appearance.secondary).lineLimit(1)
                }
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).frame(width: 32, height: 32) }
                    .background(appearance.ink.opacity(0.05), in: Circle()).accessibilityLabel("关闭原文选段")
            }
            ScrollView {
                Text(passage.text).font(.custom("NotoSerifSC-Regular", size: 16)).lineSpacing(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 160)
                .padding(.leading, 12).overlay(alignment: .leading) { Rectangle().fill(appearance.accent.opacity(0.55)).frame(width: 2) }
            HStack(spacing: 12) {
                smallAction("书签", icon: "bookmark", action: bookmark)
                smallAction("复制", icon: "doc.on.doc", action: copy)
                if canPlay { smallAction("从这里演", icon: "play", action: play) }
            }
            Button(action: discuss) {
                HStack { Image(systemName: "sparkle"); Text("问问这一段"); Spacer(); Image(systemName: "arrow.up.right") }
                    .font(.system(size: 15, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 14)
                    .background(appearance.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(appearance.accent)
            }.disabled(!canDiscuss)
            Text(issue ?? "带上原文进入讨论，由你确认发送。")
                .font(.system(size: 11)).foregroundStyle(appearance.secondary)
        }
        .padding(22).foregroundStyle(appearance.ink)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(appearance.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 28, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, dismiss)
    }
    private func smallAction(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon).font(.system(size: 12)).frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(appearance.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
}
