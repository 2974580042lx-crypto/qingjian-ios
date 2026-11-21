import SwiftUI
import UIKit
import Photos

@MainActor
enum ChatCameraPicker {
    private static var current: Coordinator?

    @discardableResult
    static func present(
        onError: @escaping (String) -> Void,
        picked: @escaping (UIImage) -> Void
    ) -> Bool {
        if let open = current, open.picker?.presentingViewController == nil {
            current = nil
        }
        guard current == nil else {
            onError("相机已打开，请先完成拍摄。")
            return false
        }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            onError("当前设备没有可用相机，请直接选择「照片」。")
            return false
        }
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        var visible = window?.rootViewController
        while let presented = visible?.presentedViewController {
            visible = presented
        }
        guard let presenter = visible,
              presenter.viewIfLoaded?.window != nil,
              !presenter.isBeingPresented,
              !presenter.isBeingDismissed else {
            onError("当前界面正在切换，请稍后再打开相机。")
            return false
        }

        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image"]
        picker.modalPresentationStyle = .fullScreen

        let coordinator = Coordinator(picked: picked)
        coordinator.picker = picker
        picker.delegate = coordinator
        current = coordinator
        presenter.view.endEditing(true)
        presenter.present(picker, animated: true)
        return true
    }

    @MainActor
    private final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let picked: (UIImage) -> Void
        weak var picker: UIImagePickerController?
        private var finished = false

        init(picked: @escaping (UIImage) -> Void) {
            self.picked = picked
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard !finished else { return }
            finished = true
            let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            picker.dismiss(animated: true) {
                ChatCameraPicker.current = nil
                if let image {
                    self.picked(image)
                }
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            guard !finished else { return }
            finished = true
            picker.dismiss(animated: true) {
                ChatCameraPicker.current = nil
            }
        }
    }
}

private struct RecentPhotoItem: Identifiable {
    let id: String
    let asset: PHAsset
    let thumbnail: UIImage
}

