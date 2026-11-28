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
    @State private var initialProjectID: UUID? = nil
    @State private var showAllChats = previewFlag("all-chats")
    @State private var intakeToReview: ShareIntakeItem?
    @State private var reviewingBackup = false
    @State private var showSidebar = previewFlag("sidebar")
    @State private var keyboardVisible = false
    @State private var composerPanelHeight: CGFloat = 130
    @AppStorage(AppearanceMode.key) private var appearance = AppearanceMode.system.rawValue

    var body: some View {
        let _ = StyleAppearance.shared.revision
        GeometryReader { geometry in
            let bottomInset = geometry.safeAreaInsets.bottom
            let topInset = geometry.safeAreaInsets.top
            let excludedHeight = composerPanelHeight + (keyboardVisible ? 0 : bottomInset + FloatingChrome.navigationHeight)
            SidebarDrawerContainer(
                isOpen: $showSidebar,
                reduceMotion: reduceMotion,
                appearanceRaw: appearance,
                styleRevision: StyleAppearance.shared.revision,
                composerExcludedHeight: excludedHeight,
                sidebarBuilder: {
                    HistorySidebar(close: { showSidebar = false },
                                   openSettings: { showSettings = true },
                                   openProjects: { initialProjectID = nil; showProjects = true },
                                   openAllChats: { showAllChats = true })
                        .environmentObject(store)
                        .environmentObject(profile)
                        .preferredColorScheme(AppearanceMode.scheme(appearance))
                },
                main: NavigationStack {
                    ChatScreen(openHistory: { showSidebar = true },
                               openSettings: { showSettings = true },
                               openProject: { id in initialProjectID = id; showProjects = true },
                               reviewIncoming: { intakeToReview = store.pendingShareIntake },
                               reviewBackup: { reviewingBackup = true },
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
            Haptic.settle()
            if open { store.refreshBalance() }
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store).environmentObject(profile) }
        .sheet(item: Binding(get: { reviewingBackup && !showSettings ? store.unifiedRestorePreview : nil }, set: { value in
            if reviewingBackup { store.unifiedRestorePreview = value }
        }), onDismiss: { reviewingBackup = false }) { preview in
            UnifiedRestorePreviewSheet(preview: preview)
                .environmentObject(store)
        }
        .sheet(isPresented: $showProjects, onDismiss: { initialProjectID = nil }) {
            ProjectsView(
                opened: { showProjects = false; showSidebar = false },
                initialProjectID: initialProjectID,
                initiallyUnlocked: initialProjectID.map { !store.isLocked($0) } ?? false
            )
            .environmentObject(store)
            .environmentObject(profile)
        }
        // Route files & deep links opened from Files / WeChat / Safari / Shortcuts:
        // .sermobackup opens backup restore directly; all other files, images, links & notes
        // open the lightweight intake card to send to the active chat or file into a project library.
        .onOpenURL { url in
            switch ShareIntakeURLParser.parse(url) {
            case .backup(let backupURL):
                Task {
                    guard let local = await Task.detached(priority: .userInitiated, operation: { IncomingFile.privateCopy(of: backupURL) }).value else {
                        store.errorMessage = "没能读取这个备份文件，请在「文件」里确认它已下载后再试。"
                        return
                    }
                    store.prepareBackupRestore(local, removeWhenDone: true)
                }
            case .intake(let item):
                if let fileURL = item.localFileURL {
                    Task { @MainActor in
                        guard let local = await Task.detached(priority: .userInitiated, operation: { IncomingFile.privateCopy(of: fileURL) }).value else {
                            store.errorMessage = "没能读取这个文件，请在「文件」里确认它已下载后再试。"
                            return
                        }
                        var copied = item
                        copied.localFilePath = local.path
                        store.enqueueShareIntake(copied)
                    }
                } else {
                    store.enqueueShareIntake(item)
                }
            case .ignored:
                break
            }
        }
        .sheet(item: $intakeToReview, onDismiss: { store.advanceShareIntakeQueue() }) { item in
            ShareIntakeSheet(
                item: item,
                onSendToCurrentChat: { chosen in
                    switch chosen.kind {
                    case .file:
                        if let url = chosen.localFileURL { store.incomingChatFileURL = url }
                    case .image:
                        if let url = chosen.localFileURL { store.incomingChatImageURL = url }
                    case .webLink, .text:
                        let text = chosen.composerPrefillText()
                        if !text.isEmpty { store.incomingChatPrefillText = text }
                    }
                },
                onDismissCleanup: {
                    if let url = item.localFileURL,
                       url.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            )
            .environmentObject(store)
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

// These panels stay attached to the conversation that opened them.
private struct ConversationPanelTarget: Identifiable {
    let threadID: UUID
    var id: UUID { threadID }
}

struct ChatPhotoLibrarySheet: UIViewControllerRepresentable {
    let limit: Int
    let selected: ([PHPickerResult]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(selected: selected) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        let picker = ChatPhotoPicker.makePicker(limit: limit)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}

    @MainActor final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let selected: ([PHPickerResult]) -> Void
        init(selected: @escaping ([PHPickerResult]) -> Void) { self.selected = selected }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            selected(results)
        }
    }
}

@MainActor
enum ChatPhotoPicker {
    static func makePicker(limit: Int) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = max(1, min(4, limit))
        config.selection = .ordered
        config.preferredAssetRepresentationMode = .current
        return PHPickerViewController(configuration: config)
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


}

@MainActor @Observable
private final class ChatScrollUIState {
    var showJumpToLatest = false
}

/// Isolates live typing text in its own `@Observable` model so keystrokes only
/// invalidate `ComposerObserverScope` inside `composerHost` and never re-evaluate
/// `ChatScreen.body` or `transcript` / `messageRows` (PERF-4).
@MainActor @Observable
private final class ComposerDraftModel {
    var text: String = ""
}

@MainActor
private struct ComposerObserverScope<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}

/// 1.47.1: how the conversation keeps up with what is being written.
///
/// While you are at the end of the page it stays there: new text, a card, a picture, the
/// finished answer's controls, the keyboard coming or going all push the page up instead of
/// running off below the screen. A finger on the page pauses that (the page never fights
/// the finger); when you let go it carries on, unless you yourself moved the page up by
/// more than about three lines, which means you are reading above. Back at the end, or
/// with the 「↓」 button, it follows again.
///
/// Kept in a plain object, not view state: it changes as you scroll and the page does not
/// need to redraw for it.
@MainActor
private final class TranscriptScrollBox {
    var proxy: ScrollViewProxy?
    /// Following the end of the conversation.
    var follows = true
    /// The page as last measured.
    var geometry = TranscriptGeometry()
    /// A finger, or the fling it left, is moving the page: the page as it was when it began.
    var touch: TranscriptGeometry?
    var sidebarOpen = false
    /// Until then the page also follows growth when nothing is being written (an answer's
    /// controls arriving as it finishes, a chat you just opened finishing its layout).
    private var followsGrowthUntil: TimeInterval = 0

    /// Moved up by more than this yourself and the page stops following (about three lines).
    static let readingAbove: CGFloat = 80

    /// Someone is watching the end of the answer: for 出字震动.
    var watchingLive: Bool { follows && touch == nil && !sidebarOpen }
    var followsGrowth: Bool { Date().timeIntervalSinceReferenceDate < followsGrowthUntil }
    func followGrowth(for seconds: TimeInterval) {
        followsGrowthUntil = max(followsGrowthUntil, Date().timeIntervalSinceReferenceDate + seconds)
    }

    /// Down to the end: a short glide when it is near, a jump when it is more than a screen.
    func glideToBottom() {
        guard let proxy else { return }
        let travel = abs(geometry.distance)
        guard travel > 0.5 else { return }
        if Motion.reduced || travel > geometry.visibleHeight * 1.2 {
            proxy.scrollTo("chat-bottom-anchor", anchor: .bottom)
        } else {
            withAnimation(Motion.follow) { proxy.scrollTo("chat-bottom-anchor", anchor: .bottom) }
        }
    }
    func scrollToBottom(animated: Bool = false, with animation: Animation = Motion.snappy) {
        guard let proxy else { return }
        if animated && !Motion.reduced {
            withAnimation(animation) {
                proxy.scrollTo("chat-bottom-anchor", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("chat-bottom-anchor", anchor: .bottom)
        }
    }
    func scrollToMessage(_ id: UUID) {
        proxy?.scrollTo(id, anchor: .top)
    }
}

/// The transcript's scroll position and size, as much as following the end needs.
private struct TranscriptGeometry: Equatable {
    var contentHeight: CGFloat = 0
    var insetTop: CGFloat = 0
    var insetBottom: CGFloat = 0
    var containerHeight: CGFloat = 0
    var offsetY: CGFloat = 0

    init() {}
    init(_ g: ScrollGeometry) {
        contentHeight = (g.contentSize.height * 2).rounded() / 2
        insetTop = g.contentInsets.top
        insetBottom = g.contentInsets.bottom
        containerHeight = g.containerSize.height
        offsetY = g.contentOffset.y
    }
    /// How much of the conversation is below the visible part (below zero: pulled past the end).
    var distance: CGFloat { contentHeight + insetBottom - offsetY - containerHeight }
    /// The part between the top bar and the composer.
    var visibleHeight: CGFloat { max(0, containerHeight - insetTop - insetBottom) }
    /// Same page, only scrolled.
    func sameSize(as other: TranscriptGeometry) -> Bool {
        abs(contentHeight - other.contentHeight) < 0.5 && abs(insetBottom - other.insetBottom) < 0.5
            && abs(insetTop - other.insetTop) < 0.5 && abs(containerHeight - other.containerHeight) < 0.5
    }
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
    var openProject: (UUID) -> Void = { _ in }
    let reviewIncoming: () -> Void
    let reviewBackup: () -> Void
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
    /// Following the end of the conversation (kept on `scrollBox`, see there).
    private var followsOutput: Bool {
        get { scrollBox.follows }
        nonmutating set { scrollBox.follows = newValue }
    }
    @State private var scrollUIState = ChatScrollUIState()
    @State private var timeReveal = SwipeTimeRevealModel()
    @State private var cachedContext: ContextUsageSnapshot?
    @State private var choosingFiles = false
    @State private var choosingPhotos = false
    @State private var fileImportTask: Task<Void, Never>?
    @State private var fileImportThreadID: UUID?
    @State private var fileImportProgress = ""
    @State private var queuedFileImports: [(urls: [URL], origin: UUID, removeAfterImport: Bool)] = []
    @State private var photoLoadThreadID: UUID?
    @State private var photoLoadSessionID: UUID?
    @State private var photoLoadTask: Task<Void, Never>?
    @State private var imagesByThread: [UUID: [PendingImage]] = [:]
    @State private var documentsByThread: [UUID: [PendingDocument]] = [:]
    @State private var previewingDocument: DocumentPreviewTarget?
    @State private var attachmentReport: String?
    @State private var showAddToChatSheet = false
    @State private var afterAttachmentDismissal: (() -> Void)?
    @StateObject private var systemPickers = DocumentPicker()
    @State private var reportDetails: String?
    @State private var agentTimelineTarget: AgentTimelineTarget?
    @State private var showWorkspaceSheet = false
    @State private var selectedDeliverable: ProjectDeliverable?
    @State private var showVoiceDictationSheet = false
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
    @State private var skillDraftTarget: ProjectSkillTarget?
    @State private var memorySheetTarget: ProjectMemoryTarget?
    @State private var versionsTarget: ConversationPanelTarget?
    @State private var messageBrowser: ChatMessageBrowserRequest?
    @State private var messageBrowserVisible = false
    @State private var pendingMessageJump: ChatMessageJump?
    @State private var focusedMessageID: UUID?
    @State private var quotingMessage: QuotedMessage?
    private var isEmptyPage: Bool { store.activeThread?.messages.isEmpty != false }
    private var composerPlaceholder: String {
        if store.isGenerating(in: store.activeThreadID) {
            return "中途补充要求，当前步骤完成后衔接…"
        }
        return "与 Sermo 对话"
    }
    private var hasInput: Bool {
        !localDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty || !pendingDocuments.isEmpty
    }
    // 猜你想说: after an answer, one suggested reply waits as grey text in the empty
    // composer; send takes it as is, a tap on it puts it in to edit, 「换一条」 cycles.
    @State private var suggestionIndex = 0
    private var ghostSource: ChatMessage? {
        guard store.settings.shouldSuggestReplies, store.activeProject?.studySubject == nil,
              !store.isGenerating, let thread = store.activeThread,
              !store.isHidden(thread), let last = thread.messages.last, last.role == .assistant,
              last.state == .complete, let batch = last.replySuggestions, !batch.replies.isEmpty else { return nil }
        return last
    }
    private var ghostReplies: [String] { Array(ghostSource?.replySuggestions?.replies.prefix(3) ?? []) }
    private var ghostText: String? {
        guard quotingMessage == nil, !hasInput, !ghostReplies.isEmpty else { return nil }
        return ghostReplies[suggestionIndex % ghostReplies.count]
    }
    /// Sends with the 1.47 motion: a firm tap, your message rises out of the composer and
    /// the page glides up after it.
    private func sendAnimated(_ text: String, images: [Data]) -> Bool {
        Haptic.send()
        lastSendAt = Date()
        return withMotion(Motion.lively) { store.send(text, images: images) }
    }

    private func takeGhost(send: Bool) {
        guard let text = ghostText, let source = ghostSource, let threadID = store.activeThreadID,
              store.useReplySuggestion(text, threadID: threadID, messageID: source.id) else { return }
        clearMessageNavigation()
        followsOutput = true
        if send {
            if sendAnimated(store.activeDraft, images: []) {
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

    // Only a small round 「换一条」 button, right-aligned above the composer; no label, no cost.
    @ViewBuilder private var ghostBar: some View {
        if ghostText != nil, ghostReplies.count > 1 {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button {
                    Haptic.select()
                    withMotion(Motion.snappy) { suggestionIndex += 1 }
                } label: {
                    // Turns a full circle each time, so you feel it fetch the next one.
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .regular))
                        .rotationEffect(.degrees(Double(suggestionIndex) * 180))
                        .animation(Motion.lively.motionSafe, value: suggestionIndex)
                        .foregroundStyle(Ink.ink2)
                        .frame(width: 32, height: 32)
                        .background(Ink.card, in: Circle())
                        .overlay(Circle().stroke(Ink.line, lineWidth: 0.6))
                        .contentShape(Circle())
                }
                .buttonStyle(.pressFeedback)
                .accessibilityLabel("换一条猜你想说")
            }
            .padding(.horizontal, 6)
            .transition(.pop)
        }
    }
    @State private var scrollBox = TranscriptScrollBox()
    // 1.47 motion: how far the transcript has settled in after a chat switch (0 to 1), when you
    // last sent (so the scroll that follows glides), and the answer that has just finished here.
    @State private var threadEntrance: Double = 1
    @State private var lastSendAt = Date.distantPast
    @State private var justFinishedID: UUID?
    @State private var bottomObstruction: CGFloat = 0
    @State private var visibleMessageCount = 40
    @State private var hasPositionedInitially = false
    private var visibleMessages: [ChatMessage] {
        guard let thread = store.activeThread, !store.isHidden(thread) else { return [] }
        return Array(thread.messages.suffix(visibleMessageCount))
    }
    private var shouldFollowOutput: Bool { followsOutput && pendingMessageJump == nil && focusedMessageID == nil }

    // Typing stays inside `draftModel` (observed only by `ComposerObserverScope`) and reaches
    // the store off-main-thread after a brief pause; `composerHeightBucket` only changes when
    // line count / empty / slash state changes so `KeyboardChatLayout` avoids per-key measurements.
    @State private var draftModel = ComposerDraftModel()
    @State private var composerHeightBucket = 0
    @State private var draftThreadID: UUID?
    @State private var lastPushedDraft = ""
    @State private var draftPushTask: Task<Void, Never>?
    private static func computeHeightBucket(for text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmpty = trimmed.isEmpty ? 0 : 1
        let slash = (trimmed.hasPrefix("/") || trimmed.hasPrefix("／")) ? 1 : 0
        let explicitLines = text.reduce(1) { $0 + ($1 == "\n" ? 1 : 0) }
        let wrappedEst = min(5, max(explicitLines, (text.count / 24) + 1))
        return (nonEmpty * 100) + (slash * 10) + wrappedEst
    }
    private var localDraft: String {
        get { draftModel.text }
        nonmutating set {
            draftModel.text = newValue
            let nextBucket = Self.computeHeightBucket(for: newValue)
            if composerHeightBucket != nextBucket {
                composerHeightBucket = nextBucket
            }
        }
    }
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

    private func consumeIncomingChatTransfers() {
        let origin = store.activeThreadID ?? store.threads.first?.id
        if let incomingFile = store.incomingChatFileURL, let origin {
            store.incomingChatFileURL = nil
            importDocuments([incomingFile], into: origin, removeAfterImport: true)
        }
        if let incomingImage = store.incomingChatImageURL {
            store.incomingChatImageURL = nil
            Task { @MainActor in
                defer {
                    if incomingImage.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                        try? FileManager.default.removeItem(at: incomingImage)
                    }
                }
                guard let origin else { return }
                do {
                    let jpeg = try await Task.detached(priority: .userInitiated) {
                        try ImageStore.prepared(file: incomingImage)
                    }.value
                    guard let thread = store.threads.first(where: { $0.id == origin }), !store.isHidden(thread) else {
                        attachmentReport = "原对话已删除或上锁，图片未添加。"
                        return
                    }
                    guard (imagesByThread[origin]?.count ?? 0) < 4 else {
                        attachmentReport = "待发送图片已满 4 张，请先发送或移除一张。"
                        return
                    }
                    guard let preview = UIImage(data: jpeg) else { throw ChatError.server("图片无法预览。") }
                    imagesByThread[origin, default: []].append(PendingImage(data: jpeg, preview: preview))
                } catch { attachmentReport = error.localizedDescription }
            }
        }
        if let prefill = store.incomingChatPrefillText {
            store.incomingChatPrefillText = nil
            localDraft = OralDrillPromptBuilder.mergeIntoDraft(existing: localDraft, spoken: prefill)
            scheduleDraftPush()
        }
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

    private var effectiveBottomObstruction: CGFloat {
        max(keyboardVisible ? 0 : bottomInset, bottomObstruction)
    }

    private var composerLayoutSignature: Int {
        var hasher = Hasher()
        hasher.combine(composerHeightBucket)
        hasher.combine(store.pendingShareIntake?.id)
        hasher.combine(store.unifiedRestorePreview?.id)
        hasher.combine(store.errorMessage)
        hasher.combine(attachmentReport)
        hasher.combine(store.noticeMessage)
        hasher.combine(store.composerNotice?.id)
        hasher.combine(pendingImages.count)
        hasher.combine(pendingDocuments.count)
        hasher.combine(quotingMessage != nil)
        hasher.combine(ghostSource?.id)
        hasher.combine(suggestionIndex)
        hasher.combine(store.pendingApproval?.id)
        hasher.combine(store.pendingApproval?.threadID == store.activeThreadID)
        hasher.combine(store.searchingThreadID == store.activeThreadID && store.isGenerating)
        hasher.combine(store.isGenerating)
        hasher.combine(store.generatingThreadID == store.activeThreadID)
        hasher.combine(store.canChat)
        hasher.combine(keyboardVisible)
        hasher.combine(cachedContext != nil)
        return hasher.finalize()
    }

    private var transcript: some View {
        let bottomClearance = composerPanelHeight + effectiveBottomObstruction
        return ZStack(alignment: .bottom) {
            if isEmptyPage {
                VStack(spacing: 0) {
                    Spacer(minLength: 12)
                    WelcomeView(name: profile.name, page: store.activeThreadID ?? UUID(), projectName: store.activeProject?.name,
                                incognito: store.activeThread?.keepsOutOfMemory == true)
                        .id(store.activeThreadID)
                    Spacer(minLength: 12)
                }
                .padding(.top, topChrome)
                .padding(.bottom, bottomClearance)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isComposerFocused { focusComposer(false) }
                }
            } else {
                let rowSpacing: CGFloat = 30
                let totalMessagesCount = store.activeThread?.messages.count ?? 0
                ScrollViewReader { scrollProxy in
                    let _ = (scrollBox.proxy = scrollProxy)
                    ScrollView {
                        VStack(alignment: .leading, spacing: rowSpacing) {
                            if totalMessagesCount > visibleMessageCount {
                                Button("查看更早消息（还有 \(totalMessagesCount - visibleMessageCount) 条）") {
                                    followsOutput = false
                                    let anchorID = visibleMessages.first?.id
                                    visibleMessageCount += 40
                                    if let anchorID {
                                        DispatchQueue.main.async {
                                            scrollBox.scrollToMessage(anchorID)
                                        }
                                    }
                                }.font(TypeScale.caption).foregroundStyle(Palette.secondary)
                                    .frame(maxWidth: .infinity)
                            }
                            messageRows
                            Color.clear.frame(height: 1).id("chat-bottom-anchor")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Personal.margin).padding(.top, 10).padding(.bottom, 18)
                        // 1.47: a chat you switch to settles in instead of snapping into place.
                        .opacity(threadEntrance)
                        .offset(y: (1 - threadEntrance) * 14)
                    }
                    .accessibilityIdentifier("chat-scroll")
                    // Native iOS 26 soft edge blur at both top and bottom so text gently dissolves
                    // behind the floating glass toolbar, composer, and Home Indicator.
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
                    .contentMargins(.top, topChrome, for: .scrollContent)
                    .contentMargins(.top, topChrome, for: .scrollIndicators)
                    .contentMargins(.bottom, bottomClearance + 14, for: .scrollContent)
                    .contentMargins(.bottom, bottomClearance + 14, for: .scrollIndicators)
                    .scrollDismissesKeyboard(.interactively)
                    .onAppear { transcriptAppeared() }
                    .onScrollGeometryChange(for: TranscriptGeometry.self) { g in
                        TranscriptGeometry(g)
                    } action: { old, new in
                        transcriptMoved(from: old, to: new)
                    }
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting || phase == .decelerating {
                            if timeReveal.offset != 0 { timeReveal.offset = 0 }
                        }
                        transcriptPhase(phase)
                    }
                    .onChange(of: store.activeThread?.messages.count) { _, _ in
                        guard shouldFollowOutput else { return }
                        scrollBox.followGrowth(for: 1.2)
                        // Right after you send, the page glides up with your message.
                        let justSent = Date().timeIntervalSince(lastSendAt) < 1
                        scrollBox.scrollToBottom(animated: justSent, with: Motion.lively)
                    }
                    .onChange(of: store.activeThread?.messages.last?.replySuggestions) { _, _ in
                        if shouldFollowOutput { scrollBox.scrollToBottom() }
                    }
                }
            }

            ChatFloatingControlsOverlay(
                scrollUIState: scrollUIState,
                hasMessages: !isEmptyPage,
                canChooseProject: store.canChooseProject,
                projectMenu: { projectPill },
                jumpToLatest: jumpToLatest
            )
            .padding(.horizontal, 16)
            .padding(.bottom, bottomClearance + 8)
        }
    }

    var body: some View { chatWithAlerts.systemPickerHost(systemPickers) }

    // Separate opaque view expressions keep type checking bounded. State remains
    // on ChatScreen, and the transcript preference stays inside its hosting tree.
    private var chatLayout: some View {
        KeyboardChatLayout(
            layoutSignature: composerLayoutSignature,
            onBottomObstructionChange: { obstructed in
                if abs(bottomObstruction - obstructed) > 0.5 {
                    bottomObstruction = obstructed
                }
            }
        ) {
            transcript.environmentObject(store).environmentObject(profile)
        } composer: {
            composer.fixedSize(horizontal: false, vertical: true)
                .environmentObject(store).environmentObject(profile)
        }
        // Up under the status bar and down behind the Home Indicator so prose glides smoothly
        // beneath both the top glass chrome and bottom Liquid Glass composer on iPhone Air.
        .ignoresSafeArea(.container, edges: [.top, .bottom])
    }

    private var chatWithNavigation: some View {
        chatLayout
        .background(AppBackground())
        .navigationTitle("Sermo")
        .navigationBarTitleDisplayMode(.inline)
        // No title in the bar: only the floating glass buttons, as in the Claude app.
        .toolbar(removing: .title)
        .toolbar {
            if let activeProject = store.activeProject {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        focusComposer(false)
                        openProject(activeProject.id)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15.5, weight: .medium))
                    }
                    .accessibilityLabel("返回项目 \(activeProject.name)")
                    .accessibilityIdentifier("chat-back-to-project")
                }
                ToolbarSpacer(.fixed, placement: .topBarLeading)
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        focusComposer(false)
                        openProject(activeProject.id)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: activeProject.studySubject != nil ? "graduationcap" : "tray.full")
                                .font(.system(size: 13.5, weight: .regular))
                            Text(activeProject.name.count > 9 ? String(activeProject.name.prefix(8)) + "…" : activeProject.name)
                                .font(.system(size: 14, weight: .medium))
                                .lineLimit(1)
                        }
                    }
                    .accessibilityLabel("当前所属项目：\(activeProject.name)，点击返回项目")
                    .accessibilityIdentifier("chat-project-badge")
                }
            } else {
                ToolbarItem(placement: .topBarLeading) {
                    Button { focusComposer(false); openHistory() } label: { SidebarGlyph() }
                        .accessibilityLabel("打开历史对话")
                }
            }
            // Like the Claude app: no title in the bar, only the floating glass controls.
            // In a conversation the right one holds optional deliverables shortcut, new-page and a "⋯" menu.
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !store.workspaceDeliverables(projectID: store.activeThread?.projectID, threadID: store.activeThreadID).isEmpty {
                    Button {
                        focusComposer(false)
                        showWorkspaceSheet = true
                    } label: {
                        Image(systemName: "doc.text").font(.system(size: 15.5, weight: .regular))
                    }
                    .accessibilityLabel("项目成果与资料库")
                    .accessibilityIdentifier("workspace-sheet-button")
                }
                // A new page stays in the project you are in.
                Button { store.createThread(in: store.activeThread?.projectID); followsOutput = true } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 16, weight: .regular))
                }
                    .accessibilityLabel("新建对话")
                if !isEmptyPage || store.activeProject != nil { titleMenu }
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
        .sheet(item: $skillDraftTarget) { target in
            ProjectSkillEditor(projectID: target.projectID, draft: target.draft).environmentObject(store)
        }
        .sheet(item: $memorySheetTarget) { target in
            ProjectMemorySheet(projectID: target.id).environmentObject(store)
        }
    }

    private var chatWithFocusEvents: some View {
        chatWithPromptAndVersionSheets
        .onChange(of: isComposerFocused) { _, focused in
            keyboardVisible = focused
            if timeReveal.offset != 0 { timeReveal.offset = 0 }
            if focused && shouldFollowOutput { scrollBox.scrollToBottom() }
        }
        .onChange(of: sidebarOpen) { _, open in
            scrollBox.sidebarOpen = open
            if open && timeReveal.offset != 0 { timeReveal.offset = 0 }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            flushDraft()
            if timeReveal.offset != 0 { timeReveal.offset = 0 }
        }
        .onAppear {
            loadDraft()
            refreshContextStats()
            consumeIncomingChatTransfers()
        }
    }

    private var chatWithGenerationEvents: some View {
        chatWithFocusEvents
        .onChange(of: store.activeThread?.messages.count) { _, _ in refreshContextStats() }
        .onChange(of: store.isGenerating) { _, generating in if !generating { refreshContextStats() } }
        // An answer here has just finished: 「嗒嗒」, and its controls rise in.
        .onChange(of: store.generatingThreadID) { old, new in answerEnded(writingIn: old, now: new) }
        .onChange(of: store.compactingThreadID) { _, _ in refreshContextStats() }
        .onChange(of: store.activeChatSettings) { _, _ in refreshContextStats() }
    }

    private func answerEnded(writingIn old: UUID?, now new: UUID?) {
        guard new == nil, let old, old == store.activeThreadID else { return }
        // The answer's controls (or 重试) arrive below it: brought into view if you are at the end.
        scrollBox.followGrowth(for: 1.6)
        DispatchQueue.main.async {
            if shouldFollowOutput && scrollBox.touch == nil { scrollBox.glideToBottom() }
        }
        guard let last = store.activeThread?.messages.last, last.role == .assistant,
              last.state == .complete else { return }
        justFinishedID = last.id
        // 「嗒嗒」 when the last character lands, not when the network says it is done.
        StreamHaptics.shared.finish(messageID: last.id, length: last.content.count) { Haptic.finish() }
    }

    private var chatWithDraftEvents: some View {
        chatWithGenerationEvents
        .onChange(of: store.incomingChatFileURL) { _, _ in consumeIncomingChatTransfers() }
        .onChange(of: store.incomingChatImageURL) { _, _ in consumeIncomingChatTransfers() }
        .onChange(of: store.incomingChatPrefillText) { _, _ in consumeIncomingChatTransfers() }
        .onDisappear { flushDraft() }
        // Something else changed the draft (a suggestion put in, a file read in, a send
        // clearing it): show that, but not the echo of our own typing coming back.
        .onChange(of: store.activeDraft) { _, new in
            guard draftThreadID == store.activeThreadID else { return }
            if new != localDraft && new != lastPushedDraft { localDraft = new; lastPushedDraft = new }
        }
        .onChange(of: store.activeThreadID) { oldID, newID in
            activeChatChanged(from: oldID, to: newID)
        }
    }

    private func activeChatChanged(from oldID: UUID?, to newID: UUID?) {
        // Typing still waiting belongs to the chat you were in.
        draftPushTask?.cancel(); draftPushTask = nil
        if let old = draftThreadID, old != newID, store.draft(of: old) != localDraft { store.setDraft(localDraft, threadID: old) }
        loadDraft()
        refreshContextStats()
        store.speech.stop()
        systemPromptTarget = nil; versionsTarget = nil
        messageBrowser = nil; clearMessageNavigation()
        store.webSearchEnabled = false
        pendingSuggestedReply = nil
        quotingMessage = nil
        if timeReveal.offset != 0 { timeReveal.offset = 0 }
        visibleMessageCount = 40; followsOutput = true
        scrollBox.touch = nil
        scrollBox.followGrowth(for: 1.0)
        scrollUIState.showJumpToLatest = false
        StreamHaptics.shared.silence()
        justFinishedID = nil
        // The new chat settles in: drawn a little low and clear, then eased up into place.
        // Not for a retry or an edit, which open a new version of the same conversation.
        let sameConversation = oldID.flatMap { old in
            newID.map { ConversationHistory.memberIDs(for: $0, in: store.threads).contains(old) }
        } ?? false
        if !reduceMotion && !sameConversation {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { threadEntrance = 0 }
        }
        DispatchQueue.main.async {
            if store.activeThreadID == newID && shouldFollowOutput { scrollBox.scrollToBottom() }
            withMotion(Motion.gentle) { threadEntrance = 1 }
        }
    }

    private var chatWithMessageSheets: some View {
        chatWithDraftEvents
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

    private var chatWithToolSheets: some View {
        chatWithMessageSheets
        .sheet(item: $thinkingTarget) { target in ThinkingSheet(target: target).environmentObject(store) }
        .sheet(item: $agentTimelineTarget) { target in
            AgentWorkingTimelineSheet(target: target).environmentObject(store)
        }
        .sheet(item: $selectedDeliverable) { item in
            DeliverableDetailSheet(deliverable: item) { target in
                selectedDeliverable = nil
                localDraft = "请基于《\(target.fileName)》（ID: \(target.id.uuidString)）继续修改："
                scheduleDraftPush()
                focusComposer(true)
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $showWorkspaceSheet) {
            ProjectWorkspaceSheet(
                projectID: store.activeThread?.projectID,
                threadID: store.activeThreadID
            ) { target in
                showWorkspaceSheet = false
                localDraft = "请基于《\(target.fileName)》（ID: \(target.id.uuidString)）继续修改："
                scheduleDraftPush()
                focusComposer(true)
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $showVoiceDictationSheet) {
            VoiceDictationSheet(
                activeProject: store.activeProject,
                onInsertDraft: { spoken in
                    localDraft = OralDrillPromptBuilder.mergeIntoDraft(existing: localDraft, spoken: spoken)
                    scheduleDraftPush()
                    focusComposer(true)
                },
                onSendDirectly: { payload in
                    clearMessageNavigation()
                    followsOutput = true
                    let textWithQuote = MessageQuoteCodec.encode(quote: quotingMessage, userText: payload)
                    let fullPayload = PendingDocumentCodec.encode(userText: textWithQuote, documents: pendingDocuments)
                    if sendAnimated(fullPayload, images: pendingImages.map(\.data)) {
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
            )
            .environmentObject(store)
        }
        .sheet(isPresented: $showAddToChatSheet, onDismiss: {
            let action = afterAttachmentDismissal
            afterAttachmentDismissal = nil
            action?()
        }) {
            let activeID = store.activeThreadID ?? store.threads.first?.id ?? UUID()
            AddToChatSheet(
                threadID: activeID,
                dismissThen: { action in
                    guard showAddToChatSheet, afterAttachmentDismissal == nil else { return }
                    afterAttachmentDismissal = {
                        guard store.activeThreadID == activeID, let thread = store.activeThread,
                              !store.isHidden(thread) else { return }
                        action()
                    }
                    showAddToChatSheet = false
                },
                remainingPhotoSlots: max(0, 4 - pendingImages.count),
                showsSystemPromptControl: showsSystemPromptControl,
                systemPromptTitle: store.systemPromptTitle(for: store.activeThread),
                onTakeCameraPhoto: { chooseCameraPhoto() },
                onPickPhotos: { choosePhotos() },
                onPickFiles: { chooseDocuments() },
                onAttachPreparedImage: { data, preview in
                    guard store.activeThreadID == activeID, let thread = store.activeThread, !store.isHidden(thread), pendingImages.count < 4 else { return }
                    pendingImages.append(PendingImage(data: data, preview: preview))
                },
                onPasteClipboard: { pasteFromClipboard() },
                onOpenSystemPrompt: {
                    if let thread = store.activeThread, store.canChooseSystemPrompt(for: thread) {
                        focusComposer(false)
                        systemPromptTarget = ConversationPanelTarget(threadID: thread.id)
                    }
                },
                onOpenSettings: {
                    focusComposer(false)
                    openSettings()
                }
            )
            .environmentObject(store)
        }
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
        .alert("详情", isPresented: Binding(get: { reportDetails != nil }, set: { if !$0 { reportDetails = nil } })) {
            Button("完成") { reportDetails = nil }
        } message: { Text(reportDetails ?? "") }
    }

    private var chatWithAlerts: some View {
        chatWithInput
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
        let visible = visibleMessages
        return ForEach(Array(visible.enumerated()), id: \.element.id) { index, message in
            let prev: ChatMessage? = index > 0 ? visible[index - 1] : nil
            let showDivider = MessageTimeDivider.shouldShow(previous: prev, current: message)
            VStack(alignment: .leading, spacing: 14) {
                if showDivider {
                    Text(MessageTimeDivider.label(message.createdAt))
                        .font(TypeScale.tiny)
                        .foregroundStyle(Ink.ink3.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .padding(.top, index == 0 ? 0 : 6)
                        .padding(.bottom, 2)
                }
                // Equatable: only the message that changed redraws while an answer streams.
                messageRow(message, threadID: threadID, isLast: message.id == lastID)
                    .overlay(alignment: .leading) {
                        if focusedMessageID == message.id {
                            RoundedRectangle(cornerRadius: 2).fill(Ink.seal.opacity(0.7)).frame(width: 3).padding(.leading, -10)
                                .allowsHitTesting(false).accessibilityHidden(true)
                                .transition(.opacity)
                        }
                    }
            }
            .id(message.id)
            // Sent inside an animation: yours comes up out of the composer, the answer's
            // first line rises in under it.
            .transition(message.role == .user ? AnyTransition.sent : AnyTransition.rise)
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
            scrollBox.scrollToMessage(request.messageID)
            pendingMessageJump = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                if focusedMessageID == request.messageID && store.activeThreadID == request.threadID {
                    scrollBox.scrollToMessage(request.messageID)
                }
            }
        }
    }
    private func clearMessageNavigation() {
        pendingMessageJump = nil; focusedMessageID = nil
    }

    @ViewBuilder private func messageRow(_ message: ChatMessage, threadID: UUID?, isLast: Bool) -> some View {
        let timestamp: Date? = message.directive == nil ? message.createdAt : nil
        SwipeTimestampRow(timeReveal: timeReveal, timestamp: timestamp) {
            if message.state == .streaming {
                // The answer being written redraws on its own, without the rest of the page.
                LiveMessageRow(live: store.live, message: message, onGrow: { StreamHaptics.shared.feed(from: $0) }) { shown in
                    messageBody(shown, threadID: threadID, isLast: isLast)
                }
            } else {
                messageBody(message, threadID: threadID, isLast: isLast)
            }
        }
    }

    private func messageBody(_ message: ChatMessage, threadID: UUID?, isLast: Bool) -> some View {
        let quoteHandler: (() -> Void)? = message.directive == nil && message.state != .streaming ? {
            let author = message.role == .user ? "你" : "Sermo"
            let excerpt = MessageQuoteCodec.cleanExcerpt(
                from: message.content,
                hasImages: message.images?.isEmpty == false
            )
            withMotion(Motion.snappy) { quotingMessage = QuotedMessage(author: author, excerpt: excerpt) }
            Haptic.tap()
            focusComposer(true)
        } : nil
        let runRecord = message.role == .assistant ? store.agentRunRecord(for: message, threadID: threadID) : nil
        return MessageView(message: message, threadID: threadID, isLast: isLast,
                    isGenerating: isLast ? store.isGenerating(in: threadID) : false, canRegenerate: store.canChat,
                    showsSuggestions: store.settings.shouldSuggestReplies && store.activeProject?.studySubject == nil,
                    edit: { focusComposer(false); editingThreadID = threadID; editedMessage = message },
                    regenerate: regeneratePreservingDraftImages,
                    openThinking: { if let threadID { thinkingTarget = ThinkingTarget(threadID: threadID, messageID: message.id) } },
                    useSuggestedReply: { text in prepareSuggestedReply(text, messageID: message.id) },
                    signInDrive: { store.drive.signIn() },
                    celebrates: message.id == justFinishedID,
                    quoteReply: quoteHandler,
                    speech: store.speech,
                    toggleBookmark: {
                        guard let thread = store.activeThread, thread.id == threadID, !store.isHidden(thread) else { return }
                        store.toggleBookmark(threadID: thread.id, messageID: message.id)
                    }, retryColab: {
                        if let threadID { store.retryColabWithDeepSeek(threadID: threadID, messageID: message.id) }
                    }, generatedImages: store.generatedImages[message.id] ?? [],
                    agentRecord: runRecord,
                    openAgentTimeline: {
                        focusComposer(false)
                        agentTimelineTarget = AgentTimelineTarget(threadID: threadID, messageID: message.id)
                    },
                    deliverables: message.role == .assistant ? store.deliverables(forMessage: message.id) : [],
                    openDeliverable: { item in
                        focusComposer(false)
                        selectedDeliverable = item
                    })
            .equatable()
    }

    private func transcriptAppeared() {
        scrollBox.sidebarOpen = sidebarOpen
        StreamHaptics.shared.isWatching = { [weak box = scrollBox] in box?.watchingLive ?? false }
        if !hasPositionedInitially && !store.isPreview {
            let threadID = store.activeThreadID
            DispatchQueue.main.async {
                if store.activeThreadID == threadID && shouldFollowOutput { scrollBox.scrollToBottom() }
            }
        }
        hasPositionedInitially = true
    }

    // 1.47.1: following the end of the conversation (see `TranscriptScrollBox`).
    private func transcriptMoved(from old: TranscriptGeometry, to new: TranscriptGeometry) {
        scrollBox.geometry = new
        // 「↓」 only once you have left the end, so it does not flash while a card or a
        // picture is being followed into view.
        let overflows = new.contentHeight > new.visibleHeight + 80
        let showJump = overflows && new.distance > 220 && !scrollBox.follows
        if scrollUIState.showJumpToLatest != showJump { scrollUIState.showJumpToLatest = showJump }
        // Only a page that changed size: not your own scrolling, and not the first measure
        // (the chat positions itself when it opens).
        guard !new.sameSize(as: old), old.containerHeight > 0, !store.isPreview,
              shouldFollowOutput, scrollBox.touch == nil else { return }
        let windowChanged = abs(new.insetBottom - old.insetBottom) >= 0.5
            || abs(new.insetTop - old.insetTop) >= 0.5
            || abs(new.containerHeight - old.containerHeight) >= 0.5
        if !windowChanged {
            // Taller: followed while an answer is being written here, or just after
            // something that should land in view; not when something higher up opens out.
            guard new.contentHeight > old.contentHeight else { return }
            let writingHere = store.generatingThreadID != nil && store.generatingThreadID == store.activeThreadID
            guard writingHere || scrollBox.followsGrowth else { return }
        }
        scrollBox.glideToBottom()
    }

    private func transcriptPhase(_ phase: ScrollPhase) {
        switch phase {
        case .interacting:
            guard scrollBox.touch == nil else { return }
            // A finger on the page: stop pushing it, so the page never fights the finger.
            scrollBox.touch = scrollBox.geometry
            followsOutput = false
            clearMessageNavigation()
        case .idle:
            let now = scrollBox.geometry
            if let start = scrollBox.touch {
                scrollBox.touch = nil
                // How far you moved the page up yourself: what is below the screen now, less
                // what was written below it while you held it. Putting the keyboard away
                // with a swipe moves nothing up.
                let added = max(0, now.contentHeight - start.contentHeight)
                if now.distance - added < TranscriptScrollBox.readingAbove {
                    followsOutput = true
                    scrollBox.glideToBottom()
                }
            } else if now.distance < 28 && pendingMessageJump == nil && focusedMessageID == nil {
                // A scroll of ours that ended at the end (the 「↓」 button, say) follows on.
                followsOutput = true
            }
        default:
            break
        }
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
            .font(TypeScale.ui(14, weight: .medium))
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
                if let contextLine = contextSummaryText {
                    Text(contextLine)
                }
                Divider()
                if let activeProject = store.activeProject {
                    Button("返回项目「\(activeProject.name)」", systemImage: activeProject.studySubject != nil ? "graduationcap" : "tray.full") {
                        focusComposer(false)
                        openProject(activeProject.id)
                    }
                    Button("项目成果与文献库", systemImage: "doc.on.doc") {
                        focusComposer(false)
                        showWorkspaceSheet = true
                    }
                    Button("打开历史侧栏", systemImage: "sidebar.left") {
                        focusComposer(false)
                        openHistory()
                    }
                    Divider()
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
                if thread.projectID != nil, store.activeProject?.studySubject == nil {
                    Button("Auto-Dream 整理项目记忆", systemImage: "moon.stars") {
                        store.dreamConsolidateActiveProject()
                    }
                    .disabled(store.isGenerating || store.memorizingProjectID != nil)
                    // 1.46: one conversation the project's memory leaves alone.
                    Toggle(isOn: Binding(
                        get: { thread.keepsOutOfMemory == true },
                        set: { store.setKeepsOutOfMemory($0, threadID: thread.id) }
                    )) {
                        Label("这段对话不进记忆", systemImage: "eye.slash")
                    }
                }
                if store.canUsePureRoleplay(store.activeProject) {
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

    // The model pill: model and thinking level in one soft capsule. Switching either one
    // rolls the new name in instead of swapping it.
    private var modelPillLabel: some View {
        HStack(spacing: 5) {
            Text(store.pillModelTitle).fontWeight(.medium).foregroundStyle(Ink.ink).lineLimit(1)
                .contentTransition(.interpolate)
            Text(store.pillEffortTitle).fontWeight(.regular).foregroundStyle(Ink.ink3)
                .contentTransition(.interpolate)
        }
        // A soft neutral capsule matching Claude iOS ("Opus 5.5 中等").
        .font(.system(size: 13.5)).monospacedDigit()
        .padding(.horizontal, 12).frame(height: 34)
        .background(Ink.raised, in: Capsule())
        .contentShape(Capsule())
        .animation(Motion.snappy.motionSafe, value: store.pillModelTitle + store.pillEffortTitle)
        .onChange(of: store.pillModelTitle + store.pillEffortTitle) { _, _ in Haptic.select() }
    }

    // The web switch: a slim muted globe beside the model pill. Turned on, the globe
    // gives a small bounce, takes the accent and 「联网」 slides out beside it.
    private var webToggleLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "globe").font(.system(size: 15.5, weight: .light))
                .symbolEffect(.bounce, value: store.webSearchEnabled)
            if store.webSearchEnabled {
                Text("联网").font(.system(size: 13, weight: .medium))
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .foregroundStyle(store.webSearchEnabled ? Ink.seal : Ink.ink3)
        .frame(minWidth: 34, minHeight: 34)
        .contentShape(Rectangle())
        .animation(Motion.lively.motionSafe, value: store.webSearchEnabled)
    }

    private func jumpToLatest() {
        clearMessageNavigation()
        followsOutput = true
        Haptic.tap()
        scrollBox.scrollToBottom(animated: true, with: Motion.gentle)
    }

    private func choosePhotos() {
        guard !attachmentBusy, store.canPersist, let thread = store.activeThread, !store.isHidden(thread) else { return }
        let origin = thread.id
        let remaining = 4 - (imagesByThread[origin]?.count ?? 0)
        guard remaining > 0 else { attachmentReport = "一次最多添加 4 张图片。"; return }
        focusComposer(false)
        choosingPhotos = true
        systemPickers.photos(limit: remaining, onError: { issue in
            choosingPhotos = false
            attachmentReport = issue
        }) { results in
            choosingPhotos = false
            acceptPhotos(results, into: origin)
        }
    }

    private func acceptPhotos(_ results: [PHPickerResult], into origin: UUID) {
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
        let shown = systemPickers.presentMany(DocumentTextImporter.allowedContentTypes, asCopy: true,
            onCancel: { choosingFiles = false },
            onError: { issue in choosingFiles = false; attachmentReport = issue }) { urls in
                choosingFiles = false
                importDocuments(urls, into: origin)
            }
        if !shown { choosingFiles = false }
    }

    private func importDocuments(_ urls: [URL], into origin: UUID, removeAfterImport: Bool = false) {
        guard !urls.isEmpty else { return }
        if fileImportThreadID != nil {
            queuedFileImports.append((urls, origin, removeAfterImport))
            return
        }
        fileImportThreadID = origin
        fileImportTask = Task { @MainActor in
            defer {
                fileImportThreadID = nil
                fileImportTask = nil
                fileImportProgress = ""
                if removeAfterImport {
                    for url in urls { try? FileManager.default.removeItem(at: url) }
                }
                if !queuedFileImports.isEmpty {
                    let next = queuedFileImports.removeFirst()
                    importDocuments(next.urls, into: next.origin, removeAfterImport: next.removeAfterImport)
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
                    guard let target = store.threads.first(where: { $0.id == origin }), !store.isHidden(target) else {
                        details.append("原对话已删除或上锁，文件没有加入其他对话。")
                        break
                    }
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
        return true
    }

    private var attachmentButton: some View {
        Button {
            Haptic.tap()
            flushDraft()
            focusComposer(false)
            showAddToChatSheet = true
        } label: {
            Image(systemName: "plus").font(.system(size: 15.5, weight: .regular))
                .foregroundStyle(Ink.ink2)
                .frame(width: 34, height: 34)
                .background(Ink.raised, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.pressFeedback)
        .accessibilityLabel("添加到会话")
        .accessibilityIdentifier("chat-attachments")
    }

    private func chooseCameraPhoto() {
        guard !attachmentBusy, store.canPersist, let thread = store.activeThread, !store.isHidden(thread) else { return }
        let origin = thread.id
        guard (imagesByThread[origin]?.count ?? 0) < 4 else {
            attachmentReport = "一次最多添加 4 张图片。"
            return
        }
        focusComposer(false)
        systemPickers.camera(onError: { issue in
            attachmentReport = issue
        }) { captured in
            prepareCapturedImage(captured, origin: origin)
        }
    }

    private func prepareCapturedImage(_ image: UIImage, origin: UUID) {
        Task { @MainActor in
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    guard let raw = image.jpegData(compressionQuality: 0.9) ?? image.pngData() else {
                        throw ChatError.server("无法读取这张图片。")
                    }
                    return try ImageStore.prepared(raw)
                }.value
                guard let target = store.threads.first(where: { $0.id == origin }), !store.isHidden(target) else { return }
                guard (imagesByThread[origin]?.count ?? 0) < 4 else {
                    attachmentReport = "待发送区已满 4 张图片。"
                    return
                }
                guard let preview = UIImage(data: data) else { throw ChatError.server("图片无法预览。") }
                imagesByThread[origin, default: []].append(PendingImage(data: data, preview: preview))
            } catch { attachmentReport = error.localizedDescription }
        }
    }

    private func pasteFromClipboard() {
        guard store.canPersist, let id = store.activeThreadID else { return }
        if UIPasteboard.general.hasImages, let image = UIPasteboard.general.image {
            guard pendingImages.count < 4 else {
                attachmentReport = "每条消息最多附加 4 张图片。"
                return
            }
            prepareCapturedImage(image, origin: id)
            return
        }
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            attachmentReport = "剪贴板里没有图片或文字。"
            return
        }
        flushDraft()
        _ = store.appendImportedText(text, to: id)
    }

    private var isSlashCommandActive: Bool {
        let trimmed = localDraft.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/") || trimmed.hasPrefix("／")
    }

    @ViewBuilder private func composerNoticeBar(_ notice: ComposerNotice) -> some View {
        let close = { withMotion(Motion.snappy) { store.dismissComposerNotice() } }
        switch notice.kind {
        case .compactOffer:
            ComposerNoticeBar(text: "这段对话已经很长了，浓缩后每次回答更省钱。",
                              actionTitle: "浓缩",
                              action: { withMotion(Motion.snappy) { store.acceptCompactionOffer() } },
                              dismiss: close)
        case .memoryIssue(let text):
            ComposerNoticeBar(text: text, dismiss: close)
        case let .memoryUpdated(projectID, batchID):
            ComposerNoticeBar(text: "记忆已更新。",
                              actionTitle: "查看记忆",
                              action: {
                                  store.composerNotice = nil
                                  focusComposer(false)
                                  memorySheetTarget = ProjectMemoryTarget(id: projectID)
                              },
                              secondTitle: "撤回",
                              second: { withMotion(Motion.snappy) { store.undoMemoryChange(batchID, in: projectID) } },
                              dismiss: close)
        }
    }

    // Context usage moved into the top-right 「⋯」 menu (see `contextSummaryText`); only the
    // compaction progress still shows above the composer, because it is a live task.
    @ViewBuilder private var contextStatusBar: some View {
        if let thread = store.activeThread, store.compactingThreadID == thread.id {
            HStack(spacing: 6) {
                ThinkingMark(live: true, size: 12)
                Text("正在浓缩…").font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                    .shimmering()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .transition(.barRise)
        }
    }

    /// One line for the 「⋯」 menu: context share, rough size and cache hit rate of the last answer.
    private var contextSummaryText: String? {
        guard let stats = cachedContext, stats.messageCount >= 2 else { return nil }
        let pct = max(1, Int(round(stats.ratio * 100)))
        let size = stats.estimatedTokens >= 1000
            ? String(format: "%.1fk", Double(stats.estimatedTokens) / 1000.0)
            : "\(stats.estimatedTokens)"
        var line = "上下文 \(pct)% · 约 \(size) Tokens"
        if let hit = stats.cacheHitRate { line += " · 缓存 \(hit)%" }
        return line
    }

    /// What you have typed after 「/」, up to the first space.
    private var slashQuery: String {
        let trimmed = localDraft.trimmingCharacters(in: .whitespaces)
        return String(trimmed.dropFirst().prefix(while: { $0 != " " }))
    }

    /// The commands for this conversation, in the order Claude Code lists them: name, then what it does.
    private var slashCommands: [SlashCommand] {
        var list: [SlashCommand] = []
        list.append(SlashCommand(name: "深搜", detail: "多轮深度搜索后再回答") {
            store.webSearchEnabled = true
            let remainder = String(localDraft.drop(while: { $0 != " " })).trimmingCharacters(in: .whitespaces)
            localDraft = remainder
            scheduleDraftPush()
        })
        list.append(SlashCommand(name: "浓缩", detail: "把上文浓缩成摘要，原对话保留") {
            localDraft = ""
            scheduleDraftPush()
            store.compactActiveThread()
        })
        if store.activeThread?.projectID != nil, store.activeProject?.studySubject == nil {
            list.append(SlashCommand(name: "做梦", detail: "整理这个项目的记忆，去重合并") {
                localDraft = ""
                scheduleDraftPush()
                store.dreamConsolidateActiveProject()
            })
        }
        if store.activeProject?.studySubject == .english {
            list.append(SlashCommand(name: "考词", detail: "随机抽 10 个词考我") {
                localDraft = ""
                flushDraft()
                _ = sendAnimated("请随机抽 10 个单词考考我。", images: [])
                focusComposer(false)
            })
        }
        if store.activeProject?.studySubject != nil {
            list.append(SlashCommand(name: "周报", detail: "生成本周学习周报") {
                localDraft = ""
                flushDraft()
                _ = sendAnimated("帮我生成本周学习周报。", images: [])
                focusComposer(false)
            })
        }
        if showsSystemPromptControl, let thread = store.activeThread, store.canChooseSystemPrompt(for: thread) {
            list.append(SlashCommand(name: "指令", detail: "切换这段对话的系统指令") {
                localDraft = ""
                scheduleDraftPush()
                focusComposer(false)
                systemPromptTarget = ConversationPanelTarget(threadID: thread.id)
            })
        }
        // 1.46 固定做法: each saved routine is a command; picking one keeps 「/名字 」 in the draft
        // so you can go on typing what it is for.
        if let project = store.activeProject, project.studySubject == nil {
            for skill in project.skills ?? [] {
                list.append(SlashCommand(name: skill.name, detail: skill.whenToUse.isEmpty ? "固定做法" : skill.whenToUse) {
                    localDraft = "/\(skill.name) "
                    scheduleDraftPush()
                })
            }
            if (project.skills ?? []).count < ProjectSkill.countLimit {
                list.append(SlashCommand(name: "存为做法", detail: "把刚才的要求存成这个项目的固定做法") {
                    localDraft = ""
                    scheduleDraftPush()
                    focusComposer(false)
                    let lastAsk = store.activeThread?.messages.last(where: { $0.role == .user })
                        .map { PendingDocumentCodec.extractEditableUserText($0.content) } ?? ""
                    skillDraftTarget = ProjectSkillTarget(projectID: project.id, draft: ProjectSkillDraft(body: lastAsk))
                })
            }
        }
        let query = slashQuery
        guard !query.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query) }
    }

    /// True once a routine has been picked and you are typing what it is for (「/周报 这周…」).
    private var slashRoutineChosen: Bool {
        let lead = localDraft.drop(while: { $0.isWhitespace })
        guard lead.count > 1, let space = lead.firstIndex(where: { $0.isWhitespace }) else { return false }
        let word = String(lead[lead.index(after: lead.startIndex)..<space])
        return store.activeProject?.skills?.contains { $0.name == word } == true
    }

    // 1.46: a plain list on one card, like Claude Code's command menu, instead of a row of capsules.
    @ViewBuilder private var slashCommandBar: some View {
        let commands = isSlashCommandActive && !store.isGenerating && !slashRoutineChosen ? slashCommands : []
        if !commands.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // By position: a routine may share a name with a built-in command.
                ForEach(Array(commands.prefix(7).enumerated()), id: \.offset) { index, command in
                    if index > 0 { Rectangle().fill(Ink.line.opacity(0.7)).frame(height: 0.5).padding(.leading, 14) }
                    Button {
                        Haptic.tap()
                        command.action()
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("/" + command.name)
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                .foregroundStyle(Ink.ink)
                            Text(command.detail)
                                .font(.system(size: 13))
                                .foregroundStyle(Ink.ink3)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressFeedback)
                    .accessibilityLabel("/\(command.name)：\(command.detail)")
                }
            }
            .background(Ink.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Ink.line, lineWidth: 0.6))
            .transition(.barRise)
        }
    }

    private var composer: some View {
        ComposerObserverScope {
            composerBody
        }
    }

    @ViewBuilder private var chatStatusNotice: some View {
        if let issue = store.errorMessage {
            ComposerNoticeBar(text: issue, actionTitle: "详情", action: { reportDetails = issue },
                              dismiss: { store.errorMessage = nil })
        } else if let report = attachmentReport {
            ComposerNoticeBar(text: report, actionTitle: "详情", action: { reportDetails = report },
                              dismiss: { attachmentReport = nil })
        } else if let incoming = store.pendingShareIntake {
            ComposerNoticeBar(text: "收到「\(incoming.title)」", actionTitle: "查看", action: reviewIncoming)
        } else if let backup = store.unifiedRestorePreview {
            ComposerNoticeBar(text: "备份已就绪：\(backup.fileName)", actionTitle: "查看", action: reviewBackup)
        } else if let notice = store.noticeMessage {
            ComposerNoticeBar(text: notice, actionTitle: "详情", action: { reportDetails = notice },
                              dismiss: { store.noticeMessage = nil })
        }
    }

    private var composerBody: some View {
        let isCurrentGenerating = store.isGenerating(in: store.activeThreadID)
        let steerDraft = localDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSteerCurrentRun = isCurrentGenerating && !steerDraft.isEmpty && pendingImages.isEmpty && pendingDocuments.isEmpty
        return VStack(spacing: 8) {
            chatStatusNotice
            if let approval = store.pendingApproval {
                if approval.threadID == store.activeThreadID {
                    InlineToolApprovalCard(approval: approval) { store.resolveApproval($0) }
                } else {
                    ComposerNoticeBar(text: "另一个对话在等你确认一个操作。", actionTitle: "前往", action: {
                        if let target = store.threads.first(where: { $0.id == approval.threadID }), !store.isHidden(target) {
                            store.activeThreadID = target.id
                        }
                    })
                }
            }
            if let notice = store.composerNotice,
               notice.threadID == nil || notice.threadID == store.activeThreadID,
               notice.projectID == nil || notice.projectID == store.activeThread?.projectID {
                composerNoticeBar(notice)
            }
            contextStatusBar
            slashCommandBar
            ghostBar
            if store.searchingThreadID == store.activeThreadID && store.isGenerating {
                HStack(spacing: 8) {
                    ThinkingMark(live: true, size: 14)
                    Text("正在深度联网检索与核对正文…").font(TypeScale.caption).foregroundStyle(Ink.ink2)
                        .shimmering()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .transition(.barRise)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("web-search-progress")
            }

            if !store.canChat {
                Button { focusComposer(false); openSettings() } label: {
                    Label(store.chatUnavailableMessage,
                          systemImage: store.activeProvider == .chatGPT ? "person.crop.circle" : "key")
                        .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                }.padding(.bottom, 2)
            }
            VStack(alignment: .leading, spacing: 12) {
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
                                        withMotion(Motion.snappy) { pendingDocuments.removeAll { $0.id == doc.id } }
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
                                .background(Ink.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Ink.line, lineWidth: 1))
                                .transition(.pop)
                            }
                        }
                    }
                    .transition(.barRise)
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
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(alignment: .topTrailing) {
                                        Button { withMotion(Motion.snappy) { pendingImages.removeAll { $0.id == item.id } } } label: {
                                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(Ink.onSolid)
                                                .frame(width: 20, height: 20).background(Ink.solid, in: Circle())
                                                .padding(3).contentShape(Rectangle())
                                        }.buttonStyle(.plain).accessibilityLabel("移除这张图片")
                                    }
                                    .transition(.pop)
                            }
                            if loadingPhotos { ProgressView().frame(width: 64, height: 64) }
                        }
                    }
                    .transition(.barRise)
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
                            withMotion(Motion.snappy) { quotingMessage = nil }
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
                    .background(Ink.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(.barRise)
                }
                Group {
                    if usesPreviewKeyboard {
                        PreviewKeyboardField(text: draft, isFocused: previewComposerFocused, focusChanged: { previewComposerFocused = $0 })
                            .padding(.horizontal, 3)
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
                                        .id(ghost)
                                        .transition(.ghostSwap)
                                } else {
                                    // Unfocused, a tap puts it in to edit; send takes it as is.
                                    Button { takeGhost(send: false) } label: {
                                        Text(ghost).userMessageStyle().foregroundStyle(Ink.ink3.opacity(0.75)).lineLimit(4)
                                            .multilineTextAlignment(.leading)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .id(ghost)
                                    // A new suggestion drifts up into the field; 换一条 swaps it the same way.
                                    .transition(.ghostSwap)
                                    .accessibilityLabel("猜你想说：\(ghost)，点一下放进输入框修改，或直接点发送")
                                }
                            }
                        }
                        .padding(.horizontal, 3)
                    }
                }
                    .disabled(!store.canPersist)
                    .accessibilityIdentifier("chat-composer")
                HStack(spacing: 10) {
                    attachmentButton
                    let _ = store.webRoutingRevision
                    let currentWebChannel = WebSearchRouting.channel(for: store.activeProvider)
                    // Model and thinking level in one pill, like "Haiku 5.5 中等" in the Claude app.
                    Menu {
                        Section("当前能力与联网") {
                            Text(ProviderCapabilities.forProvider(store.activeProvider).summaryLabel)
                            Text("联网通道：\(currentWebChannel.title)")
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
                            Section("思考档位（对齐 Codex）") {
                                Picker("思考", selection: Binding(get: { store.activeChatSettings.selectedSubscriptionEffort }, set: { store.setSubscriptionEffort($0) })) {
                                    ForEach(store.subscription.availableEfforts(for: store.activeChatSettings.subscriptionModel)) { effort in
                                        Text(effort.menuLabel).tag(effort)
                                    }
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
                    if currentWebChannel != .directLinksOnly {
                        // On, the button itself says so; no hint line over the conversation.
                        Button { Haptic.select(); store.webSearchEnabled.toggle() } label: {
                            webToggleLabel
                        }
                        .disabled(store.isGenerating)
                        .accessibilityLabel("联网搜索")
                        .accessibilityValue(store.webSearchEnabled ? "已开启" : "已关闭")
                        .accessibilityIdentifier("web-search-toggle")
                    }
                    if store.activeProvider == .chatGPT && store.imageGenerationEnabled {
                        Button {
                            Haptic.tap()
                            store.imageGenerationEnabled = false
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "wand.and.stars").font(.system(size: 13, weight: .medium))
                                Text("画图").font(.system(size: 13, weight: .medium))
                                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(Ink.seal)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressFeedback)
                        .accessibilityLabel("已开启本轮生图，点击取消")
                    }

                    Spacer(minLength: 0)
                    if canSteerCurrentRun {
                        Button {
                            Haptic.tap()
                            store.stopGeneration()
                        } label: {
                            SendButtonFace(mode: .stop, enabled: true)
                        }
                        .buttonStyle(.pressFeedback)
                        .accessibilityLabel("停止生成")

                        Button {
                            Haptic.tap()
                            if store.steerActiveRun(steerDraft) {
                                draftPushTask?.cancel()
                                draftPushTask = nil
                                localDraft = ""
                                lastPushedDraft = ""
                                if let activeID = store.activeThreadID {
                                    store.setDraft("", threadID: activeID)
                                }
                                focusComposer(false)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("追加")
                                    .font(.system(size: 13.5, weight: .semibold))
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(Ink.sendGlyph)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(Ink.sendFill, in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.pressFeedback)
                        .accessibilityLabel("追加补充要求")
                    } else {
                        if !isCurrentGenerating && store.canPersist {
                            Button {
                                Haptic.tap()
                                focusComposer(false)
                                showVoiceDictationSheet = true
                            } label: {
                                Image(systemName: "mic")
                                    .font(.system(size: 16, weight: .regular))
                                    .foregroundStyle(Ink.ink2)
                                    .frame(width: 34, height: 34)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.pressFeedback)
                            .accessibilityLabel("语音输入或口述抽背")
                            .accessibilityIdentifier("voice-dictation-button")
                        }
                        Button {
                            if isCurrentGenerating {
                                store.stopGeneration()
                            } else if store.isGenerating {
                                store.errorMessage = "另一个对话正在后台生成中，可点下方提示切回查看或等待完成。"
                            } else if ghostText != nil {
                                takeGhost(send: true)
                            } else {
                                clearMessageNavigation()
                                followsOutput = true
                                flushDraft()
                                let textWithQuote = MessageQuoteCodec.encode(quote: quotingMessage, userText: store.activeDraft)
                                let payload = PendingDocumentCodec.encode(userText: textWithQuote, documents: pendingDocuments)
                                if sendAnimated(payload, images: pendingImages.map(\.data)) {
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
                            let isStop = isCurrentGenerating
                            let sendDisabled = !isStop && (!store.canChat || !readyToSend || !store.canPersist || loadingPhotos
                                || (fileImportThreadID != nil && fileImportThreadID == store.activeThreadID))
                            SendButtonFace(mode: isStop ? .stop : (readyToSend ? .ready : .idle),
                                           enabled: isStop || !sendDisabled)
                        }
                        .buttonStyle(.pressFeedback)
                        .disabled(!isCurrentGenerating && (!store.canChat || !(hasInput || ghostText != nil) || !store.canPersist || loadingPhotos
                            || (fileImportThreadID != nil && fileImportThreadID == store.activeThreadID)))
                        .accessibilityLabel(isCurrentGenerating ? "停止生成" : "发送消息")
                    }
                }
            }
            .padding(.horizontal, 11).padding(.top, 12).padding(.bottom, 9)
            .clearGlass(radius: 26)
            if store.isGenerating && store.generatingThreadID != store.activeThreadID {
                Button {
                    Haptic.tap()
                    if let bgID = store.generatingThreadID,
                       let target = store.threads.first(where: { $0.id == bgID }),
                       !store.isHidden(target) {
                        store.activeThreadID = bgID
                    }
                } label: {
                    Text("另一个对话正在后台生成 · 点此切回查看 ›")
                        .font(TypeScale.tiny)
                        .foregroundStyle(Ink.ink3)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
        }
        // When idle, `keyboardLayoutGuide.topAnchor` already sits at `safeAreaLayoutGuide.bottomAnchor`
        // (34pt above screen bottom on iPhone Air), so 0pt extra bottom padding lands the Liquid Glass
        // card at the exact Claude position; when keyboard is open, add 8pt breathing room above keyboard.
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, keyboardVisible ? 8 : 0)
        .background(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: Ink.paper.opacity(0), location: 0),
                    .init(color: Ink.paper.opacity(0.45), location: 0.48),
                    .init(color: Ink.paper.opacity(0.78), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(.top, -10)
            .padding(.bottom, keyboardVisible ? 0 : -bottomInset)
            .allowsHitTesting(false)
        }
        // Bars above the input come and go with one spring, and the panel resizes with it.
        .animation(Motion.snappy.motionSafe, value: composerLayoutSignature)
        .accessibilityElement(children: .contain).accessibilityIdentifier("chat-composer-panel")
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
            if abs(composerPanelHeight - newHeight) > 0.5 {
                composerPanelHeight = newHeight
            }
        }
        .onChange(of: ghostSource?.id) { _, _ in suggestionIndex = 0 }
    }
}

/// The round key at the right of the composer.
/// Idle it is a quiet grey arrow; with something to send it fills with the accent and
/// gives a small spring; while an answer is coming it turns into a stop square with a
/// thin arc going round it, so the composer itself shows the work in progress.
@MainActor
private struct SendButtonFace: View {
    enum Mode: Equatable { case idle, ready, stop }
    let mode: Mode
    let enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ready = mode == .ready
        ZStack {
            Circle().fill(ready ? Ink.sendFill : Ink.raised)
            Image(systemName: mode == .stop ? "stop.fill" : "arrow.up")
                .font(.system(size: mode == .stop ? 11 : 14, weight: ready ? .semibold : .medium))
                .foregroundStyle(mode == .stop ? Ink.ink : (ready ? Ink.sendGlyph : Ink.ink3.opacity(0.65)))
                .contentTransition(.symbolEffect(.replace.downUp))
            if mode == .stop {
                WorkingArc().transition(.opacity)
            }
        }
        .frame(width: 34, height: 34)
        .scaleEffect(ready && !reduceMotion ? 1 : (mode == .stop ? 1 : 0.94))
        .opacity(ready && !enabled ? 0.42 : 1)
        .contentShape(Circle())
        .animation(Motion.lively.motionSafe, value: mode)
    }
}

/// A short accent arc going round a circular control while work is under way.
@MainActor
struct WorkingArc: View {
    var lineWidth: CGFloat = 1.6
    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.24)
            .stroke(Ink.seal, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .padding(lineWidth / 2)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .opacity(reduceMotion ? 0.6 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { spinning = true }
            }
            .accessibilityHidden(true)
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
                    .transition(.pop)
                }
            }
            .animation(Motion.lively.motionSafe, value: showJump)
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
    // 1.47: true for the answer that has just finished here; its controls rise in one by one.
    var celebrates = false
    var quoteReply: (() -> Void)? = nil
    var speech: OpenAISpeech? = nil
    var toggleBookmark: (() -> Void)? = nil
    var retryColab: (() -> Void)? = nil
    var generatedImages: [URL] = []
    var agentRecord: AgentRunRecord? = nil
    var openAgentTimeline: () -> Void = {}
    var deliverables: [ProjectDeliverable] = []
    var openDeliverable: (ProjectDeliverable) -> Void = { _ in }
    @State private var selecting = false
    @State private var showSourcesSheet = false
    @State private var showDocumentArtifact = false

    nonisolated static func == (lhs: MessageView, rhs: MessageView) -> Bool {
        lhs.message == rhs.message && lhs.threadID == rhs.threadID && lhs.isLast == rhs.isLast
            && lhs.isGenerating == rhs.isGenerating && lhs.canRegenerate == rhs.canRegenerate
            && lhs.showsSuggestions == rhs.showsSuggestions && lhs.celebrates == rhs.celebrates
            && lhs.generatedImages == rhs.generatedImages
            && lhs.agentRecord == rhs.agentRecord
            && lhs.deliverables == rhs.deliverables
    }

    private var documentArtifactTitle: String {
        for rawLine in message.content.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#*`> "))
            if !cleaned.isEmpty { return String(cleaned.prefix(24)) }
        }
        return "文稿阅读"
    }

    private var supportsDocumentArtifact: Bool {
        message.role == .assistant && message.state == .complete && message.content.count >= 450
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
                // with what you should read underneath.
                VStack(spacing: 12) {
                    Text("— \(label) —").font(TypeScale.caption).foregroundStyle(Ink.ink3)
                        .accessibilityLabel(label)
                    if let detail = message.directiveDetail, !detail.isEmpty {
                        Text(detail).font(TypeScale.label).foregroundStyle(Ink.ink2).lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Ink.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .accessibilityLabel("前情提要：\(detail)")
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
            } else {
                content
            }
        }
        .contextMenu {
            // The most used actions come first; extra actions live below.
            Section {
                if let quoteReply {
                    Button("引用回复", systemImage: "arrowshape.turn.up.left") { quoteReply() }
                }
                Button("复制", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = cleanCopyText
                    Haptic.success()
                }
                Button("选择文字", systemImage: "text.viewfinder") { selecting = true }
                if message.role == .assistant && message.state == .complete && message.content.count >= 160 {
                    Button("独立文稿预览", systemImage: "doc.richtext") { showDocumentArtifact = true }
                }
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
            if isLast && message.role == .assistant {
                Button("重新生成", systemImage: "arrow.clockwise") { regenerate() }
                    .disabled(isGenerating || !canRegenerate)
            }
            if let usage = message.usage {
                Section {
                    Text(usageLabel(usage))
                }
            }
        }
        .sheet(isPresented: $selecting) { SelectableTextSheet(text: cleanCopyText) }
        .sheet(isPresented: $showSourcesSheet) {
            if let sources = message.webSources, !sources.isEmpty {
                WebSourcesSheet(sources: sources, searchUsage: message.searchUsage)
            }
        }
        .sheet(isPresented: $showDocumentArtifact) {
            ArtifactPreviewSheet(artifact: .document(markdown: message.content, title: documentArtifactTitle))
        }
    }

    // Your message on the right in a light bubble; the answer as open text below it,
    // with its controls underneath (the Claude app's layout).
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if message.role == .user {
                userBubble
            } else {
                answerParts
                if message.state == .streaming {
                    StreamActivityView(message: message)
                } else {
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
                            .arrive(active: celebrates)
                        }
                    } else {
                        answerFooter
                    }
                }
            }
            trailingParts
        }
    }

    private var userBubble: some View {
        let docDecoded = PendingDocumentCodec.decode(message.content)
        let quoteDecoded = MessageQuoteCodec.decode(docDecoded.userText)
        return HStack(spacing: 0) {
            Spacer(minLength: 52)
            VStack(alignment: .trailing, spacing: 6) {
                if let quote = quoteDecoded.quote {
                    QuotedReplyCard(quote: quote, alignTrailing: true)
                }
                if let names = message.images, !names.isEmpty { AttachmentRow(names: names) }
                if !docDecoded.attachments.isEmpty {
                    MessageDocumentCards(attachments: docDecoded.attachments)
                }
                if !quoteDecoded.userText.isEmpty {
                    Text(quoteDecoded.userText).userMessageStyle().lineSpacing(max(Personal.lineSpacing - 2, 3)).chineseReading()
                        .foregroundStyle(Ink.ink)
                        .textSelection(.enabled)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .background(Personal.bubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // Copy, select, edit, read aloud, retry; then sources and what it cost. When the answer
    // has only just finished, each line rises in a beat after the one before.
    private var answerFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                CopyGlyphButton(label: "复制回答") { message.content }
                    .frame(width: 24, height: 28)
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
            }
            .foregroundStyle(Ink.ink2.opacity(0.72))
            .buttonStyle(.pressFeedback)
            .padding(.top, 6)
            .arrive(delay: 0.02, active: celebrates)
            if (message.webSources?.isEmpty == false) || supportsDocumentArtifact {
                HStack(spacing: 14) {
                    if let sources = message.webSources, !sources.isEmpty {
                        Button {
                            Haptic.tap()
                            showSourcesSheet = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "globe")
                                    .font(.system(size: 13, weight: .regular))
                                Text("\(sources.count) 个来源")
                                    .font(.system(size: 13, weight: .regular))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Ink.ink3.opacity(0.7))
                            }
                            .foregroundStyle(Ink.ink2)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressFeedback)
                        .accessibilityIdentifier("web-search-sources")
                    }
                    if supportsDocumentArtifact {
                        Button {
                            Haptic.tap()
                            showDocumentArtifact = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.richtext")
                                    .font(.system(size: 12, weight: .regular))
                                Text("独立文稿预览")
                                    .font(.system(size: 13, weight: .regular))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Ink.ink3.opacity(0.7))
                            }
                            .foregroundStyle(Ink.ink2)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressFeedback)
                        .accessibilityLabel("在独立文稿卡片中阅读")
                    }
                    Spacer(minLength: 0)
                }
                .arrive(delay: 0.08, active: celebrates)
            }
            // What this answer cost, as one faint line at the very bottom — where Claude
            // puts 「Claude 是 AI，可能会出错」.
            if let usage = message.usage {
                Text(usageLabel(usage))
                    .font(TypeScale.ui(11.5, relativeTo: .caption2))
                    .foregroundStyle(Ink.ink3.opacity(0.8))
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityLabel("这条回答的用量：\(usageLabel(usage))")
                    .arrive(delay: 0.14, distance: 4, active: celebrates)
            }
        }
    }

    // Thinking, tool calls and the answer text.
    @ViewBuilder private var answerParts: some View {
        if !message.reasoning.isEmpty {
            ThinkingRow(message: message, open: openThinking)
        }
        if let record = agentRecord {
            AgentWorkingSummaryRow(
                record: record,
                toolItems: message.toolActivity ?? [],
                signInDrive: signInDrive,
                openTimeline: openAgentTimeline
            )
        }
        if !generatedImages.isEmpty {
            GeneratedImagesGalleryView(urls: generatedImages)
                .transition(.rise)
        }
        if !deliverables.isEmpty {
            DeliverableFileRowList(deliverables: deliverables, open: openDeliverable)
                .transition(.rise)
        }
        if !message.content.isEmpty {
            // The text inks in while it is written, and finishes inking after it is done.
            MarkdownAnswer(content: message.content, expandsWidth: true,
                           inkKey: message.id.uuidString, writing: message.state == .streaming).equatable()
        }
    }

    // Notes and reply suggestions under an answer.
    @ViewBuilder private var trailingParts: some View {
        if let note = message.note {
            Text(note).font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .arrive(delay: 0.1, distance: 4, active: celebrates)
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

// Ready replies live in the composer as grey text (猜你想说); under the answer only the
// waiting, error and 「生成回复建议」 states show.
@MainActor
struct ReplySuggestionPanel: View {
    @EnvironmentObject private var store: AppStore
    let message: ChatMessage
    let threadID: UUID
    let use: (String) -> Void

    var body: some View {
        if message.replySuggestions != nil {
            EmptyView()
        } else if store.isSuggesting(threadID: threadID, messageID: message.id) {
            HStack(spacing: 8) {
                ThinkingMark(live: true, size: 13)
                Text("正在想几种回复…").font(TypeScale.caption).foregroundStyle(Ink.ink3)
                    .shimmering()
            }
            .padding(.top, 10).padding(.vertical, 4)
            .transition(.rise)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("reply-suggestions-loading")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if let error = store.suggestionError(threadID: threadID, messageID: message.id) {
                    Text(error).font(TypeScale.tiny).foregroundStyle(Ink.ink3)
                }
                Button("生成回复建议") { store.generateReplySuggestions(threadID: threadID, messageID: message.id) }
                    .font(TypeScale.caption).foregroundStyle(Ink.ink2).buttonStyle(.pressFeedback).disabled(store.isGenerating)
                    .padding(.vertical, 8)
            }
            .padding(.top, 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("reply-suggestions-panel")
        }
    }

    static func costLabel(_ batch: ReplySuggestionBatch) -> String? {
        if batch.provider == .colab { return "免费" }
        guard let usage = batch.usage else { return nil }
        return batch.provider == .chatGPT ? "订阅额度"
            : Pricing.label(Pricing.cost(model: batch.pricedModel, usage: usage, at: batch.createdAt)) + Pricing.bandTag(batch.createdAt)
    }
}

struct AttachmentRow: View {
    let names: [String]
    var body: some View {
        PhotoStackView(names: names)
    }
}

// Equatable so finished answers are not re-parsed while a new one streams in.
// Paragraphs, code, tables and math are Equatable too: while text arrives only
// the actively growing block is re-tokenized or laid out again.
//
// 1.47: `inkKey` names the answer for the ink-in of text being written (see StreamInk);
// `writing` is true while it is. The block the writing is in grows its ink; a block that
// has just been left finishes inking; everything older is drawn plainly.
struct MarkdownAnswer: View, Equatable {
    let content: String
    var expandsWidth: Bool = true
    var inkKey: String? = nil
    var writing: Bool = false
    nonisolated static func == (lhs: MarkdownAnswer, rhs: MarkdownAnswer) -> Bool {
        lhs.content == rhs.content && lhs.expandsWidth == rhs.expandsWidth
            && lhs.inkKey == rhs.inkKey && lhs.writing == rhs.writing
    }
    private var blocks: [MarkdownBlock] { MarkdownBlock.parse(content) }
    var body: some View {
        let parsed = blocks
        // Paragraphs a clear step apart (about one line), so each reads as its own block.
        let column = VStack(alignment: .leading, spacing: Personal.paragraphGap) {
            ForEach(Array(parsed.enumerated()), id: \.offset) { index, block in
                let tail = writing && index == parsed.count - 1
                let key = inkKey.map { "\($0)|\(index)" }
                blockView(block, key: key, tail: tail)
                    // A block that is not text (code, a table, a rule) fades in as it appears.
                    .arrive(distance: 6, active: tail && !block.inks)
            }
        }
        if expandsWidth {
            column.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            column
        }
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock, key: String?, tail: Bool) -> some View {
        switch block {
        case .paragraph(let text, let marks):
            MarkdownParagraph(text: text, marks: marks, inkKey: key, grows: tail).equatable()
        case .heading(let text, let level):
            EditorialHeadingRow(text: text, level: level, inkKey: key, grows: tail)
        case .list(let items):
            // Items breathe almost like paragraphs, as in the Claude app.
            VStack(alignment: .leading, spacing: max(10, Personal.paragraphGap - 8)) {
                ForEach(Array(items.enumerated()), id: \.offset) { itemIndex, item in
                    let lastItem = itemIndex == items.count - 1
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        EditorialListMarker(marker: item.marker)
                        MarkdownParagraph(text: item.text, marks: item.marks,
                                          inkKey: key.map { "\($0).\(itemIndex)" }, grows: tail && lastItem).equatable()
                    }
                    .padding(.leading, 4 + CGFloat(item.level) * 20)
                    // A new item's marker comes in with its first words.
                    .arrive(distance: 4, active: tail && lastItem)
                }
            }
        case .quote(let text, let marks):
            MarkdownParagraph(text: text, marks: marks, inkKey: key, grows: tail).equatable()
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.0, style: .continuous)
                        .fill(Ink.ink3.opacity(0.32)).frame(width: 2.0)
                }
        case .table(let header, let rows, let alignments):
            MarkdownTableBlockView(header: header, rows: rows, alignments: alignments).equatable()
        case .divider:
            Rectangle().fill(Ink.line).frame(height: 1).padding(.vertical, 4)
        case .code(let segment):
            MarkdownCodeBlockView(segment: segment).equatable()
        case .math(let formula):
            MarkdownMathBlockView(formula: formula).equatable()
        }
    }

    static func highlightedCode(_ body: String, language: String?) -> AttributedString {
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

private extension MarkdownBlock {
    /// Blocks drawn as running text, which ink in character by character.
    var inks: Bool {
        switch self {
        case .paragraph, .heading, .list, .quote: return true
        case .table, .divider, .code, .math: return false
        }
    }
}

private struct MarkdownTableBlockView: View, Equatable {
    let header: [String]
    let rows: [[String]]
    let alignments: [TableAlignment]

    nonisolated static func == (lhs: MarkdownTableBlockView, rhs: MarkdownTableBlockView) -> Bool {
        lhs.header == rhs.header && lhs.rows == rhs.rows && lhs.alignments == rhs.alignments
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
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Ink.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct MarkdownCodeBlockView: View, Equatable {
    let segment: String
    @State private var showArtifact = false

    nonisolated static func == (lhs: MarkdownCodeBlockView, rhs: MarkdownCodeBlockView) -> Bool {
        lhs.segment == rhs.segment
    }

    var body: some View {
        let parsed = CodeSyntaxTokenizer.parseHeaderAndBody(segment)
        let previewable = HTMLPreviewHelper.isPreviewable(language: parsed.language, body: parsed.body)
        let lineCount = max(1, parsed.body.components(separatedBy: .newlines).count)
        let collapsesToArtifact = previewable || lineCount >= 18
        let artifactTitle = HTMLPreviewHelper.extractTitle(code: parsed.body, language: parsed.language)
        let artifact: ArtifactKind = previewable
            ? .web(code: parsed.body, language: parsed.language, title: artifactTitle)
            : .code(code: parsed.body, language: parsed.language, title: artifactTitle)

        Group {
            if collapsesToArtifact {
                let langLabel = parsed.language?.uppercased() ?? (previewable ? "HTML" : "代码")
                let subtitle = previewable
                    ? "\(langLabel) 网页 · \(lineCount) 行 · 点开直接预览"
                    : "\(langLabel) · \(lineCount) 行 · 点开查看与复制"
                ArtifactCardView(
                    title: artifactTitle,
                    subtitle: subtitle,
                    iconName: artifact.iconName,
                    actionHint: previewable ? "预览" : "查看"
                ) {
                    showArtifact = true
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text(parsed.language ?? "代码")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Ink.ink3)
                        Spacer()
                        CopyGlyphButton(label: "复制代码", size: 14, lineWidth: 1.32) { parsed.body }
                            .foregroundStyle(Ink.ink3)
                    }
                    Rectangle().fill(Ink.line).frame(height: 0.5)
                    ScrollView(.horizontal) {
                        Text(MarkdownAnswer.highlightedCode(parsed.body, language: parsed.language))
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
                .background(Ink.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Ink.line, lineWidth: 0.8).allowsHitTesting(false))
            }
        }
        .sheet(isPresented: $showArtifact) {
            ArtifactPreviewSheet(artifact: artifact)
        }
    }
}

private struct MarkdownMathBlockView: View, Equatable {
    let formula: String

    nonisolated static func == (lhs: MarkdownMathBlockView, rhs: MarkdownMathBlockView) -> Bool {
        lhs.formula == rhs.formula
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("公式")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Ink.ink3)
                Spacer()
                CopyGlyphButton(label: "复制公式原文", size: 14, lineWidth: 1.32) { formula }
                    .foregroundStyle(Ink.ink3)
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
        .background(Ink.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Ink.line, lineWidth: 0.8).allowsHitTesting(false))
    }
}

