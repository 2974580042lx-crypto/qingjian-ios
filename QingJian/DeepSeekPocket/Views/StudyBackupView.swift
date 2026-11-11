import SwiftUI
import UniformTypeIdentifiers

struct StudyCloudBackupSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var cloud: StudyBackupController
    @State private var importing = false
    @State private var keepLocal = false
    var body: some View {
        Section {
            Toggle("自动备份学习项目到 Drive", isOn: Binding(get: { cloud.state.enabled }, set: cloud.setEnabled))
            LabeledContent("Google账号", value: store.drive.accountLabel)
            Text(cloud.status).font(TypeScale.caption).foregroundStyle(Ink.ink3)
            if let capacity = cloud.imageCapacity {
                LabeledContent("关联图片", value: "\(capacity.count)张 · \(String(format: "%.1f", Double(capacity.bytes) / 1048576)) MB")
                if capacity.unavailable > 0 { Text("有\(capacity.unavailable)张关联图片暂时不可读取，备份会明确列为缺图。 ").font(TypeScale.caption).foregroundStyle(.orange) }
                if capacity.bytes >= StudyBackupCodec.imageWarningBytes {
                    Text("图片已接近64MB预算，备份会进一步压缩副本。仍放不下时先保住全部记录和可容纳图片，明确列出缺图；本机图片与旧完整备份保留。")
                        .font(TypeScale.caption).foregroundStyle(.orange)
                }
            }
            LabeledContent("最近回读校验", value: cloud.state.lastVerifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "尚未完成")
            if cloud.busy { ProgressView().controlSize(.small) }
            if let issue = cloud.issue { Text(issue).font(TypeScale.caption).foregroundStyle(.red) }
            Button("立即备份到 Drive") { cloud.syncNow() }.disabled(cloud.busy || !store.drive.connected || !store.canPersist)
            Button("刷新云端版本") { cloud.refreshFiles() }.disabled(cloud.busy || !store.drive.connected)
            if cloud.state.conflict {
                Text("云端版本会保留。你可以先查看并恢复云端，或确认以本机内容另存一个新版本。")
                    .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                Button("保留本机内容，继续备份") { keepLocal = true }.disabled(cloud.busy || cloud.files.isEmpty)
            }
            if let link = cloud.state.lastFileURL, let url = URL(string: link), url.scheme == "https" {
                Link("查看最近已核验的云盘文件", destination: url)
            }
            if (cloud.state.lastOmittedImageCount ?? 0) > 0, let link = cloud.state.lastCompleteFileURL, let url = URL(string: link) {
                Link("查看保留的上一份完整备份", destination: url)
            }
            if !cloud.files.isEmpty {
                DisclosureGroup("云端版本（最近\(min(50, cloud.files.count))份）") {
                    ForEach(cloud.files.prefix(50)) { file in
                        Button { cloud.prepareRestore(file) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(file.name)
                                Text("点开后先核对项目、记录与图片数量，再决定是否恢复。")
                                    .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                            }
                        }.disabled(cloud.busy || !store.canRestoreStudyBackup)
                    }
                }
            }
            Button("从本地学习备份恢复") { importing = true }.disabled(cloud.busy || !store.canRestoreStudyBackup)
            if !cloud.localRecoveryFiles.isEmpty {
                DisclosureGroup("恢复前的本机版本") {
                    ForEach(cloud.localRecoveryFiles.prefix(10), id: \.path) { url in
                        Button {
                            cloud.prepareLocalRestore(url)
                        } label: {
                            Text((try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)?.formatted(date: .abbreviated, time: .shortened) ?? "恢复前快照")
                        }.disabled(cloud.busy || !store.canRestoreStudyBackup)
                    }
                }
            }
        } header: { Text("学习备份") } footer: {
            Text("保存学习项目、对话、资料、进度和周报。图片原已压缩存储，接近52MB时提醒并压缩备份副本；超额时生成标明缺图的保底包，不宣称图片完整。使用当前Google账号私人目录，不含凭据；前台通常至少间隔5分钟，旧云端版本保留。")
        }
        .onAppear { cloud.refreshRecoveryFiles(); cloud.refreshImageCapacity() }
        .confirmationDialog("以本机内容另存一个云端版本？", isPresented: $keepLocal) {
            Button("保留本机，另存新版本") { cloud.syncNow(keepLocal: true) }
        } message: {
            Text("当前账号：\(store.drive.accountLabel)\n云端最近版本：\(cloud.files.first?.name ?? "尚未读取")\n已有云端版本会保留。")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do { cloud.prepareLocalRestore(try result.get()) }
            catch { cloud.issue = error.localizedDescription }
        }
        .sheet(item: $cloud.preview) { preview in
            StudyRestorePreviewView(cloud: cloud, preview: preview)
        }
    }
}

private struct StudyRestorePreviewView: View {
    @ObservedObject var cloud: StudyBackupController
    @Environment(\.dismiss) private var dismiss
    let preview: StudyRestorePreview
    @State private var confirming = false
    var body: some View {
        NavigationStack {
            Form {
                Section("已核验的备份") {
                    Text(preview.file.name).textSelection(.enabled)
                    LabeledContent("生成时间", value: preview.payload.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("学习项目范围", value: "\(preview.payload.projectIDs.count)")
                    LabeledContent("学习对话", value: "\(preview.payload.snapshot.threads.count)")
                    LabeledContent("学习数据行", value: "\(preview.payload.learning.rows.count)")
                    LabeledContent("图片实体", value: "\(preview.payload.images.count) 张，已检查完整性")
                    if !preview.payload.isComplete {
                        Text("这是记录保底包，缺少\(preview.payload.omittedImages?.count ?? 0)张图片。文字和进度可恢复；本机已有原图可沿用，但在新手机上不会凭空恢复缺失照片。")
                            .foregroundStyle(.orange)
                        DisclosureGroup("查看未包含的图片") {
                            ForEach(preview.payload.omittedImages ?? [], id: \.name) { Text($0.name).font(TypeScale.caption).textSelection(.enabled) }
                        }
                    }
                    ForEach(preview.payload.snapshot.projects ?? []) { project in Text(project.name) }
                }
                if !preview.payload.images.isEmpty {
                    Section {
                        DisclosureGroup("图片抽样（前3张，全部图片均已程序校验）") {
                            ForEach(Array(preview.payload.images.prefix(3)), id: \.name) { image in
                                if let uiImage = UIImage(data: image.data) {
                                    Image(uiImage: uiImage).resizable().scaledToFit().frame(maxHeight: 220)
                                }
                            }
                        }
                    }
                }
                Section {
                    Text("将替换这份备份所列学习项目及其学习对话，并保留其他项目、当前全局设置和登录。恢复前先另存本机记录与可读取图片；恢复中断时自动回退。")
                    if let issue = cloud.issue { Text(issue).foregroundStyle(.red) }
                    Button("恢复这一版本") { confirming = true }.disabled(cloud.busy)
                }
            }
            .font(TypeScale.body).scrollContentBackground(.hidden).background(AppBackground()).foregroundStyle(Ink.ink).tint(Ink.ink)
            .navigationTitle("核对恢复内容").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .confirmationDialog("确认恢复上述学习项目？", isPresented: $confirming) {
                Button("保存本机快照并恢复") { cloud.confirmRestore() }
            } message: { Text("将恢复\(preview.payload.snapshot.threads.count)个对话和\(preview.payload.images.count)张图片。\(preview.payload.isComplete ? "" : "另有\(preview.payload.omittedImages?.count ?? 0)张图未包含。")原云端文件不会改变。") }
        }
    }
}
