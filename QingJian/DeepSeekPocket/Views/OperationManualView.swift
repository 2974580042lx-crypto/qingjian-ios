import SwiftUI
import UIKit

@MainActor
struct OperationManualView: View {
    @EnvironmentObject private var store: AppStore
    @State private var creatingChapter = false
    @State private var confirmResetAll = false

    var body: some View {
        List {
            Section {
                Text("所有项目与普通对话中的 AI 都自带规范查阅工具（manual_search / manual_read）。平时系统只附带极简的一句话目录，不占上下文；当你问起规范或需要执行对应操作时，AI 会自己翻阅正文，绝不会让你手动发文件。所有规范只约束后台数据真实性，100% 尊重你设定的人设与语气。")
                    .font(TypeScale.caption)
                    .foregroundStyle(Ink.ink2)
                    .padding(.vertical, 2)
            } header: {
                Text("工作原理 · 已启用 \(store.operationManual.enabledCount) / \(store.operationManual.chapters.count) 章")
            } footer: {
                Text("你对任意章节的修改、开关状态和新建章节都会单独保存在本机，并在导出 .sermobackup 完整备份或每日自动备份时一并打包。")
            }

            Section {
                ForEach(store.operationManual.chapters) { chapter in
                    NavigationLink {
                        OperationManualChapterEditor(chapter: chapter, isNew: false)
                    } label: {
                        chapterRow(chapter)
                    }
                }
            } header: {
                Text("规范章节列表（点开查看或修改）")
            }

            if store.operationManual.hasUserChanges {
                Section {
                    Button(role: .destructive) {
                        confirmResetAll = true
                    } label: {
                        Label("将全部内置章节恢复为出厂默认", systemImage: "arrow.counterclockwise")
                    }
                } footer: {
                    Text("只恢复内置的 9 个章节及其启用开关；你自己新建的章节会完整保留。")
                }
            }
        }
        .font(TypeScale.body)
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .foregroundStyle(Ink.ink)
        .tint(Ink.seal)
        .navigationTitle("内置文档规范")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    creatingChapter = true
                } label: {
                    Label("新建章节", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $creatingChapter) {
            NavigationStack {
                OperationManualChapterEditor(
                    chapter: OperationManualChapter(
                        id: "custom-\( String(UUID().uuidString.lowercased().prefix(6)) )",
                        title: "",
                        whenToRead: "",
                        content: "",
                        scope: .custom,
                        isEnabled: true,
                        version: 1,
                        isCustom: true,
                        isUserModified: true,
                        updatedAt: Date()
                    ),
                    isNew: true
                )
            }
            .environmentObject(store)
        }
        .confirmationDialog("恢复全部内置章节？", isPresented: $confirmResetAll, titleVisibility: .visible) {
            Button("恢复内置章节默认内容", role: .destructive) {
                _ = store.resetAllBuiltInManualChapters()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("内置章节里的手工改动会还原为 Sermo 默认版本，你自己新建的章节不会受影响。")
        }
    }

    private func chapterRow(_ chapter: OperationManualChapter) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(chapter.title)
                        .font(TypeScale.body.weight(.medium))
                        .foregroundStyle(chapter.isEnabled ? Ink.ink : Ink.ink3)
                    Text(badgeText(for: chapter))
                        .font(TypeScale.tiny)
                        .foregroundStyle(chapter.isUserModified || chapter.isCustom ? Ink.seal : Ink.ink3)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Ink.raised, in: Capsule())
                }
                Text("\(chapter.scope.title) · [\(chapter.id)]")
                    .font(TypeScale.tiny)
                    .foregroundStyle(Ink.ink3)
                Text(chapter.whenToRead)
                    .font(TypeScale.caption)
                    .foregroundStyle(Ink.ink2)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(
                get: { chapter.isEnabled },
                set: { store.setManualChapterEnabled($0, id: chapter.id) }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 3)
    }

    private func badgeText(for chapter: OperationManualChapter) -> String {
        if chapter.isCustom { return "自建 v\(chapter.version)" }
        if chapter.isUserModified { return "已改 v\(chapter.version)" }
        return "内置 v\(chapter.version)"
    }
}

