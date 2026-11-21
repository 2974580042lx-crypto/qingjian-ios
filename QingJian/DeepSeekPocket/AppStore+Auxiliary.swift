import Foundation

// 1.46: Sermo's background helpers — the turn router, memory, compaction, reply suggestions —
// run on DeepSeek Flash by default. When DeepSeek cannot answer (no key, balance used up,
// rate limited) they move on to the ChatGPT subscription by themselves. Settings → 聊天与指令
// → 辅助调用 can put the subscription first or follow the chat's own service.
extension AppStore {
    /// Services to try for a helper request, in order, leaving out ones that are not set up.
    func auxiliaryCandidates(for thread: ChatThread? = nil) -> [AIProvider] {
        AuxiliaryRouting.order(policy: settings.auxiliaryProviderPolicy, chatProvider: provider(for: thread ?? activeThread))
            .filter { isReady($0) }
    }

    /// Runs one small helper request and returns its text. A service that is out of balance or
    /// unavailable is skipped for the next one; any other error is passed on.
    func runAuxiliary(_ request: ChatRequest, thread: ChatThread? = nil, subscriptionModel: String? = nil,
                      timeout: TimeInterval = 60) async throws -> (text: String, provider: AIProvider) {
        let candidates = auxiliaryCandidates(for: thread)
        guard !candidates.isEmpty else { throw ChatError.missingKey }
        var lastError: Error = ChatError.missingKey
        for provider in candidates {
            let buffer = AuxTextBuffer()
            do {
                try await streamModel(request, provider: provider,
                    subscriptionModel: subscriptionModel ?? settings.subscriptionModel,
                    requestTimeout: timeout, resourceTimeout: timeout * 2,
                    onRestart: { buffer.value = AuxTextAccumulator() }) { buffer.value.consume($0) }
                recordUsage(buffer.value.usage, model: provider == .deepSeek ? .flash : nil, at: Date(), provider: provider)
                let text = try buffer.value.result()
                return (text, provider)
            } catch {
                lastError = error
                guard AuxiliaryRouting.shouldTryNextService(after: error), !Task.isCancelled else { throw error }
            }
        }
        throw lastError
    }

