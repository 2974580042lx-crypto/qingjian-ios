import Observation
import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

private func previewFlag(_ names: String...) -> Bool {
    names.contains { ProcessInfo.processInfo.arguments.contains("--preview-" + $0) }
}

@MainActor
struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var profile: ProfileStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Settings, projects and the full list open from the sidebar; there is no tab bar.
    @State private var showSettings = previewFlag("settings", "profile", "usage")
    @State private var showProjects = previewFlag("projects", "project")
    @State private var showAllChats = previewFlag("all-chats")
    @State private var showBooks = previewFlag("books")
    @State private var showSidebar = previewFlag("sidebar")
    @State private var keyboardVisible = false
    @State private var composerPanelHeight: CGFloat = 130
    @AppStorage("qingjian.haptics") private var hapticsEnabled = true
    @AppStorage(AppearanceMode.key) private var appearance = AppearanceMode.system.rawValue

    var body: some View {
        let _ = StyleAppearance.shared.revision
        let isSwiss = InterfaceStyle.isSwiss
        GeometryReader { geometry in
            let bottomInset = geometry.safeAreaInsets.bottom
            let topInset = geometry.safeAreaInsets.top
            let excludedHeight = composerPanelHeight + (keyboardVisible ? 0 : bottomInset + FloatingChrome.navigationHeight)
            SidebarDrawerContainer(
                isOpen: $showSidebar,
                reduceMotion: reduceMotion,
                isSwiss: isSwiss,
                appearanceRaw: appearance,
                styleRevision: StyleAppearance.shared.revision,
                composerExcludedHeight: excludedHeight,
                sidebarBuilder: {
                    HistorySidebar(close: { showSidebar = false },
                                   openSettings: { showSettings = true },
                                   openProjects: { showProjects = true },
                                   openAllChats: { showAllChats = true },
                                   openBooks: { showBooks = true })
                        .environmentObject(store)
                        .environmentObject(profile)
                        .preferredColorScheme(AppearanceMode.scheme(appearance))
                },
                main: NavigationStack {
                    ChatScreen(openHistory: { showSidebar = true },
                               openSettings: { showSettings = true },
                               keyboardVisible: $keyboardVisible,
                               composerPanelHeight: $composerPanelHeight,
                               bottomInset: bottomInset,
                               topInset: topInset,
                               sidebarOpen: showSidebar)
                }
                .tint(Ink.ink)
                .background(AppBackground())
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .environmentObject(store)
                .environmentObject(profile)
                .preferredColorScheme(AppearanceMode.scheme(appearance))
            )
            .ignoresSafeArea()
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .preferredColorScheme(AppearanceMode.scheme(appearance))
        .onChange(of: showSidebar) { _, open in
            if hapticsEnabled { UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.65) }
            if open { store.refreshBalance() }
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store).environmentObject(profile) }
        .sheet(item: Binding(get: { showSettings ? nil : store.unifiedRestorePreview }, set: { store.unifiedRestorePreview = $0 })) { preview in
            UnifiedRestorePreviewSheet(preview: preview)
                .environmentObject(store)
        }
        .sheet(isPresented: $showProjects) {
            ProjectsView(opened: { showProjects = false; showSidebar = false }).environmentObject(store).environmentObject(profile)
        }
        // Route files opened from the Files app / Share sheet: only .sermobackup restores backups;
        // all other files attach silently to the active conversation's pending document strip.
        .onOpenURL { url in
            guard url.isFileURL else { return }
            if IncomingURLRoute.classify(url) == .backup {
                Task {
                    guard let local = await Task.detached(priority: .userInitiated, operation: { IncomingFile.privateCopy(of: url) }).value else {
                        store.errorMessage = "没能读取这个备份文件，请在「文件」里确认它已下载后再试。"
                        return
                    }
                    store.prepareBackupRestore(local, removeWhenDone: true)
                }
                return
            }
            Task { @MainActor in
                guard let local = await Task.detached(priority: .userInitiated, operation: { IncomingFile.privateCopy(of: url) }).value else {
                    store.errorMessage = "没能读取这个文件，请在「文件」里确认它已下载后再试。"
                    return
                }
                store.incomingChatFileURL = local
            }
        }
        .sheet(isPresented: $showBooks) {
            BookshelfView(opened: { showBooks = false; showSidebar = false }).environmentObject(store).environmentObject(store.books)
        }
        .sheet(isPresented: $showAllChats) {
            AllChatsView(opened: { showAllChats = false; showSidebar = false }).environmentObject(store).environmentObject(profile)
        }
        .onChange(of: profile.name) { _, name in store.userName = name }
        .onAppear {
            store.userName = profile.name
            if store.isPreview {
                let result = "QINGJIAN_SONGTI_LOADED=\(UIFont(name: "NotoSerifSC-Regular", size: 18) != nil)\n"
                FileHandle.standardOutput.write(Data(result.utf8))
            }
        }
    }

}

struct PendingImage: Identifiable {
    let id = UUID()
    let data: Data
    let preview: UIImage
}

private struct PendingSuggestedReply {
    let threadID: UUID
    let messageID: UUID
    let text: String
}

private struct InnerThoughtsTarget: Identifiable {
    let threadID: UUID
    let messageID: UUID
    var id: String { "\(threadID.uuidString):\(messageID.uuidString)" }
}

// These panels stay attached to the conversation that opened them.
private struct ConversationPanelTarget: Identifiable {
    let threadID: UUID
    var id: UUID { threadID }
}

// Present from the real visible controller. The composer lives in a separate
// UIHostingController, so attaching a photosPicker to the outer SwiftUI page
// makes its presentation depend on another host and on menu dismissal timing.
@MainActor
enum ChatPhotoPicker {
    private static var current: Coordinator?

    @discardableResult
    static func present(limit: Int, onError: @escaping (String) -> Void,
                        picked: @escaping ([PHPickerResult]) -> Void) -> Bool {
        // A picker that never appeared (or vanished unannounced) must not block the next tap.
        if let open = current, open.picker?.presentingViewController == nil { current = nil }
        guard current == nil else { onError("相册已打开，请先完成当前选择。"); return false }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        var visible = window?.rootViewController
        while let presented = visible?.presentedViewController { visible = presented }
        guard let presenter = visible, presenter.viewIfLoaded?.window != nil,
              !presenter.isBeingPresented, !presenter.isBeingDismissed,
              !(presenter is UIAlertController), !(presenter is UIDocumentPickerViewController),
              !(presenter is PHPickerViewController) else {
            onError("当前界面正在切换，请关闭其他弹窗后再选择图片。")
            return false
        }
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = max(1, min(4, limit))
        config.selection = .ordered
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        let coordinator = Coordinator(picked: picked)
        coordinator.picker = picker
        picker.delegate = coordinator
        picker.modalPresentationStyle = .pageSheet
        picker.presentationController?.delegate = coordinator
        current = coordinator
        presenter.view.endEditing(true)
        presenter.present(picker, animated: true) { picker.presentationController?.delegate = coordinator }
        return true
    }

    static func loadData(_ provider: NSItemProvider) async throws -> Data {
        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else {
            throw ChatError.server("这项内容没有可读取的图片格式。")
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                if let error { continuation.resume(throwing: error); return }
                guard let url else { continuation.resume(throwing: ChatError.server("图片未能下载，请稍后重试。")); return }
                do {
                    // The provider's temporary URL is only valid inside this callback.
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 40 * 1024 * 1024 else { throw ChatError.server("图片超过 40 MB，请选择压缩后的照片或截图。") }
                    let data = try Data(contentsOf: url)
                    guard data.count <= 40 * 1024 * 1024 else { throw ChatError.server("图片超过 40 MB。") }
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    @MainActor private final class Coordinator: NSObject, PHPickerViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
        let picked: ([PHPickerResult]) -> Void
        weak var picker: PHPickerViewController?
        private var finished = false
        init(picked: @escaping ([PHPickerResult]) -> Void) { self.picked = picked }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !finished else { return }
            finished = true
            var delivered = false
            let deliver = {
                guard !delivered else { return }
                delivered = true
                ChatPhotoPicker.current = nil
                self.picked(results)
            }
            picker.dismiss(animated: true, completion: deliver)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: deliver)
        }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            guard !finished else { return }
            finished = true
            ChatPhotoPicker.current = nil
            picked([])
        }
    }
}

@MainActor @Observable
private final class ChatScrollUIState {
    var nearBottom = true
    var showJumpToLatest = false
}

private struct ScrollBottomMetrics: Equatable {
    let nearBottom: Bool
    let showJump: Bool
}

private struct ContextUsageSnapshot {
    let ratio: Double
    let estimatedTokens: Int
    let messageCount: Int
    let cacheHitRate: Int?
}

