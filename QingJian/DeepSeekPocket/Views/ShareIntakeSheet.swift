import SwiftUI
import UIKit

/// Lightweight Claude-style bottom intake card shown when files, images, links, or notes
/// arrive from outside Sermo ("用 Sermo 打开", `sermo://inbox`, or iOS Shortcuts AppIntents).
/// Lets the user choose between attaching to the current chat or filing into a project's SQLite library.
@MainActor
struct ShareIntakeSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let item: ShareIntakeItem
    let onSendToCurrentChat: (ShareIntakeItem) -> Void
    let onDismissCleanup: () -> Void

    @State private var selectedProjectID: UUID?
    @State private var savingToLibrary = false
    @State private var statusError: String?

    private var unlockedProjects: [ChatProject] {
        store.projects.filter { !store.isLocked($0.id) }
    }

    private var supportsProjectLibrary: Bool {
        item.kind != .image && !unlockedProjects.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    previewCard

                    VStack(spacing: 10) {
                        Button {
                            Haptic.tap()
                            dismiss()
                            onSendToCurrentChat(item)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "bubble.left.and.text.bubble.right")
                                    .font(.system(size: 15, weight: .medium))
                                Text("放进当前对话待发送")
                                    .font(TypeScale.ui(15.5, weight: .medium))
                            }
                            .foregroundStyle(Ink.onSolid)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Ink.solid, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.pressFeedback)
                        .disabled(savingToLibrary)

                        if supportsProjectLibrary {
                            libraryImportCard
                        } else if item.kind == .image {
                            Text("图片将作为视觉附件直接放入当前对话的待发送区。")
                                .font(TypeScale.caption)
                                .foregroundStyle(Ink.ink3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }
                    }

                    if let statusError {
                        Text(statusError)
                            .font(TypeScale.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle("收到外部内容")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ClaudeSheetCloseButton(label: "取消") {
                        onDismissCleanup()
                        dismiss()
                    }
                }
            }
        }
        .tint(Ink.ink)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { pickInitialProject() }
    }

    private var previewCard: some View {
        HStack(spacing: 14) {
            if item.kind == .image, let url = item.localFileURL, let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.adaptive(light: 0xE6EFF9, dark: 0x6096E6, lightAlpha: 1, darkAlpha: 0.17))
                    .frame(width: 54, height: 54)
                    .overlay {
                        Image(systemName: iconName)
                            .font(.system(size: 21, weight: .regular))
                            .foregroundStyle(Color.adaptive(light: 0x1C4D8C, dark: 0x8AB6F9))
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(2)
                Text(subtitleText)
                    .font(TypeScale.caption)
                    .foregroundStyle(Ink.ink3)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.adaptive(light: 0xF6F6F5, dark: 0x202020), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Ink.line, lineWidth: 0.8)
        )
    }

    private var libraryImportCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("存入项目百万字检索库", systemImage: "books.vertical")
                    .font(TypeScale.ui(14.5, weight: .medium))
                    .foregroundStyle(Ink.ink)
                Spacer()
                Menu {
                    ForEach(unlockedProjects) { proj in
                        Button {
                            selectedProjectID = proj.id
                        } label: {
                            let mark = proj.id == selectedProjectID ? "✓ " : ""
                            Text("\(mark)\(proj.name)")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedProjectName)
                            .font(TypeScale.ui(13.5, weight: .medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Ink.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Ink.paper, in: Capsule())
                    .overlay(Capsule().stroke(Ink.line, lineWidth: 0.8))
                }
            }

            Text("存入后独立建立全文索引，不占平时聊天上下文，AI 回答时会自动按需检索原句与页码。")
                .font(TypeScale.tiny)
                .foregroundStyle(Ink.ink3)
                .lineSpacing(3)

            Button {
                saveIntoSelectedProjectLibrary()
            } label: {
                HStack(spacing: 8) {
                    if savingToLibrary {
                        ProgressView().tint(Ink.ink)
                    } else {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 14.5, weight: .medium))
                    }
                    Text(savingToLibrary ? "正在解析并建库…" : "存入「\(selectedProjectName)」文献库")
                        .font(TypeScale.ui(14.5, weight: .medium))
                }
                .foregroundStyle(Ink.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Ink.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Ink.line, lineWidth: 0.9))
            }
            .buttonStyle(.pressFeedback)
            .disabled(savingToLibrary || selectedProjectID == nil)
        }
        .padding(14)
        .background(Ink.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Ink.line, lineWidth: 0.7))
    }

    private var iconName: String {
        switch item.kind {
        case .file: return "doc.text"
        case .image: return "photo"
        case .webLink: return "link"
        case .text: return "text.alignleft"
        }
    }

    private var subtitleText: String {
        switch item.kind {
        case .file:
            let ext = item.localFileURL?.pathExtension.uppercased() ?? ""
            return ext.isEmpty ? "外部文档文件" : "外部文档 · \(ext)"
        case .image:
            return "图片附件"
        case .webLink:
            return item.urlString ?? "外部网页链接"
        case .text:
            return (item.bodyText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var selectedProjectName: String {
        if let id = selectedProjectID, let proj = unlockedProjects.first(where: { $0.id == id }) {
            return proj.name
        }
        return unlockedProjects.first?.name ?? "选择项目"
    }

    private func pickInitialProject() {
        if let preferred = item.preferredProjectName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty,
           let matched = unlockedProjects.first(where: { $0.name.localizedCaseInsensitiveContains(preferred) }) {
            selectedProjectID = matched.id
            return
        }
        if let activeID = store.activeThread?.projectID,
           unlockedProjects.contains(where: { $0.id == activeID }) {
            selectedProjectID = activeID
            return
        }
        selectedProjectID = unlockedProjects.first?.id
    }

    private func saveIntoSelectedProjectLibrary() {
        guard let projectID = selectedProjectID, !savingToLibrary else { return }
        savingToLibrary = true
        statusError = nil
        Task { @MainActor in
            defer { savingToLibrary = false }
            do {
                switch item.kind {
                case .file:
                    guard let fileURL = item.localFileURL else {
                        statusError = "找不到已接收的本地文件，请重新分享一次。"
                        return
                    }
                    let res = try await store.importLibraryDocument(projectID: projectID, url: fileURL)
                    onDismissCleanup()
                    store.noticeMessage = "已存入「\(selectedProjectName)」文献库：《\(res.doc.name)》（\(res.doc.characterCount.formatted()) 字，\(res.doc.chunkCount) 段索引）。"
                    dismiss()
                case .text, .webLink:
                    guard let payload = item.libraryTextPayload() else {
                        statusError = "内容为空，无法存入文献库。"
                        return
                    }
                    let doc = try store.importLibraryText(projectID: projectID, name: payload.name, text: payload.text)
                    onDismissCleanup()
                    store.noticeMessage = "已存入「\(selectedProjectName)」文献库：《\(doc.name)》（\(doc.characterCount.formatted()) 字）。"
                    dismiss()
                case .image:
                    statusError = "图片请直接选择「放进当前对话待发送」。"
                }
            } catch {
                statusError = "入库失败：\(error.localizedDescription)"
            }
        }
    }
}