@MainActor
struct OperationManualChapterEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let original: OperationManualChapter
    let isNew: Bool

    @State private var id: String
    @State private var title: String
    @State private var whenToRead: String
    @State private var content: String
    @State private var scope: OperationManualScope
    @State private var isEnabled: Bool
    @State private var issue: String?
    @State private var confirmResetOne = false
    @State private var confirmDelete = false

    init(chapter: OperationManualChapter, isNew: Bool) {
        self.original = chapter
        self.isNew = isNew
        _id = State(initialValue: chapter.id)
        _title = State(initialValue: chapter.title)
        _whenToRead = State(initialValue: chapter.whenToRead)
        _content = State(initialValue: chapter.content)
        _scope = State(initialValue: chapter.scope)
        _isEnabled = State(initialValue: chapter.isEnabled)
    }

    private var hasChanges: Bool {
        if isNew {
            return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return id != original.id
            || title != original.title
            || whenToRead != original.whenToRead
            || content != original.content
            || scope != original.scope
            || isEnabled != original.isEnabled
    }

    var body: some View {
        Form {
            Section {
                TextField("章节标题（如：英语：聊天式精读与做题）", text: $title)
                if isNew {
                    TextField("章节标识 ID（英文与短横线，如 my-reading-rule）", text: $id)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    LabeledContent("章节标识 ID", value: id)
                        .font(TypeScale.caption)
                }
                Picker("适用范围", selection: $scope) {
                    ForEach(OperationManualScope.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                Toggle("启用此章节", isOn: $isEnabled)
            } header: {
                Text("基本信息")
            } footer: {
                Text("AI 只会在符合「适用范围」的对话里看到这一章的目录条目，不会串到无关科目或普通闲聊中。")
            }

            Section {
                TextField("用一句话说明什么时候需要翻阅本章", text: $whenToRead, axis: .vertical)
                    .lineLimit(2...4)
            } header: {
                Text("何时查阅（目录摘要 · \(whenToRead.count) / 300 字）")
            } footer: {
                Text("这句话会出现在极简目录里，告诉 AI 在什么场景下调用 manual_read 翻开本章。")
            }

            Section {
                HStack(spacing: 12) {
                    Button {
                        if let clip = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty {
                            content = clip
                            issue = nil
                        } else {
                            issue = "剪贴板里目前没有可粘贴的文字。"
                        }
                    } label: {
                        Label("粘贴覆盖", systemImage: "doc.on.clipboard")
                            .font(TypeScale.caption)
                    }
                    .buttonStyle(.borderless)

                    Button {
                        if let clip = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty {
                            content = content.isEmpty ? clip : (content + "\n\n" + clip)
                            issue = nil
                        } else {
                            issue = "剪贴板里目前没有可粘贴的文字。"
                        }
                    } label: {
                        Label("粘贴追加", systemImage: "plus.rectangle.on.rectangle")
                            .font(TypeScale.caption)
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Button {
                        UIPasteboard.general.string = content
                        store.noticeMessage = "已复制本章规范正文。"
                    } label: {
                        Label("复制全文", systemImage: "doc.on.doc")
                            .font(TypeScale.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(content.isEmpty)
                }

                TextEditor(text: $content)
                    .frame(minHeight: 260)
                    .font(TypeScale.serif(15))
                    .scrollContentBackground(.hidden)
            } header: {
                Text("规范正文 · \(content.count.formatted()) / 20,000 字")
            } footer: {
                Text("支持随时按你自己的习惯增删修改；升级 App 版本时不会覆盖你改过的章节。")
            }

            if let issue {
                Section {
                    Text(issue)
                        .font(TypeScale.caption)
                        .foregroundStyle(.red)
                }
            }

            if !isNew {
                if !original.isCustom, OperationManualBook.defaultChapter(id: original.id) != nil {
                    Section {
                        Button {
                            confirmResetOne = true
                        } label: {
                            Label("恢复本章出厂默认内容", systemImage: "arrow.counterclockwise")
                        }
                    }
                }
                if original.isCustom {
                    Section {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("删除此自建章节", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .font(TypeScale.body)
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .foregroundStyle(Ink.ink)
        .tint(Ink.seal)
        .navigationTitle(isNew ? "新建规范章节" : "编辑规范章节")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    save()
                }
                .disabled(!hasChanges && !isNew)
            }
        }
        .confirmationDialog("恢复本章出厂默认？", isPresented: $confirmResetOne, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) {
                if store.resetManualChapter(id: original.id) {
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("「\(original.title)」将还原为 Sermo 内置默认版本。")
        }
        .confirmationDialog("删除「\(original.title)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除章节", role: .destructive) {
                if store.deleteCustomManualChapter(id: original.id) {
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func save() {
        var draft = original
        draft.id = id
        draft.title = title
        draft.whenToRead = whenToRead
        draft.content = content
        draft.scope = scope
        draft.isEnabled = isEnabled
        switch store.saveManualChapter(draft, creatingNew: isNew) {
        case .success:
            issue = nil
            dismiss()
        case .failure(let err):
            issue = err.localizedDescription
        }
    }
}