@MainActor
struct ChatScreen: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var profile: ProfileStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let openHistory: () -> Void
    let openSettings: () -> Void
    @Binding var keyboardVisible: Bool
    @Binding var composerPanelHeight: CGFloat
    let bottomInset: CGFloat
    // The status bar; the chat now runs up behind the floating buttons, so its
    // first line is pushed down by this plus the button row instead.
    let topInset: CGFloat
    let sidebarOpen: Bool
    private var topChrome: CGFloat { topInset + 56 }
    @FocusState private var composerFocused: Bool
    @State private var previewComposerFocused = false
    private var isComposerFocused: Bool { composerFocused || previewComposerFocused }
    private var usesPreviewKeyboard: Bool { store.isPreview && ProcessInfo.processInfo.arguments.contains("--preview-tall-keyboard") }
    private func focusComposer(_ focused: Bool) {
        if usesPreviewKeyboard { previewComposerFocused = focused } else { composerFocused = focused }
    }
    @State private var editedMessage: ChatMessage?
    @State private var editingThreadID: UUID?
    @State private var thinkingTarget: ThinkingTarget?
    @State private var pendingSuggestedReply: PendingSuggestedReply?
    @State private var followsOutput = true
    @State private var scrollUIState = ChatScrollUIState()
    @State private var timeReveal = SwipeTimeRevealModel()
    @State private var cachedContext: ContextUsageSnapshot?
    @State private var choosingFiles = false
    @State private var choosingPhotos = false
    @State private var fileImportTask: Task<Void, Never>?
    @State private var fileImportThreadID: UUID?
    @State private var fileImportProgress = ""
    @State private var photoLoadThreadID: UUID?
    @State private var photoLoadSessionID: UUID?
    @State private var photoLoadTask: Task<Void, Never>?
    @State private var imagesByThread: [UUID: [PendingImage]] = [:]
    @State private var documentsByThread: [UUID: [PendingDocument]] = [:]
    @State private var previewingDocument: DocumentPreviewTarget?
    @State private var attachmentReport: String?
    @State private var attachTrayOpen = false
    private var loadingPhotos: Bool { photoLoadThreadID == store.activeThreadID && photoLoadThreadID != nil }
    private var attachmentBusy: Bool { choosingFiles || choosingPhotos || fileImportThreadID != nil || photoLoadThreadID != nil }
    private var pendingImages: [PendingImage] {
        get {
            guard let thread = store.activeThread, !store.isHidden(thread) else { return [] }
            return imagesByThread[thread.id] ?? []
        }
        nonmutating set {
            guard let id = store.activeThreadID else { return }
            imagesByThread[id] = newValue
        }
    }
    private var pendingDocuments: [PendingDocument] {
        get {
            guard let thread = store.activeThread, !store.isHidden(thread) else { return [] }
            return documentsByThread[thread.id] ?? []
        }
        nonmutating set {
            guard let id = store.activeThreadID else { return }
            documentsByThread[id] = newValue
        }
    }
    @State private var renaming = false
    @State private var renameText = ""
    @State private var exportURL: URL?
    @State private var systemPromptTarget: ConversationPanelTarget?
    @State private var versionsTarget: ConversationPanelTarget?
    @State private var storySettingsFor: UUID?
    @State private var storyPlayFor: UUID?
    @State private var checkpointMessage: UUID?
    @State private var checkpointName = ""
    @State private var bookEvidence: ChatMessage?
    @State private var correctionTarget: ChatMessage?
    @State private var thoughtsTarget: InnerThoughtsTarget?
    @State private var messageBrowser: ChatMessageBrowserRequest?
    @State private var messageBrowserVisible = false
    @State private var pendingMessageJump: ChatMessageJump?
    @State private var focusedMessageID: UUID?
    @State private var quotingMessage: QuotedMessage?
    private var currentLayoutMode: ChatLayoutMode {
        ChatLayoutPreferences.shared.mode(for: store.activeThreadID)
    }
    private var isEmptyPage: Bool { store.activeThread?.messages.isEmpty != false }
    private var composerPlaceholder: String {
        if store.activeThread?.bookDiscussion != nil, let character = store.activeThread?.discussionDraftCharacter {
            return "问\(character)，听听他的想法…"
        }
        if let discussion = store.activeThread?.bookDiscussion { return "聊聊《\(discussion.bookTitle)》…" }
        guard let story = store.activeThread?.story else { return "与 Sermo 对话" }
        return "对\(story.character)说…"
    }
    private var hasInput: Bool {
        !localDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty || !pendingDocuments.isEmpty
    }
    // 猜你想说: after an answer, one suggested reply waits as grey text in the empty
    // composer; send takes it as is, a tap on it puts it in to edit, 「换一条」 cycles.
    @State private var suggestionIndex = 0
    private var ghostSource: ChatMessage? {
        guard !swiss, store.settings.shouldSuggestReplies, store.activeProject?.studySubject == nil,
              !store.isGenerating, let thread = store.activeThread,
              !store.isHidden(thread), let last = thread.messages.last, last.role == .assistant,
              last.state == .complete, let batch = last.replySuggestions, !batch.replies.isEmpty else { return nil }
        return last
    }
    private var ghostReplies: [String] { Array(ghostSource?.replySuggestions?.replies.prefix(3) ?? []) }
    private var ghostText: String? {
        guard !hasInput, !ghostReplies.isEmpty else { return nil }
        return ghostReplies[suggestionIndex % ghostReplies.count]
    }
    private func takeGhost(send: Bool) {
        guard let text = ghostText, let source = ghostSource, let threadID = store.activeThreadID,
              store.useReplySuggestion(text, threadID: threadID, messageID: source.id) else { return }
        clearMessageNavigation()
        followsOutput = true
        if send {
            Haptic.tap()
            if store.send(store.activeDraft, images: []) {
                draftPushTask?.cancel()
                draftPushTask = nil
                localDraft = ""
                lastPushedDraft = ""
                quotingMessage = nil
                focusComposer(false)
            }
        } else {
            focusComposer(true)
        }
    }

    @ViewBuilder private var ghostBar: some View {
        if ghostText != nil, let batch = ghostSource?.replySuggestions {
            HStack(spacing: 8) {
                Text("猜你想说 \(suggestionIndex % ghostReplies.count + 1)/\(ghostReplies.count)")
                    .font(TypeScale.caption).foregroundStyle(Ink.ink3).monospacedDigit()
                if let cost = ReplySuggestionPanel.costLabel(batch) {
                    Text(cost).font(TypeScale.tiny).foregroundStyle(Ink.ink3).monospacedDigit().lineLimit(1)
                }
                Spacer(minLength: 4)
                if ghostReplies.count > 1 {
                    Button {
                        Haptic.tap()
                        withAnimation(.snappy(duration: 0.2)) { suggestionIndex += 1 }
                    } label: {
                        Label("换一条", systemImage: "shuffle").font(TypeScale.label)
                            .foregroundStyle(Ink.seal)
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(Ink.seal.opacity(0.1), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.pressFeedback)
                    .accessibilityLabel("换一条猜你想说")
                }
            }
            .padding(.horizontal, 6)
            .transition(.opacity)
        }
    }
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var visibleMessageCount = 100
    @State private var hasPositionedInitially = false
    @State private var lastAutoScrollAt = Date.distantPast
    private var visibleMessages: [ChatMessage] { Array((store.activeThread?.messages ?? []).suffix(visibleMessageCount)) }
    private var navigationSpace: CGFloat { 0 }
    // Read in body, so switching the look in Settings redraws this page.
    private var style: InterfaceStyle { InterfaceStyle.current }
    private var swiss: Bool { style == .swiss }
    private var night: Bool { style == .night }
    private var shouldFollowOutput: Bool { followsOutput && pendingMessageJump == nil && focusedMessageID == nil }

    // Typing stays in this screen and reaches the store a moment after you pause, so
    // a keystroke no longer redraws the sidebar or re-saves every chat; long messages
    // used to make every key heavier.
    @State private var localDraft = ""
    @State private var draftThreadID: UUID?
    @State private var lastPushedDraft = ""
    @State private var draftPushTask: Task<Void, Never>?
    private var draft: Binding<String> {
        Binding(get: { localDraft }, set: { localDraft = $0; scheduleDraftPush() })
    }
    private func scheduleDraftPush() {
        draftPushTask?.cancel()
        let target = draftThreadID ?? store.activeThreadID
        draftPushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            pushDraft(localDraft, to: target)
        }
    }
    private func pushDraft(_ text: String, to threadID: UUID?) {
        guard let threadID else { return }
        lastPushedDraft = text
        store.setDraft(text, threadID: threadID)
    }
    /// Hands any typing still waiting to the store, before sending or leaving the chat.
    private func flushDraft() {
        draftPushTask?.cancel(); draftPushTask = nil
        guard let threadID = draftThreadID ?? store.activeThreadID, store.draft(of: threadID) != localDraft else { return }
        pushDraft(localDraft, to: threadID)
    }
    private func loadDraft() {
        draftThreadID = store.activeThreadID
        localDraft = store.activeDraft
        lastPushedDraft = localDraft
    }
    private var errorPresented: Binding<Bool> {
        Binding(get: { store.errorMessage != nil && editedMessage == nil },
                set: { if !$0 { store.errorMessage = nil } })
    }

    private func refreshContextStats() {
        guard let thread = store.activeThread, !thread.messages.isEmpty else {
            cachedContext = nil
            return
        }
        let stats = ChatRequest.estimateContextUsage(
            settings: store.activeChatSettings,
            messages: thread.messages
        )
        let lastUsage = thread.messages.last(where: { $0.role == .assistant && $0.usage != nil })?.usage
        let cacheHitRate: Int? = {
            guard let u = lastUsage, u.promptTokens > 0, u.cachedTokens > 0 else { return nil }
            return Int(round(Double(u.cachedTokens) / Double(u.promptTokens) * 100))
        }()
        cachedContext = ContextUsageSnapshot(
            ratio: stats.ratio,
            estimatedTokens: stats.estimatedTokens,
            messageCount: stats.messageCount,
            cacheHitRate: cacheHitRate
        )
    }

    private var transcript: some View {
        ZStack(alignment: .bottom) {
            if isEmptyPage {
                VStack(spacing: 0) {
                    Spacer(minLength: 12)
                    if let discussion = store.activeThread?.bookDiscussion {
                        BookDiscussionWelcome(session: discussion).environmentObject(store).id(store.activeThreadID)
                    } else {
                        WelcomeView(name: profile.name, page: store.activeThreadID ?? UUID(), projectName: store.activeProject?.name)
                            .id(store.activeThreadID)
                    }
                    Spacer(minLength: 12)
                }.padding(.top, topChrome).padding(.bottom, composerPanelHeight)
            } else {
                let rowSpacing: CGFloat = swiss ? 0 : (currentLayoutMode == .imessage ? 16 : (currentLayoutMode == .smart ? 24 : 30))
                ScrollView {
                    VStack(alignment: .leading, spacing: rowSpacing) {
                        if swiss, let thread = store.activeThread {
                            SwissThreadHeader(title: thread.title, date: thread.createdAt,
                                              model: store.pillModelTitle + " / " + store.pillEffortTitle,
                                              rounds: thread.messages.filter { $0.role == .user }.count)
                                .padding(.top, 6)
                        }
                        if (store.activeThread?.messages.count ?? 0) > visibleMessageCount {
                            Button("查看更早消息") {
                                visibleMessageCount += 100
                                scrollPosition.scrollTo(edge: .top)
                            }.font(TypeScale.caption).foregroundStyle(Palette.secondary)
                                .frame(maxWidth: .infinity)
                        }
                        messageRows
                        Color.clear.frame(height: 2)
                    }
                    .scrollTargetLayout()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, swiss ? 20 : Personal.margin).padding(.top, 10).padding(.bottom, 22)
                }
                .accessibilityIdentifier("chat-scroll")
                // Native iOS 26 soft edge blur at both top and bottom so text gently dissolves
                // behind the floating glass toolbar and composer, plus a compact status-bar clock scrim.
                .scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .background(TranscriptLeftSwipePan(enabled: !sidebarOpen, model: timeReveal))
                .overlay(alignment: .top) {
                    ZStack {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                        LinearGradient(
                            stops: [
                                .init(color: Ink.paper.opacity(0.72), location: 0),
                                .init(color: Ink.paper.opacity(0.32), location: 0.55),
                                .init(color: Ink.paper.opacity(0), location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black.opacity(0.82), location: 0.48),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: topInset + 22).allowsHitTesting(false).accessibilityHidden(true)
                }
                .scrollPosition($scrollPosition)
                .contentMargins(.top, topChrome, for: .scrollContent)
                .contentMargins(.top, topChrome, for: .scrollIndicators)
                .contentMargins(.bottom, composerPanelHeight + 18, for: .scrollContent)
                .contentMargins(.bottom, composerPanelHeight + 18, for: .scrollIndicators)
                .scrollDismissesKeyboard(.interactively)
                .onAppear {
                    if !hasPositionedInitially && !store.isPreview {
                        let threadID = store.activeThreadID
                        DispatchQueue.main.async {
                            if store.activeThreadID == threadID && shouldFollowOutput { scrollPosition.scrollTo(edge: .bottom) }
                        }
                    }
                    hasPositionedInitially = true
                }
                .onScrollGeometryChange(for: ScrollBottomMetrics.self) { g in
                    let visibleHeight = max(0, g.containerSize.height - g.contentInsets.top - g.contentInsets.bottom)
                    let distance = g.contentSize.height + g.contentInsets.bottom - g.contentOffset.y - g.containerSize.height
                    let overflows = g.contentSize.height > visibleHeight + 48
                    return ScrollBottomMetrics(nearBottom: distance < 48, showJump: overflows && distance > 160)
                } action: { _, value in
                    if scrollUIState.nearBottom != value.nearBottom { scrollUIState.nearBottom = value.nearBottom }
                    if scrollUIState.showJumpToLatest != value.showJump { scrollUIState.showJumpToLatest = value.showJump }
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting || phase == .decelerating {
                        if timeReveal.offset != 0 { timeReveal.offset = 0 }
                    }
                    if phase == .interacting { followsOutput = false; clearMessageNavigation() }
                    if phase == .idle && scrollUIState.nearBottom && pendingMessageJump == nil && focusedMessageID == nil { followsOutput = true }
                }
                .onChange(of: store.activeThread?.messages.count) { _, _ in
                    // Straight to the new message: a glide here, on top of the list's own
                    // update, left a ghost of the text while sending.
                    guard shouldFollowOutput else { return }
                    lastAutoScrollAt = Date()
                    scrollPosition.scrollTo(edge: .bottom)
                }
                .onChange(of: store.activeThread?.messages.last?.content) { _, _ in
                    followLiveText()
                }
                .onChange(of: store.activeThread?.messages.last?.replySuggestions) { _, _ in
                    if shouldFollowOutput { scrollPosition.scrollTo(edge: .bottom) }
                }
            }

            ChatFloatingControlsOverlay(
                scrollUIState: scrollUIState,
                hasMessages: !isEmptyPage,
                canChooseProject: store.canChooseProject,
                projectMenu: { projectPill },
                jumpToLatest: jumpToLatest
            )
            .padding(.horizontal, 14)
            .padding(.bottom, composerPanelHeight + 10)
        }
    }

    var body: some View { chatWithAlerts }

    // Separate opaque view expressions keep type checking bounded. State remains
    // on ChatScreen, and the transcript preference stays inside its hosting tree.
    private var chatLayout: some View {
        KeyboardChatLayout {
            transcript.environmentObject(store).environmentObject(profile)
        } composer: {
            composer.fixedSize(horizontal: false, vertical: true)
                .environmentObject(store).environmentObject(profile)
        }
        // Up under the status bar and the glass buttons: before, the chat began below
        // the bar, so text could never pass behind the buttons and stopped at a band.
        .ignoresSafeArea(.container, edges: .top)
    }

    private var chatWithNavigation: some View {
        chatLayout
        .background(AppBackground())
        .navigationTitle("Sermo")
        .navigationBarTitleDisplayMode(.inline)
        // No title in the bar: only the floating glass buttons, as in the Claude app.
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { focusComposer(false); openHistory() } label: { SidebarGlyph() }
                    .accessibilityLabel("打开历史对话")
            }
            ToolbarItem(placement: .principal) {
                if let thread = store.activeThread, thread.story != nil { StoryDirectionMenu(threadID: thread.id) }
                else if night { MoonDisc(size: 22, glow: store.isGenerating).accessibilityLabel("Sermo") }
            }
            // Like the Claude app: no title in the bar, only the two glass controls.
            // In a conversation the right one holds new-page and a "⋯" menu with the title.
            ToolbarItemGroup(placement: .topBarTrailing) {
                // A new page stays in the project you are in.
                Button { store.createThread(in: store.activeThread?.projectID); followsOutput = true } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 16, weight: .regular))
                }
                    .accessibilityLabel("新建对话")
                if !isEmptyPage || store.activeThread?.bookDiscussion != nil { titleMenu }
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
    }

    private var chatWithConversationActions: some View {
        chatWithNavigation
        .alert("重命名对话", isPresented: $renaming) {
            TextField("对话名称", text: $renameText)
            Button("取消", role: .cancel) { }
            Button("保存") { if let id = store.activeThreadID { store.renameThread(id, title: renameText) } }
        }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } }), onDismiss: {
            if let url = exportURL, url.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                try? FileManager.default.removeItem(at: url)
            }
            exportURL = nil
        }) {
            if let url = exportURL { ShareSheet(items: [url]) }
        }
    }

    private var chatWithPromptAndVersionSheets: some View {
        chatWithConversationActions
        .sheet(item: $systemPromptTarget) { target in
            SystemPromptPickerSheet(threadID: target.threadID).environmentObject(store)
        }
        .sheet(item: $versionsTarget) { target in
            ConversationVersionsSheet(threadID: target.threadID).environmentObject(store)
        }
    }

    private var chatWithMessageSheets: some View {
        chatWithPromptAndVersionSheets
        .onChange(of: isComposerFocused) { _, focused in
            keyboardVisible = focused
            if timeReveal.offset != 0 { timeReveal.offset = 0 }
            if focused && shouldFollowOutput { scrollPosition.scrollTo(edge: .bottom) }
        }
        .onChange(of: sidebarOpen) { _, open in
            if open && timeReveal.offset != 0 { timeReveal.offset = 0 }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            if timeReveal.offset != 0 { timeReveal.offset = 0 }
        }
        .onAppear {
            loadDraft()
            refreshContextStats()
            if let incoming = store.incomingChatFileURL, let origin = store.activeThreadID ?? store.threads.first?.id {
                store.incomingChatFileURL = nil
                importDocuments([incoming], into: origin, removeAfterImport: true)
            }
        }
        .onChange(of: store.activeThread?.messages.count) { _, _ in refreshContextStats() }
        .onChange(of: store.isGenerating) { _, generating in if !generating { refreshContextStats() } }
        .onChange(of: store.compactingThreadID) { _, _ in refreshContextStats() }
        .onChange(of: store.activeChatSettings) { _, _ in refreshContextStats() }
        .onChange(of: store.incomingChatFileURL) { _, incoming in
            guard let incoming, let origin = store.activeThreadID ?? store.threads.first?.id else { return }
            store.incomingChatFileURL = nil
            importDocuments([incoming], into: origin, removeAfterImport: true)
        }
        .onDisappear { flushDraft() }
        // Something else changed the draft (a suggestion put in, a file read in, a send
        // clearing it): show that, but not the echo of our own typing coming back.
        .onChange(of: store.activeDraft) { _, new in
            if new != localDraft && new != lastPushedDraft { localDraft = new; lastPushedDraft = new }
        }
        .onChange(of: store.activeThreadID) { _, newID in
            // Typing still waiting belongs to the chat you were in.
            draftPushTask?.cancel(); draftPushTask = nil
            if let old = draftThreadID, old != newID, store.draft(of: old) != localDraft { store.setDraft(localDraft, threadID: old) }
            loadDraft()
            refreshContextStats()
            store.speech.stop()
            systemPromptTarget = nil; versionsTarget = nil
            messageBrowser = nil; clearMessageNavigation()
            store.webSearchEnabled = false
            storyPlayFor = nil; pendingSuggestedReply = nil
            quotingMessage = nil
            if timeReveal.offset != 0 { timeReveal.offset = 0 }
            visibleMessageCount = 100; followsOutput = true
            scrollUIState.nearBottom = true
            scrollUIState.showJumpToLatest = false
            DispatchQueue.main.async {
                if store.activeThreadID == newID && shouldFollowOutput { scrollPosition.scrollTo(edge: .bottom) }
            }
        }
        .onDisappear { keyboardVisible = false }
        .sheet(item: $messageBrowser, onDismiss: {
            messageBrowserVisible = false
            finishMessageJump()
        }) { request in
            ChatMessageBrowser(request: request) { messageID in
                prepareMessageJump(messageID, in: request.threadID)
            }.environmentObject(store)
        }
        .sheet(item: $editedMessage, onDismiss: finishMessageEditing) { message in EditMessageView(message: message) }
    }

    private var chatWithStorySheets: some View {
        chatWithMessageSheets
        .sheet(item: $thoughtsTarget) { target in
            InnerThoughtsSheet(threadID: target.threadID, messageID: target.messageID).environmentObject(store)
        }
        .sheet(item: $correctionTarget) { message in
            if let id = store.activeThreadID { StoryCorrectionSheet(threadID: id, answer: message.content).environmentObject(store) }
        }
        .sheet(isPresented: Binding(get: { storySettingsFor != nil }, set: { if !$0 { storySettingsFor = nil } })) {
            if let id = storySettingsFor { StorySettingsSheet(threadID: id).environmentObject(store) }
        }
        .sheet(isPresented: Binding(get: { storyPlayFor != nil }, set: { if !$0 { storyPlayFor = nil } })) {
            if let id = storyPlayFor { StoryPlaySheet(threadID: id).environmentObject(store) }
        }
        .alert("保存剧情存档", isPresented: Binding(get: { checkpointMessage != nil }, set: { if !$0 { checkpointMessage = nil } })) {
            TextField("名称，例如：赴宴之前", text: $checkpointName)
            Button("取消", role: .cancel) { checkpointMessage = nil }
            Button("保存") {
                if let id = store.activeThreadID { _ = store.saveStoryCheckpoint(threadID: id, through: checkpointMessage, name: checkpointName) }
                checkpointMessage = nil; checkpointName = ""
            }
        }
        .sheet(item: $bookEvidence) { message in
            BookReferencesView(references: message.bookReferences ?? []).environmentObject(store).environmentObject(store.books)
        }
    }

    private var chatWithToolSheets: some View {
        chatWithStorySheets
        .sheet(item: $thinkingTarget) { target in ThinkingSheet(target: target).environmentObject(store) }
        .alert("替换输入框里的文字？", isPresented: Binding(
            get: { pendingSuggestedReply != nil },
            set: { if !$0 { pendingSuggestedReply = nil } })) {
            Button("取消", role: .cancel) { pendingSuggestedReply = nil }
            Button("替换") {
                if let selection = pendingSuggestedReply { applySuggestedReply(selection) }
                pendingSuggestedReply = nil
            }
        } message: { Text("你已经写了些内容。替换后仍可以编辑，再自己发送。") }
    }

    private var chatWithInput: some View {
        chatWithToolSheets
        .alert("附件处理结果", isPresented: Binding(get: { attachmentReport != nil }, set: { if !$0 { attachmentReport = nil } })) {
            Button("知道了") { attachmentReport = nil }
        } message: { Text(attachmentReport ?? "") }
    }

    private var chatWithAlerts: some View {
        chatWithInput
        .alert("暂时没有完成", isPresented: errorPresented) {
            Button("知道了") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--preview-multiline-keyboard") {
                store.setDraft("第一行输入\n第二行输入\n第三行输入\n第四行输入\n第五行输入\n第六行输入")
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-keyboard") || ProcessInfo.processInfo.arguments.contains("--preview-multiline-keyboard") {
                try? await Task.sleep(nanoseconds: 350_000_000)
                focusComposer(true)
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-edit") {
                editedMessage = store.activeThread?.messages.last
            }
            if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--preview-reasoning") }),
               let threadID = store.activeThreadID, let last = store.activeThread?.messages.last {
                try? await Task.sleep(nanoseconds: 400_000_000)
                thinkingTarget = ThinkingTarget(threadID: threadID, messageID: last.id)
            }
        }
    }

    // Kept out of body so the compiler can type-check the page in reasonable time.
    private var messageRows: some View {
        let lastID = store.activeThread?.messages.last?.id, threadID = store.activeThreadID
        let rounds = Self.roundNumbers(store.activeThread?.messages ?? [])
        let look = self.style
        let layout = self.currentLayoutMode
        let visible = visibleMessages
        return ForEach(Array(visible.enumerated()), id: \.element.id) { index, message in
            let prev: ChatMessage? = index > 0 ? visible[index - 1] : nil
            let showDivider = !swiss && MessageTimeDivider.shouldShow(previous: prev, current: message)
            VStack(alignment: .leading, spacing: layout == .imessage ? 10 : 14) {
                if showDivider {
                    Text(MessageTimeDivider.label(message.createdAt))
                        .font(TypeScale.tiny)
                        .foregroundStyle(Ink.ink3.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .padding(.top, index == 0 ? 0 : 6)
                        .padding(.bottom, 2)
                }
                // Equatable: only the message that changed redraws while an answer streams.
                messageRow(message, threadID: threadID, isLast: message.id == lastID,
                           round: rounds[message.id] ?? 1, style: look, layoutMode: layout)
                    .overlay(alignment: .leading) {
                        if focusedMessageID == message.id {
                            RoundedRectangle(cornerRadius: 2).fill(Ink.seal.opacity(0.7)).frame(width: 3).padding(.leading, -10)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
            }
            .id(message.id)
        }
    }

    private func openMessageBrowser(_ mode: ChatMessageBrowserMode) {
        guard let thread = store.activeThread, !store.isHidden(thread) else { return }
        focusComposer(false)
        messageBrowserVisible = true
        messageBrowser = ChatMessageBrowserRequest(threadID: thread.id, mode: mode)
    }
    private func prepareMessageJump(_ messageID: UUID, in threadID: UUID) {
        guard let thread = store.activeThread, thread.id == threadID, !store.isHidden(thread),
              let index = thread.messages.firstIndex(where: { $0.id == messageID }) else { return }
        focusComposer(false); followsOutput = false
        focusedMessageID = nil
        pendingMessageJump = ChatMessageJump(threadID: threadID, messageID: messageID)
        // Render the target even when it is older than the default last 100 messages.
        visibleMessageCount = max(visibleMessageCount, thread.messages.count - index)
        messageBrowser = nil
    }
    private func finishMessageJump() {
        guard !messageBrowserVisible, messageBrowser == nil, let request = pendingMessageJump else { return }
        DispatchQueue.main.async {
            guard pendingMessageJump?.id == request.id, let thread = store.activeThread,
                  thread.id == request.threadID, !store.isHidden(thread),
                  thread.messages.contains(where: { $0.id == request.messageID }) else { return }
            followsOutput = false
            focusedMessageID = request.messageID
            scrollPosition.scrollTo(id: request.messageID, anchor: .top)
            pendingMessageJump = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                if focusedMessageID == request.messageID && store.activeThreadID == request.threadID {
                    scrollPosition.scrollTo(id: request.messageID, anchor: .top)
                }
            }
        }
    }
    private func clearMessageNavigation() {
        pendingMessageJump = nil; focusedMessageID = nil
    }

    /// Exchange numbers: each message of yours starts a new one, the answers after it share it.
    static func roundNumbers(_ messages: [ChatMessage]) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        var round = 0
        for message in messages {
            if message.role == .user { round += 1 }
            result[message.id] = max(round, 1)
        }
        return result
    }

    @ViewBuilder private func messageRow(_ message: ChatMessage, threadID: UUID?, isLast: Bool, round: Int, style: InterfaceStyle, layoutMode: ChatLayoutMode) -> some View {
        let timestamp: Date? = message.directive == nil ? message.createdAt : nil
        SwipeTimestampRow(timeReveal: timeReveal, timestamp: timestamp) {
            if message.state == .streaming {
                // The answer being written redraws on its own, without the rest of the page.
                LiveMessageRow(live: store.live, message: message, onGrow: followLiveText) { shown in
                    messageBody(shown, threadID: threadID, isLast: isLast, round: round, style: style, layoutMode: layoutMode)
                }
            } else {
                messageBody(message, threadID: threadID, isLast: isLast, round: round, style: style, layoutMode: layoutMode)
            }
        }
    }

    private func messageBody(_ message: ChatMessage, threadID: UUID?, isLast: Bool, round: Int, style: InterfaceStyle, layoutMode: ChatLayoutMode) -> some View {
        var markOff: (() -> Void)?
        var thoughts: (() -> Void)?
        var checkpoint: (() -> Void)?
        if store.activeThread?.story != nil && message.state == .complete {
            checkpoint = { checkpointName = ""; checkpointMessage = message.id }
        }
        if store.activeThread?.story != nil && message.role == .assistant && message.directive == nil {
            markOff = { correctionTarget = message }
        }
        if message.role == .assistant, message.state == .complete, message.directive == nil,
           !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let threadID {
            thoughts = {
                guard let thread = store.threads.first(where: { $0.id == threadID }), !store.isHidden(thread),
                      thread.messages.contains(where: { $0.id == message.id }) else { return }
                focusComposer(false)
                thoughtsTarget = InnerThoughtsTarget(threadID: threadID, messageID: message.id)
            }
        }
        let quoteHandler: (() -> Void)? = message.directive == nil && message.state != .streaming ? {
            let author = message.role == .user ? "你" : (message.discussionCharacter ?? "Sermo")
            let excerpt = MessageQuoteCodec.cleanExcerpt(
                from: message.content,
                hasImages: message.images?.isEmpty == false
            )
            quotingMessage = QuotedMessage(author: author, excerpt: excerpt)
            Haptic.tap()
            focusComposer(true)
        } : nil
        return MessageView(message: message, threadID: threadID, isLast: isLast,
                    isGenerating: store.isGenerating, canRegenerate: store.canChat,
                    showsSuggestions: store.settings.shouldSuggestReplies && store.activeProject?.studySubject == nil,
                    edit: { focusComposer(false); editingThreadID = threadID; editedMessage = message },
                    regenerate: regeneratePreservingDraftImages,
                    openThinking: { if let threadID { thinkingTarget = ThinkingTarget(threadID: threadID, messageID: message.id) } },
                    useSuggestedReply: { text in prepareSuggestedReply(text, messageID: message.id) },
                    signInDrive: { store.drive.signIn() }, round: round, style: style, layoutMode: layoutMode,
                    quoteReply: quoteHandler,
                    markOffCharacter: markOff, showThoughts: thoughts, saveCheckpoint: checkpoint, showBookReferences: { bookEvidence = message },
                    speech: store.speech,
                    toggleBookmark: {
                        guard let thread = store.activeThread, thread.id == threadID, !store.isHidden(thread) else { return }
                        store.toggleBookmark(threadID: thread.id, messageID: message.id)
                    }, retryColab: {
                        if let threadID { store.retryColabWithDeepSeek(threadID: threadID, messageID: message.id) }
                    })
            .equatable()
    }

    private func followLiveText() {
        guard shouldFollowOutput && store.generatingThreadID == store.activeThreadID else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAutoScrollAt) >= 0.18 else { return }
        lastAutoScrollAt = now
        scrollPosition.scrollTo(edge: .bottom)
    }

    private func regeneratePreservingDraftImages() {
        let origin = store.activeThreadID
        store.regenerate()
        carryDraftImagesToNewVersion(from: origin)
    }

    private func finishMessageEditing() {
        let origin = editingThreadID
        editingThreadID = nil
        carryDraftImagesToNewVersion(from: origin)
    }

    private func carryDraftImagesToNewVersion(from origin: UUID?) {
        guard let origin, let current = store.activeThread, current.id != origin,
              current.parentThreadID == origin, !store.isHidden(current),
              imagesByThread[current.id]?.isEmpty != false,
              let images = imagesByThread[origin], !images.isEmpty else { return }
        // A retry/edit creates a new path. Manual version selection never calls this.
        imagesByThread[current.id] = images
    }

    private func prepareSuggestedReply(_ text: String, messageID: UUID) {
        guard let threadID = store.activeThreadID else { return }
        let selection = PendingSuggestedReply(threadID: threadID, messageID: messageID, text: text)
        if !localDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && localDraft != text {
            pendingSuggestedReply = selection
        } else { applySuggestedReply(selection) }
    }

    private func applySuggestedReply(_ selection: PendingSuggestedReply) {
        if store.useReplySuggestion(selection.text, threadID: selection.threadID, messageID: selection.messageID) {
            clearMessageNavigation()
            followsOutput = true
            focusComposer(true)
        }
    }

    // "⋯" for the open conversation. Its title (and project) head the menu.
    // A folder button while the page has no project, the project's name once it has
    // one. Locked projects ask for Face ID first. The pick is remembered for new chats.
    private var projectPill: some View {
        let current = store.activeProject
        return Menu {
            Picker("项目", selection: Binding(get: { store.activeThread?.projectID }, set: { chooseProject($0) })) {
                Label("无项目", systemImage: "bubble.left").tag(UUID?.none)
                ForEach(store.projects) { project in
                    Label(project.name, systemImage: project.isLocked ? "lock" : "folder").tag(Optional(project.id))
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: current == nil ? "folder" : "folder.fill").font(.system(size: 14))
                if let name = current?.name {
                    // As wide as the name: a max-width frame stretched "11" to a long bar.
                    Text(name.count > 8 ? String(name.prefix(7)) + "…" : name).lineLimit(1).fixedSize()
                }
            }
            .font(swiss ? TypeScale.mono(11) : TypeScale.serif(15))
            .foregroundStyle(current == nil ? Ink.ink2 : Ink.ink)
            .padding(.horizontal, current == nil ? 0 : 14)
            .frame(minWidth: 44, minHeight: 44)
            .floatingGlass(in: current == nil ? AnyShape(Circle()) : AnyShape(Capsule()))
            .contentShape(Rectangle())
        }
        .disabled(!store.canPersist)
        .accessibilityLabel("选择项目")
        .accessibilityValue(current?.name ?? "无项目")
        .accessibilityIdentifier("project-pill")
    }

    private func chooseProject(_ id: UUID?) {
        guard let id, store.isLocked(id) else { store.chooseProjectForNewChat(id); return }
        Task { if await ProjectLock.open(id, store: store) { store.chooseProjectForNewChat(id) } }
    }

    private var titleMenu: some View {
        Menu {
            if let thread = store.activeThread {
                Text(store.activeProject.map { thread.title + " · " + $0.name } ?? thread.title)
                if let story = thread.story {
                    Text("书架 ·《\(story.bookTitle)》" + (story.userRole.isEmpty ? "" : " · 你是\(story.userRole)"))
                }
                if let discussion = thread.bookDiscussion {
                    Text("讨论 ·《\(discussion.bookTitle)》")
                    Button("新建本书讨论", systemImage: "plus.bubble") { _ = store.startBookDiscussion(discussion.bookID) }
                }
                Divider()
                if !swiss {
                    Menu("排版样式 · \(currentLayoutMode.title)", systemImage: currentLayoutMode.symbol) {
                        ForEach(ChatLayoutMode.allCases) { mode in
                            Button {
                                Haptic.tap()
                                withAnimation(.snappy(duration: 0.24)) {
                                    ChatLayoutPreferences.shared.setMode(mode, for: thread.id)
                                }
                            } label: {
                                Label {
                                    VStack(alignment: .leading) {
                                        Text(mode.title)
                                        Text(mode.summary)
                                    }
                                } icon: {
                                    Image(systemName: currentLayoutMode == mode ? "checkmark" : mode.symbol)
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("chat-layout-mode-menu")
                }
                Button("搜索本对话", systemImage: "magnifyingglass") { openMessageBrowser(.search) }
                Button("本对话收藏", systemImage: "bookmark") { openMessageBrowser(.bookmarks) }
                let versionCount = store.conversationVersions(for: thread.id).count
                if versionCount > 1 {
                    Button("旧答案 · \(versionCount) 个版本", systemImage: "clock.arrow.circlepath") {
                        focusComposer(false)
                        versionsTarget = ConversationPanelTarget(threadID: thread.id)
                    }
                    .accessibilityLabel("查看旧答案和历史版本")
                    .accessibilityIdentifier("chat-versions")
                }
                if thread.messages.count >= 6 {
                    Button("浓缩本对话上文（/compact）", systemImage: "arrow.down.right.and.arrow.up.left") {
                        store.compactActiveThread()
                    }
                    .disabled(store.isGenerating || store.compactingThreadID != nil)
                }
                if thread.projectID != nil {
                    Button("Auto-Dream 整理项目记忆", systemImage: "moon.stars") {
                        store.dreamConsolidateActiveProject()
                    }
                    .disabled(store.isGenerating || store.memorizingProjectID != nil)
                }
                if thread.story != nil {
                    Button("剧情控制、记忆与存档", systemImage: "arrow.triangle.branch") { storyPlayFor = thread.id }
                    Button("本局设定", systemImage: "slider.horizontal.3") { storySettingsFor = thread.id }
                }
                if thread.story == nil, thread.bookDiscussion == nil,
                   store.canUsePureRoleplay(store.activeProject) {
                    Toggle(isOn: Binding(
                        get: { store.isPureRoleplay(thread) },
                        set: { store.setPureRoleplay($0, for: thread.id) }
                    )) {
                        Label("纯角色扮演模式", systemImage: "theatermasks")
                    }
                }
                Button("重命名", systemImage: "pencil") { renameText = thread.title; renaming = true }
                Button(thread.isPinned == true ? "取消置顶" : "置顶", systemImage: "pin") { store.togglePinned(thread.id) }
                Menu("移到项目", systemImage: "folder") {
                    ForEach(store.projects.filter { !store.isLocked($0.id) }) { project in
                        Button(project.name) { store.moveThreads([thread.id], to: project.id) }
                            .disabled(project.id == thread.projectID)
                    }
                    if thread.projectID != nil {
                        Button("移出项目", systemImage: "tray.and.arrow.up") { store.moveThreads([thread.id], to: nil) }
                    }
                }.disabled(store.projects.isEmpty && thread.projectID == nil)
                Button("导出为 Markdown", systemImage: "square.and.arrow.up") {
                    exportURL = store.exportConversation(thread.id, userName: profile.name)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("对话选项")
        .accessibilityIdentifier("chat-title-menu")
    }

    // The model pill: a capsule on paper, a plain monospaced FLASH / HIGH ▾ in the Swiss look.
    @ViewBuilder private var modelPillLabel: some View {
        if swiss {
            Text((store.pillModelTitle + " / " + store.pillEffortTitle).uppercased() + " ▾")
                .font(TypeScale.mono(11)).foregroundStyle(Ink.ink).lineLimit(1)
                .frame(height: 38).contentShape(Rectangle())
        } else {
            HStack(spacing: 5) {
                Text(store.pillModelTitle).fontWeight(.medium).foregroundStyle(Ink.ink).lineLimit(1)
                Text(store.pillEffortTitle).fontWeight(.regular).foregroundStyle(Ink.ink3)
            }
            // A soft neutral capsule matching Claude iOS ("Opus 5.5 中等").
            .font(.system(size: 13.5)).monospacedDigit()
            .padding(.horizontal, 12).frame(height: 34)
            .background(Ink.raised, in: Capsule())
            .contentShape(Capsule())
        }
    }

    // The web switch: a slim muted globe beside the model pill, brightening when enabled.
    @ViewBuilder private var webToggleLabel: some View {
        if swiss {
            Text(store.webSearchEnabled ? "WEB: ON" : "WEB: OFF")
                .font(TypeScale.mono(11))
                .foregroundStyle(store.webSearchEnabled ? Ink.seal : Ink.ink3)
                .frame(minWidth: 34, minHeight: 34).contentShape(Rectangle())
        } else {
            HStack(spacing: 4) {
                Image(systemName: "globe").font(.system(size: 15.5, weight: .light))
                if store.webSearchEnabled { Text("联网").font(.system(size: 13, weight: .medium)) }
            }
            .foregroundStyle(store.webSearchEnabled ? Ink.seal : Ink.ink3)
            .frame(minWidth: 34, minHeight: 34)
            .contentShape(Rectangle())
        }
    }

    private func jumpToLatest() {
        clearMessageNavigation()
        followsOutput = true
        withAnimation(.easeOut(duration: 0.2)) { scrollPosition.scrollTo(edge: .bottom) }
    }

    private func choosePhotos() {
        guard !attachmentBusy, store.canPersist, let thread = store.activeThread, !store.isHidden(thread) else { return }
        let origin = thread.id
        let remaining = 4 - (imagesByThread[origin]?.count ?? 0)
        guard remaining > 0 else { attachmentReport = "一次最多添加 4 张图片。"; return }
        focusComposer(false)
        choosingPhotos = true
        let shown = ChatPhotoPicker.present(limit: remaining, onError: { issue in
            choosingPhotos = false; attachmentReport = issue
        }) { results in
            choosingPhotos = false
            guard !results.isEmpty else { return }
            let session = UUID()
            photoLoadSessionID = session
            photoLoadThreadID = origin
            photoLoadTask = Task { @MainActor in
                defer {
                    if photoLoadSessionID == session {
                        photoLoadThreadID = nil; photoLoadSessionID = nil; photoLoadTask = nil
                    }
                }
                var added = 0, failures = 0
                for result in results {
                    guard !Task.isCancelled, photoLoadSessionID == session else { return }
                    guard let current = store.threads.first(where: { $0.id == origin }), !store.isHidden(current) else {
                        attachmentReport = "原对话已删除或上锁，图片没有加入其他对话。"
                        return
                    }
                    guard (imagesByThread[origin]?.count ?? 0) < 4 else { break }
                    do {
                        let raw = try await ChatPhotoPicker.loadData(result.itemProvider)
                        try Task.checkCancellation()
                        guard photoLoadSessionID == session else { return }
                        let prepared = try await Task.detached(priority: .userInitiated) { try ImageStore.prepared(raw) }.value
                        try Task.checkCancellation()
                        guard photoLoadSessionID == session else { return }
                        guard let current = store.threads.first(where: { $0.id == origin }), !store.isHidden(current) else {
                            attachmentReport = "原对话已删除或上锁，图片没有加入其他对话。"
                            return
                        }
                        guard let preview = UIImage(data: prepared) else { failures += 1; continue }
                        imagesByThread[origin, default: []].append(PendingImage(data: prepared, preview: preview))
                        added += 1
                    } catch is CancellationError { return }
                    catch { failures += 1 }
                }
                guard !Task.isCancelled, photoLoadSessionID == session else { return }
                if failures > 0 {
                    attachmentReport = "已添加 \(added) 张图片，\(failures) 张未能读取。请确认云端照片已下载，或换一张普通照片/截图。"
                } else if origin != store.activeThreadID {
                    attachmentReport = "\(added) 张图片已加入原来对话的待发送区，切回即可查看。"
                }
            }
        }
        if !shown { choosingPhotos = false }
    }

    private func cancelPhotoImport() {
        photoLoadTask?.cancel()
        // Providers may finish a cloud download after cancellation. A new session
        // can start immediately; the old task cannot append images or clear it.
        photoLoadSessionID = nil
        photoLoadThreadID = nil
        photoLoadTask = nil
    }

    private func chooseDocuments() {
        guard !attachmentBusy, store.canPersist, let thread = store.activeThread, !store.isHidden(thread) else { return }
        let origin = thread.id
        focusComposer(false)
        choosingFiles = true
        let shown = DocumentPicker.presentMany(DocumentTextImporter.allowedContentTypes, asCopy: true,
            onCancel: { choosingFiles = false },
            onError: { issue in choosingFiles = false; attachmentReport = issue }) { urls in
                choosingFiles = false
                importDocuments(urls, into: origin)
            }
        if !shown { choosingFiles = false }
    }

    private func importDocuments(_ urls: [URL], into origin: UUID, removeAfterImport: Bool = false) {
        guard !urls.isEmpty else { return }
        fileImportThreadID = origin
        fileImportTask = Task { @MainActor in
            defer {
                fileImportThreadID = nil
                fileImportTask = nil
                fileImportProgress = ""
                if removeAfterImport {
                    for url in urls { try? FileManager.default.removeItem(at: url) }
                }
            }
            var successes = 0
            var details: [String] = []
            for (index, url) in urls.enumerated() {
                if Task.isCancelled { details.append("已取消剩余文件；已经挂入的文件保留。"); break }
                guard let current = store.threads.first(where: { $0.id == origin }), !store.isHidden(current) else {
                    details.append("原对话已删除或上锁，剩余文件没有加入其他对话。")
                    break
                }
                let existing = documentsByThread[origin] ?? []
                guard existing.count < 5 else {
                    details.append("\(url.lastPathComponent)：单条消息最多附加 5 份文件。")
                    break
                }
                fileImportProgress = "正在读取 \(index + 1)/\(urls.count)：\(url.lastPathComponent)"
                do {
                    let imported = try await DocumentTextImporter.load(url, apiKey: store.apiKey)
                    try Task.checkCancellation()
                    let doc = PendingDocument(
                        name: imported.name,
                        fileExtension: url.pathExtension.lowercased(),
                        text: imported.text,
                        warnings: imported.warnings
                    )
                    documentsByThread[origin, default: []].append(doc)
                    successes += 1
                    details.append(contentsOf: imported.warnings.map { "\(imported.name)：\($0)" })
                } catch is CancellationError {
                    details.append("已取消剩余文件；已经挂入的文件保留。")
                    break
                } catch {
                    details.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            if !details.isEmpty || successes < urls.count {
                let location = origin == store.activeThreadID ? "当前对话" : "原来对话"
                var report = "已将 \(successes)/\(urls.count) 份文件挂入\(location)的待发送区。"
                if !details.isEmpty { report += "\n\n" + details.joined(separator: "\n\n") }
                attachmentReport = report
            }
        }
    }

    private var showsSystemPromptControl: Bool {
        guard let thread = store.activeThread, !store.isHidden(thread) else { return false }
        return thread.story == nil && thread.bookDiscussion == nil
    }

    @ViewBuilder private var systemPromptControl: some View {
        if showsSystemPromptControl, let thread = store.activeThread {
            Button {
                guard store.canChooseSystemPrompt(for: thread), !store.isGenerating, store.canPersist else { return }
                focusComposer(false)
                systemPromptTarget = ConversationPanelTarget(threadID: thread.id)
            } label: {
                Image(systemName: "text.bubble").font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Ink.ink)
                    .frame(width: 44, height: 44)
                    .floatingGlass(in: AnyShape(Circle()))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(store.isGenerating || !store.canPersist || !store.canChooseSystemPrompt(for: thread))
            .accessibilityLabel("切换系统指令")
            .accessibilityValue(store.systemPromptTitle(for: thread))
            .accessibilityHint("为当前对话选择系统指令，草稿保持不变")
            .accessibilityIdentifier("chat-system-prompt")
        }
    }

    private var attachmentButton: some View {
        Button {
            Haptic.tap()
            withAnimation(.snappy(duration: 0.22)) { attachTrayOpen.toggle() }
        } label: {
            Image(systemName: "plus").font(.system(size: 15, weight: .regular))
                .foregroundStyle(Ink.ink2)
                .rotationEffect(.degrees(attachTrayOpen ? 45 : 0))
                .frame(width: 34, height: 34)
                .background(Ink.raised, in: swiss ? AnyShape(Rectangle()) : AnyShape(Circle()))
                .contentShape(Circle())
        }
        .buttonStyle(.pressFeedback)
        .accessibilityLabel(attachTrayOpen ? "收起添加内容" : "添加图片、文件、文字或切换指令")
        .accessibilityIdentifier("chat-attachments")
    }

    private var attachmentTray: some View {
        HStack(spacing: 8) {
            if showsSystemPromptControl, let thread = store.activeThread {
                let current = store.systemPromptTitle(for: thread)
                trayButton("指令 · " + (current.count > 6 ? String(current.prefix(5)) + "…" : current),
                           symbol: "text.bubble", id: "chat-system-prompt",
                           disabled: store.isGenerating || !store.canPersist || !store.canChooseSystemPrompt(for: thread)) {
                    focusComposer(false)
                    systemPromptTarget = ConversationPanelTarget(threadID: thread.id)
                }
            }
            trayButton("图片", symbol: "photo", id: "chat-add-photos",
                       disabled: attachmentBusy || !store.canPersist || pendingImages.count >= 4) { choosePhotos() }
            trayButton("文件", symbol: "doc.badge.plus", id: "chat-add-document",
                       disabled: attachmentBusy || !store.canPersist) { chooseDocuments() }
            trayButton("粘贴", symbol: "doc.on.clipboard", id: "chat-paste-text", disabled: !store.canPersist) {
                guard let id = store.activeThreadID else { return }
                if UIPasteboard.general.hasImages, let image = UIPasteboard.general.image {
                    guard pendingImages.count < 4 else {
                        attachmentReport = "每条消息最多附加 4 张图片。"
                        return
                    }
                    if let data = image.jpegData(compressionQuality: 0.85) ?? image.pngData() {
                        pendingImages.append(PendingImage(data: data, preview: image))
                        Haptic.tap()
                        return
                    }
                }
                guard let text = UIPasteboard.general.string, !text.isEmpty else {
                    attachmentReport = "剪贴板里没有图片或文字。"
                    return
                }
                if store.appendImportedText(text, to: id) { focusComposer(true) }
            }
            Spacer(minLength: 0)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func trayButton(_ title: String, symbol: String, id: String, disabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button {
            attachTrayOpen = false
            flushDraft()
            action()
        } label: {
            Label(title, systemImage: symbol).font(TypeScale.label).foregroundStyle(Ink.ink)
                .padding(.horizontal, 14).frame(height: 36)
                .background(Ink.raised, in: swiss ? AnyShape(Rectangle()) : AnyShape(Capsule()))
                .contentShape(Capsule())
        }
        .buttonStyle(.pressFeedback).disabled(disabled)
        .accessibilityIdentifier(id)
    }

    private var isSlashCommandActive: Bool {
        let trimmed = localDraft.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/") || trimmed.hasPrefix("／")
    }

    @ViewBuilder private var contextStatusBar: some View {
        if let thread = store.activeThread, let stats = cachedContext,
           (stats.messageCount >= 4 || store.compactingThreadID == thread.id) {
            let pct = max(1, Int(round(stats.ratio * 100)))
            let barColor: Color = stats.ratio > 0.80 ? .red : (stats.ratio > 0.55 ? .orange : Ink.seal)
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Ink.ink3.opacity(0.18))
                        Capsule().fill(barColor).frame(width: max(4, geo.size.width * CGFloat(stats.ratio)))
                    }
                }
                .frame(width: 44, height: 5)
                Text("上下文 \(pct)% · 约\(stats.estimatedTokens >= 1000 ? String(format: "%.1fk", Double(stats.estimatedTokens) / 1000.0) : "\(stats.estimatedTokens)")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Ink.ink3)
                    .lineLimit(1)
                if let hit = stats.cacheHitRate {
                    Text("缓存 \(hit)%")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Ink.seal)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Ink.seal.opacity(0.10), in: Capsule())
                }
                Spacer(minLength: 4)
                if store.compactingThreadID == thread.id {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("正在浓缩…").font(TypeScale.tiny).foregroundStyle(Ink.seal)
                    }
                }
            }
            .padding(.horizontal, 8)
            .transition(.opacity)
        }
    }

    @ViewBuilder private var slashCommandBar: some View {
        if isSlashCommandActive && !store.isGenerating {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    slashPill("/深搜", subtitle: "多轮深度搜索") {
                        store.webSearchEnabled = true
                        let remainder = String(localDraft.drop(while: { $0 != " " })).trimmingCharacters(in: .whitespaces)
                        localDraft = remainder
                        scheduleDraftPush()
                    }
                    slashPill("/浓缩", subtitle: "无损浓缩上文") {
                        localDraft = ""
                        scheduleDraftPush()
                        store.compactActiveThread()
                    }
                    if store.activeThread?.projectID != nil {
                        slashPill("/做梦", subtitle: "整合去重记忆") {
                            localDraft = ""
                            scheduleDraftPush()
                            store.dreamConsolidateActiveProject()
                        }
                    }
                    if store.activeProject?.studySubject == .english {
                        slashPill("/考词", subtitle: "随机抽10个词") {
                            localDraft = ""
                            flushDraft()
                            _ = store.send("请随机抽 10 个单词考考我。", images: [])
                            focusComposer(false)
                        }
                    }
                    if store.activeProject?.studySubject != nil {
                        slashPill("/周报", subtitle: "生成本周周报") {
                            localDraft = ""
                            flushDraft()
                            _ = store.send("帮我生成本周学习周报。", images: [])
                            focusComposer(false)
                        }
                    }
                    if showsSystemPromptControl, let thread = store.activeThread, store.canChooseSystemPrompt(for: thread) {
                        slashPill("/指令", subtitle: "切换系统指令") {
                            localDraft = ""
                            scheduleDraftPush()
                            focusComposer(false)
                            systemPromptTarget = ConversationPanelTarget(threadID: thread.id)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func slashPill(_ command: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptic.tap()
            action()
        } label: {
            HStack(spacing: 5) {
                Text(command)
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Ink.seal)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Ink.ink2)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Ink.raised, in: Capsule())
            .overlay(Capsule().stroke(Ink.seal.opacity(0.28), lineWidth: 0.8))
        }
        .buttonStyle(.pressFeedback)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let approval = store.pendingApproval {
                InlineToolApprovalCard(approval: approval) { store.resolveApproval($0) }
            }
            contextStatusBar
            slashCommandBar
            ghostBar
            if store.searchingThreadID == store.activeThreadID && store.isGenerating {
                HStack { ProgressView(); Text("正在深度联网检索与核对正文…").font(TypeScale.caption) }
                    .accessibilityIdentifier("web-search-progress")
            }

            if !store.canChat {
                Button { focusComposer(false); openSettings() } label: {
                    Label(store.activeProvider == .chatGPT ? "在设置里登录 ChatGPT 订阅，就能用这个项目" : "在设置里填好 DeepSeek API Key，就能开始聊天",
                          systemImage: store.activeProvider == .chatGPT ? "person.crop.circle" : "key")
                        .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                }.padding(.bottom, 2)
            }
            VStack(alignment: .leading, spacing: 12) {
                if attachTrayOpen { attachmentTray }
                if photoLoadThreadID != nil {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(photoLoadThreadID == store.activeThreadID ? "正在读取图片…" : "正在为原对话读取图片…")
                            .font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                        Spacer(minLength: 4)
                        Button("取消", action: cancelPhotoImport).font(TypeScale.label)
                    }
                }
                if fileImportThreadID != nil {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(fileImportProgress).font(TypeScale.tiny).foregroundStyle(Ink.ink3).lineLimit(2)
                        Spacer(minLength: 4)
                        Button("取消") { fileImportTask?.cancel() }.font(TypeScale.label)
                    }
                }
                if let thread = store.activeThread, thread.bookDiscussion != nil {
                    BookDiscussionVoiceControl(threadID: thread.id, open: { focusComposer(false) })
                        .id(thread.id)
                }
                if !pendingDocuments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(pendingDocuments) { doc in
                                HStack(spacing: 6) {
                                    Button {
                                        previewingDocument = DocumentPreviewTarget(
                                            title: doc.fileExtension.isEmpty ? doc.name : "\(doc.name).\(doc.fileExtension)",
                                            text: doc.text
                                        )
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "doc.text")
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(Ink.seal)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(doc.fileExtension.isEmpty ? doc.name : "\(doc.name).\(doc.fileExtension)")
                                                    .font(TypeScale.label)
                                                    .foregroundStyle(Ink.ink)
                                                    .lineLimit(1)
                                                Text("\(doc.characterCount.formatted()) 字 · 点击预览")
                                                    .font(TypeScale.tiny)
                                                    .foregroundStyle(Ink.ink3)
                                            }
                                            .frame(maxWidth: 160, alignment: .leading)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    Button {
                                        pendingDocuments.removeAll { $0.id == doc.id }
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(Ink.onSolid)
                                            .frame(width: 18, height: 18)
                                            .background(Ink.solid, in: Circle())
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("移除文件 \(doc.name)")
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Ink.raised, in: RoundedRectangle(cornerRadius: swiss ? 0 : 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: swiss ? 0 : 12, style: .continuous).stroke(Ink.line, lineWidth: 1))
                            }
                        }
                    }
                    .sheet(item: $previewingDocument) { target in
                        DocumentPreviewSheet(target: target)
                    }
                }
                if !pendingImages.isEmpty || loadingPhotos {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(pendingImages) { item in
                                Image(uiImage: item.preview).resizable().scaledToFill()
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: swiss ? 0 : 12, style: .continuous))
                                    .overlay(alignment: .topTrailing) {
                                        Button { pendingImages.removeAll { $0.id == item.id } } label: {
                                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(Ink.onSolid)
                                                .frame(width: 20, height: 20).background(Ink.solid, in: Circle())
                                                .padding(3).contentShape(Rectangle())
                                        }.buttonStyle(.plain).accessibilityLabel("移除这张图片")
                                    }
                            }
                            if loadingPhotos { ProgressView().frame(width: 64, height: 64) }
                        }
                    }
                }
                if let quote = quotingMessage {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Ink.seal)
                            .frame(width: 3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("回复 \(quote.author)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Ink.seal)
                                .lineLimit(1)
                            Text(quote.excerpt)
                                .font(TypeScale.tiny)
                                .foregroundStyle(Ink.ink2)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button {
                            Haptic.tap()
                            withAnimation(.snappy(duration: 0.18)) { quotingMessage = nil }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(Ink.ink3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("取消引用回复")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Ink.raised, in: RoundedRectangle(cornerRadius: swiss ? 0 : 12, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                Group {
                    if usesPreviewKeyboard {
                        PreviewKeyboardField(text: draft, isFocused: previewComposerFocused, focusChanged: { previewComposerFocused = $0 })
                    } else {
                        // The suggestion is drawn over the empty field in grey (wrapping like the
                        // reply it is), not as a placeholder, which would stay on one line. A ZStack,
                        // so the composer grows to fit it instead of the text spilling out.
                        ZStack(alignment: .topLeading) {
                            TextField(ghostText == nil ? composerPlaceholder : "", text: draft, axis: .vertical)
                                .userMessageStyle().lineLimit(1...5)
                                .focused($composerFocused).tint(Ink.ink)
                            if let ghost = ghostText {
                                if isComposerFocused {
                                    Text(ghost).userMessageStyle().foregroundStyle(Ink.ink3.opacity(0.75)).lineLimit(4)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .allowsHitTesting(false).accessibilityHidden(true)
                                } else {
                                    // Unfocused, a tap puts it in to edit; send takes it as is.
                                    Button { takeGhost(send: false) } label: {
                                        Text(ghost).userMessageStyle().foregroundStyle(Ink.ink3.opacity(0.75)).lineLimit(4)
                                            .multilineTextAlignment(.leading)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("猜你想说：\(ghost)，点一下放进输入框修改，或直接点发送")
                                }
                            }
                        }
                    }
                }
                    .disabled(!store.canPersist)
                    .accessibilityIdentifier("chat-composer")
                HStack(spacing: 10) {
                    attachmentButton
                    // Model and thinking level in one pill, like "Haiku 5.5 中等" in the Claude app.
                    Menu {
                        Section("当前能力边界") {
                            Text(ProviderCapabilities.forProvider(store.activeProvider).summaryLabel)
                        }
                        Section("服务") {
                            Picker("服务", selection: Binding(get: { store.activeProvider }, set: { store.setProvider($0) })) {
                                ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                            }.disabled(store.isGenerating)
                        }
                        if store.activeProvider == .colab {
                            Section("Colab") {
                                Text(store.pillModelTitle)
                                Toggle("思考", isOn: Binding(get: { store.activeChatSettings.colabOptions.thinking }, set: { store.setColabThinking($0) }))
                            }
                        } else if store.activeProvider == .compatible {
                            Section("其他模型（兼容端点）") {
                                Text("\(store.compatible.configuration.activePreset.title) · \(store.pillModelTitle)")
                                Text("可在「设置 → 模型与服务 → 其他模型」切换预设或填写 API Key")
                            }
                        } else if store.activeProvider == .chatGPT {
                            Section("ChatGPT 订阅") {
                                Picker("模型", selection: Binding(get: { store.activeChatSettings.subscriptionModel }, set: { store.setSubscriptionModel($0) })) {
                                    if !store.subscription.models.contains(where: { $0.slug == store.activeChatSettings.subscriptionModel }) {
                                        Text(store.activeChatSettings.subscriptionModel).tag(store.activeChatSettings.subscriptionModel)
                                    }
                                    ForEach(store.subscription.models) { model in Text(model.displayName).tag(model.slug) }
                                }
                            }
                            Section("思考") {
                                Picker("思考", selection: Binding(get: { store.activeChatSettings.selectedSubscriptionEffort }, set: { store.setSubscriptionEffort($0) })) {
                                    ForEach(SubscriptionEffort.allCases) { effort in Text(effort.title).tag(effort) }
                                }
                            }
                        } else {
                        Section { Text(Pricing.statusLabel()) }
                        Section("模型") {
                            Picker("模型", selection: Binding(get: { store.activeChatSettings.model }, set: { store.setModel($0) })) {
                                ForEach(DeepSeekModel.allCases) { model in Text(model.title).tag(model) }
                            }
                        }
                        Section("思考") {
                            Picker("思考", selection: Binding(get: { store.activeChatSettings.thinkingEnabled ? store.activeChatSettings.effort.rawValue : "off" },
                                                            set: { value in
                                if let effort = ThinkingEffort(rawValue: value) { store.setThinkingEffort(effort) }
                                else if store.activeChatSettings.thinkingEnabled { store.toggleThinking() }
                            })) {
                                Text("Off").tag("off")
                                ForEach(ThinkingEffort.allCases) { effort in Text(effort.title).tag(effort.rawValue) }
                            }
                        }
                        }
                    } label: {
                        modelPillLabel
                    }
                    .accessibilityLabel("选择模型和思考档位")
                    .accessibilityValue("\(store.pillModelTitle) \(store.pillEffortTitle)")
                    .accessibilityIdentifier("model-effort-pill")
                    if store.activeProvider == .deepSeek {
                        // On, the button itself says so; no hint line over the conversation.
                        Button { store.webSearchEnabled.toggle() } label: {
                            webToggleLabel
                        }
                        .disabled(store.isGenerating)
                        .accessibilityLabel("联网搜索")
                        .accessibilityValue(store.webSearchEnabled ? "已开启" : "已关闭")
                        .accessibilityIdentifier("web-search-toggle")
                    }

                    Spacer(minLength: 0)
                    Button {
                        if store.isGenerating { store.stopGeneration() }
                        else if ghostText != nil {
                            takeGhost(send: true)
                        } else {
                            clearMessageNavigation()
                            followsOutput = true
                            Haptic.tap()
                            flushDraft()
                            let textWithQuote = MessageQuoteCodec.encode(quote: quotingMessage, userText: store.activeDraft)
                            let payload = PendingDocumentCodec.encode(userText: textWithQuote, documents: pendingDocuments)
                            if store.send(payload, images: pendingImages.map(\.data)) {
                                draftPushTask?.cancel()
                                draftPushTask = nil
                                localDraft = ""
                                lastPushedDraft = ""
                                pendingImages = []
                                pendingDocuments = []
                                quotingMessage = nil
                                focusComposer(false)
                            }
                        }
                    } label: {
                        let readyToSend = hasInput || ghostText != nil
                        let isStop = store.isGenerating
                        let sendDisabled = !isStop && (!store.canChat || !readyToSend || !store.canPersist || loadingPhotos
                            || (fileImportThreadID != nil && fileImportThreadID == store.activeThreadID))
                        let circleFill: Color = isStop
                            ? (swiss ? Ink.solid : (night ? Ink.seal : Ink.raised))
                            : (readyToSend ? Ink.sendFill : Ink.raised)
                        let glyphColor: Color = isStop
                            ? (swiss ? Ink.onSolid : (night ? Ink.onSeal : Ink.ink))
                            : (readyToSend ? Ink.sendGlyph : Ink.ink3.opacity(0.65))
                        Image(systemName: isStop ? "stop.fill" : "arrow.up")
                            .font(.system(size: isStop ? 11 : 14, weight: readyToSend ? .semibold : .medium))
                            .foregroundStyle(glyphColor)
                            .frame(width: 34, height: 34)
                            .background(circleFill, in: RoundedRectangle(cornerRadius: swiss ? 0 : 17, style: .continuous))
                            .shadow(color: night && (readyToSend || isStop) ? Ink.seal.opacity(0.35) : .clear, radius: night ? 12 : 0)
                            .opacity(readyToSend && sendDisabled ? 0.42 : 1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.isGenerating && (!store.canChat || !(hasInput || ghostText != nil) || !store.canPersist || loadingPhotos
                        || (fileImportThreadID != nil && fileImportThreadID == store.activeThreadID)))
                    .accessibilityLabel(store.isGenerating ? "停止生成" : "发送消息")
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            .clearGlass(radius: 24)
            if store.isGenerating && store.generatingThreadID != store.activeThreadID {
                Text("另一个对话正在生成，右侧按钮可停止。")
                    .font(TypeScale.tiny).foregroundStyle(Ink.ink3)
            }
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 10)
        .background(alignment: .bottom) {
            // Sheer translucent edge fade so scrolling text visibly drifts behind the liquid-glass composer.
            LinearGradient(
                stops: [
                    .init(color: Ink.paper.opacity(0), location: 0),
                    .init(color: Ink.paper.opacity(0.55), location: 0.42),
                    .init(color: Ink.paper.opacity(0.84), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(.top, -12)
            .ignoresSafeArea(.container, edges: .bottom)
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("chat-composer-panel")
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
            if abs(composerPanelHeight - newHeight) > 0.5 {
                composerPanelHeight = newHeight
            }
        }
        .onChange(of: ghostSource?.id) { _, _ in suggestionIndex = 0 }
    }
}

private enum ChatMessageBrowserMode: Equatable {
    case search, bookmarks
    var title: String { self == .search ? "搜索本对话" : "本对话收藏" }
}

private struct ChatMessageBrowserRequest: Identifiable {
    let id = UUID()
    let threadID: UUID
    let mode: ChatMessageBrowserMode
}

private struct ChatMessageJump {
    let id = UUID()
    let threadID: UUID
    let messageID: UUID
}

@MainActor
private struct ChatFloatingControlsOverlay<ProjectMenu: View>: View {
    let scrollUIState: ChatScrollUIState
    let hasMessages: Bool
    let canChooseProject: Bool
    @ViewBuilder let projectMenu: () -> ProjectMenu
    let jumpToLatest: () -> Void

    var body: some View {
        let showJump = hasMessages && scrollUIState.showJumpToLatest
        if canChooseProject || showJump {
            ZStack {
                if canChooseProject {
                    HStack {
                        projectMenu()
                        Spacer(minLength: 0)
                    }
                }
                if showJump {
                    Button(action: jumpToLatest) {
                        Image(systemName: "arrow.down").font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Ink.ink)
                            .frame(width: 40, height: 40)
                            .floatingGlass(in: AnyShape(Circle()))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.pressFeedback)
                    .accessibilityLabel("一键回到最新消息")
                    .accessibilityIdentifier("chat-jump-to-latest")
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .animation(.snappy(duration: 0.2), value: showJump)
        }
    }
}

@MainActor
private struct SwipeTimestampRow<Content: View>: View {
    let timeReveal: SwipeTimeRevealModel
    let timestamp: Date?
    @ViewBuilder let content: () -> Content

    var body: some View {
        let offset = timestamp == nil ? 0 : timeReveal.offset
        content()
            .offset(x: offset)
            .overlay(alignment: .trailing) {
                if let timestamp, offset < -4 {
                    let progress = min(1.0, max(0.0, Double(-offset - 4) / 34.0))
                    Text(MessageTime.swipeLabel(timestamp))
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Ink.ink3)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: 56 + offset)
                        .opacity(progress)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

@MainActor
private struct ChatMessageBrowser: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let request: ChatMessageBrowserRequest
    let open: (UUID) -> Void
    @State private var query = ""
    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var thread: ChatThread? {
        guard let current = store.activeThread, current.id == request.threadID, !store.isHidden(current) else { return nil }
        return current
    }
    private var matches: [ChatMessage] {
        guard let thread else { return [] }
        if request.mode == .search && term.isEmpty { return [] }
        return thread.messages.filter { message in
            (request.mode != .bookmarks || message.isBookmarked == true)
                && (term.isEmpty || message.content.localizedCaseInsensitiveContains(term))
        }
    }
    var body: some View {
        NavigationStack {
            browserContents
                .background(Ink.groupedBg.ignoresSafeArea())
                .navigationTitle(request.mode.title)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: request.mode == .search ? "搜索消息正文" : "搜索收藏内容")
                .toolbar { ToolbarItem(placement: .topBarLeading) { ClaudeSheetCloseButton(label: "完成") { dismiss() } } }
        }
        .tint(Ink.ink).presentationDragIndicator(.visible)
        .alert("暂时没有完成", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } })) {
                Button("知道了") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
    }
    @ViewBuilder private var browserContents: some View {
        if thread == nil {
            ContentUnavailableView("此对话暂不可查看", systemImage: "lock", description: Text("请回到对话后再打开。"))
        } else if request.mode == .search && term.isEmpty {
            ContentUnavailableView("查找这段对话", systemImage: "text.magnifyingglass", description: Text("输入关键词，点选结果可回到那条消息。"))
        } else {
            resultsList
        }
    }
    private var resultsList: some View {
        let found = matches
        return List {
            if found.isEmpty {
                emptyResults
            } else {
                Section {
                    ForEach(found) { message in resultRow(message) }
                } header: {
                    Text(request.mode == .bookmarks && term.isEmpty ? "已收藏 \(found.count) 条消息" : "找到 \(found.count) 条消息")
                } footer: {
                    Text("点选一条消息，回到它在对话中的位置。")
                }
            }
        }
        .claudeGroupedListStyle()
    }
    private var emptyResults: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(request.mode == .bookmarks && term.isEmpty ? "还没有收藏消息" : "没有找到匹配的消息")
                .font(TypeScale.body).foregroundStyle(Ink.ink)
            Text(request.mode == .bookmarks && term.isEmpty ? "长按对话中的消息，选择「收藏消息」。" : "试试更短的关键词。")
                .font(TypeScale.label).foregroundStyle(Ink.ink3)
        }.padding(.vertical, 10).claudeCardRow()
    }
    private func resultRow(_ message: ChatMessage) -> some View {
        ChatMessageMatchRow(message: message, query: term) { open(message.id) }
            .claudeCardRow()
            .contextMenu {
                Button(message.isBookmarked == true ? "取消收藏" : "收藏消息", systemImage: message.isBookmarked == true ? "bookmark.slash" : "bookmark") {
                    guard let thread, thread.messages.contains(where: { $0.id == message.id }) else { return }
                    store.toggleBookmark(threadID: thread.id, messageID: message.id)
                }.disabled(message.state == .streaming || !store.canPersist)
            }
    }
}

@MainActor
private struct ChatMessageMatchRow: View {
    let message: ChatMessage
    let query: String
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text(message.role == .user ? "你" : "Sermo").font(TypeScale.label).foregroundStyle(Ink.seal)
                    Text(MessageTime.label(message.createdAt)).font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                    Spacer(minLength: 4)
                    if message.isBookmarked == true {
                        Image(systemName: "bookmark.fill").font(.system(size: 11)).foregroundStyle(Ink.seal).accessibilityLabel("已收藏")
                    }
                    Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(Ink.ink3).accessibilityHidden(true)
                }
                Text(highlightedExcerpt).font(TypeScale.body).foregroundStyle(Ink.ink).lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }.padding(.vertical, 7).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private var excerpt: String {
        guard !message.content.isEmpty else {
            if let images = message.images, !images.isEmpty { return "图片消息（\(images.count) 张）" }
            return "这条消息没有文字内容。"
        }
        let source = message.content as NSString
        let match = query.isEmpty ? NSRange(location: NSNotFound, length: 0) : source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
        let start = match.location == NSNotFound ? 0 : max(0, match.location - 40)
        let proposed = NSRange(location: start, length: min(200, source.length - start))
        let range = source.rangeOfComposedCharacterSequences(for: proposed)
        return (range.location > 0 ? "…" : "") + source.substring(with: range) + (NSMaxRange(range) < source.length ? "…" : "")
    }
    private var highlightedExcerpt: AttributedString {
        let excerpt = self.excerpt
        var text = AttributedString(excerpt)
        guard !query.isEmpty else { return text }
        let source = excerpt as NSString
        var cursor = 0
        while cursor < source.length {
            let match = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                     range: NSRange(location: cursor, length: source.length - cursor))
            guard match.location != NSNotFound, match.length > 0 else { break }
            if let range = Range(match, in: excerpt),
               let lower = AttributedString.Index(range.lowerBound, within: text),
               let upper = AttributedString.Index(range.upperBound, within: text) {
                text[lower..<upper].foregroundColor = Ink.seal
                text[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            }
            cursor = NSMaxRange(match)
        }
        return text
    }
}

// Holds no store: everything it shows comes in as values, so with .equatable()
// only the message that changed redraws while an answer streams.
@MainActor
struct MessageView: View, Equatable {
    let message: ChatMessage
    let threadID: UUID?
    let isLast: Bool
    let isGenerating: Bool
    let canRegenerate: Bool
    let showsSuggestions: Bool
    let edit: () -> Void
    let regenerate: () -> Void
    let openThinking: () -> Void
    let useSuggestedReply: (String) -> Void
    var signInDrive: () -> Void = {}
    // Which exchange this is (Q.01 / A.01 in the Swiss look) and the look itself,
    // part of equality so a style switch redraws rows the stream would skip.
    var round = 1
    var style: InterfaceStyle = .paper
    var layoutMode: ChatLayoutMode = .editorial
    var quoteReply: (() -> Void)? = nil
    // Bookshelf conversations: 「这里不像」 on an answer (1.10.0).
    var markOffCharacter: (() -> Void)? = nil
    // A separate literary inner-voice supplement; available for completed assistant replies.
    var showThoughts: (() -> Void)? = nil
    var saveCheckpoint: (() -> Void)? = nil
    var showBookReferences: (() -> Void)? = nil
    var speech: OpenAISpeech? = nil
    var toggleBookmark: (() -> Void)? = nil
    var retryColab: (() -> Void)? = nil
    @State private var copied = false
    @State private var selecting = false

    nonisolated static func == (lhs: MessageView, rhs: MessageView) -> Bool {
        lhs.message == rhs.message && lhs.threadID == rhs.threadID && lhs.isLast == rhs.isLast
            && lhs.isGenerating == rhs.isGenerating && lhs.canRegenerate == rhs.canRegenerate
            && lhs.showsSuggestions == rhs.showsSuggestions && lhs.round == rhs.round
            && lhs.style == rhs.style && lhs.layoutMode == rhs.layoutMode
    }

    private var cleanCopyText: String {
        guard message.role == .user else { return message.content }
        let docFree = PendingDocumentCodec.decode(message.content).userText
        let quoteFree = MessageQuoteCodec.decode(docFree).userText
        return quoteFree.isEmpty ? message.content : quoteFree
    }

    var body: some View {
        Group {
            if let label = message.directive {
                // A request the app sent on your behalf: a quiet marker instead of a message,
                // with what you should read (a story's recap) underneath.
                VStack(spacing: 12) {
                    Text("— \(label) —").font(TypeScale.caption).foregroundStyle(Ink.ink3)
                        .accessibilityLabel(label)
                    if let detail = message.directiveDetail, !detail.isEmpty {
                        Text(detail).font(TypeScale.label).foregroundStyle(Ink.ink2).lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Ink.raised, in: RoundedRectangle(cornerRadius: style == .swiss ? 0 : 16, style: .continuous))
                            .accessibilityLabel("前情提要：\(detail)")
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
            } else if style == .swiss { swissContent } else { paperContent }
        }
        .contextMenu {
            if message.directive == nil && message.state != .streaming {
                ControlGroup {
                    ForEach(MessageReactionStore.quickEmojis, id: \.self) { emoji in
                        Button(emoji) {
                            MessageReactionStore.shared.toggle(emoji, for: message.id)
                        }
                    }
                }
                Menu("更多表情", systemImage: "face.smiling") {
                    ForEach(MessageReactionStore.moreEmojis, id: \.self) { emoji in
                        Button(emoji) {
                            MessageReactionStore.shared.toggle(emoji, for: message.id)
                        }
                    }
                    if MessageReactionStore.shared.reaction(for: message.id) != nil {
                        Divider()
                        Button("移除表情", systemImage: "xmark.circle", role: .destructive) {
                            MessageReactionStore.shared.clear(for: message.id)
                        }
                    }
                }
            }
            // The most used actions come first; extra actions live below.
            Section {
                if let quoteReply {
                    Button("引用回复", systemImage: "arrowshape.turn.up.left") { quoteReply() }
                }
                Button("复制", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = cleanCopyText
                    Haptic.tap()
                }
                Button("选择文字", systemImage: "text.viewfinder") { selecting = true }
                Button("编辑文字", systemImage: "pencil") { edit() }.disabled(isGenerating)
                if message.role == .assistant && message.state == .complete, let speech {
                    Button(speech.isActive(message.id) ? "停止朗读" : "朗读回答",
                           systemImage: speech.isActive(message.id) ? "stop.circle" : "speaker.wave.2") {
                        if speech.isActive(message.id) { speech.stop() }
                        else { speech.speak(message.content, messageID: message.id) }
                    }
                }
            }
            if let toggleBookmark {
                Button(message.isBookmarked == true ? "取消收藏" : "收藏消息", systemImage: message.isBookmarked == true ? "bookmark.slash" : "bookmark") {
                    toggleBookmark()
                }.disabled(message.state == .streaming)
            }
            if let showThoughts {
                Button("他在想什么", systemImage: "bubble.left.and.text.bubble.right") { showThoughts() }
            }
            if let markOffCharacter {
                Button("这里不像…", systemImage: "person.crop.circle.badge.exclamationmark") { markOffCharacter() }
            }
            if let saveCheckpoint {
                Button("在这里保存剧情存档", systemImage: "bookmark") { saveCheckpoint() }.disabled(isGenerating)
            }
            if isLast && message.role == .assistant {
                Button("重新生成", systemImage: "arrow.clockwise") { regenerate() }
                    .disabled(isGenerating || !canRegenerate)
            }
            if layoutMode == .imessage, let usage = message.usage {
                Section {
                    Text(usageLabel(usage))
                }
            }
        }
        .sheet(isPresented: $selecting) { SelectableTextSheet(text: cleanCopyText) }
    }

    // 纸笺: adapts seamlessly across 书页 (editorial), 信息气泡 (iMessage), and 智能 (hybrid).
    private var paperContent: some View {
        let isImessage = (layoutMode == .imessage && style != .swiss)
        return VStack(alignment: .leading, spacing: 12) {
            if message.role == .user {
                let docDecoded = PendingDocumentCodec.decode(message.content)
                let quoteDecoded = MessageQuoteCodec.decode(docDecoded.userText)
                if style == .night && round > 1 && !isImessage { WaveRule().padding(.bottom, 8) }
                HStack(spacing: 0) {
                    Spacer(minLength: 52)
                    VStack(alignment: .trailing, spacing: 6) {
                        discussionVoiceLabel
                        if let quote = quoteDecoded.quote {
                            QuotedReplyCard(quote: quote, alignTrailing: true, swiss: false)
                        }
                        if let names = message.images, !names.isEmpty { AttachmentRow(names: names, swiss: false) }
                        if !docDecoded.attachments.isEmpty {
                            MessageDocumentCards(attachments: docDecoded.attachments, swiss: false)
                        }
                        if !quoteDecoded.userText.isEmpty {
                            let shape = AsymmetricBubbleShape.chatBubbleShape(isUser: true, position: .single)
                            Text(quoteDecoded.userText).userMessageStyle().lineSpacing(max(Personal.lineSpacing - 2, 3)).chineseReading()
                                .foregroundStyle(isImessage ? Ink.onSeal : Ink.ink)
                                .textSelection(.enabled)
                                .padding(.horizontal, 16).padding(.vertical, 11)
                                .background(
                                    isImessage ? Ink.seal : Personal.bubble,
                                    in: isImessage
                                        ? AnyShape(shape)
                                        : AnyShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                )
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        MessageReactionBadge(messageID: message.id)
                            .offset(x: -8, y: -10)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                answerParts
                if message.state == .streaming {
                    if isImessage && message.content.isEmpty && message.reasoning.isEmpty && (message.toolActivity?.isEmpty != false) {
                        TypingIndicatorBubble()
                    } else {
                        StreamActivityView(message: message)
                    }
                } else if !(isImessage && message.state != .failed) {
                    let isEmptyFailure = message.state == .failed && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if isEmptyFailure {
                        if isLast {
                            HStack(spacing: 12) {
                                Button { regenerate() } label: {
                                    Label("重试", systemImage: "arrow.clockwise")
                                        .font(.system(size: 13.5, weight: .medium))
                                }
                                .disabled(isGenerating || !canRegenerate)
                                .accessibilityLabel("重新生成")
                                Spacer(minLength: 4)
                            }
                            .foregroundStyle(Ink.ink2).buttonStyle(.pressFeedback).padding(.top, 2)
                        }
                    } else {
                        HStack(spacing: 14) {
                            Button { copyAnswer() } label: {
                                ClaudeActionGlyph(kind: copied ? .copied : .copy)
                                    .frame(width: 24, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("复制回答")
                            Button { selecting = true } label: {
                                ClaudeActionGlyph(kind: .selectText)
                                    .frame(width: 24, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("选择部分文字")
                            Button { edit() } label: {
                                ClaudeActionGlyph(kind: .edit)
                                    .frame(width: 24, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .disabled(isGenerating).accessibilityLabel("编辑回答")
                            if message.state == .complete, let speech {
                                SpeechPlaybackControl(speech: speech, text: message.content, messageID: message.id)
                            }
                            if isLast {
                                Button { regenerate() } label: {
                                    ClaudeActionGlyph(kind: .retry)
                                        .frame(width: 24, height: 28)
                                        .contentShape(Rectangle())
                                }
                                .disabled(isGenerating || !canRegenerate).accessibilityLabel("重新生成")
                            }
                            Spacer(minLength: 4)
                            // Cost only; the time is in the long-press menu.
                            if let usage = message.usage {
                                Text(usageLabel(usage)).font(.system(size: 11)).monospacedDigit().lineLimit(1)
                                    .foregroundStyle(Ink.ink3.opacity(0.72))
                                    .accessibilityLabel("本次请求共 \(usage.totalTokens) 个 Token")
                            }
                        }
                        .foregroundStyle(Ink.ink2.opacity(0.72))
                        .buttonStyle(.pressFeedback)
                        .padding(.top, 6)
                    }
                }
            }
            trailingParts
        }
    }

    // 瑞士: a ruled grid. A narrow column of numbers (Q.01, A.01) on the left,
    // the text on the right, a rule between exchanges, small monospaced controls.
    private var swissContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if message.role == .user {
                let docDecoded = PendingDocumentCodec.decode(message.content)
                let quoteDecoded = MessageQuoteCodec.decode(docDecoded.userText)
                if round > 1 { SwissRule(weight: 1, strong: true) }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    MonoLabel(text: String(format: "Q.%02d", round)).frame(width: 46, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        discussionVoiceLabel
                        if let quote = quoteDecoded.quote {
                            QuotedReplyCard(quote: quote, alignTrailing: false, swiss: true)
                        }
                        if let names = message.images, !names.isEmpty { AttachmentRow(names: names, swiss: true) }
                        if !docDecoded.attachments.isEmpty {
                            MessageDocumentCards(attachments: docDecoded.attachments, swiss: true)
                        }
                        if !quoteDecoded.userText.isEmpty {
                            Text(quoteDecoded.userText).readingStyle(adjustment: -2).fontWeight(.medium).lineSpacing(5)
                                .textSelection(.enabled).foregroundStyle(Ink.ink)
                        }
                        MonoLabel(text: MessageTime.label(message.createdAt))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 16)
                SwissRule()
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    MonoLabel(text: String(format: "A.%02d", round), color: Ink.seal).frame(width: 46, alignment: .leading)
                    VStack(alignment: .leading, spacing: 12) {
                        answerParts
                        if message.state == .streaming {
                            StreamActivityView(message: message)
                        } else {
                            swissActions
                        }
                        trailingParts
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 16).padding(.bottom, 22)
            }
        }
    }

    private var swissActions: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 18) {
                Button { copyAnswer() } label: { MonoLabel(text: copied ? "COPIED" : "COPY", color: Ink.ink).frame(minHeight: 32) }
                    .accessibilityLabel("复制回答")
                Button { edit() } label: { MonoLabel(text: "EDIT", color: Ink.ink).frame(minHeight: 32) }
                    .disabled(isGenerating).accessibilityLabel("编辑回答")
                if message.state == .complete, let speech {
                    SpeechPlaybackControl(speech: speech, text: message.content, messageID: message.id)
                }
                if isLast {
                    Button { regenerate() } label: { MonoLabel(text: "RETRY", color: Ink.ink).frame(minHeight: 32) }
                        .disabled(isGenerating || !canRegenerate).accessibilityLabel("重新生成")
                }
                Spacer(minLength: 4)
                MonoLabel(text: MessageTime.label(message.createdAt), size: 10)
            }
            if let usage = message.usage {
                MonoLabel(text: usageLabel(usage), size: 10)
                    .accessibilityLabel("本次请求共 \(usage.totalTokens) 个 Token")
            }
        }
        .buttonStyle(.plain)
    }

    // Thinking, tool calls and the answer text: adapts between 书页, 信息气泡, and 智能.
    @ViewBuilder private var answerParts: some View {
        discussionVoiceLabel
        if !message.reasoning.isEmpty {
            ThinkingRow(message: message, open: openThinking)
        }
        if let tools = message.toolActivity, !tools.isEmpty {
            ToolActivityList(items: tools, signIn: signInDrive)
        }
        if !message.content.isEmpty {
            let isImessage = (layoutMode == .imessage && style != .swiss)
            let isSmartBubble = (layoutMode == .smart && style != .swiss && ChatBubbleRules.isCasualShortReply(message.content))
            let showBubble = isImessage || isSmartBubble
            answerBubbleBody(showBubble: showBubble)
                .animation(.easeInOut(duration: 0.24), value: showBubble)
                .overlay(alignment: .topTrailing) {
                    MessageReactionBadge(messageID: message.id)
                        .offset(x: 6, y: -10)
                }
        }
    }

    @ViewBuilder
    private func answerBubbleBody(showBubble: Bool) -> some View {
        let casualParts = showBubble
            ? ChatBubbleRules.casualBubbleParts(for: message.content, mode: layoutMode, isStreaming: message.state == .streaming)
            : nil
        if let parts = casualParts {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    let pos = BubbleGroupPosition.forIndex(index, total: parts.count)
                    let shape = AsymmetricBubbleShape.chatBubbleShape(isUser: false, position: pos)
                    HStack(spacing: 0) {
                        MarkdownAnswer(content: part, style: style, expandsWidth: false).equatable()
                            .padding(.horizontal, 15)
                            .padding(.vertical, 10)
                            .background(Ink.raised, in: shape)
                            .overlay(shape.stroke(Ink.line.opacity(0.55), lineWidth: 0.6).allowsHitTesting(false))
                        Spacer(minLength: 42)
                    }
                }
            }
        } else if showBubble {
            let shape = AsymmetricBubbleShape.chatBubbleShape(isUser: false, position: .single)
            if ChatBubbleRules.isCompactSingleBubble(message.content) {
                HStack(spacing: 0) {
                    MarkdownAnswer(content: message.content, style: style, expandsWidth: false).equatable()
                        .padding(.horizontal, 15)
                        .padding(.vertical, 11)
                        .background(Ink.raised, in: shape)
                        .overlay(shape.stroke(Ink.line.opacity(0.55), lineWidth: 0.6).allowsHitTesting(false))
                    Spacer(minLength: 42)
                }
            } else {
                MarkdownAnswer(content: message.content, style: style, expandsWidth: true).equatable()
                    .padding(15)
                    .background(Ink.raised, in: shape)
                    .overlay(shape.stroke(Ink.line.opacity(0.55), lineWidth: 0.6).allowsHitTesting(false))
            }
        } else {
            MarkdownAnswer(content: message.content, style: style, expandsWidth: true).equatable()
        }
    }

    @ViewBuilder private var discussionVoiceLabel: some View {
        if let character = message.discussionCharacter {
            Label(message.role == .user ? "问\(character)" : "\(character) · 角色回答",
                  systemImage: "person.bubble")
                .font(TypeScale.caption).foregroundStyle(Ink.seal)
            if message.role == .assistant {
                Text("依据原文演绎人物想法").font(TypeScale.tiny).foregroundStyle(Ink.ink3)
            }
        }
    }

    // Sources, notes and reply suggestions under an answer.
    @ViewBuilder private var trailingParts: some View {
        if let references = message.bookReferences, !references.isEmpty, let showBookReferences {
            Button { showBookReferences() } label: {
                Label("本次书内依据 · \(references.count)处", systemImage: "text.book.closed")
                    .font(TypeScale.caption).foregroundStyle(Ink.seal)
            }.padding(.top, 6)
        }
        if let sources = message.webSources, !sources.isEmpty {
            DisclosureGroup("联网来源（\(sources.count)）") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                        if let url = URL(string: source.url) {
                            Link("[\(index + 1)] \(source.title)", destination: url)
                                .font(TypeScale.caption)
                        }
                    }
                    if let usage = message.searchUsage {
                        Text("搜索 \(usage.totalTokens) Tokens；搜索费用以服务商账单为准，未计入聊天金额估算。")
                            .font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }.font(TypeScale.caption).accessibilityIdentifier("web-search-sources")
        }
        if let note = message.note {
            Text(note).font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if message.role == .assistant, message.provider == .colab, message.state == .failed, let retryColab {
            Button("用 DeepSeek 重发这条", action: retryColab)
                .font(TypeScale.caption).foregroundStyle(Ink.seal).disabled(isGenerating)
        }
        if message.role == .assistant, message.provider == .colab, message.usage == nil, message.state != .streaming {
            Text("免费").font(TypeScale.tiny).foregroundStyle(Ink.ink3)
        }
        if isLast, message.role == .assistant, message.state == .complete, showsSuggestions, let threadID {
            ReplySuggestionPanel(message: message, threadID: threadID, use: useSuggestedReply)
        }
    }

    // The tick shows for a moment, then the copy icon comes back.
    private func copyAnswer() {
        UIPasteboard.general.string = message.content
        Haptic.tap()
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    // Tokens come from the server; the price is our estimate from the official list.
    // The ChatGPT plan has no price per answer, so it shows tokens and the plan.
    private func usageLabel(_ usage: TokenUsage) -> String {
        let tokens = "\(usage.totalTokens.formatted()) Tokens"
        if message.provider == .colab { return tokens + " · 免费" }
        if message.isSubscription { return tokens + " · 订阅额度" }
        guard let model = message.model else { return tokens }
        return tokens + " · " + Pricing.label(Pricing.cost(model: model, usage: usage, at: message.createdAt))
            + Pricing.bandTag(message.createdAt)
    }
}

// Reads like a short table of contents under the answer: number, line, hairline.
// Only the last answer has one, so its store updates touch nothing else.
@MainActor
struct ReplySuggestionPanel: View {
    @EnvironmentObject private var store: AppStore
    let message: ChatMessage
    let threadID: UUID
    let use: (String) -> Void

    var body: some View {
        // The Swiss look: a monospaced header, numbers in the accent, ruled top and bottom.
        let swiss = InterfaceStyle.isSwiss
        // Ready replies live in the composer as grey text (猜你想说); here only the
        // waiting, error and 「生成回复建议」 states remain. Swiss keeps its ruled list.
        if !swiss && message.replySuggestions != nil { EmptyView() }
        else if InterfaceStyle.isNight { nightPanel } else { listPanel(swiss: swiss) }
    }

    static func costLabel(_ batch: ReplySuggestionBatch) -> String? {
        if batch.provider == .colab { return "免费" }
        guard let usage = batch.usage else { return nil }
        return batch.provider == .chatGPT ? "订阅额度"
            : Pricing.label(Pricing.cost(model: batch.pricedModel, usage: usage, at: batch.createdAt)) + Pricing.bandTag(batch.createdAt)
    }

    // 夜江: the replies float as glass capsules on the water.
    private var nightPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let batch = message.replySuggestions {
                FlowRows(spacing: 8) {
                    ForEach(Array(batch.replies.prefix(3).enumerated()), id: \.offset) { index, reply in
                        Button { use(reply) } label: {
                            Text(reply).font(TypeScale.serif(15)).foregroundStyle(Ink.ink)
                                .multilineTextAlignment(.leading).lineSpacing(3)
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .frame(minHeight: 44)
                                .clearGlass(radius: 22)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain).disabled(store.isGenerating)
                        .accessibilityLabel("使用回复建议 \(index + 1)：\(reply)")
                        .accessibilityIdentifier("reply-suggestion-\(index)")
                    }
                }
                if let usage = batch.usage {
                    Text("建议 \(usage.totalTokens.formatted()) Tokens · " + suggestionCost(batch, usage))
                        .font(TypeScale.serif(11)).monospacedDigit().foregroundStyle(Ink.ink3)
                }
            } else if store.isSuggesting(threadID: threadID, messageID: message.id) {
                HStack(spacing: 8) {
                    PulseDot(size: 7)
                    Text("正在想几种回复…").font(TypeScale.caption).foregroundStyle(Ink.ink3)
                }.padding(.vertical, 8).accessibilityIdentifier("reply-suggestions-loading")
            } else {
                if let error = store.suggestionError(threadID: threadID, messageID: message.id) {
                    Text(error).font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                }
                Button("生成回复建议") { store.generateReplySuggestions(threadID: threadID, messageID: message.id) }
                    .font(TypeScale.caption).foregroundStyle(Ink.ink2).buttonStyle(.plain).disabled(store.isGenerating)
                    .padding(.vertical, 8)
            }
        }
        .padding(.top, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reply-suggestions-panel")
    }

    private func listPanel(swiss: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if swiss {
                MonoLabel(text: "猜你回复 / REPLIES").padding(.bottom, 6)
                SwissRule(strong: true)
            } else {
                Text("猜你回复").font(TypeScale.caption).foregroundStyle(Ink.ink3).padding(.bottom, 4)
            }
            if let batch = message.replySuggestions {
                ForEach(Array(batch.replies.prefix(3).enumerated()), id: \.offset) { index, reply in
                    Button { use(reply) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            if swiss {
                                Text(String(format: "%02d", index + 1))
                                    .font(TypeScale.mono(11)).monospacedDigit().foregroundStyle(Ink.seal)
                            } else {
                                // A light arrow instead of numbers and rules: three quiet
                                // lines you can tap, not a table of contents.
                                Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Ink.ink3).accessibilityHidden(true)
                            }
                            Text(reply).font(TypeScale.serif(15)).foregroundStyle(Ink.ink2).chineseReading()
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, swiss ? 12 : 8)
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottom) {
                            if swiss { SwissRule() }
                        }
                    }
                    .buttonStyle(.pressFeedback).disabled(store.isGenerating)
                    .accessibilityLabel("使用回复建议 \(index + 1)：\(reply)")
                    .accessibilityIdentifier("reply-suggestion-\(index)")
                }
                if let usage = batch.usage {
                    Text("建议 \(usage.totalTokens.formatted()) Tokens · " + suggestionCost(batch, usage))
                        .font(TypeScale.serif(11)).monospacedDigit().foregroundStyle(Ink.ink3).padding(.top, 2)
                }
            } else if store.isSuggesting(threadID: threadID, messageID: message.id) {
                HStack(spacing: 8) {
                    PulseDot(size: 7)
                    Text("正在想几种回复…").font(TypeScale.caption).foregroundStyle(Ink.ink3)
                }.padding(.vertical, 8).accessibilityIdentifier("reply-suggestions-loading")
            } else {
                if let error = store.suggestionError(threadID: threadID, messageID: message.id) {
                    Text(error).font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                }
                Button("生成回复建议") { store.generateReplySuggestions(threadID: threadID, messageID: message.id) }
                    .font(TypeScale.caption).foregroundStyle(Ink.ink2).buttonStyle(.plain).disabled(store.isGenerating)
                    .padding(.vertical, 8)
            }
        }
        .padding(.top, 10)
        // Without .contain the panel's identifier would replace each suggestion button's own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reply-suggestions-panel")
    }

    private func suggestionCost(_ batch: ReplySuggestionBatch, _ usage: TokenUsage) -> String {
        if batch.provider == .colab { return "免费" }
        return batch.provider == .chatGPT ? "订阅额度"
            : Pricing.label(Pricing.cost(model: batch.pricedModel, usage: usage, at: batch.createdAt)) + Pricing.bandTag(batch.createdAt)
    }
}

struct AttachmentRow: View {
    let names: [String]
    var swiss: Bool = false
    var body: some View {
        PhotoStackView(names: names, swiss: swiss)
    }
}

// Equatable so finished answers are not re-parsed while a new one streams in.
// Paragraphs, code, tables and math are Equatable too: while text arrives only
// the actively growing block is re-tokenized or laid out again.
struct MarkdownAnswer: View, Equatable {
    let content: String
    var style: InterfaceStyle = .paper
    var expandsWidth: Bool = true
    nonisolated static func == (lhs: MarkdownAnswer, rhs: MarkdownAnswer) -> Bool {
        lhs.content == rhs.content && lhs.style == rhs.style && lhs.expandsWidth == rhs.expandsWidth
    }
    private var swiss: Bool { style == .swiss }
    // Paragraphs, headings, lists, quotes, dividers and code, each text block told
    // how many of the answer's highlighter marks it may still draw.
    private var blocks: [MarkdownBlock] { MarkdownBlock.parse(content) }
    var body: some View {
        // Paragraphs a clear step apart (about one line), so each reads as its own block.
        let column = VStack(alignment: .leading, spacing: style == .swiss ? 16 : Personal.paragraphGap) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text, let marks):
                    MarkdownParagraph(text: text, marks: marks, style: style).equatable()
                case .heading(let text, let level):
                    EditorialHeadingRow(text: text, level: level, style: style)
                case .list(let items):
                    VStack(alignment: .leading, spacing: swiss ? 8 : 12) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: swiss ? 8 : 6) {
                                if swiss {
                                    // Bullets become dashes, numbers go monospaced, both in the accent.
                                    Text(item.marker == "•" ? "—" : item.marker == "◦" ? "–" : item.marker)
                                        .font(TypeScale.mono(13)).foregroundStyle(Ink.seal)
                                        .frame(minWidth: 24, alignment: .leading)
                                } else {
                                    EditorialListMarker(marker: item.marker)
                                }
                                MarkdownParagraph(text: item.text, marks: item.marks, style: style).equatable()
                            }
                            .padding(.leading, CGFloat(item.level) * 20)
                        }
                    }
                case .quote(let text, let marks):
                    MarkdownParagraph(text: text, marks: marks, style: style).equatable()
                        .padding(.leading, 14)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: swiss ? 0 : 1.0, style: .continuous)
                                .fill(swiss ? Ink.ink : Ink.ink3.opacity(0.32)).frame(width: swiss ? 3 : 2.0)
                        }
                case .table(let header, let rows, let alignments):
                    MarkdownTableBlockView(header: header, rows: rows, alignments: alignments, swiss: swiss).equatable()
                case .divider:
                    Rectangle().fill(swiss ? Ink.ink : Ink.line).frame(height: 1).padding(.vertical, 4)
                case .code(let segment):
                    MarkdownCodeBlockView(segment: segment, swiss: swiss).equatable()
                case .math(let formula):
                    MarkdownMathBlockView(formula: formula, swiss: swiss).equatable()
                }
            }
        }
        if expandsWidth {
            column.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            column
        }
    }
    fileprivate static func inline(_ text: String, baseSize: CGFloat = 18) -> AttributedString {
        HighlightMarks.parseInline(text)
            .applyingTerracottaCodeAndEmphasis(baseSize: baseSize, boldColor: Ink.seal)
    }
    fileprivate static func highlightedCode(_ body: String, language: String?) -> AttributedString {
        let tokens = CodeSyntaxTokenizer.tokenize(body, language: language)
        var result = AttributedString()
        for token in tokens {
            var part = AttributedString(token.text)
            switch token.kind {
            case .plain:
                part.foregroundColor = Ink.ink
            case .keyword:
                part.foregroundColor = Personal.syntaxKeyword
                part.inlinePresentationIntent = .stronglyEmphasized
            case .typeName:
                part.foregroundColor = Personal.syntaxType
            case .stringLiteral:
                part.foregroundColor = Personal.syntaxString
            case .numberLiteral:
                part.foregroundColor = Personal.syntaxNumber
            case .comment:
                part.foregroundColor = Ink.ink3
            }
            result.append(part)
        }
        return result
    }
}

