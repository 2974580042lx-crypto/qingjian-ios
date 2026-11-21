import QuickLook
import SwiftUI
import UIKit

/// 1:1 Claude V3 single-column file deliverable row.
/// Uses restrained 500 medium typography, neutral row fill, and a soft blue 52×52 document tile.
@MainActor
struct DeliverableFileRow: View {
    let item: ProjectDeliverable
    var swiss: Bool = false
    let open: () -> Void

    private var rowBackground: Color {
        if swiss { return Ink.card }
        return Color.adaptive(light: 0xF6F6F5, dark: 0x202020)
    }

    private var tileBackground: Color {
        if swiss { return Ink.raised }
        return Color.adaptive(light: 0xE6EFF9, dark: 0x6096E6, lightAlpha: 1, darkAlpha: 0.17)
    }

    private var tileGlyph: Color {
        if swiss { return Ink.ink }
        return Color.adaptive(light: 0x1C4D8C, dark: 0x8AB6F9)
    }

    private var titleColor: Color {
        if swiss { return Ink.ink }
        return Color.adaptive(light: 0x1F1F1E, dark: 0xE8E8E6)
    }

    private var subtitleColor: Color {
        if swiss { return Ink.ink3 }
        return Color.adaptive(light: 0x767673, dark: 0x949490)
    }

    var body: some View {
        Button {
            Haptic.tap()
            open()
        } label: {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: swiss ? 0 : 11, style: .continuous)
                    .fill(tileBackground)
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: iconName)
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(tileGlyph)
                    }

                VStack(alignment: .leading, spacing: 2.5) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(titleColor)
                        .lineSpacing(3)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(item.claudeSubtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(subtitleColor)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .padding(.top, 7)
            .padding(.bottom, 7)
            .padding(.leading, 7)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: swiss ? 0 : 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: swiss ? 0 : 16, style: .continuous)
                    .stroke(swiss ? Ink.ink : Ink.line, lineWidth: swiss ? 1 : 0.8)
            )
            .contentShape(RoundedRectangle(cornerRadius: swiss ? 0 : 16, style: .continuous))
        }
        .buttonStyle(.pressFeedback)
        .accessibilityLabel("\(item.title)，\(item.claudeSubtitle)，点击预览或导出")
    }

    private var iconName: String {
        switch item.format {
        case .docx: return "doc.text"
        case .xlsx, .csv: return "tablecells"
        case .pdf: return "doc.richtext"
        case .html: return "globe"
        case .md, .txt: return "doc.plaintext"
        }
    }
}

