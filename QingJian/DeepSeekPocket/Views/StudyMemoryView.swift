import SwiftUI
import UniformTypeIdentifiers

struct StudyMemoryView: View {
    @EnvironmentObject private var store: AppStore
    let projectID: UUID
    @State private var records: [StudyMemoryRecord] = []
    @State private var events: [StudyMemoryEvent] = []
    @State private var pending: [StudyPendingOperation] = []
    @State private var editing: EditTarget?
    @State private var exportURL: URL?
    @State private var showExport = false
    @State private var loadError: String?
    @State private var importingWordsBusy = false
    @State private var wordCount = 0
    @State private var wordSummary: StudyWordPracticeSummary?
    @State private var importingReadingsBusy = false
    @State private var readingCount = 0
    @State private var readingAnsweredCount = 0
    @State private var reviewKind: ReviewTarget?
    @State private var topics: [StudyTopic] = []
    @State private var practices: [StudyPractice] = []
    @State private var importingHistoryBusy = false
    @State private var historyPreview: HistoryTarget?
    @State private var historyReferenceCount = 0
    @State private var historyOutlineCount = 0
    @State private var temporaryMap: StudyTemporaryMap?
    @State private var importingMapBusy = false
    private struct ReviewTarget: Identifiable { let id: String }
    private struct HistoryTarget: Identifiable { let id = UUID(); let pack: StudyHistoryPack }
    private struct EditTarget: Identifiable { let id = UUID(); let record: StudyMemoryRecord?; let category: String }
    private var subject: StudySubject? { store.project(projectID)?.studySubject }