private struct MarkdownTableBlockView: View, Equatable {
    let header: [String]
    let rows: [[String]]
    let alignments: [TableAlignment]
    let swiss: Bool

    nonisolated static func == (lhs: MarkdownTableBlockView, rhs: MarkdownTableBlockView) -> Bool {
        lhs.header == rhs.header && lhs.rows == rhs.rows && lhs.alignments == rhs.alignments && lhs.swiss == rhs.swiss
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                        TableCell(text: cell, header: true, alignment: alignments[min(column, alignments.count - 1)])
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            TableCell(text: cell, header: false, alignment: alignments[min(column, alignments.count - 1)])
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: swiss ? 0 : 12, style: .continuous)
                .stroke(swiss ? Ink.ink : Ink.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: swiss ? 0 : 12, style: .continuous))
        }
    }
}

private struct MarkdownCodeBlockView: View, Equatable {
    let segment: String
    let swiss: Bool
    @State private var showHTMLPreview = false
    @State private var copied = false

    nonisolated static func == (lhs: MarkdownCodeBlockView, rhs: MarkdownCodeBlockView) -> Bool {
        lhs.segment == rhs.segment && lhs.swiss == rhs.swiss
    }

    var body: some View {
        let parsed = CodeSyntaxTokenizer.parseHeaderAndBody(segment)
        let previewable = HTMLPreviewHelper.isPreviewable(language: parsed.language, body: parsed.body)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(swiss ? (parsed.language.map { "CODE · \($0)" } ?? "CODE") : (parsed.language ?? "代码"))
                    .font(swiss ? TypeScale.mono(10) : .system(size: 12, weight: .medium))
                    .foregroundStyle(swiss ? Ink.seal : Ink.ink3)
                Spacer()
                if previewable {
                    Button {
                        Haptic.tap()
                        showHTMLPreview = true
                    } label: {
                        Label("预览网页", systemImage: "safari")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Ink.ink2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Ink.raised, in: Capsule())
                    }
                    .buttonStyle(.pressFeedback)
                    .accessibilityLabel("预览网页效果")
                }
                Button {
                    UIPasteboard.general.string = parsed.body
                    Haptic.tap()
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(swiss ? Ink.seal : Ink.ink3)
                }
                .font(.system(size: 12.5, weight: .light))
                .accessibilityLabel("复制代码")
            }
            if !swiss {
                Rectangle().fill(Ink.line).frame(height: 0.5)
            }
            ScrollView(.horizontal) {
                Text(MarkdownAnswer.highlightedCode(parsed.body, language: parsed.language))
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(swiss ? Ink.raised : Ink.card, in: RoundedRectangle(cornerRadius: swiss ? 0 : 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: swiss ? 0 : 14, style: .continuous)
            .stroke(Ink.line, lineWidth: swiss ? 1 : 0.8).allowsHitTesting(false))
        .sheet(isPresented: $showHTMLPreview) {
            HTMLPreviewSheet(code: parsed.body, language: parsed.language)
        }
    }
}