/// The copy glyph that turns into a tick for a moment, with a little spring and a
/// success tap; shared by answers, code and formulas.
struct CopyGlyphButton: View {
    let label: String
    var size: CGFloat = 16.5
    var lineWidth: CGFloat = 1.38
    let text: () -> String
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            UIPasteboard.general.string = text()
            Haptic.success()
            withMotion(Motion.lively) { copied = true }
            resetTask?.cancel()
            resetTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                withMotion(Motion.snappy) { copied = false }
            }
        } label: {
            ZStack {
                ClaudeActionGlyph(kind: .copy, size: size, lineWidth: lineWidth)
                    .opacity(copied ? 0 : 1)
                    .scaleEffect(copied ? 0.6 : 1)
                ClaudeActionGlyph(kind: .copied, size: size, lineWidth: lineWidth)
                    .opacity(copied ? 1 : 0)
                    .scaleEffect(copied ? 1 : 0.4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressFeedback)
        .accessibilityLabel(copied ? "已复制" : label)
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
    var inkKey: String? = nil
    var grows = false
    @AppStorage(FontLibrary.choiceKey) private var fontChoice = ""
    @AppStorage(FontLibrary.revisionKey) private var fontRevision = 0
    @AppStorage("qingjian.reading.size") private var readingSize = 16.0
    var body: some View {
        let _ = (fontChoice, fontRevision, StyleAppearance.shared.revision, FontAppearance.shared.revision)
        let delta: CGFloat = level == 1 ? 5 : (level == 2 ? 3.5 : 2)
        let styled = HighlightMarks.parseInline(text).applyingEditorialStyle(
            baseSize: CGFloat(readingSize) + delta,
            boldColor: Ink.ink,
            forceBold: true
        )
        InkText(text: Text(styled), length: styled.characters.count, key: inkKey, grows: grows)
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
        let size = TypeScale.scaled(CGFloat(readingSize), .body)
        if isNumbered {
            Text(marker)
                .font(ReadingFont.resolve(baseSize: CGFloat(readingSize), bold: false, italic: false))
                .monospacedDigit()
                .foregroundStyle(Ink.ink2)
                .frame(minWidth: 22, alignment: .leading)
        } else {
            // A drawn dot reads cleaner than the "•" glyph, whose size and height vary by font.
            let dot = max(4.5, size * 0.3)
            Group {
                if marker == "◦" {
                    Circle().stroke(Ink.ink2, lineWidth: 1).frame(width: dot, height: dot)
                } else {
                    Circle().fill(Ink.ink).frame(width: dot, height: dot)
                }
            }
            .frame(width: 16, alignment: .leading)
            // Sit the dot on the middle of a Chinese character (about 0.36 em above the baseline).
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + size * 0.36 }
            .accessibilityHidden(true)
        }
    }
}