    var body: some View {
        Form {
            if let subject, !store.isLocked(projectID) {
                if let issue = store.studyIssue {
                    Section { Text(issue).foregroundStyle(.red); Button("重新读取") { reload() } }
                }
                Section {
                    Text("学习记录由这个项目的对话共用。每条记录保留出处与修改历史，切换模型后仍读取这里。")
                        .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                }
                Section("复习与周报") {
                    Button("今日语音复习提示词") { reviewKind = ReviewTarget(id: "voice") }
                    Button("本周学习周报") { reviewKind = ReviewTarget(id: "weekly") }
                }
                if subject == .history {
                    Section("历史资料") {
                        Text(historyOutlineCount == 0 ? "可以使用网络临时地图或自主专题；不会标为官方大纲。" : "已导入 \(historyOutlineCount) 条用户核对的学习地图。")
                            .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                        Text("参考词条 \(historyReferenceCount) 条，与正式大纲分开。")
                            .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                        Button(importingHistoryBusy ? "正在读取…" : "导入历史资料 JSON") { pickHistoryPack() }.disabled(importingHistoryBusy)
                        Button(importingMapBusy ? "正在导入…" : "导入网络临时学习地图") { pickTemporaryMap() }.disabled(importingMapBusy)
                    }
                }
                if subject != .english {
                    Section("专题与复习顺序") {
                        if topics.isEmpty { Text("尚无专题记录，在聊天里说想学什么即可。 ").foregroundStyle(Ink.ink3) }
                        ForEach(topics) { topic in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(topic.title)
                                Text("\(topic.phase.title) · \(topic.level.title) · \(sourceName(topic.source.kind))")
                                    .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                                Text(topic.note).font(TypeScale.caption)
                                Text("记录日期：\(topic.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(TypeScale.caption).foregroundStyle(Ink.ink3)
                            }
                        }
                    }
                    Section("最近练习") {
                        if practices.isEmpty { Text("尚无练习记录；正确率只统计用户确认的实际作答。 ").foregroundStyle(Ink.ink3) }
                        ForEach(practices.prefix(20)) { practice in
                            DisclosureGroup(practice.area + " · " + practice.question) {
                                if !practice.questionIsQuoted { Text("题目为模型整理摘要，需要核对原题。 ").font(TypeScale.caption).foregroundStyle(Ink.ink3) }
                                Text("实际作答：" + (practice.answer.isEmpty ? "未记录" : practice.answer))
                                Text("结果：" + (practice.outcome == .correct ? "正确" : practice.outcome == .wrong ? "错误" : "未确认"))
                                Text(practice.weakPoint)
                                Text(sourceName(practice.source.kind)).font(TypeScale.caption).foregroundStyle(Ink.ink3)
                                Text(practice.source.quote.isEmpty ? "出处为用户图片，文字整理待核。" : practice.source.quote).font(TypeScale.caption)
                            }
                        }
                        Text("更正或移除时，在聊天里说明是哪一题，原记录会保留修改历史。这里显示最近20条，完整记录可在聊天中查询。")
                            .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                    }
                }
                if subject == .english {
                    Section("私人词库与背词进度") {
                        Text(wordCount == 0 ? "导入一次后，在聊天里说“开始背词”即可。" : "已导入 \(wordCount) 个词，每次在聊天中作答判分都会实时记录在这里。")
                            .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                        if let summary = wordSummary, summary.totalWords > 0 {
                            HStack(spacing: 12) {
                                Text("已背 \(summary.learnedWords) 词")
                                    .font(TypeScale.caption.weight(.semibold)).foregroundStyle(Ink.seal)
                                Text("今日已练 \(summary.todayWords) 词")
                                    .font(TypeScale.caption).foregroundStyle(Ink.ink2)
                                Text("待复习 \(summary.dueWords) 词")
                                    .font(TypeScale.caption).foregroundStyle(summary.dueWords > 0 ? Ink.seal : Ink.ink3)
                            }
                            if let unit = summary.activeSessionUnit, summary.activeSessionCount > 0 {
                                Text("当前进行中：\(unit)（第 \(min(summary.activeSessionPosition + 1, summary.activeSessionCount)) / \(summary.activeSessionCount) 词）")
                                    .font(TypeScale.caption).foregroundStyle(Ink.ink2)
                            }
                            if !summary.todayWordsList.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("今日各窗口已聊单词（\(summary.todayWordsList.count) 词）")
                                        .font(TypeScale.caption.weight(.medium)).foregroundStyle(Ink.ink2)
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 6) {
                                            ForEach(summary.todayWordsList.prefix(25), id: \.word.id) { item in
                                                Text("\(item.word.word) · \(ratingLabel(item.lastRating))")
                                                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                                    .foregroundStyle(Ink.seal)
                                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                                    .background(Ink.seal.opacity(0.12), in: Capsule())
                                            }
                                        }
                                    }
                                }
                            }
                            if !summary.recentWords.isEmpty {
                                DisclosureGroup("最近背过的单词（共 \(summary.learnedWords) 词）") {
                                    ForEach(summary.recentWords, id: \.word.id) { item in
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text(item.word.word).font(TypeScale.body.weight(.semibold)).foregroundStyle(Ink.seal)
                                                if let phonetic = item.word.phonetic, !phonetic.isEmpty {
                                                    Text(phonetic).font(TypeScale.caption).foregroundStyle(Ink.ink3)
                                                }
                                                Spacer()
                                                Text(ratingLabel(item.lastRating))
                                                    .font(TypeScale.tiny.weight(.medium))
                                                    .foregroundStyle(Ink.seal)
                                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                                    .background(Ink.seal.opacity(0.12), in: Capsule())
                                            }
                                            Text(item.word.meaning).font(TypeScale.caption).foregroundStyle(Ink.ink2).lineLimit(2)
                                            if let reviewedAt = item.lastReviewedAt {
                                                Text("已练 \(item.reviewCount) 次 · 最近：\(reviewedAt.formatted(date: .abbreviated, time: .shortened))")
                                                    .font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                                            }
                                        }
                                        .padding(.vertical, 3)
                                    }
                                }
                            }
                        }
                        Button(importingWordsBusy ? "正在导入…" : "导入词库 JSON") { pickVocabulary() }.disabled(importingWordsBusy)
                    }
                    Section("阅读资料与做题进度") {
                        Text(readingCount == 0 ? "导入后，在聊天里说“开始某年 Text 4”或“继续上次阅读”。" : "已导入 \(readingCount) 篇 · 累计已作答 \(readingAnsweredCount) 道阅读题。正文按段读取，原文和待答题留在聊天中。")
                            .font(TypeScale.caption).foregroundStyle(readingAnsweredCount > 0 ? Ink.seal : Ink.ink3)
                        Button(importingReadingsBusy ? "正在导入…" : "导入阅读 JSON") { pickReadings() }.disabled(importingReadingsBusy)
                    }
                }
                ForEach(subject.categories, id: \.self) { category in
                    Section(category) {
                        if category == "大纲条目状态", let map = temporaryMap {
                            Text("临时学习地图 · 网络整理、待核").font(TypeScale.caption).foregroundStyle(Ink.ink3)
                            ForEach(StudyLessonTools.historyAreas, id: \.self) { block in
                                DisclosureGroup(block) {
                                    ForEach(map.entries.filter { $0.block == block }) { entry in
                                        DisclosureGroup {
                                            Text(entry.status).font(TypeScale.caption).foregroundStyle(Ink.ink3)
                                            ForEach(entry.differences, id: \.self) { Text($0).font(TypeScale.caption) }
                                            ForEach(map.sources.filter { entry.sourceIDs.contains($0.id) }) { source in
                                                if let url = URL(string: source.url) { Link(source.title, destination: url).font(TypeScale.caption) }
                                            }
                                            Text("可能关联教材章节\(entry.relatedChapterIDs.count)项、参考词条\(entry.relatedTermIDs.count)条（关键词匹配，待核）。在聊天里指定此条目开始学习即可记录进度。")
                                                .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                                        } label: {
                                            HStack { Text(entry.title); Spacer(); Text(topics.first { $0.outlineID == entry.id }?.level.title ?? "未学").font(TypeScale.caption).foregroundStyle(Ink.ink3) }
                                        }
                                    }
                                }
                            }
                        }
                        let matches = records.filter { $0.category == category }
                        if matches.isEmpty { Text(loadError == nil ? "尚无记录" : "暂时无法读取").foregroundStyle(Ink.ink3) }
                        ForEach(matches) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(record.text).textSelection(.enabled)
                                Text("\(sourceName(record.source.kind)) · \(record.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                                DisclosureGroup("出处") { Text(record.source.quote.isEmpty ? "用户图片，模型整理内容待核。" : record.source.quote).font(TypeScale.caption).textSelection(.enabled) }
                                if let material = record.source.material {
                                    DisclosureGroup("\(material.passageTitle) · 第\(material.paragraph)段") {
                                        Text(material.originalSentence).font(TypeScale.body).textSelection(.enabled)
                                        Text(material.source).font(TypeScale.caption).foregroundStyle(Ink.ink3)
                                        Text(material.linkedWordIDs.isEmpty ? "词库中尚无精确匹配；收藏不等于已背熟。" : "已关联词库词条；收藏没有增加作答次数。")
                                            .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                                    }
                                }
                                Button("编辑") { editing = EditTarget(record: record, category: category) }.font(TypeScale.caption)
                            }.padding(.vertical, 4)
                        }
                        Button("添加记录") { editing = EditTarget(record: nil, category: category) }
                    }
                }
                if !pending.isEmpty {
                    Section("待处理") {
                        ForEach(pending) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.command.text)
                                Text(item.error ?? "等待完成保存").font(TypeScale.caption).foregroundStyle(Ink.ink3)
                                HStack {
                                    Button("重试") { store.retryStudyOperation(item) }
                                    Spacer()
                                    Button("取消这项操作", role: .destructive) { store.discardStudyOperation(item) }
                                }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
                Section("修改历史") {
                    if events.isEmpty { Text("尚无修改").foregroundStyle(Ink.ink3) }
                    ForEach(events.prefix(100)) { event in
                        DisclosureGroup {
                            if let before = event.before { Text("修改前\n" + before.text).font(TypeScale.caption) }
                            Text("修改后\n" + event.after.text).font(TypeScale.caption)
                            Text(event.after.source.quote).font(TypeScale.caption).foregroundStyle(Ink.ink3)
                            Button("撤销这次修改") { store.undoStudyEvent(event) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(StudyReceipt(event: event).message)
                                Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(TypeScale.caption).foregroundStyle(Ink.ink3)
                            }
                        }
                    }
                }
                Section {
                    Button("导出本项目学习备份") {
                        exportURL = store.exportStudyMemory(projectID: projectID)
                        showExport = exportURL != nil
                    }
                } footer: {
                    Text("完整学习备份包含记录、资料、修改历史、现场和图片实体。云盘状态与恢复入口在设置的“用量与备份”里。")
                }
            } else { Text("项目已上锁或不存在，请返回后重新打开。") }
        }
        .font(TypeScale.body).scrollContentBackground(.hidden).background(AppBackground())
        .foregroundStyle(Ink.ink).tint(Ink.ink).navigationTitle("项目学习记忆")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onChange(of: store.studyRevision) { _, _ in reload() }
        .onChange(of: store.unlockedProjectIDs) { _, _ in reload() }
        .sheet(item: $editing) { target in
            StudyRecordEditor(projectID: projectID, record: target.record, category: target.category).environmentObject(store)
        }
        .sheet(isPresented: $showExport) { if let exportURL { ShareSheet(items: [exportURL]) } }
        .sheet(item: $reviewKind) { target in StudyReviewView(projectID: projectID, kind: target.id).environmentObject(store) }
        .sheet(item: $historyPreview) { target in StudyHistoryImportPreview(projectID: projectID, pack: target.pack).environmentObject(store) }
    }
    private func pickHistoryPack() {
        DocumentPicker.present([.json], asCopy: true, onError: { store.studyIssue = $0 }) { url in
            importingHistoryBusy = true
            Task { @MainActor in
                defer { try? FileManager.default.removeItem(at: url); importingHistoryBusy = false }
                do { historyPreview = HistoryTarget(pack: try await store.previewHistoryPack(url: url)) }
                catch { store.studyIssue = error.localizedDescription }
            }
        }
    }
    private func pickTemporaryMap() {
        DocumentPicker.present([.json], asCopy: true, onError: { store.studyIssue = $0 }) { url in
            importingMapBusy = true
            Task { @MainActor in
                defer { try? FileManager.default.removeItem(at: url); importingMapBusy = false }
                _ = await store.importTemporaryHistoryMap(projectID: projectID, url: url)
                reload()
            }
        }
    }
    private func pickVocabulary() {
        DocumentPicker.present([.json], asCopy: true, onError: { store.studyIssue = $0 }) { url in
            importingWordsBusy = true
            Task { @MainActor in
                defer { try? FileManager.default.removeItem(at: url); importingWordsBusy = false }
                _ = await store.importStudyVocabulary(projectID: projectID, url: url)
                reload()
            }
        }
    }
    private func pickReadings() {
        DocumentPicker.present([.json], asCopy: true, onError: { store.studyIssue = $0 }) { url in
            importingReadingsBusy = true
            Task { @MainActor in
                defer { try? FileManager.default.removeItem(at: url); importingReadingsBusy = false }
                _ = await store.importStudyReadings(projectID: projectID, url: url)
                reload()
            }
        }
    }
    private func reload() {
        do {
            records = try store.studyRecords(for: projectID)
            events = try store.studyEvents(for: projectID)
            pending = try store.studyPending(for: projectID)
            topics = try store.studyTopics(projectID: projectID)
            practices = try store.studyPractices(projectID: projectID)
            if subject == .history {
                historyReferenceCount = try store.historyPack(projectID: projectID, kind: "reference")?.entries.count ?? 0
                historyOutlineCount = try store.historyPack(projectID: projectID, kind: "outline")?.entries.count ?? 0
                temporaryMap = try store.temporaryHistoryMap(projectID: projectID)
            }
            if subject == .english {
                wordCount = try store.studyVocabularyCount(projectID: projectID)
                wordSummary = try store.studyWordSummary(projectID: projectID)
                readingCount = try store.studyReadingCount(projectID: projectID)
                readingAnsweredCount = (try? store.studyReadingAnsweredCount(projectID: projectID)) ?? 0
            }
            loadError = nil
        } catch {
            records = []; events = []; pending = []; topics = []; practices = []; historyOutlineCount = 0; historyReferenceCount = 0; temporaryMap = nil
            loadError = error.localizedDescription; store.studyIssue = error.localizedDescription
        }
    }
    private func ratingLabel(_ rating: String?) -> String {
        switch rating {
        case "easy": return "轻松"
        case "good": return "记得"
        case "hard": return "模糊"
        case "again": return "忘了"
        default: return "已练"
        }
    }
    private func sourceName(_ kind: StudySource.Kind) -> String {
        switch kind { case .manual: return "手动记录"; case .userStatement: return "用户原话"; case .modelInference: return "模型判断，可纠正" }
    }
}