private struct MarkdownMathBlockView: View, Equatable {
    let formula: String
    let swiss: Bool
    @State private var copied = false

    nonisolated static func == (lhs: MarkdownMathBlockView, rhs: MarkdownMathBlockView) -> Bool {
        lhs.formula == rhs.formula && lhs.swiss == rhs.swiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(swiss ? "MATH" : "公式")
                    .font(swiss ? TypeScale.mono(10) : .system(size: 12, weight: .medium))
                    .foregroundStyle(swiss ? Ink.seal : Ink.ink3)
                Spacer()
                Button {
                    UIPasteboard.general.string = formula
                    Haptic.tap()
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(swiss ? Ink.seal : Ink.ink3)
                }
                .font(.system(size: 12.5, weight: .light))
                .accessibilityLabel("复制公式原文")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(MathFormatter.format(formula))
                    .font(.system(size: 16, design: .serif))
                    .italic()
                    .foregroundStyle(Ink.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
            }
        }
        .padding(14)
        .background(swiss ? Ink.raised : Ink.card, in: RoundedRectangle(cornerRadius: swiss ? 0 : 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: swiss ? 0 : 14, style: .continuous)
            .stroke(Ink.line, lineWidth: swiss ? 1 : 0.8).allowsHitTesting(false))
    }
}

