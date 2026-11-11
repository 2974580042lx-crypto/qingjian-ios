import SwiftUI
import UIKit

struct StudyReviewView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let kind: String
    @State private var presentation: StudyReviewPresentation?
    @State private var issue: String?
    @State private var copied = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let issue { Text(issue).foregroundStyle(.red) }
                    if let presentation {
                        if kind == "weekly" {
                            Button(presentation.current ? "重新生成" : "生成最新周报") { load(generate: true) }
                                .buttonStyle(.bordered).tint(Ink.ink)
                        }
                        Text(presentation.text).font(TypeScale.body).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if kind == "voice" {
                            Text("复制后粘贴到其他AI的文字或语音对话中即可。原始图片不会随提示词一起复制。")
                                .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                        }
                    }
                }.padding(20)
            }
            .background(AppBackground()).foregroundStyle(Ink.ink)
            .navigationTitle(kind == "voice" ? "今日语音复习" : "本周周报").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(copied ? "已复制" : "复制") { copyCurrent() }
                        .disabled(presentation?.current != true)
                }
            }
            .tint(Ink.ink)
            .onAppear { load() }
            .onChange(of: store.studyRevision) { _, _ in load() }
            .onChange(of: store.unlockedProjectIDs) { _, _ in load() }
        }
    }
    private func load(generate: Bool = false) {
        do { presentation = try store.studyReview(projectID: projectID, kind: kind, generate: generate); issue = nil; copied = false }
        catch { issue = error.localizedDescription; presentation = nil }
    }
    private func copyCurrent() {
        // Re-read immediately before copying; a preview may have become stale.
        load()
        guard let presentation, presentation.current else { return }
        UIPasteboard.general.string = presentation.text; copied = true
    }
}

struct StudyHistoryImportPreview: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let pack: StudyHistoryPack
    var body: some View {
        NavigationStack {
            Form {
                Section("来源") {
                    Text(pack.source)
                    Text("\(pack.entries.count) 条 · \(pack.verification)").font(TypeScale.caption).foregroundStyle(Ink.ink3)
                    Text(pack.kind == "outline" ? "核对条目后再导入为学习地图。用户核对不等于出版社或考试机构认证。" : "这是参考词条，不是正式考纲；AI整理内容需要与自己的书核对。")
                        .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                    if let issue = store.studyIssue { Text(issue).foregroundStyle(.red) }
                }
                Section("条目预览") {
                    ForEach(pack.entries) { entry in
                        DisclosureGroup(entry.title) {
                            Text(entry.block).font(TypeScale.caption).foregroundStyle(Ink.ink3)
                            Text(entry.text).textSelection(.enabled)
                        }
                    }
                }
            }
            .font(TypeScale.body).scrollContentBackground(.hidden).background(AppBackground()).foregroundStyle(Ink.ink)
            .navigationTitle("导入历史资料").navigationBarTitleDisplayMode(.inline).tint(Ink.ink)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pack.kind == "outline" ? "已核对，导入" : "导入参考资料") {
                        if store.importHistoryPack(projectID: projectID, pack: pack, confirmed: pack.kind == "outline") { dismiss() }
                    }
                }
            }
        }
    }
}