struct MarkdownParagraph: View, Equatable {
    let text: String
    /// Kept for callers; bold phrases are no longer drawn as highlighter marks.
    var marks = HighlightMarks.perAnswer
    var inkKey: String? = nil
    var grows = false
    nonisolated static func == (lhs: MarkdownParagraph, rhs: MarkdownParagraph) -> Bool {
        lhs.text == rhs.text && lhs.marks == rhs.marks && lhs.inkKey == rhs.inkKey && lhs.grows == rhs.grows
    }
    private var parsed: AttributedString {
        HighlightMarks.parseInline(text)
    }
    var body: some View {
        if text.hasPrefix("#") {
            let level = text.prefix(while: { $0 == "#" }).count
            let bodyText = String(text.drop(while: { $0 == "#" || $0 == " " }))
            EditorialHeadingRow(text: bodyText, level: level, inkKey: inkKey, grows: grows)
        } else {
            EditorialParagraphBody(parsed: parsed, inkKey: inkKey, grows: grows)
        }
    }
}

/// Non-equatable inner view so appearance/font/size changes redraw paragraphs even while `MarkdownParagraph` stays `.equatable()`.
private struct EditorialParagraphBody: View {
    let parsed: AttributedString
    var inkKey: String? = nil
    var grows = false
    @AppStorage(FontLibrary.choiceKey) private var fontChoice = ""
    @AppStorage(FontLibrary.revisionKey) private var fontRevision = 0
    @AppStorage("qingjian.reading.size") private var readingSize = 16.0
    var body: some View {
        let _ = (fontChoice, fontRevision, StyleAppearance.shared.revision, FontAppearance.shared.revision)
        let styled = parsed.applyingEditorialStyle(baseSize: CGFloat(readingSize))
        InkText(text: Text(styled), length: styled.characters.count, key: inkKey, grows: grows)
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
            .onAppear {
                text = message.role == .user
                    ? PendingDocumentCodec.extractEditableUserText(message.content)
                    : message.content
            }
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
    @State private var previewTarget: DocumentPreviewTarget?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
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
                    .background(Ink.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Ink.line, lineWidth: 1))
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

/// One entry in the 「/」 menu above the composer.
struct SlashCommand: Identifiable {
    let name: String
    let detail: String
    let action: () -> Void
    var id: String { name }
}

/// The 「/存为做法」 editor, for the sheet on the chat screen.
struct ProjectSkillTarget: Identifiable {
    let projectID: UUID
    let draft: ProjectSkillDraft
    var id: UUID { draft.id }
}

/// Opens a project's memory from the 「记忆已更新」 line.
struct ProjectMemoryTarget: Identifiable {
    let id: UUID
}