// One table cell: inline Markdown, wrapped past a comfortable width, a hairline below.
struct TableCell: View {
    let text: String
    let header: Bool
    let alignment: TableAlignment
    @AppStorage(FontLibrary.choiceKey) private var fontChoice = ""
    @AppStorage(FontLibrary.revisionKey) private var fontRevision = 0
    @AppStorage("qingjian.reading.size") private var readingSize = 16.0
    private var frameAlignment: Alignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
    var body: some View {
        let _ = (fontChoice, fontRevision, StyleAppearance.shared.revision, FontAppearance.shared.revision)
        let styled = HighlightMarks.parseInline(text)
            .applyingEditorialStyle(baseSize: max(14, CGFloat(readingSize) - 2),
                                    boldColor: header ? Ink.ink : nil,
                                    forceBold: header)
        Text(styled)
            .foregroundStyle(header ? Ink.ink : Ink.ink2)
            .chineseReading()
            .multilineTextAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .frame(minWidth: 56, maxWidth: 240, alignment: frameAlignment)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
            .background(header ? Ink.raised : Color.clear)
            .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 0.5) }
    }
}

private struct EditorialHeadingRow: View {
    let text: String
    let level: Int
    let style: InterfaceStyle
    @AppStorage(FontLibrary.choiceKey) private var fontChoice = ""
    @AppStorage(FontLibrary.revisionKey) private var fontRevision = 0
    @AppStorage("qingjian.reading.size") private var readingSize = 16.0
    var body: some View {
        let _ = (fontChoice, fontRevision, StyleAppearance.shared.revision, FontAppearance.shared.revision)
        let delta: CGFloat = level == 1 ? 5 : (level == 2 ? 3.5 : 2)
        let styled = HighlightMarks.parseInline(text).applyingEditorialStyle(
            baseSize: CGFloat(readingSize) + delta,
            boldColor: style == .swiss ? Ink.seal : Ink.ink,
            forceBold: true
        )
        Text(styled)
            .chineseReading()
            .foregroundStyle(Ink.ink)
            .padding(.top, 6)
    }
}