private struct StudyRecordEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let record: StudyMemoryRecord?
    @State private var category: String
    @State private var text: String
    @State private var deleting = false
    @State private var operationID = UUID().uuidString
    @State private var sourceThreadID = UUID()
    @State private var lastAttempt: String?
    init(projectID: UUID, record: StudyMemoryRecord?, category: String) {
        self.projectID = projectID; self.record = record
        _category = State(initialValue: category); _text = State(initialValue: record?.text ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Picker("栏目", selection: $category) {
                    ForEach(store.project(projectID)?.studySubject?.categories ?? [], id: \.self) { Text($0).tag($0) }
                }
                TextEditor(text: $text).frame(minHeight: 180)
                Text("\(text.count) / 4000 字").font(TypeScale.caption).foregroundStyle(Ink.ink3)
                if let issue = store.studyIssue { Text(issue).font(TypeScale.caption).foregroundStyle(.red) }
                if record != nil { Button("移出有效记忆", role: .destructive) { deleting = true } }
            }
            .font(TypeScale.body).scrollContentBackground(.hidden).background(AppBackground()).tint(Ink.ink)
            .navigationTitle(record == nil ? "添加学习记录" : "编辑学习记录").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save(deleting: false)
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 4000)
                }
            }
            .confirmationDialog("移出有效记忆后，可以在修改历史里撤销。", isPresented: $deleting) {
                Button("移出有效记忆", role: .destructive) {
                    save(deleting: true)
                }
            }
        }
    }
    private func save(deleting: Bool) {
        let value = deleting ? (record?.text ?? text) : text
        let selected = deleting ? (record?.category ?? category) : category
        let signature = "\(deleting)\n\(selected)\n\(value)"
        if let lastAttempt, lastAttempt != signature {
            guard store.discardStudyOperation(projectID: projectID, operationID: operationID) else { return }
            operationID = UUID().uuidString
        }
        lastAttempt = signature
        if store.saveStudyRecord(projectID: projectID, record: record, category: selected, text: value,
                                 operationID: operationID, sourceThreadID: sourceThreadID, deleting: deleting) { dismiss() }
    }
}