/// 1:1 Claude iOS「添加到会话」native bottom Sheet with half & expanded detents.
/// Maps every control to Sermo's real, working capabilities — zero fake empty shells.
@MainActor
struct AddToChatSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let threadID: UUID
    let remainingPhotoSlots: Int
    let showsSystemPromptControl: Bool
    let systemPromptTitle: String
    let onTakeCameraPhoto: () -> Void
    let onPickPhotos: () -> Void
    let onPickFiles: () -> Void
    let onAttachPreparedImage: (Data, UIImage) -> Void
    let onPasteClipboard: () -> Void
    let onOpenSystemPrompt: () -> Void
    let onOpenSettings: () -> Void

    private enum SubPage: Equatable {
        case project
        case permission
        case connectors
        case skills

        var title: String {
            switch self {
            case .project: return "添加到项目"
            case .permission: return "权限"
            case .connectors: return "连接器"
            case .skills: return "Skills · 内置规范"
            }
        }
    }

    @State private var subPage: SubPage? = nil
    @State private var subPageNotice: String? = nil
    @State private var showRecentPhotos = false
    @State private var recentPhotos: [RecentPhotoItem] = []
    @State private var loadingRecent = false
    @State private var inlineHint: String? = nil

    private static let sheetSurface = Color.adaptive(light: 0xF5F5F4, dark: 0x1C1C1C)
    private static let topTileSurface = Color.adaptive(light: 0xEEEEED, dark: 0x2A2A2A)
    private static let claudeBlue = Color.adaptive(light: 0x1E5FAF, dark: 0x6FA6FA)
    private static let toggleTint = Color.adaptive(light: 0x1E62B5, dark: 0x3678DF)
    private static let hairline = Color.adaptive(light: 0x171717, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.075)

    private var currentThread: ChatThread? {
        store.threads.first(where: { $0.id == threadID }) ?? store.activeThread
    }

    private var currentProject: ChatProject? {
        store.project(currentThread?.projectID)
    }

    private var supportsToolsForActiveModel: Bool {
        let provider = store.provider(for: currentThread)
        let settings = store.settings(for: currentThread)
        return ToolCapabilityRegistry.supportsFunctionTools(
            provider: provider,
            colabToolsEnabled: settings.colabOptions.tools,
            compatibleToolsEnabled: store.compatible.configuration.allowsTools
        )
    }

    var body: some View {
        let _ = store.agentRunRevision
        let _ = store.webRoutingRevision
        VStack(spacing: 0) {
            if let page = subPage {
                subHeader(title: page.title)
                ScrollView {
                    subPageContent(for: page)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                }
            } else {
                mainHeader
                ScrollView {
                    mainBody
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                }
            }
        }
        .background(Self.sheetSurface.ignoresSafeArea())
        .presentationDetents([.fraction(0.60), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
    }

    // MARK: - Headers

    private var mainHeader: some View {
        HStack {
            Button {
                Haptic.tap()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Ink.ink)
                    .frame(width: 40, height: 40)
                    .background(Ink.card, in: Circle())
                    .overlay(Circle().stroke(Ink.line, lineWidth: 0.8))
                    .contentShape(Circle())
            }
            .buttonStyle(.pressFeedback)
            .accessibilityLabel("关闭添加到会话")

            Spacer()
            Text("添加到会话")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Ink.ink)
            Spacer()

            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }

    private func subHeader(title: String) -> some View {
        HStack {
            Button {
                Haptic.tap()
                withAnimation(.snappy(duration: 0.2)) {
                    subPage = nil
                    subPageNotice = nil
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("返回")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(Ink.ink)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(Ink.card, in: Capsule())
                .overlay(Capsule().stroke(Ink.line, lineWidth: 0.8))
                .contentShape(Capsule())
            }
            .buttonStyle(.pressFeedback)

            Spacer()
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Ink.ink)
            Spacer()

            Color.clear.frame(width: 66, height: 38)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }

    // MARK: - Main Sheet Content (1:1 Match to Claude iOS Screenshots 3 & 4)

    private var mainBody: some View {
        VStack(spacing: 12) {
            // 1. Top 3 Equal-Width Large Rounded Action Tiles: 相机 | 照片 | 文件
            HStack(spacing: 10) {
                topActionTile(title: "相机", symbol: "camera", id: "chat-add-camera", disabled: remainingPhotoSlots <= 0) {
                    dismissThen(onTakeCameraPhoto)
                }
                topActionTile(title: "照片", symbol: "photo", id: "chat-add-photos", disabled: remainingPhotoSlots <= 0) {
                    dismissThen(onPickPhotos)
                }
                topActionTile(title: "文件", symbol: "arrow.up.doc", id: "chat-add-document", disabled: false) {
                    dismissThen(onPickFiles)
                }
            }

            // 2. Standalone Full-Width Row: 显示最近的照片
            Button {
                Haptic.tap()
                handleRecentPhotosTap()
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(Self.claudeBlue)
                        .frame(width: 22)
                    Text("显示最近的照片")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Self.claudeBlue)
                    Spacer()
                    if loadingRecent {
                        ProgressView().controlSize(.small)
                    } else if showRecentPhotos {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Ink.ink3)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 54)
                .background(Ink.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.pressFeedback)
            .disabled(remainingPhotoSlots <= 0)

            if showRecentPhotos && !recentPhotos.isEmpty {
                recentPhotosStrip
            }

            // 3. Standalone Row: 添加到项目
            standaloneNavRow(
                symbol: "archivebox",
                title: "添加到项目",
                value: currentProject?.name ?? "无"
            ) {
                openSubPage(.project)
            }

            // 4. Standalone Row: 权限
            standaloneNavRow(
                symbol: "forward",
                title: "权限",
                value: store.permissionPolicy(for: threadID).title
            ) {
                openSubPage(.permission)
            }

            // 5. Unified 4-Row Grouped Card: 研究 / 连接器 / Skills / 记忆
            VStack(spacing: 0) {
                researchRow
                groupedDivider
                groupedNavRow(symbol: "square.grid.2x2", title: "连接器") {
                    openSubPage(.connectors)
                }
                groupedDivider
                groupedNavRow(symbol: "text.book.closed", title: "Skills") {
                    openSubPage(.skills)
                }
                groupedDivider
                memoryRow
            }
            .background(Ink.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            if let hint = inlineHint {
                Text(hint)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ink.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }

            // 6. Preserved Sermo quick utilities (Clipboard Paste & System Prompt)
            VStack(spacing: 0) {
                Button {
                    Haptic.tap()
                    dismissThen(onPasteClipboard)
                } label: {
                    HStack(spacing: 13) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(Ink.ink2)
                            .frame(width: 22)
                        Text("从剪贴板粘贴图文")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(Ink.ink)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressFeedback)
                .accessibilityIdentifier("chat-paste-text")

                if showsSystemPromptControl {
                    groupedDivider
                    Button {
                        Haptic.tap()
                        dismissThen(onOpenSystemPrompt)
                    } label: {
                        HStack(spacing: 13) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 17, weight: .regular))
                                .foregroundStyle(Ink.ink2)
                                .frame(width: 22)
                            Text("系统指令")
                                .font(.system(size: 16, weight: .regular))
                                .foregroundStyle(Ink.ink)
                            Spacer()
                            Text(systemPromptTitle)
                                .font(.system(size: 15))
                                .foregroundStyle(Ink.ink3)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Ink.ink3.opacity(0.75))
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 54)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressFeedback)
                    .disabled(store.isGenerating)
                    .accessibilityIdentifier("chat-system-prompt")
                }
            }
            .background(Ink.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func topActionTile(
        title: String,
        symbol: String,
        id: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptic.tap()
            action()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Ink.ink)
                    .frame(height: 26)
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Ink.ink)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 94)
            .background(Self.topTileSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .opacity(disabled ? 0.45 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.pressFeedback)
        .disabled(disabled)
        .accessibilityIdentifier(id)
    }

    private func standaloneNavRow(
        symbol: String,
        title: String,
        value: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptic.tap()
            action()
        } label: {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 17.5, weight: .regular))
                    .foregroundStyle(Ink.ink2)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Ink.ink)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Text(value)
                        .font(.system(size: 15.5, weight: .regular))
                        .foregroundStyle(Ink.ink3)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Ink.ink3.opacity(0.75))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(Ink.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.pressFeedback)
    }

    private var groupedDivider: some View {
        Rectangle()
            .fill(Self.hairline)
            .frame(height: 1)
            .padding(.leading, 52)
            .padding(.trailing, 16)
    }

    private func groupedNavRow(
        symbol: String,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptic.tap()
            action()
        } label: {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Ink.ink2)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Ink.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Ink.ink3.opacity(0.75))
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressFeedback)
    }

    private var researchRow: some View {
        let policy = store.permissionPolicy(for: threadID)
        let researchAvailable = policy != .chatOnly && supportsToolsForActiveModel
        return HStack(spacing: 13) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Ink.ink2)
                .frame(width: 22)
            Text("研究")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(researchAvailable ? Ink.ink : Ink.ink3)
            Spacer()
            Toggle("", isOn: Binding(
                get: { researchAvailable && store.isResearchModeEnabled(for: threadID) },
                set: { newValue in
                    guard researchAvailable else {
                        inlineHint = policy == .chatOnly
                            ? "当前权限为「仅纯聊天」，切回「自动」后即可开启多步研究模式。"
                            : "当前模型未开启工具调用，请在设置中开启工具或切换支持工具的模型。"
                        return
                    }
                    inlineHint = nil
                    store.setResearchMode(newValue, for: threadID)
                }
            ))
            .labelsHidden()
            .tint(Self.toggleTint)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    private var memoryRow: some View {
        let proj = currentProject
        let isStudy = proj?.studySubject != nil
        let isOn: Bool = {
            guard let proj else { return false }
            if proj.studySubject != nil { return true }
            return proj.remembers
        }()
        return HStack(spacing: 13) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Ink.ink2)
                .frame(width: 22)
            Text("记忆")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Ink.ink)
            Spacer()
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { newValue in
                    guard var proj else {
                        subPageNotice = "将当前对话加入一个项目后，即可开启跨对话长期记忆。"
                        openSubPage(.project)
                        return
                    }
                    if isStudy {
                        inlineHint = "学习项目内置长期复习账本，记忆始终保持开启。"
                        return
                    }
                    inlineHint = nil
                    proj.autoMemory = newValue
                    _ = store.updateProject(proj)
                }
            ))
            .labelsHidden()
            .tint(Self.toggleTint)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    private var recentPhotosStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(recentPhotos) { item in
                    Button {
                        Haptic.tap()
                        attachAsset(item.asset)
                    } label: {
                        Image(uiImage: item.thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 68, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(Ink.line, lineWidth: 0.7)
                            )
                    }
                    .buttonStyle(.pressFeedback)
                }

                Button {
                    Haptic.tap()
                    dismissThen(onPickPhotos)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                        Text("更多")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Ink.ink2)
                    .frame(width: 68, height: 68)
                    .background(Self.topTileSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.pressFeedback)
            }
            .padding(12)
        }
        .background(Ink.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Sub-Pages Inside Sheet

    private func openSubPage(_ target: SubPage) {
        withAnimation(.snappy(duration: 0.2)) {
            subPage = target
        }
    }

    @ViewBuilder
    private func subPageContent(for page: SubPage) -> some View {
        switch page {
        case .project:
            projectSubPage
        case .permission:
            permissionSubPage
        case .connectors:
            connectorsSubPage
        case .skills:
            skillsSubPage
        }
    }

    private var projectSubPage: some View {
        let selectedID = currentThread?.projectID
        return VStack(alignment: .leading, spacing: 10) {
            if let notice = subPageNotice {
                Text(notice)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Ink.seal)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)
            }

            VStack(spacing: 0) {
                projectOptionRow(title: "无（留在最近对话）", subtitle: "不关联特定项目资料库", isLocked: false, isSelected: selectedID == nil) {
                    assignToProject(nil)
                }
                ForEach(store.projects) { proj in
                    groupedDivider
                    projectOptionRow(
                        title: proj.name,
                        subtitle: proj.documents.isEmpty ? "项目独立指令与长期记忆" : "含 \(proj.documents.count) 份资料 · 共享长期记忆",
                        isLocked: proj.isLocked && store.isLocked(proj.id),
                        isSelected: selectedID == proj.id
                    ) {
                        assignToProject(proj.id)
                    }
                }
            }
            .background(Ink.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func projectOptionRow(
        title: String,
        subtitle: String,
        isLocked: Bool,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptic.tap()
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isLocked ? "lock" : "folder")
                    .font(.system(size: 16.5))
                    .foregroundStyle(isSelected ? Self.claudeBlue : Ink.ink2)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(Ink.ink)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Ink.ink3)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Self.claudeBlue)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var permissionSubPage: some View {
        let current = store.permissionPolicy(for: threadID)
        return VStack(spacing: 10) {
            ForEach(ToolPermissionPolicy.allCases) { option in
                let selected = (current == option)
                Button {
                    Haptic.tap()
                    store.setPermissionPolicy(option, for: threadID)
                    withAnimation(.snappy(duration: 0.2)) { subPage = nil }
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.title)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Ink.ink)
                            Text(option.subtitle)
                                .font(.system(size: 13))
                                .foregroundStyle(Ink.ink3)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 8)
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(Self.claudeBlue)
                        }
                    }
                    .padding(16)
                    .background(Ink.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.pressFeedback)
            }
        }
    }

    private var connectorsSubPage: some View {
        let activeProvider = store.provider(for: currentThread)
        let currentChannel = WebSearchRouting.channel(for: activeProvider)
        let driveOn = store.effectiveDriveTools(for: currentThread)
        let githubOn = store.effectiveGitHubTools(for: currentThread)
        let webOn = store.effectiveWebTools(for: currentThread)

        return VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                // Google Drive connector
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Google 云盘")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Ink.ink)
                        Text(store.drive.connected ? "已登录 · 支持检索与读取云盘资料" : "未登录谷歌账号")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Ink.ink3)
                    }
                    Spacer()
                    if store.drive.connected {
                        Toggle("", isOn: Binding(
                            get: { driveOn },
                            set: { store.setConnectorEnabled(kind: "drive", enabled: $0, for: threadID) }
                        ))
                        .labelsHidden()
                        .tint(Self.toggleTint)
                    } else {
                        Button("登录") {
                            store.drive.signIn()
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Self.claudeBlue)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)

                groupedDivider

                // GitHub connector
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("GitHub 仓库")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Ink.ink)
                        Text(store.github.connected ? "令牌已配置 · 支持代码查阅与运行状态检查" : "尚未在设置中填写 GitHub 令牌")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Ink.ink3)
                    }
                    Spacer()
                    if store.github.connected {
                        Toggle("", isOn: Binding(
                            get: { githubOn },
                            set: { store.setConnectorEnabled(kind: "github", enabled: $0, for: threadID) }
                        ))
                        .labelsHidden()
                        .tint(Self.toggleTint)
                    } else {
                        Button("去设置") {
                            dismissThen(onOpenSettings)
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Self.claudeBlue)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)

                groupedDivider

                // Web reading & search tools
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("网页读取与联网检索")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Ink.ink)
                        Text("当前通道：\(currentChannel.title)")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Ink.ink3)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { webOn },
                        set: { store.setConnectorEnabled(kind: "web", enabled: $0, for: threadID) }
                    ))
                    .labelsHidden()
                    .tint(Self.toggleTint)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }
            .background(Ink.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text("当前服务（\(activeProvider.title)）联网通道")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Ink.ink3)
                    .padding(.horizontal, 6)

                VStack(spacing: 0) {
                    ForEach(Array(WebSearchChannel.allCases.enumerated()), id: \.element.id) { idx, channel in
                        if idx > 0 { groupedDivider }
                        Button {
                            Haptic.tap()
                            store.setWebSearchChannel(channel, for: activeProvider)
                        } label: {
                            HStack {
                                Text(channel.title)
                                    .font(.system(size: 15.5))
                                    .foregroundStyle(Ink.ink)
                                Spacer()
                                if currentChannel == channel {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Self.claudeBlue)
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 50)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Ink.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private var skillsSubPage: some View {
        let chapters = store.operationManual.chapters
        return VStack(alignment: .leading, spacing: 10) {
            Text("以下为 Sermo 内置的按需操作规范（Skills）。AI 仅在对应场景下按需查阅启用项，不会拖慢日常闲聊。")
                .font(.system(size: 13))
                .foregroundStyle(Ink.ink3)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                    if index > 0 { groupedDivider }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(chapter.title)
                                .font(.system(size: 15.5, weight: .medium))
                                .foregroundStyle(Ink.ink)
                            Text(chapter.whenToRead)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Ink.ink3)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(
                            get: { chapter.isEnabled },
                            set: { store.setManualChapterEnabled($0, id: chapter.id) }
                        ))
                        .labelsHidden()
                        .tint(Self.toggleTint)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .background(Ink.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    // MARK: - Actions & PhotosKit Helpers

    private func dismissThen(_ action: @escaping () -> Void) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            action()
        }
    }

    private func assignToProject(_ projectID: UUID?) {
        let applyMove = {
            if store.canChooseProject && store.activeThreadID == threadID {
                store.chooseProjectForNewChat(projectID)
            } else {
                store.moveThreads([threadID], to: projectID)
            }
            withAnimation(.snappy(duration: 0.2)) {
                subPage = nil
                subPageNotice = nil
            }
        }

        if let projectID, store.isLocked(projectID) {
            Task {
                if await ProjectLock.open(projectID, store: store) {
                    applyMove()
                }
            }
        } else {
            applyMove()
        }
    }

    private func handleRecentPhotosTap() {
        if showRecentPhotos {
            withAnimation(.snappy(duration: 0.2)) { showRecentPhotos = false }
            return
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            Task { await loadRecentPhotosOrFallback() }
        case .notDetermined:
            Task {
                let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                if granted == .authorized || granted == .limited {
                    await loadRecentPhotosOrFallback()
                } else {
                    dismissThen(onPickPhotos)
                }
            }
        default:
            dismissThen(onPickPhotos)
        }
    }

    private func loadRecentPhotosOrFallback() async {
        loadingRecent = true
        defer { loadingRecent = false }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.fetchLimit = 8
        let fetched = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        guard fetched.count > 0 else {
            dismissThen(onPickPhotos)
            return
        }

        var items: [RecentPhotoItem] = []
        let manager = PHImageManager.default()
        let reqOptions = PHImageRequestOptions()
        reqOptions.deliveryMode = .opportunistic
        reqOptions.isSynchronous = false
        reqOptions.isNetworkAccessAllowed = true
        reqOptions.resizeMode = .fast

        for i in 0..<fetched.count {
            let asset = fetched.object(at: i)
            if let thumb = await requestThumbnail(manager: manager, asset: asset, options: reqOptions) {
                items.append(RecentPhotoItem(id: asset.localIdentifier, asset: asset, thumbnail: thumb))
            }
        }

        if items.isEmpty {
            dismissThen(onPickPhotos)
        } else {
            withAnimation(.snappy(duration: 0.2)) {
                recentPhotos = items
                showRecentPhotos = true
            }
        }
    }

    private func requestThumbnail(
        manager: PHImageManager,
        asset: PHAsset,
        options: PHImageRequestOptions
    ) async -> UIImage? {
        let singleShot = PHImageRequestOptions()
        singleShot.deliveryMode = .highQualityFormat
        singleShot.resizeMode = .fast
        singleShot.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            var resumed = false
            manager.requestImage(
                for: asset,
                targetSize: CGSize(width: 180, height: 180),
                contentMode: .aspectFill,
                options: singleShot
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let hasError = info?[PHImageErrorKey] != nil
                guard (!isDegraded || isCancelled || hasError), !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    private func attachAsset(_ asset: PHAsset) {
        guard remainingPhotoSlots > 0 else { return }
        loadingRecent = true
        Task {
            defer { loadingRecent = false }
            let opts = PHImageRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .highQualityFormat
            let rawData: Data? = await withCheckedContinuation { continuation in
                var resumed = false
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: opts) { data, _, _, _ in
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: data)
                }
            }
            guard let rawData,
                  let prepared = try? await Task.detached(priority: .userInitiated, operation: {
                      try ImageStore.prepared(rawData)
                  }).value,
                  let preview = UIImage(data: prepared) else {
                dismissThen(onPickPhotos)
                return
            }
            onAttachPreparedImage(prepared, preview)
            dismiss()
        }
    }
}