private struct EditorialListMarker: View {
    let marker: String
    @AppStorage(FontLibrary.choiceKey) private var fontChoice = ""
    @AppStorage(FontLibrary.revisionKey) private var fontRevision = 0
    @AppStorage("qingjian.reading.size") private var readingSize = 16.0
    var body: some View {
        let _ = (fontChoice, fontRevision, StyleAppearance.shared.revision, FontAppearance.shared.revision)
        let isNumbered = marker != "•" && marker != "◦"
        Text(marker)
            .font(ReadingFont.resolve(baseSize: CGFloat(readingSize), bold: isNumbered, italic: false))
            .monospacedDigit()
            .foregroundStyle(Ink.ink)
            .frame(minWidth: isNumbered ? 20 : 12, alignment: .leading)
    }
}

struct MarkdownParagraph: View, Equatable {
    let text: String
    /// Kept for callers; bold phrases are no longer drawn as highlighter marks.
    var marks = HighlightMarks.perAnswer
    /// The Swiss look draws bold in the accent colour instead of a highlighter.
    var style: InterfaceStyle = .paper
    nonisolated static func == (lhs: MarkdownParagraph, rhs: MarkdownParagraph) -> Bool {
        lhs.text == rhs.text && lhs.marks == rhs.marks && lhs.style == rhs.style
    }
    private var parsed: AttributedString {
        HighlightMarks.parseInline(text)
    }
    var body: some View {
        if text.hasPrefix("#") {
            let level = text.prefix(while: { $0 == "#" }).count
            let bodyText = String(text.drop(while: { $0 == "#" || $0 == " " }))
            EditorialHeadingRow(text: bodyText, level: level, style: style)
        } else if style == .swiss {
            Text(markdown: parsed, emphasis: Ink.seal).readingStyle(adjustment: -1).lineSpacing(6)
                .foregroundStyle(Ink.ink)
        } else {
            EditorialParagraphBody(parsed: parsed)
        }
    }
}

