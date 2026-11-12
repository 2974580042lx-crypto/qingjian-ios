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
    @State private var sidebarDrag: CGFloat = 0
    @AppStorage("qingjian.haptics") private var hapticsEnabled = true
    @AppStorage(AppearanceMode.key) private var appearance = AppearanceMode.system.rawValue

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width * 0.82, 360)
            let position = min(width, max(0, (showSidebar ? width : 0) + sidebarDrag))
            let progress = position / width
            let frontPage = PageContour(radius: Radius.pageFront * progress, topInset: geometry.safeAreaInsets.top, bottomInset: geometry.safeAreaInsets.bottom)
            let backPage = PageContour(radius: Radius.pageBack * progress, topInset: geometry.safeAreaInsets.top, bottomInset: geometry.safeAreaInsets.bottom)
            ZStack(alignment: .leading) {
                Ink.sheet.ignoresSafeArea()
                // Not built while closed, so it does not redraw with every streamed chunk.
                Group {
                    if progress > 0 || showSidebar {
                        HistorySidebar(close: { showSidebar = false },
                                       openSettings: { showSettings = true },
                                       openProjects: { showProjects = true },
                                       openAllChats: { showAllChats = true },
                                       openBooks: { showBooks = true })
                    } else { Color.clear }
                }
                .frame(width: width)
                .background(Ink.sheet.ignoresSafeArea())
                .clipShape(backPage)
                .overlay(backPage.stroke(Ink.line.opacity(progress), lineWidth: 0.5).allowsHitTesting(false))
                .offset(x: -width * 0.2 * (1 - progress))
                .opacity(min(1, progress * 3))
                .allowsHitTesting(showSidebar)
                .accessibilityHidden(!showSidebar)

                NavigationStack {
                    ChatScreen(openHistory: { showSidebar = true }, openSettings: { showSettings = true }, keyboardVisible: $keyboardVisible,
                               composerPanelHeight: $composerPanelHeight, bottomInset: geometry.safeAreaInsets.bottom,
                               topInset: geometry.safeAreaInsets.top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollDisabled(sidebarDrag != 0)
                .tint(Ink.ink)
                .background(AppBackground())
                .overlay {
                    if progress > 0 {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { showSidebar = false }
                    }
                }
                .clipShape(frontPage)
                .background(frontPage.fill(Ink.paper)
                    .shadow(color: Color.black.opacity(0.16 * progress), radius: 24, x: -8)
                    .allowsHitTesting(false))
                .overlay(frontPage.stroke(Ink.line.opacity(progress), lineWidth: 0.6).allowsHitTesting(false))
                .offset(x: position)
                .accessibilityHidden(showSidebar)
            }
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: showSidebar)
            .background(SidebarPan(enabled: true, isOpen: showSidebar,
                maximumStartY: geometry.frame(in: .global).maxY - composerPanelHeight - (keyboardVisible ? 0 : FloatingChrome.navigationHeight),
                changed: { distance in
                    sidebarDrag = showSidebar ? max(-width, min(0, distance)) : min(width, max(0, distance))
                }, ended: { distance, prediction in
                    let threshold = min(65, width * 0.18)
                    let open = showSidebar ? !(distance < -threshold || prediction < -width * 0.45) :
                        (distance > threshold || prediction > width * 0.45)
                    if open {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { showSidebar = open; sidebarDrag = 0 }
                }, cancelled: {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { sidebarDrag = 0 }
                }))
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
        // Route files opened from the Files app by extension: backups vs novels.
        .onOpenURL { url in
            guard url.isFileURL else { return }
            let ext = url.pathExtension.lowercased()
            if ext == "sermobackup" || ext == "json" {
                Task {
                    guard let local = await Task.detached(priority: .userInitiated, operation: { IncomingFile.privateCopy(of: url) }).value else {
                        store.errorMessage = "没能读取这个备份文件，请在「文件」里确认它已下载后再试。"
                        return
                    }
                    store.prepareBackupRestore(local, removeWhenDone: true)
                }
                return
            }
            showBooks = true
            Task {
                // Import a private copy: the importer removes what it reads, and the
                // original may now be the user's own file rather than a system copy.
                guard let local = await Task.detached(priority: .userInitiated, operation: { IncomingFile.privateCopy(of: url) }).value else {
                    store.errorMessage = "没能读取这个文件，请在「文件」里确认它已下载后再试。"
                    return
                }
                _ = await store.books.importBook(from: local)
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
            picker.dismiss(animated: true) {
                ChatPhotoPicker.current = nil
                self.picked(results)
            }
        }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            guard !finished else { return }
            finished = true
            ChatPhotoPicker.current = nil
            picked([])
        }
    }
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
    @State private var nearBottom = true
    @State private var choosingFiles = false
    @State private var choosingPhotos = false
    @State private var fileImportTask: Task<Void, Never>?
    @State private var fileImportThreadID: UUID?
    @State private var fileImportProgress = ""
    @State private var photoLoadThreadID: UUID?
    @State private var photoLoadSessionID: UUID?
    @State private var photoLoadTask: Task<Void, Never>?
    @State private var imagesByThread: [UUID: [PendingImage]] = [:]
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
    @State private var laidOutMessageJumpID: UUID?
    @State private var focusedMessageID: UUID?
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
        !localDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty
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
            if store.send(store.activeDraft, images: []) { focusComposer(false) }
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

    private var transcript: some View {
        Group {
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
            ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: swiss ? 0 : 30) {
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
                .padding(.horizontal, swiss ? 20 : Personal.margin).padding(.top, 10).padding(.bottom, 22)
            }
            .accessibilityIdentifier("chat-scroll")
            // The system's top edge effect drew a solid paper band behind the buttons, so
            // they never looked afloat. Text now passes under the glass; only the clock
            // keeps a short fade so it stays readable.
            .scrollEdgeEffectHidden(true, for: .top)
            .overlay(alignment: .top) {
                // The clock row sits on the page colour fading out below it, so the time
                // never prints over the text. A plain gradient: a live blur here had to be
                // recomputed every frame while an answer streamed and scrolled under it.
                LinearGradient(stops: [.init(color: Ink.paper, location: 0), .init(color: Ink.paper, location: 0.62),
                                       .init(color: Ink.paper.opacity(0), location: 1)], startPoint: .top, endPoint: .bottom)
                    .frame(height: topInset + 14).allowsHitTesting(false).accessibilityHidden(true)
            }
            .scrollPosition($scrollPosition)
            .contentMargins(.top, topChrome, for: .scrollContent)
            .contentMargins(.top, topChrome, for: .scrollIndicators)
            .contentMargins(.bottom, composerPanelHeight + bottomInset + 12, for: .scrollContent)
            .contentMargins(.bottom, composerPanelHeight + bottomInset + 12, for: .scrollIndicators)
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
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentSize.height + g.contentInsets.bottom - g.contentOffset.y - g.containerSize.height < 80
            } action: { _, value in nearBottom = value }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { followsOutput = false; clearMessageNavigation() }
                if phase == .idle && nearBottom && pendingMessageJump == nil && focusedMessageID == nil { followsOutput = true }
            }
            .onChange(of: store.activeThread?.messages.count) { _, _ in
                // Straight to the new message: a glide here, on top of the list's own
                // update, left a ghost of the text while sending.
                guard shouldFollowOutput else { return }
                scrollPosition.scrollTo(edge: .bottom)
            }
            .onChange(of: store.activeThread?.messages.last?.content) { _, _ in
                if shouldFollowOutput && store.generatingThreadID == store.activeThreadID {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
            .onChange(of: store.activeThread?.messages.last?.replySuggestions) { _, _ in
                if shouldFollowOutput { scrollPosition.scrollTo(edge: .bottom) }
            }
            }
            }
        }
    }

    var body: some View { chatWithAlerts }

    // Separate opaque view expressions keep type checking bounded. State remains
    // on ChatScreen, and the transcript preference stays inside its hosting tree.
    private var chatLayout: some View {
        KeyboardChatLayout {
            transcript.environmentObject(store).environmentObject(profile)
                .onPreferenceChange(ChatMessageJumpLayoutKey.self) { requestID in
                    laidOutMessageJumpID = requestID
                    finishMessageJump()
                }
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
                Button { store.createThread(in: store.activeThread?.projectID); followsOutput = true } label: { Image(systemName: "square.and.pencil") }
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
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
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
            if focused && shouldFollowOutput { scrollPosition.scrollTo(edge: .bottom) }
        }
        .onAppear { loadDraft() }
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
            store.speech.stop()
            systemPromptTarget = nil; versionsTarget = nil
            messageBrowser = nil; clearMessageNavigation()
            store.webSearchEnabled = false
            storyPlayFor = nil; pendingSuggestedReply = nil
            visibleMessageCount = 100; followsOutput = true
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
        // A Drive write the model asked for waits here; closing the sheet counts as "no".
        .sheet(item: Binding(get: { store.pendingApproval }, set: { if $0 == nil { store.resolveApproval(false) } })) { approval in
            ToolApprovalSheet(approval: approval) { store.resolveApproval($0) }
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
        return ForEach(visibleMessages) { message in
            // Equatable: only the message that changed redraws while an answer streams.
            messageRow(message, threadID: threadID, isLast: message.id == lastID, round: rounds[message.id] ?? 1, style: look)
                .background {
                    if pendingMessageJump?.messageID == message.id, let requestID = pendingMessageJump?.id {
                        GeometryReader { geometry in
                            Color.clear.preference(key: ChatMessageJumpLayoutKey.self,
                                                   value: geometry.size.height > 0 ? requestID : nil)
                        }
                    }
                }
                .overlay(alignment: .leading) {
                    if focusedMessageID == message.id {
                        RoundedRectangle(cornerRadius: 2).fill(Ink.seal.opacity(0.7)).frame(width: 3).padding(.leading, -10)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
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
        focusedMessageID = nil; laidOutMessageJumpID = nil
        pendingMessageJump = ChatMessageJump(threadID: threadID, messageID: messageID)
        // Render the target even when it is older than the default last 100 messages.
        visibleMessageCount = max(visibleMessageCount, thread.messages.count - index)
        messageBrowser = nil
    }
    private func finishMessageJump() {
        guard !messageBrowserVisible, messageBrowser == nil, let request = pendingMessageJump, laidOutMessageJumpID == request.id else { return }
        // The target has reported a nonzero layout; issue the scroll on the next UI turn.
        DispatchQueue.main.async {
            guard pendingMessageJump?.id == request.id, let thread = store.activeThread,
                  thread.id == request.threadID, !store.isHidden(thread),
                  thread.messages.contains(where: { $0.id == request.messageID }) else { return }
            followsOutput = false
            focusedMessageID = request.messageID
            scrollPosition.scrollTo(id: request.messageID, anchor: .top)
            pendingMessageJump = nil; laidOutMessageJumpID = nil
        }
    }
    private func clearMessageNavigation() {
        pendingMessageJump = nil; laidOutMessageJumpID = nil; focusedMessageID = nil
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

    @ViewBuilder private func messageRow(_ message: ChatMessage, threadID: UUID?, isLast: Bool, round: Int, style: InterfaceStyle) -> some View {
        if message.state == .streaming {
            // The answer being written redraws on its own, without the rest of the page.
            LiveMessageRow(live: store.live, message: message, onGrow: followLiveText) { shown in
                messageBody(shown, threadID: threadID, isLast: isLast, round: round, style: style)
            }.id(message.id)
        } else {
            messageBody(message, threadID: threadID, isLast: isLast, round: round, style: style).id(message.id)
        }
    }

    private func messageBody(_ message: ChatMessage, threadID: UUID?, isLast: Bool, round: Int, style: InterfaceStyle) -> some View {
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
        return MessageView(message: message, threadID: threadID, isLast: isLast,
                    isGenerating: store.isGenerating, canRegenerate: store.canChat,
                    showsSuggestions: store.settings.shouldSuggestReplies && store.activeProject?.studySubject == nil,
                    edit: { focusComposer(false); editingThreadID = threadID; editedMessage = message },
                    regenerate: regeneratePreservingDraftImages,
                    openThinking: { if let threadID { thinkingTarget = ThinkingTarget(threadID: threadID, messageID: message.id) } },
                    useSuggestedReply: { text in prepareSuggestedReply(text, messageID: message.id) },
                    signInDrive: { store.drive.signIn() }, round: round, style: style,
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
        if shouldFollowOutput && store.generatingThreadID == store.activeThreadID {
            scrollPosition.scrollTo(edge: .bottom)
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
            HStack(spacing: 6) {
                Text(store.pillModelTitle).foregroundStyle(Ink.ink).lineLimit(1)
                Text(store.pillEffortTitle).foregroundStyle(Ink.ink3)
            }
            // A soft grey capsule, as in the Claude app ("Opus 5.5 中等").
            .font(.system(size: 14, weight: .medium)).monospacedDigit()
            .padding(.horizontal, 14).frame(height: 38)
            .background(Ink.raised, in: Capsule())
            .contentShape(Capsule())
        }
    }

    // The web switch: a globe that grows into a 联网 pill, or WEB: ON / OFF in the Swiss look.
    @ViewBuilder private var webToggleLabel: some View {
        if swiss {
            Text(store.webSearchEnabled ? "WEB: ON" : "WEB: OFF")
                .font(TypeScale.mono(11))
                .foregroundStyle(store.webSearchEnabled ? Ink.seal : Ink.ink3)
                .frame(minWidth: 38, minHeight: 38).contentShape(Rectangle())
        } else {
            // Off: a quiet globe. On: the globe and 「联网」 in the accent colour, no base.
            HStack(spacing: 5) {
                Image(systemName: "globe")
                if store.webSearchEnabled { Text("联网").font(.system(size: 14, weight: .medium)) }
            }
            .foregroundStyle(store.webSearchEnabled ? Ink.seal : Ink.ink3)
            .frame(minWidth: 38, minHeight: 38)
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

    private func importDocuments(_ urls: [URL], into origin: UUID) {
        guard !urls.isEmpty else { return }
        fileImportThreadID = origin
        fileImportTask = Task { @MainActor in
            defer { fileImportThreadID = nil; fileImportTask = nil; fileImportProgress = "" }
            var successes = 0
            var details: [String] = []
            for (index, url) in urls.enumerated() {
                if Task.isCancelled { details.append("已取消剩余文件；已经导入的内容保留。"); break }
                guard let current = store.threads.first(where: { $0.id == origin }), !store.isHidden(current) else {
                    details.append("原对话已删除或上锁，剩余内容没有加入其他对话。")
                    break
                }
                fileImportProgress = "正在读取 \(index + 1)/\(urls.count)：\(url.lastPathComponent)"
                do {
                    let imported = try await DocumentTextImporter.load(url)
                    try Task.checkCancellation()
                    let addition = "【文件：\(imported.name)】\n\(imported.text)"
                    if store.appendImportedText(addition, to: origin) {
                        successes += 1
                        details.append(contentsOf: imported.warnings.map { "\(imported.name)：\($0)" })
                    } else {
                        details.append("\(imported.name)：\(store.errorMessage ?? "未能保存到草稿，请稍后再试。")")
                        store.errorMessage = nil
                    }
                } catch is CancellationError {
                    details.append("已取消剩余文件；已经导入的内容保留。")
                    break
                } catch {
                    details.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            let location = origin == store.activeThreadID ? "当前对话" : "原来对话"
            var report = "已将 \(successes)/\(urls.count) 份文件加入\(location)的草稿，由你检查后发送。"
            if !details.isEmpty { report += "\n\n" + details.joined(separator: "\n\n") }
            attachmentReport = report
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

    @ViewBuilder private var composerTopControls: some View {
        let hasMessages = store.activeThread?.messages.isEmpty == false
        if store.canChooseProject || (hasMessages && !nearBottom) {
            // Small glass buttons floating above the composer: the project on a new page,
            // 「回到最新」 on the right only while you are scrolled up. The instruction
            // button lives in the 「+」 row now, so nothing sits on the text you read.
            HStack(spacing: 10) {
                if store.canChooseProject { projectPill }
                Spacer(minLength: 0)
                if hasMessages && !nearBottom {
                    Button(action: jumpToLatest) {
                        Image(systemName: "arrow.down").font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Ink.ink)
                            .frame(width: 44, height: 44)
                            .floatingGlass(in: AnyShape(Circle()))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.pressFeedback).accessibilityLabel("一键回到最新消息")
                    .accessibilityIdentifier("chat-jump-to-latest")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .animation(.snappy(duration: 0.2), value: nearBottom)
        }
    }

    // Photos, files and pasted text behind one 「+」. It opens a small row inside the
    // composer instead of a system menu: a picker started while a menu was still
    // closing was dropped, so 「图片」 needed several taps before.
    private var attachmentButton: some View {
        Button {
            Haptic.tap()
            withAnimation(.snappy(duration: 0.22)) { attachTrayOpen.toggle() }
        } label: {
            Image(systemName: "plus").font(.system(size: 17, weight: .medium))
                .foregroundStyle(Ink.ink)
                .rotationEffect(.degrees(attachTrayOpen ? 45 : 0))
                .frame(width: 38, height: 38)
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
                guard let text = UIPasteboard.general.string, !text.isEmpty else {
                    attachmentReport = "剪贴板里没有文字。"
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

    private var composer: some View {
        VStack(spacing: 8) {
            composerTopControls
            ghostBar
            if store.searchingThreadID == store.activeThreadID && store.isGenerating {
                HStack { ProgressView(); Text("正在联网搜索…").font(TypeScale.caption) }
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
                            if store.send(store.activeDraft, images: pendingImages.map(\.data)) {
                                pendingImages = []
                                focusComposer(false)
                            }
                        }
                    } label: {
                        Image(systemName: store.isGenerating ? "stop.fill" : "arrow.up")
                            .font(.system(size: 15, weight: .bold)).foregroundStyle(Ink.sendGlyph)
                            .frame(width: 38, height: 38)
                            .background(Ink.sendFill, in: RoundedRectangle(cornerRadius: swiss ? 0 : 19, style: .continuous))
                            .shadow(color: night ? Ink.seal.opacity(0.35) : .clear, radius: night ? 12 : 0)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.isGenerating && (!store.canChat || !(hasInput || ghostText != nil) || !store.canPersist || loadingPhotos
                        || (fileImportThreadID != nil && fileImportThreadID == store.activeThreadID)))
                    .opacity(!store.isGenerating && !(hasInput || ghostText != nil) ? 0.35 : 1)
                    .accessibilityLabel(store.isGenerating ? "停止生成" : "发送消息")
                }
            }
            .padding(.horizontal, 14).padding(.top, swiss ? 14 : 16).padding(.bottom, swiss ? 10 : 12)
            .clearGlass(radius: 26)
            if store.isGenerating && store.generatingThreadID != store.activeThreadID {
                Text("另一个对话正在生成，右侧按钮可停止。")
                    .font(TypeScale.tiny).foregroundStyle(Ink.ink3)
            }
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10)
        .accessibilityElement(children: .contain).accessibilityIdentifier("chat-composer-panel")
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerPanelHeight = $0 }
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

private struct ChatMessageJumpLayoutKey: PreferenceKey {
    static var defaultValue: UUID? { nil }
    static func reduce(value: inout UUID?, nextValue: () -> UUID?) {
        if let next = nextValue() { value = next }
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
                .background(AppBackground())
                .navigationTitle(request.mode.title)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: request.mode == .search ? "搜索消息正文" : "搜索收藏内容")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
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
        .listStyle(.insetGrouped).scrollContentBackground(.hidden)
    }
    private var emptyResults: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(request.mode == .bookmarks && term.isEmpty ? "还没有收藏消息" : "没有找到匹配的消息")
                .font(TypeScale.body).foregroundStyle(Ink.ink)
            Text(request.mode == .bookmarks && term.isEmpty ? "长按对话中的消息，选择「收藏消息」。" : "试试更短的关键词。")
                .font(TypeScale.label).foregroundStyle(Ink.ink3)
        }.padding(.vertical, 10).listRowBackground(Ink.raised)
    }
    private func resultRow(_ message: ChatMessage) -> some View {
        ChatMessageMatchRow(message: message, query: term) { open(message.id) }
            .listRowBackground(Ink.raised)
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
    @AppStorage("qingjian.reading.aiBubble") private var aiBubble = false
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
            && lhs.showsSuggestions == rhs.showsSuggestions && lhs.round == rhs.round && lhs.style == rhs.style
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
            // Times are no longer printed under every message; they are one press away.
            Text(MessageTime.label(message.createdAt))
            // The three used most come first; everything else sits below a divider.
            Section {
                Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.content; Haptic.tap() }
                Button("选择文字", systemImage: "selection.pin.in.out") { selecting = true }
                Button("编辑文字", systemImage: "pencil") { edit() }.disabled(isGenerating)
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
        }
        .sheet(isPresented: $selecting) { SelectableTextSheet(text: message.content) }
    }

    // 纸笺: one column; your note set off by a thin rule, the answer as plain text.
    private var paperContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if message.role == .user {
                // Your words on the right in a soft rounded bubble, like the Claude app;
                // the answer stays plain text on the page. 夜江 keeps its water line.
                if style == .night && round > 1 { WaveRule().padding(.bottom, 8) }
                HStack(spacing: 0) {
                    Spacer(minLength: 52)
                    VStack(alignment: .trailing, spacing: 6) {
                        discussionVoiceLabel
                        if let names = message.images, !names.isEmpty { AttachmentRow(names: names) }
                        Text(message.content).userMessageStyle().lineSpacing(max(Personal.lineSpacing - 2, 3)).chineseReading()
                            .foregroundStyle(Ink.ink).textSelection(.enabled)
                            .padding(.horizontal, 16).padding(.vertical, 11)
                            .background(Personal.bubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                answerParts
                if message.state == .streaming {
                    StreamActivityView(message: message)
                } else {
                    HStack(spacing: 18) {
                        Button { copyAnswer() } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                            .accessibilityLabel("复制回答")
                        Button { selecting = true } label: { Image(systemName: "selection.pin.in.out") }
                            .accessibilityLabel("选择部分文字")
                        Button { edit() } label: { Image(systemName: "pencil") }
                            .disabled(isGenerating).accessibilityLabel("编辑回答")
                        if message.state == .complete, let speech {
                            SpeechPlaybackControl(speech: speech, text: message.content, messageID: message.id)
                        }
                        if isLast {
                            Button { regenerate() } label: { Image(systemName: "arrow.clockwise") }
                                .disabled(isGenerating || !canRegenerate).accessibilityLabel("重新生成")
                        }
                        Spacer(minLength: 4)
                        // Cost only; the time is in the long-press menu.
                        if let usage = message.usage {
                            Text(usageLabel(usage)).font(.system(size: 11.5)).monospacedDigit().lineLimit(1)
                                .accessibilityLabel("本次请求共 \(usage.totalTokens) 个 Token")
                        }
                    }.font(.system(size: 15)).foregroundStyle(Ink.ink3).buttonStyle(.pressFeedback).padding(.top, 2)
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
                if round > 1 { SwissRule(weight: 1, strong: true) }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    MonoLabel(text: String(format: "Q.%02d", round)).frame(width: 46, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        discussionVoiceLabel
                        if let names = message.images, !names.isEmpty { AttachmentRow(names: names) }
                        Text(message.content).readingStyle(adjustment: -2).fontWeight(.medium).lineSpacing(5)
                            .textSelection(.enabled).foregroundStyle(Ink.ink)
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

    // Thinking, tool calls and the answer text: the same in both looks.
    @ViewBuilder private var answerParts: some View {
        discussionVoiceLabel
        if !message.reasoning.isEmpty {
            ThinkingRow(message: message, open: openThinking)
        }
        if let tools = message.toolActivity, !tools.isEmpty {
            ToolActivityList(items: tools, signIn: signInDrive)
        }
        if !message.content.isEmpty {
            let bubble = aiBubble && style != .swiss
            MarkdownAnswer(content: message.content, style: style).equatable()
                .padding(bubble ? 16 : 0)
                .background(bubble ? Ink.raised : .clear, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
    private var side: CGFloat { names.count == 1 ? 168 : (names.count == 2 ? 120 : 76) }
    var body: some View {
        HStack(spacing: 8) {
            ForEach(names, id: \.self) { name in
                Group {
                    if let image = ImageStore.thumbnail(named: name) {
                        Image(uiImage: image).resizable().scaledToFill().accessibilityLabel("附带的图片")
                    } else {
                        Ink.raised.overlay(Image(systemName: "photo").foregroundStyle(Ink.ink3))
                            .accessibilityLabel("图片文件已不在这台手机上")
                    }
                }
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

// Equatable so finished answers are not re-parsed while a new one streams in.
// Paragraphs are Equatable too: while text arrives only the last one is parsed again.
struct MarkdownAnswer: View, Equatable {
    let content: String
    var style: InterfaceStyle = .paper
    nonisolated static func == (lhs: MarkdownAnswer, rhs: MarkdownAnswer) -> Bool { lhs.content == rhs.content && lhs.style == rhs.style }
    private var swiss: Bool { style == .swiss }
    // Paragraphs, headings, lists, quotes, dividers and code, each text block told
    // how many of the answer's highlighter marks it may still draw.
    private var blocks: [MarkdownBlock] { MarkdownBlock.parse(content) }
    var body: some View {
        // Paragraphs a clear step apart (about one line), so each reads as its own block.
        VStack(alignment: .leading, spacing: style == .swiss ? 16 : Personal.paragraphGap) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text, let marks):
                    MarkdownParagraph(text: text, marks: marks, style: style).equatable()
                case .heading(let text, let level):
                    EditorialHeadingRow(text: text, level: level, style: style)
                case .list(let items):
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
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
                        .opacity(0.85)
                        .padding(.leading, 14)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: swiss ? 0 : 1.25, style: .continuous)
                                .fill(swiss ? Ink.ink : Ink.seal.opacity(0.75)).frame(width: swiss ? 3 : 2.5)
                        }
                case .table(let header, let rows, let alignments):
                    // Wide tables scroll sideways inside the answer instead of squeezing.
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
                case .divider:
                    Rectangle().fill(swiss ? Ink.ink : Ink.line).frame(height: 1).padding(.vertical, 4)
                case .code(let segment):
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(swiss ? "CODE" : "代码").font(swiss ? TypeScale.mono(10) : TypeScale.tiny.weight(.semibold)).foregroundStyle(Ink.seal)
                            Spacer()
                            Button { UIPasteboard.general.string = Self.codeBody(segment) } label: { Image(systemName: "doc.on.doc").foregroundStyle(Ink.seal) }
                                .font(.system(size: 11)).accessibilityLabel("复制代码")
                        }
                        ScrollView(.horizontal) {
                            Text(Self.codeBody(segment)).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                        }
                    }.padding(14).background(Ink.raised, in: RoundedRectangle(cornerRadius: swiss ? 0 : 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: swiss ? 0 : 16, style: .continuous)
                            .stroke(swiss ? Ink.line : Ink.seal.opacity(0.18), lineWidth: 1).allowsHitTesting(false))
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    fileprivate static func inline(_ text: String, baseSize: CGFloat = 18) -> AttributedString {
        HighlightMarks.parseInline(text)
            .applyingTerracottaCodeAndEmphasis(baseSize: baseSize, boldColor: Ink.seal)
    }
    private static func codeBody(_ segment: String) -> String {
        guard let newline = segment.firstIndex(of: "\n") else { return segment }
        let first = segment[..<newline].trimmingCharacters(in: .whitespaces)
        return first.isEmpty || (!first.contains(" ") && first.count < 24) ? String(segment[segment.index(after: newline)...]) : segment
    }
}

// One table cell: inline Markdown, wrapped past a comfortable width, a hairline below.
struct TableCell: View {
    let text: String
    let header: Bool
    let alignment: TableAlignment
    @AppStorage(FontLibrary.choiceKey) private var fontChoice = ""
    @AppStorage(FontLibrary.revisionKey) private var fontRevision = 0
    @AppStorage("qingjian.reading.size") private var readingSize = 18.0
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
    @AppStorage("qingjian.reading.size") private var readingSize = 18.0
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
    @AppStorage("qingjian.reading.size") private var readingSize = 18.0
    var body: some View {
        let _ = (fontChoice, fontRevision, StyleAppearance.shared.revision, FontAppearance.shared.revision)
        Text(marker)
            .font(ReadingFont.resolve(baseSize: CGFloat(readingSize), bold: false, italic: false))
            .foregroundStyle(Ink.ink)
            .frame(minWidth: marker.count > 1 ? 22 : 12, alignment: .leading)
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
    @AppStorage("qingjian.reading.size") private var readingSize = 18.0
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
            }.padding(20).background(Ink.paper)
                .navigationTitle(message.role == .user ? "编辑你的消息" : "编辑回答")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存") {
                            if store.editMessage(message.id, text: text, resend: false) { dismiss() }
                        }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }.presentationDragIndicator(.visible)
            .onAppear { text = message.content }
            .alert("暂时没有完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("知道了") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
    }
}

// "10月13日 14:32"; the year is added only for another year.
enum MessageTime {
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
}
