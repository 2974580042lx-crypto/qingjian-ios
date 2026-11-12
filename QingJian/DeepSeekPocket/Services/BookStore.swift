import Foundation
import UIKit

// The bookshelf. Each book has its own folder beside conversations.json:
//   books/<id>/book.json      what was read so far and the finished profile
//   books/<id>/chapters.json  the text, split into chapters
// Books are not part of the chat backup; they can be imported again from the file.
@MainActor
final class BookStore: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published private(set) var readingBookID: UUID?
    @Published private(set) var isImporting = false
    // Your own characters, to play in any book (1.9.0). Kept in books/personas.json.
    @Published private(set) var personas: [PersonaCard] = []
    // What a deep read is working on: a character's name, or "文风" for the style.
    @Published private(set) var deepReading: (bookID: UUID, target: String)?
    @Published var errorMessage: String?
    // Set by AppStore: the API key, and where usage is counted.
    var key: () -> String = { "" }
    var onUsage: (TokenUsage, DeepSeekModel) -> Void = { _, _ in }
    @Published private(set) var sceneScanBookID: UUID?
    @Published private(set) var sceneScanProgress = ""
    private var sceneTask: Task<Void, Never>?
    private var readingTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var cachedChapters: (id: UUID, chapters: [BookChapter])?
    private var cachedDiscussion: (id: UUID, index: BookDiscussionIndex)?
    private var cachedParagraphs: (id: UUID, paragraphs: [BookPassages.Paragraph])?
    // Dialogue indexes, built on demand off the main thread, keyed by book and the
    // names they were built with (a renamed character means a new index).
    private var cachedDialogue: [UUID: (names: [String: String], lines: [DialogueLine])] = [:]
    @Published private(set) var designingCovers: Set<UUID> = []
    var canDesignCover: () -> Bool = { false }
    var designCover: (Book) async throws -> BookCoverDesign = { _ in throw SubscriptionError.notConnected }
    private var coverQueue: [UUID] = []
    private var coverTask: Task<Void, Never>?
    private let isPreview: Bool
    @Published private(set) var canPersist = true

    init(preview: Bool = false) {
        isPreview = preview
        guard !preview else { return }
        load()
    }

    func reloadIfNeeded() {
        guard !isPreview, !canPersist || books.isEmpty else { return }
        load()
    }

    func book(_ id: UUID?) -> Book? { id.flatMap { id in books.first { $0.id == id } } }
    var isReading: Bool { readingBookID != nil }

    // MARK: Files

    private static func root() throws -> URL {
        let url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("QingJian", isDirectory: true)
            .appendingPathComponent("books", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static func folder(_ id: UUID) throws -> URL {
        let url = try root().appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func load() {
        guard let root = try? Self.root(),
              let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        var loaded: [Book] = []
        var permissionDenied = false
        for folder in folders {
            let bookURL = folder.appendingPathComponent("book.json")
            guard FileManager.default.fileExists(atPath: bookURL.path) else { continue }
            do {
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: bookURL.path)
                let data = try Data(contentsOf: bookURL)
                if var book = try? Self.decoder.decode(Book.self, from: data) {
                    if book.status == .reading { book.status = .imported }
                    loaded.append(book)
                }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
                permissionDenied = true
            } catch {
                continue
            }
        }
        let personasURL = root.appendingPathComponent("personas.json")
        if FileManager.default.fileExists(atPath: personasURL.path) {
            do {
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: personasURL.path)
                let data = try Data(contentsOf: personasURL)
                if let saved = try? Self.decoder.decode([PersonaCard].self, from: data) {
                    personas = saved
                }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
                permissionDenied = true
            } catch {}
        }
        if permissionDenied {
            canPersist = false
            if !loaded.isEmpty { books = loaded.sorted { $0.importedAt > $1.importedAt } }
        } else {
            canPersist = true
            books = loaded.sorted { $0.importedAt > $1.importedAt }
        }
    }

    func storageStats() -> (bookCount: Int, personaCount: Int, bytes: Int64) {
        guard let root = try? Self.root(),
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return (books.count, personas.count, 0)
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (books.count, personas.count, total)
    }


    // MARK: Complete bookshelf archives
    struct ImportReceipt {
        var ids: [UUID]
        var oldPersonas: [PersonaCard]
    }

    func archiveBooks() throws -> [ShelfBookArchive] {
        try books.map { book in
            let data = try Data(contentsOf: Self.folder(book.id).appendingPathComponent("chapters.json"))
            return ShelfBookArchive(book: book, chapters: try Self.decoder.decode([BookChapter].self, from: data))
        }
    }

    func installArchive(_ entries: [ShelfBookArchive], people: [PersonaCard]) throws -> ImportReceipt {
        guard !isReading, !isImporting, deepReading == nil, sceneScanBookID == nil else { throw ChatError.invalidBackup("请等待读书或精读结束再恢复书架。") }
        let root = try Self.root()
        let stage = root.appendingPathComponent(".restore-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        var installed: [UUID] = []
        let prior = personas
        do {
            for entry in entries {
                let target = root.appendingPathComponent(entry.book.id.uuidString, isDirectory: true)
                guard !fm.fileExists(atPath: target.path) else { throw ChatError.invalidBackup("恢复位置已存在，请重新导入。") }
                let folder = stage.appendingPathComponent(entry.book.id.uuidString, isDirectory: true)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                var book = entry.book
                if book.status == .reading { book.status = .imported }
                try Self.encoder.encode(book).write(to: folder.appendingPathComponent("book.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try Self.encoder.encode(entry.chapters).write(to: folder.appendingPathComponent("chapters.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            for entry in entries {
                try fm.moveItem(at: stage.appendingPathComponent(entry.book.id.uuidString), to: root.appendingPathComponent(entry.book.id.uuidString))
                installed.append(entry.book.id)
            }
            var merged = personas
            for var person in people {
                if merged.contains(where: { $0 == person }) { continue }
                if merged.contains(where: { $0.id == person.id }) { person.id = UUID() }
                merged.append(person)
            }
            try Self.encoder.encode(merged).write(to: root.appendingPathComponent("personas.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            load()
            return ImportReceipt(ids: installed, oldPersonas: prior)
        } catch {
            for id in installed { try? fm.removeItem(at: root.appendingPathComponent(id.uuidString)) }
            throw error
        }
    }

    func rollBackArchive(_ receipt: ImportReceipt) {
        guard let root = try? Self.root() else { return }
        for id in receipt.ids { try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString)) }
        try? Self.encoder.encode(receipt.oldPersonas).write(to: root.appendingPathComponent("personas.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        cachedChapters = nil
        cachedParagraphs = nil
        cachedDialogue = [:]
        load()
    }

    func restoreMetadata(_ incomingBooks: [Book], personas incomingPersonas: [PersonaCard], overwriteExisting: Bool) throws {
        guard !isReading, !isImporting, deepReading == nil, sceneScanBookID == nil else {
            throw ChatError.invalidBackup("请先等待当前读书或精读任务结束再恢复书架档案。")
        }
        let root = try Self.root()
        for var incoming in incomingBooks {
            if incoming.status == .reading { incoming.status = .imported }
            let folder = try Self.folder(incoming.id)
            let bookURL = folder.appendingPathComponent("book.json")
            if let existing = book(incoming.id) {
                if overwriteExisting || (existing.profile == nil && incoming.profile != nil) {
                    try Self.encoder.encode(incoming).write(to: bookURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
            } else {
                try Self.encoder.encode(incoming).write(to: bookURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
        var mergedPersonas = overwriteExisting ? [] : personas
        for var person in incomingPersonas {
            if mergedPersonas.contains(where: { $0 == person }) { continue }
            if let idx = mergedPersonas.firstIndex(where: { $0.id == person.id }) {
                if overwriteExisting { mergedPersonas[idx] = person }
                else { person.id = UUID(); mergedPersonas.append(person) }
            } else {
                mergedPersonas.append(person)
            }
        }
        try Self.encoder.encode(mergedPersonas).write(
            to: root.appendingPathComponent("personas.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        load()
    }

    // MARK: Your own characters

    func savePersona(_ card: PersonaCard) {
        var next = card
        next.name = String(card.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        next.detail = String(card.detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(3000))
        guard !next.name.isEmpty else { return }
        let old = personas
        if let index = personas.firstIndex(where: { $0.id == next.id }) { personas[index] = next } else { personas.append(next) }
        if !writePersonas() { personas = old }
    }

    func deletePersonas(at offsets: IndexSet) {
        let old = personas
        for index in offsets.sorted(by: >) where personas.indices.contains(index) { personas.remove(at: index) }
        if !writePersonas() { personas = old }
    }

    private func writePersonas() -> Bool {
        guard !isPreview else { return true }
        guard canPersist else { errorMessage = "请先解锁手机后再保存人物卡。"; return false }
        do {
            try Self.encoder.encode(personas).write(to: Self.root().appendingPathComponent("personas.json"),
                                                   options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            errorMessage = "人物卡没能保存：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult private func save(_ book: Book) -> Bool {
        guard isPreview || canPersist else { errorMessage = "请先解锁手机后再保存书架。"; return false }
        if let index = books.firstIndex(where: { $0.id == book.id }) { books[index] = book } else { books.insert(book, at: 0) }
        guard !isPreview else { return true }
        do {
            try Self.encoder.encode(book).write(to: Self.folder(book.id).appendingPathComponent("book.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            errorMessage = "书架没能保存：\(error.localizedDescription)"
            return false
        }
    }

    func chapters(of id: UUID) -> [BookChapter] {
        if let cached = cachedChapters, cached.id == id { return cached.chapters }
        guard let url = try? Self.folder(id).appendingPathComponent("chapters.json"),
              let data = try? Data(contentsOf: url),
              let chapters = try? Self.decoder.decode([BookChapter].self, from: data) else { return [] }
        cachedChapters = (id, chapters)
        return chapters
    }

    func discussionIndex(_ id: UUID) async -> BookDiscussionIndex {
        if let cache = cachedDiscussion, cache.id == id { return cache.index }
        let chapters = chapters(of: id)
        let index = await Task.detached(priority: .userInitiated) { BookDiscussionIndex(bookID: id, chapters: chapters) }.value
        cachedDiscussion = (id, index)
        return index
    }

    func paragraphs(of id: UUID) -> [BookPassages.Paragraph] {
        if let cached = cachedParagraphs, cached.id == id { return cached.paragraphs }
        let paragraphs = BookPassages.paragraphs(of: chapters(of: id))
        cachedParagraphs = (id, paragraphs)
        return paragraphs
    }

    /// Every quoted line of the book with its speaker, for picking examples before an answer.
    func dialogue(of id: UUID) async -> [DialogueLine] {
        guard let profile = book(id)?.profile else { return [] }
        var names: [String: String] = [:]
        for character in profile.characters {
            for name in character.allNames where name.count >= 2 { names[name] = character.name }
        }
        if let cached = cachedDialogue[id], cached.names == names { return cached.lines }
        let paragraphs = self.paragraphs(of: id)
        let map = names
        let lines = await Task.detached(priority: .userInitiated) {
            DialogueIndex.build(paragraphs: paragraphs, names: map)
        }.value
        // Keep only the current book's index; they can be large.
        cachedDialogue = [id: (names, lines)]
        return lines
    }


    // Each completed chunk is persisted. Refining scenes never rereads character/style profiles.
    func refineScenes(_ id: UUID) {
        guard sceneScanBookID == nil, !isReading, deepReading == nil,
              let book = book(id), book.isReady else { return }
        guard !key().isEmpty else { errorMessage = "请先填写 DeepSeek API Key。"; return }
        let chunks = BookScenes.chunks(chapters(of: id)), apiKey = key()
        sceneScanBookID = id
        sceneTask = Task { [weak self] in
            guard let self else { return }
            defer { self.sceneScanBookID = nil; self.sceneTask = nil }
            do {
                for (index, chunk) in chunks.enumerated() {
                    try Task.checkCancellation()
                    guard let current = self.book(id) else { return }
                    if (current.sceneScanCompleted ?? []).contains(chunk.key) { continue }
                    self.sceneScanProgress = "\(index + 1)/\(chunks.count)"
                    let request = BookScenes.request(book: current, chunk: chunk)
                    let buffer = BookTextBuffer()
                    try await DeepSeekClient(requestTimeout: 180, resourceTimeout: 300).stream(request: request, key: apiKey) { buffer.value.consume($0) }
                    self.onUsage(buffer.value.usage ?? TokenUsage(promptTokens: 0, completionTokens: 0), .flash)
                    let scenes = try BookScenes.parse(buffer.value.result(), chunk: chunk)
                    guard var latest = self.book(id), var profile = latest.profile else { return }
                    profile.scenes = BookScenes.merged(profile.scenes, scenes)
                    latest.profile = profile
                    latest.sceneScanCompleted = (latest.sceneScanCompleted ?? []) + [chunk.key]
                    guard self.save(latest) else { return }
                }
            } catch {
                if !Task.isCancelled { self.errorMessage = "名场面补全暂停：\(error.localizedDescription)。已完成的段落保留，再点一次继续。" }
            }
        }
    }

    func locateSceneStart(_ start: StorySceneStart, in id: UUID) async -> StorySceneStart? {
        guard let book = book(id) else { return nil }
        let chapters = chapters(of: id)
        guard chapters.indices.contains(start.chapter), !key().isEmpty else { errorMessage = "无法定位这场戏，请检查原文和 API Key。"; return nil }
        let chunk = BookScenes.Chunk(chapter: start.chapter, first: 0, lines: BookScenes.paragraphs(chapters[start.chapter].text))
        let request = BookScenes.request(book: book, chunk: chunk, target: start.title)
        let buffer = BookTextBuffer()
        do {
            try await DeepSeekClient(requestTimeout: 180, resourceTimeout: 300).stream(request: request, key: key()) { buffer.value.consume($0) }
            onUsage(buffer.value.usage ?? TokenUsage(promptTokens: 0, completionTokens: 0), .flash)
            guard var scene = try BookScenes.parse(buffer.value.result(), chunk: chunk).first else {
                errorMessage = "没有在这一章里定位到「\(start.title)」的触发段落。请先补全名场面，或从原文选择起点。"
                return nil
            }
            scene.title = start.title
            guard var latest = self.book(id), var profile = latest.profile else { return nil }
            profile.scenes = BookScenes.merged(profile.scenes, [scene])
            latest.profile = profile
            guard save(latest) else { return nil }
            return BookScenes.start(scene, chapters: chapters)
        } catch { errorMessage = "名场面起点没有定位成功：\(error.localizedDescription)"; return nil }
    }


    func pauseSceneRefinement() { sceneTask?.cancel() }


    // MARK: Shelf

    /// Reads a TXT file the picker handed over (a private copy). Returns the new book's id.
    func importBook(from url: URL) async -> UUID? {
        guard !isImporting else { return nil }
        isImporting = true
        defer { isImporting = false }
        let preview = isPreview
        do {
            let fileName = url.lastPathComponent
            let prepared = try await Task.detached(priority: .userInitiated) { () throws -> BookImport.Prepared in
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    // The picker's copy is ours to remove once it has been read.
                    try? FileManager.default.removeItem(at: url)
                }
                return try BookImport.prepare(Data(contentsOf: url), fileName: fileName)
            }.value
            let charCount = prepared.chapters.reduce(0) { $0 + $1.text.count }
            if let existing = books.first(where: { $0.title == prepared.title && chapters(of: $0.id).isEmpty }) {
                var reconnected = existing
                reconnected.characterCount = charCount
                if reconnected.chapterTitles.isEmpty { reconnected.chapterTitles = prepared.chapters.map(\.title) }
                if reconnected.segments.isEmpty {
                    reconnected.segments = prepared.segments
                    reconnected.notes = Array(repeating: nil, count: prepared.segments.count)
                }
                if !preview {
                    let target = try Self.folder(reconnected.id).appendingPathComponent("chapters.json")
                    let json = prepared.chaptersJSON
                    try await Task.detached(priority: .userInitiated) {
                        try json.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    }.value
                }
                cachedChapters = (reconnected.id, prepared.chapters)
                guard save(reconnected) else { return nil }
                return reconnected.id
            }
            var book = Book(title: prepared.title,
                            characterCount: charCount,
                            chapterTitles: prepared.chapters.map(\.title), segments: prepared.segments,
                            notes: Array(repeating: nil, count: prepared.segments.count))
            if !preview {
                let target = try Self.folder(book.id).appendingPathComponent("chapters.json")
                let json = prepared.chaptersJSON
                try await Task.detached(priority: .userInitiated) {
                    try json.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }.value
            }
            cachedChapters = (book.id, prepared.chapters)
            book.coverDesign = .local(title: book.title)
            book.coverRevision = UUID()
            guard save(book) else { return nil }
            requestCover(book.id, automatic: true)
            return book.id
        } catch {
            errorMessage = "没能导入：\(error.localizedDescription)"
            return nil
        }
    }

    func rename(_ id: UUID, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var book = self.book(id), !clean.isEmpty else { return }
        book.title = String(clean.prefix(60))
        save(book)
    }

    func delete(_ id: UUID) {
        if readingBookID == id { pause() }
        if sceneScanBookID == id { pauseSceneRefinement() }
        coverQueue.removeAll { $0 == id }
        designingCovers.remove(id)
        books.removeAll { $0.id == id }
        if cachedChapters?.id == id { cachedChapters = nil }
        if cachedDiscussion?.id == id { cachedDiscussion = nil }
        if cachedParagraphs?.id == id { cachedParagraphs = nil }
        guard !isPreview, let folder = try? Self.root().appendingPathComponent(id.uuidString, isDirectory: true) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Edits one character's card by hand; the next conversation uses the new text.
    func updateCharacter(_ character: BookCharacter, originalName: String, in id: UUID) {
        guard var book = self.book(id), var profile = book.profile,
              let index = profile.characters.firstIndex(where: { $0.name == originalName }) else { return }
        var next = character
        next.name = next.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.name.isEmpty else { return }
        profile.characters[index] = next
        book.profile = profile
        save(book)
    }

    func updateStyle(_ description: String, in id: UUID) {
        guard var book = self.book(id), var profile = book.profile else { return }
        profile.style.description = String(description.prefix(2000))
        book.profile = profile
        save(book)
    }

    // MARK: Deep reads, corrections, bookmark (1.10.0)

    func isDeepReading(_ target: String, in id: UUID) -> Bool { deepReading?.bookID == id && deepReading?.target == target }

    /// Reads one character again from every note, line and passage, and rewrites the card.
    /// Your corrections and the verified lines are kept.
    func deepReadCharacter(_ name: String, in id: UUID) async -> Bool {
        guard deepReading == nil, sceneScanBookID == nil, let book = self.book(id), let character = book.profile?.characters.first(where: { $0.name == name }) else { return false }
        let apiKey = key()
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorMessage = ChatError.missingKey.localizedDescription; return false }
        deepReading = (id, name)
        defer { deepReading = nil }
        let passages = BookPassages.characterPassages(names: character.allNames, quotes: character.quotes.map(\.text),
                                                       paragraphs: paragraphs(of: id), upTo: book.chapterTitles.count, limit: 24)
        let request = BookReading.characterDeepReadRequest(book: book, character: character, passages: passages)
        do {
            let answer = try await collect(request, key: apiKey, model: BookReading.profileModel, for: id)
            let next = try BookReading.parseCharacterDeepRead(answer, into: character)
            guard var latest = self.book(id), var profile = latest.profile,
                  let index = profile.characters.firstIndex(where: { $0.name == name }) else { return false }
            // Keep anything you changed by hand meanwhile that the read does not cover.
            var merged = next
            merged.corrections = profile.characters[index].corrections
            merged.quotes = profile.characters[index].quotes
            profile.characters[index] = merged
            latest.profile = profile
            return save(latest)
        } catch {
            if !(error is CancellationError) { errorMessage = "精读没有完成：\(error.localizedDescription)" }
            return false
        }
    }

    func deepReadStyle(in id: UUID) async -> Bool {
        guard deepReading == nil, sceneScanBookID == nil, let book = self.book(id), let style = book.profile?.style else { return false }
        let apiKey = key()
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorMessage = ChatError.missingKey.localizedDescription; return false }
        deepReading = (id, "文风")
        defer { deepReading = nil }
        let samples = BookPassages.styleSamples(paragraphs(of: id))
        guard samples.count >= 5 else { errorMessage = "这本书里适合研究文笔的段落太少。"; return false }
        do {
            let answer = try await collect(BookReading.styleDeepReadRequest(book: book, style: style, samples: samples),
                                           key: apiKey, model: BookReading.profileModel, for: id)
            let next = try BookReading.parseStyleDeepRead(answer, into: style, samples: samples)
            guard var latest = self.book(id), var profile = latest.profile else { return false }
            profile.style = next
            latest.profile = profile
            return save(latest)
        } catch {
            if !(error is CancellationError) { errorMessage = "精读没有完成：\(error.localizedDescription)" }
            return false
        }
    }

    /// 「这里不像」: one line of what the character would really say or do, kept on their card.
    func addCorrection(_ text: String, character name: String, in id: UUID) -> Bool {
        let clean = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        guard !clean.isEmpty, var book = self.book(id), var profile = book.profile,
              let index = profile.characters.firstIndex(where: { $0.name == name }) else { return false }
        var list = profile.characters[index].corrections ?? []
        list.append(clean)
        profile.characters[index].corrections = Array(list.suffix(20))
        book.profile = profile
        return save(book)
    }

    func setReadingModel(_ model: DeepSeekModel, in id: UUID) {
        guard !isReading || readingBookID != id, var book = self.book(id) else { return }
        book.readingModel = model == BookReading.readingModel ? nil : model
        save(book)
    }

    func addReaderMark(chapter: Int, paragraph: Int, excerpt: String, in id: UUID) {
        guard var book = self.book(id), book.chapterTitles.indices.contains(chapter) else { return }
        var marks = book.readerMarks ?? []
        if let existing = marks.firstIndex(where: { $0.chapter == chapter && $0.paragraph == paragraph }) {
            marks[existing].createdAt = Date()
        } else {
            marks.append(ReaderSavedMark(chapter: chapter, paragraph: paragraph, excerpt: String(excerpt.prefix(150))))
        }
        book.readerMarks = marks
        _ = save(book)
    }

    func deleteReaderMark(_ markID: UUID, in id: UUID) {
        guard var book = self.book(id) else { return }
        book.readerMarks?.removeAll { $0.id == markID }
        _ = save(book)
    }

    @discardableResult
    func updateReaderMarkNote(_ note: String, markID: UUID, in id: UUID) -> Bool {
        guard let original = self.book(id), var marks = original.readerMarks,
              let markIndex = marks.firstIndex(where: { $0.id == markID }) else {
            errorMessage = "这条书签已不存在，请重新打开书签列表。"
            return false
        }
        let clean = note.trimmingCharacters(in: .whitespacesAndNewlines)
        marks[markIndex].note = clean.isEmpty ? nil : clean
        var updated = original
        updated.readerMarks = marks
        guard save(updated) else {
            if let bookIndex = books.firstIndex(where: { $0.id == id }) { books[bookIndex] = original }
            return false
        }
        return true
    }

    func setBookmark(_ bookmark: BookBookmark, in id: UUID) {
        guard var book = self.book(id) else { return }
        if book.bookmark == bookmark, let read = book.lastReadAt, Date().timeIntervalSince(read) < 30 { return }
        book.bookmark = bookmark
        book.lastReadAt = Date()
        save(book)
    }

    // MARK: Reading

    /// A rough figure for the confirmation: about 0.65 tokens per Chinese character in,
    /// some 1,500 tokens of notes out per segment, and one profile request.
    func estimatedCost(of book: Book, at date: Date = Date()) -> Double {
        let remaining = book.segments.indices.filter { book.notes[$0] == nil }
        let share = Double(remaining.count) / Double(max(1, book.segments.count))
        let input = Int(Double(book.characterCount) * 0.65 * share) + remaining.count * 700
        let reading = TokenUsage(promptTokens: input, completionTokens: remaining.count * 1500)
        let profile = TokenUsage(promptTokens: book.segments.count * 2500 + 3000, completionTokens: 5000)
        return Pricing.cost(model: book.notesModel, usage: reading, at: date)
            + Pricing.cost(model: BookReading.profileModel, usage: profile, at: date)
    }

    /// Reads the segments not read yet, a few at a time, then writes the profile.
    /// Every finished segment is saved, so pausing or a failure loses nothing.
    func startReading(_ id: UUID) {
        guard !isReading, sceneScanBookID == nil, var book = self.book(id), book.status != .ready else { return }
        let apiKey = key()
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = ChatError.missingKey.localizedDescription
            return
        }
        let text = self.chapters(of: id)
        guard !text.isEmpty else { errorMessage = "这本书的正文找不到了，请删除后重新导入。"; return }
        book.status = .reading
        book.issue = nil
        save(book)
        readingBookID = id
        beginBackgroundTime()
        readingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.readingBookID = nil
                self.readingTask = nil
                self.endBackgroundTime()
            }
            do {
                try await self.readSegments(of: id, chapters: text, key: apiKey)
                try Task.checkCancellation()
                try await self.writeProfile(of: id, key: apiKey)
            } catch {
                guard var latest = self.book(id) else { return }
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    latest.status = .imported
                } else {
                    latest.status = .failed
                    latest.issue = (error as? URLError).map { _ in "网络中断了，已读的部分都保留着，可以继续。" } ?? error.localizedDescription
                }
                self.save(latest)
            }
        }
    }

    func pause() { readingTask?.cancel() }

    /// Throws away the profile and every note, to read the book from the start again.
    func resetReading(_ id: UUID) {
        guard !isReading, sceneScanBookID == nil, var book = self.book(id) else { return }
        book.notes = Array(repeating: nil, count: book.segments.count)
        book.sceneScanCompleted = nil
        book.profile = nil
        book.status = .imported
        book.issue = nil
        save(book)
    }

    /// Writes only the profile again from the saved notes.
    func rebuildProfile(_ id: UUID) {
        guard !isReading, sceneScanBookID == nil, var book = self.book(id), book.readCount == book.segments.count else { return }
        book.sceneScanCompleted = nil
        book.profile = nil
        book.status = .imported
        save(book)
        startReading(id)
    }

    private func readSegments(of id: UUID, chapters: [BookChapter], key: String) async throws {
        guard let book = self.book(id) else { return }
        var queue = book.segments.indices.filter { book.notes[$0] == nil }[...]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<BookReading.parallelReads {
                guard let index = queue.popFirst() else { break }
                group.addTask { try await self.readSegment(index, of: id, chapters: chapters, key: key) }
            }
            while try await group.next() != nil {
                guard let index = queue.popFirst() else { continue }
                group.addTask { try await self.readSegment(index, of: id, chapters: chapters, key: key) }
            }
        }
    }

    private func readSegment(_ index: Int, of id: UUID, chapters: [BookChapter], key: String) async throws {
        guard let book = self.book(id), book.segments.indices.contains(index) else { return }
        let segment = book.segments[index]
        let request = BookReading.segmentRequest(book: book, segment: segment, chapters: chapters)
        var lastError: Error = ChatError.invalidResponse
        // One retry: a note that did not parse usually comes back fine the second time.
        for _ in 0..<2 {
            try Task.checkCancellation()
            let answer = try await collect(request, key: key, model: book.notesModel, for: id)
            do {
                let note = try BookReading.parseSegment(answer, segment: segment, chapters: chapters)
                guard var latest = self.book(id) else { return }
                latest.notes[index] = note
                save(latest)
                return
            } catch { lastError = error }
        }
        throw ChatError.server("第 \(segment.first + 1)–\(segment.last + 1) 章没能整理出笔记：\(lastError.localizedDescription)")
    }

    private func writeProfile(of id: UUID, key: String) async throws {
        guard let book = self.book(id) else { return }
        let notes = book.notes.compactMap { $0 }
        guard notes.count == book.segments.count else { throw ChatError.server("还有没读完的部分。") }
        let request = BookReading.profileRequest(book: book, notes: notes)
        var lastError: Error = ChatError.invalidResponse
        for _ in 0..<2 {
            try Task.checkCancellation()
            let answer = try await collect(request, key: key, model: BookReading.profileModel, for: id)
            do {
                let profile = try BookReading.parseProfile(answer, notes: notes)
                guard var latest = self.book(id) else { return }
                latest.profile = profile
                latest.status = .ready
                latest.issue = nil
                save(latest)
                return
            } catch { lastError = error }
        }
        throw lastError
    }

    /// One request, collected whole. Its usage counts toward the book and the usage calendar.
    private func collect(_ request: ChatRequest, key: String, model: DeepSeekModel, for id: UUID) async throws -> String {
        let buffer = BookTextBuffer()
        try await DeepSeekClient().stream(request: request, key: key) { event in buffer.value.consume(event) }
        if let usage = buffer.value.usage {
            onUsage(usage, model)
            if var latest = self.book(id) {
                latest.usage = TokenUsage.combined(latest.usage, usage)
                latest.cost = (latest.cost ?? 0) + Pricing.cost(model: model, usage: usage, at: Date())
                save(latest)
            }
        }
        return try buffer.value.result()
    }

    // iOS gives an app that leaves the screen a little time to finish; the rest
    // continues the next time the bookshelf is opened.
    private func beginBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Sermo 读书") { [weak self] in
            Task { @MainActor in
                self?.pause()
                self?.endBackgroundTime()
            }
        }
    }
    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

@MainActor
private final class BookTextBuffer {
    var value = BookTextAccumulator()
}


extension BookStore {
    func requestCover(_ id: UUID, automatic: Bool = false) {
        guard var book = book(id), !designingCovers.contains(id) else { return }
        guard canDesignCover() else {
            book.coverNote = "当前使用本地花纹。连接 ChatGPT 订阅后，可在封面菜单里重新设计。"
            save(book)
            return
        }
        book.coverNote = nil
        guard save(book) else { return }
        coverQueue.append(id)
        designingCovers.insert(id)
        guard coverTask == nil else { return }
        coverTask = Task { [weak self] in
            guard let self else { return }
            defer { self.coverTask = nil }
            while !self.coverQueue.isEmpty {
                let id = self.coverQueue.removeFirst()
                defer { self.designingCovers.remove(id) }
                guard let original = self.book(id) else { continue }
                do {
                    let design = try await self.designCover(original).validated()
                    guard var latest = self.book(id), latest.coverRevision == original.coverRevision else { continue }
                    latest.coverDesign = design
                    latest.coverJPEG = nil
                    latest.coverRevision = UUID()
                    latest.coverNote = "GPT 配色与花纹 · 本地绘制"
                    self.saveCover(latest)
                } catch {
                    guard var latest = self.book(id), latest.coverRevision == original.coverRevision else { continue }
                    latest.coverNote = "本次设计未完成，原封面已保留。" + String(error.localizedDescription.prefix(160))
                    self.saveCover(latest)
                }
            }
        }
    }

    func localCover(_ id: UUID) {
        guard var latest = book(id) else { return }
        cancelQueuedCover(id)
        latest.coverDesign = .local(title: latest.title, seed: Int.random(in: 0...65535))
        latest.coverJPEG = nil
        latest.coverRevision = UUID()
        latest.coverNote = "本地花纹"
        saveCover(latest)
    }

    func setCoverJPEG(_ data: Data, for id: UUID) {
        guard var latest = book(id), data.count <= 500_000, UIImage(data: data) != nil else { return }
        cancelQueuedCover(id)
        latest.coverJPEG = data
        latest.coverRevision = UUID()
        latest.coverNote = "自选封面"
        saveCover(latest)
    }

    private func saveCover(_ next: Book) {
        let before = book(next.id)
        if !save(next), let before, let index = books.firstIndex(where: { $0.id == before.id }) { books[index] = before }
    }

    private func cancelQueuedCover(_ id: UUID) {
        // A queued job has not captured a revision yet, so remove it explicitly.
        // An active job is superseded by the new revision when it completes.
        if coverQueue.contains(id) {
            coverQueue.removeAll { $0 == id }
            designingCovers.remove(id)
        }
    }
}