/// Non-equatable inner view so appearance/font/size changes redraw paragraphs even while `MarkdownParagraph` stays `.equatable()`.
private struct EditorialParagraphBody: View {
    let parsed: AttributedString
    @AppStorage(FontLibrary.choiceKey) private var fontChoice = ""
    @AppStorage(FontLibrary.revisionKey) private var fontRevision = 0
    @AppStorage("qingjian.reading.size") private var readingSize = 16.0
    var body: some View {
        let _ = (fontChoice, fontRevision, StyleAppearance.shared.revision, FontAppearance.shared.revision)
        Text(parsed.applyingEditorialStyle(baseSize: CGFloat(readingSize)))
            .lineSpacing(Personal.lineSpacing)
            .chineseReading()
            .foregroundStyle(Ink.ink)
    }
}

@MainActor
struct EditMessageView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let message: ChatMessage
    @State private var text = ""
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(message.role == .user ? "保存会直接修改这条消息；重新发送会替换其后的内容。" : "直接修改当前回答，不新建对话。")
                    .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                TextEditor(text: $text).readingStyle().scrollContentBackground(.hidden)
                    .padding(12).background(Ink.raised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityIdentifier("message-editor")
                if message.role == .user {
                    Button {
                        if store.editMessage(message.id, text: text, resend: true) { dismiss() }
                    } label: {
                        Text("保存并重新发送").frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.inkPrimary)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(20).background(Ink.groupedBg.ignoresSafeArea())
                .navigationTitle(message.role == .user ? "编辑你的消息" : "编辑回答")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { ClaudeSheetCloseButton(label: "取消") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存") {
                            if store.editMessage(message.id, text: text, resend: false) { dismiss() }
                        }.fontWeight(.semibold).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }.tint(Ink.ink).presentationDragIndicator(.visible)
            .onAppear { text = message.content }
            .alert("暂时没有完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("知道了") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
    }
}