    /// Decides what one message needs before it is answered. When the helper cannot answer in
    /// time, the message gets the full tools, as every message did before 1.46.
    func planTurn(_ context: TurnRouter.Context, thread: ChatThread?) async -> TurnPlan {
        if let quick = TurnRouter.localPlan(context.latest, context: context) { return quick }
        let request = TurnRouter.request(context)
        let work = Task { @MainActor [weak self] () -> TurnPlan? in
            guard let self else { return nil }
            guard let reply = try? await self.runAuxiliary(request, thread: thread, timeout: 15) else { return nil }
            return TurnRouter.parse(reply.text, context: context)
        }
        let watchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            work.cancel()
        }
        let plan = await work.value
        watchdog.cancel()
        return plan ?? .fullTools
    }

    /// Looks a question up in the project's material on the device and returns a note with the
    /// best passages, or nil when nothing matches.
    func projectMaterialNote(_ query: String, project: ChatProject) async -> String? {
        let library = projectLibrary, documents = project.documents, projectID = project.id
        return await Task.detached(priority: .userInitiated) { () -> String? in
            let payload: [String: Any] = ["query": query, "limit": 6]
            let arguments = (try? JSONSerialization.data(withJSONObject: payload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let call = ToolCall(id: "route-docs", name: "project_search_docs", arguments: arguments)
            guard let found = try? ProjectLibraryTools.execute(call, projectID: projectID,
                                                               inlineDocuments: documents, store: library),
                  !found.hasPrefix("在当前项目文献库中没有找到") else { return nil }
            var passages: [String] = []
            if let hits = try? library.search(projectID: projectID, query: query, limit: 3) {
                for hit in hits {
                    if let text = try? library.readSection(projectID: projectID, documentID: hit.documentID,
                                                           chunkIndex: hit.chunkIndex, window: 1) {
                        passages.append("《\(hit.documentName)》· \(hit.pageLabel)\n\(String(text.prefix(2400)))")
                    }
                }
            }
            var note = "<project_material query=\"\(query)\">\n以下是在本项目资料里按需检索到的内容，回答涉及时据此作答，并注明出处；资料没写的不要编造。\n\(String(found.prefix(5000)))"
            if !passages.isEmpty { note += "\n\n【原文】\n" + passages.joined(separator: "\n\n") }
            return note + "\n</project_material>"
        }.value
    }
}

/// One quiet line above the composer, in the manner of Claude's 「记忆已更新。查看记忆 ×」.
struct ComposerNotice: Equatable, Identifiable {
    enum Kind: Equatable {
        /// The chat is long enough that compacting it would save money.
        case compactOffer
        /// A memory update did not go through; nothing was lost.
        case memoryIssue(String)
        /// 「记忆已更新。查看记忆 · 撤回」 — one update, undone as a whole.
        case memoryUpdated(projectID: UUID, batchID: UUID)
    }
    var id = UUID()
    /// The conversation it belongs to; nil shows it wherever you are.
    var threadID: UUID?
    /// Shown only in chats of this project, when set.
    var projectID: UUID? = nil
    var kind: Kind
}

extension AppStore {
    /// After an answer: offers to compact a chat that has grown long. Asks, never does it alone.
    func considerCompactionOffer(threadID: UUID) {
        guard settings.offersCompaction, activeThreadID == threadID, compactingThreadID == nil,
              let thread = threads.first(where: { $0.id == threadID }), thread.story == nil,
              thread.bookDiscussion == nil else { return }
        // A line already showing here stays; one meant for another project gives way.
        if let shown = composerNotice, shown.projectID == nil || shown.projectID == thread.projectID { return }
        let config = settings(for: thread)
        let estimate = ChatRequest.estimateContextUsage(settings: config, messages: thread.messages)
        guard estimate.canCompact,
              AuxiliaryRouting.isLongEnoughToCompact(estimatedTokens: estimate.estimatedTokens, messageCount: estimate.messageCount,
                                         messageLimit: config.validated().contextMessageLimit) else { return }
        if let declined = compactionOfferDeclined[threadID], estimate.messageCount < declined + 40 { return }
        composerNotice = ComposerNotice(threadID: threadID, kind: .compactOffer)
    }

    func dismissComposerNotice() {
        guard let notice = composerNotice else { return }
        if notice.kind == .compactOffer, let threadID = notice.threadID,
           let thread = threads.first(where: { $0.id == threadID }) {
            compactionOfferDeclined[threadID] = thread.messages.filter { !$0.content.isEmpty }.count
        }
        composerNotice = nil
    }

    func acceptCompactionOffer() {
        composerNotice = nil
        compactActiveThread()
    }
}

extension AppStore {
    /// Looks a question up in the project's other conversations. Returns the note for the answer
    /// and the titles it drew on, or nil when nothing relevant turns up.
    func pastChatsNote(_ query: String, projectID: UUID, excluding threadID: UUID) async -> (note: String, titles: [String])? {
        let pool = threads(in: projectID)
        return await Task.detached(priority: .userInitiated) { () -> (note: String, titles: [String])? in
            let hits = ProjectRecall.search(query, in: pool, excluding: threadID)
            guard let note = ProjectRecall.note(hits, query: query) else { return nil }
            return (note, hits.map { $0.title })
        }.value
    }
}

// MARK: Project memory entries (1.46)

extension AppStore {
    /// The memory a conversation carries: the fixed part for its system prompt (renewed after six
    /// hours or when you edit the memory) and a note for this question with the other entries
    /// that match it.
    func memoryParts(for thread: ChatThread, project: ChatProject, query: String,
                     now: Date = Date()) -> (block: String?, note: String?, renewed: Bool) {
        let pick = ProjectMemoryBook.select(project.currentMemoryItems, query: query, now: now)
        let edited = project.memoryUserEditedAt ?? .distantPast
        if let snapshot = thread.memorySnapshot, let at = thread.memorySnapshotAt,
           now.timeIntervalSince(at) < 6 * 3600, edited < at {
            let extra = pick.relevant.filter { !snapshot.contains($0.text) }
            return (snapshot.isEmpty ? nil : snapshot, ProjectMemoryBook.relevantNote(extra), false)
        }
        return (ProjectMemoryBook.alwaysBlock(pick.always), ProjectMemoryBook.relevantNote(pick.relevant), true)
    }

    /// Splits an older project's memory text into entries before it is shown or edited.
    func ensureMemoryEntries(_ projectID: UUID) {
        guard var project = project(projectID), project.migrateMemoryIfNeeded() else { return }
        _ = updateProject(project)
    }

    /// Adds, edits or deletes entries by hand; logged as one change you can undo.
    @discardableResult
    func changeMemory(_ ops: [ProjectMemoryOp], in projectID: UUID) -> Bool {
        guard var project = project(projectID) else { return false }
        _ = project.migrateMemoryIfNeeded()
        let result = ProjectMemoryBook.apply(ops, to: project.currentMemoryItems, threadID: nil, byUser: true)
        guard !result.changes.isEmpty else { return true }
        project.recordMemory(result.items, changes: result.changes)
        return updateProject(project)
    }

    func setMemoryPinned(_ pinned: Bool, itemID: UUID, in projectID: UUID) {
        guard var project = project(projectID) else { return }
        _ = project.migrateMemoryIfNeeded()
        guard var items = project.memoryItems, let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].pinned = pinned ? true : nil
        project.memoryItems = items
        project.memoryUserEditedAt = Date()
        _ = updateProject(project)
    }

    func setMemoryKeepsPrivate(_ value: Bool, in projectID: UUID) {
        guard var project = project(projectID) else { return }
        project.memoryKeepsPrivate = value ? nil : false
        _ = updateProject(project)
    }

    /// Puts back what one update changed.
    func undoMemoryChange(_ batchID: UUID, in projectID: UUID) {
        if case let .memoryUpdated(_, shown)? = composerNotice?.kind, shown == batchID { composerNotice = nil }
        guard var project = project(projectID),
              let result = ProjectMemoryBook.undo(batch: batchID, items: project.currentMemoryItems, log: project.memoryLog ?? []) else {
            errorMessage = "这次的改动已经撤不回了（相关条目后来又改过）。"
            return
        }
        project.recordMemory(result.items, changes: result.changes)
        _ = updateProject(project)
    }
}