/// Full-width single-column deliverable list rendered inside the chat transcript
/// between generated images and the AI's final prose.
@MainActor
struct DeliverableFileRowList: View {
    let deliverables: [ProjectDeliverable]
    var swiss: Bool = false
    let open: (ProjectDeliverable) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(deliverables) { item in
                DeliverableFileRow(item: item, swiss: swiss) {
                    open(item)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Native preview, version switcher (v1 → v2 → v3), share/Word/WPS export, and
/// "继续在对话中修改" handoff sheet for any Sermo-created deliverable.
@MainActor
struct DeliverableDetailSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let initialDeliverable: ProjectDeliverable
    var onReviseInChat: ((ProjectDeliverable) -> Void)? = nil

    @State private var selectedID: UUID
    @State private var viewMode: PreviewMode = .preview
    @State private var previewURL: URL?
    @State private var previewReady = false
    @State private var shareURL: URL?
    @State private var reloadToken = UUID()
    @State private var copied = false
    @State private var statusBanner: String?

    enum PreviewMode: String, CaseIterable, Identifiable {
        case preview = "预览"
        case text = "原文"
        var id: String { rawValue }
    }

    init(deliverable: ProjectDeliverable, onReviseInChat: ((ProjectDeliverable) -> Void)? = nil) {
        self.initialDeliverable = deliverable
        self.onReviseInChat = onReviseInChat
        _selectedID = State(initialValue: deliverable.id)
    }

    private var versions: [ProjectDeliverable] {
        let group = store.deliverableVersions(inGroup: initialDeliverable.groupID)
        return group.isEmpty ? [initialDeliverable] : group
    }

    private var activeItem: ProjectDeliverable {
        versions.first { $0.id == selectedID } ?? versions.first ?? initialDeliverable
    }

    private var isBinaryDocument: Bool {
        switch activeItem.format {
        case .docx, .xlsx, .pdf: return true
        case .html, .md, .txt, .csv: return false
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerMetaStrip
                Divider().overlay(Ink.line)
                contentArea
                if onReviseInChat != nil {
                    Divider().overlay(Ink.line)
                    bottomActionBar
                }
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(activeItem.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ClaudeSheetCloseButton(label: "关闭") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $viewMode) {
                        Text(isBinaryDocument ? "文档预览" : "阅读").tag(PreviewMode.preview)
                        Text(activeItem.format == .html ? "源码" : "文字版").tag(PreviewMode.text)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 152)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        saveToFiles()
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 14.5, weight: .regular))
                    }
                    .accessibilityLabel("存储到文件 App")

                    Button {
                        if let url = store.exportableDeliverableURL(for: activeItem) {
                            shareURL = url
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14.5, weight: .regular))
                    }
                    .accessibilityLabel("分享或用 Word / WPS 打开")
                }
            }
        }
        .tint(Ink.ink)
        .onAppear { refreshPreviewURL() }
        .onChange(of: selectedID) { _, _ in
            refreshPreviewURL()
            reloadToken = UUID()
        }
        .onDisappear { cleanupTempPreview() }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            }
        }
    }

    private var headerMetaStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(activeItem.detailedMetaLine)
                    .font(TypeScale.tiny)
                    .foregroundStyle(Ink.ink3)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if versions.count > 1 {
                    Menu {
                        ForEach(versions) { version in
                            Button {
                                selectedID = version.id
                            } label: {
                                let mark = version.id == activeItem.id ? "✓ " : ""
                                Text("\(mark)v\(version.version) · \(version.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("版本 v\(activeItem.version) / 共 \(versions.count) 版")
                                .font(TypeScale.ui(12, weight: .medium))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Ink.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Ink.raised, in: Capsule())
                        .overlay(Capsule().stroke(Ink.line, lineWidth: 0.7))
                    }
                }
            }

            if !activeItem.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(activeItem.summary)
                    .font(TypeScale.caption)
                    .foregroundStyle(Ink.ink2)
                    .lineLimit(2)
            }

            if let statusBanner {
                Text(statusBanner)
                    .font(TypeScale.tiny)
                    .foregroundStyle(Ink.seal)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Ink.paper)
    }

    @ViewBuilder
    private var contentArea: some View {
        if viewMode == .preview {
            switch activeItem.format {
            case .docx, .xlsx, .pdf:
                if let url = previewURL {
                    QuickLookFilePreview(url: url)
                        .id(url.path + "-" + activeItem.id.uuidString)
                        .ignoresSafeArea(edges: .bottom)
                } else if !previewReady {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在准备文档预览…")
                            .font(TypeScale.caption)
                            .foregroundStyle(Ink.ink3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    fallbackTextScroll(title: "暂未能载入系统预览，下方显示已提取的文字版本：", text: activeItem.sourcePreview)
                }
            case .html:
                let html = store.deliverableTextContent(for: activeItem)
                HTMLWebView(html: HTMLPreviewHelper.wrappedHTML(code: html, language: "html"), reloadToken: reloadToken)
                    .ignoresSafeArea(edges: .bottom)
            case .md:
                let text = store.deliverableTextContent(for: activeItem)
                ScrollView {
                    MarkdownAnswer(content: text, style: InterfaceStyle.current, expandsWidth: true)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                }
            case .txt, .csv:
                let text = store.deliverableTextContent(for: activeItem)
                ScrollView {
                    Text(text)
                        .font(.system(size: 14.5, design: activeItem.format == .csv ? .monospaced : .default))
                        .foregroundStyle(Ink.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        } else {
            let raw = isBinaryDocument ? activeItem.sourcePreview : store.deliverableTextContent(for: activeItem)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(activeItem.fileName)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Ink.ink3)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = raw
                            Haptic.tap()
                            copied = true
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 1_400_000_000)
                                copied = false
                            }
                        } label: {
                            Label(copied ? "已复制" : "复制内容", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(TypeScale.tiny.weight(.medium))
                                .foregroundStyle(Ink.ink2)
                        }
                        .buttonStyle(.plain)
                    }
                    if activeItem.format == .html {
                        Text(MarkdownAnswer.highlightedCode(raw, language: "html"))
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(raw.isEmpty ? "（暂无文字预览）" : raw)
                            .font(TypeScale.ui(14.5))
                            .foregroundStyle(Ink.ink)
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
        }
    }

    private func fallbackTextScroll(title: String, text: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(TypeScale.caption)
                    .foregroundStyle(Ink.ink3)
                Text(text.isEmpty ? "（文件本体可能已被移除）" : text)
                    .font(TypeScale.ui(15))
                    .foregroundStyle(Ink.ink)
                    .lineSpacing(5)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private var bottomActionBar: some View {
        HStack(spacing: 10) {
            Button {
                Haptic.tap()
                let chosen = activeItem
                dismiss()
                onReviseInChat?(chosen)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 13.5, weight: .medium))
                    Text("继续在对话中修改此文件")
                        .font(TypeScale.ui(14.5, weight: .medium))
                }
                .foregroundStyle(Ink.onSolid)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Ink.solid, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.pressFeedback)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Ink.paper)
    }

    private func refreshPreviewURL() {
        cleanupTempPreview()
        previewURL = store.exportableDeliverableURL(for: activeItem)
        previewReady = true
    }

    private func saveToFiles() {
        guard let url = store.exportableDeliverableURL(for: activeItem) else {
            statusBanner = "找不到该成果文件，可能已被清理。"
            return
        }
        DocumentPicker.presentExport(
            url,
            onError: { msg in statusBanner = msg },
            onSaved: { _ in
                Haptic.tap()
                statusBanner = "已保存到「文件」：\(activeItem.fileName)"
            }
        )
    }

    private func cleanupTempPreview() {
        guard let previewURL else { return }
        let parent = previewURL.deletingLastPathComponent()
        if parent.path.hasPrefix(FileManager.default.temporaryDirectory.path),
           parent.lastPathComponent.hasPrefix("SermoDeliverablePreview-") {
            try? FileManager.default.removeItem(at: parent)
        }
        self.previewURL = nil
    }
}

/// Embedded iOS native QuickLook preview controller for real `.docx`, `.xlsx`, and `.pdf` deliverables.
@MainActor
struct QuickLookFilePreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            uiViewController.reloadData()
        }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