// "10月13日 14:32"; the year is added only for another year.
enum MessageTime {
    private static let todayOnly: DateFormatter = make("HH:mm")
    private static let sameYearShort: DateFormatter = make("M/d HH:mm")
    private static let sameYear: DateFormatter = make("M月d日 HH:mm")
    private static let otherYear: DateFormatter = make("yyyy年M月d日 HH:mm")
    private static func make(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = format
        return formatter
    }
    static func label(_ date: Date) -> String {
        let calendar = Calendar.current
        return (calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? sameYear : otherYear).string(from: date)
    }
    static func swipeLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return todayOnly.string(from: date) }
        return (calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? sameYearShort : otherYear).string(from: date)
    }
}

private struct DocumentPreviewTarget: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

private struct MessageDocumentCards: View {
    let attachments: [MessageDocumentAttachment]
    let swiss: Bool
    @State private var previewTarget: DocumentPreviewTarget?

    var body: some View {
        VStack(alignment: swiss ? .leading : .trailing, spacing: 6) {
            ForEach(attachments) { item in
                Button {
                    let fullTitle = item.fileExtension.isEmpty ? item.name : "\(item.name).\(item.fileExtension)"
                    previewTarget = DocumentPreviewTarget(title: fullTitle, text: item.text)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Ink.seal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.fileExtension.isEmpty ? item.name : "\(item.name).\(item.fileExtension)")
                                .font(TypeScale.label)
                                .foregroundStyle(Ink.ink)
                                .lineLimit(1)
                            Text("\(item.characterCount.formatted()) 字 · 点击展开")
                                .font(TypeScale.tiny)
                                .foregroundStyle(Ink.ink3)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Ink.ink3)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 260, alignment: .leading)
                    .background(Ink.raised, in: RoundedRectangle(cornerRadius: swiss ? 0 : 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: swiss ? 0 : 14, style: .continuous).stroke(Ink.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: $previewTarget) { target in
            DocumentPreviewSheet(target: target)
        }
    }
}

private struct DocumentPreviewSheet: View {
    let target: DocumentPreviewTarget
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(target.text)
                    .font(.system(size: 13.5, design: .monospaced))
                    .foregroundStyle(Ink.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Ink.paper)
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ClaudeSheetCloseButton(label: "关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(copied ? "已复制" : "复制全文") {
                        UIPasteboard.general.string = target.text
                        copied = true
                    }
                }
            }
        }
        .tint(Ink.ink)
        .presentationDragIndicator(.visible)
    }
}
