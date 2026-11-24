import Foundation
import SQLite3

struct ProjectLibraryDocument: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let fileExtension: String
    let characterCount: Int
    let chunkCount: Int
    let importedAt: Date
}

struct ProjectLibraryHit: Equatable, Identifiable, Sendable {
    let id: String
    let documentID: String
    let documentName: String
    let chunkIndex: Int
    let pageLabel: String
    let excerpt: String
    let exactMatch: Bool
    let score: Double
}

enum ProjectLibraryError: LocalizedError, Equatable {
    case unavailable(String)
    case emptyContent
    case documentNotFound

    var errorDescription: String? {
        switch self {
        case .unavailable(let msg): return "项目文献库暂不可用：\(msg)"
        case .emptyContent: return "导入的文献没有可检索的正文内容。"
        case .documentNotFound: return "未找到指定的项目文献或章节。"
        }
    }
}

/// CJK bigram + ASCII word tokenizer for SQLite FTS5 so Chinese legal/historical terms
/// (e.g. 红白契, 先尽亲邻, 名公书判清明集) and English/code identifiers both match precisely.
enum ProjectLibraryTokenizer {
    static func tokenizeForIndex(_ text: String) -> String {
        var tokens: [String] = []
        tokens.reserveCapacity(text.count)
        var asciiBuf = ""
        var cjkBuf: [Character] = []

        func flushASCII() {
            guard !asciiBuf.isEmpty else { return }
            tokens.append(asciiBuf.lowercased())
            asciiBuf.removeAll(keepingCapacity: true)
        }

        func flushCJK() {
            guard !cjkBuf.isEmpty else { return }
            for i in cjkBuf.indices {
                tokens.append(String(cjkBuf[i]))
                if i + 1 < cjkBuf.count {
                    tokens.append(String(cjkBuf[i]) + String(cjkBuf[i + 1]))
                }
            }
            cjkBuf.removeAll(keepingCapacity: true)
        }

        for ch in text {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_") {
                flushCJK()
                asciiBuf.append(ch)
            } else if isCJK(ch) {
                flushASCII()
                cjkBuf.append(ch)
            } else {
                flushASCII()
                flushCJK()
            }
        }
        flushASCII()
        flushCJK()
        return tokens.joined(separator: " ")
    }

    /// Produces selective FTS5 query terms (bigrams for multi-char CJK runs, unigrams for single CJK chars, whole ASCII words).
    static func queryTerms(for query: String) -> [String] {
        var terms: [String] = []
        var asciiBuf = ""
        var cjkBuf: [Character] = []

        func flushASCII() {
            guard !asciiBuf.isEmpty else { return }
            terms.append(asciiBuf.lowercased())
            asciiBuf.removeAll(keepingCapacity: true)
        }

        func flushCJK() {
            guard !cjkBuf.isEmpty else { return }
            if cjkBuf.count == 1 {
                terms.append(String(cjkBuf[0]))
            } else {
                for i in 0..<(cjkBuf.count - 1) {
                    terms.append(String(cjkBuf[i]) + String(cjkBuf[i + 1]))
                }
            }
            cjkBuf.removeAll(keepingCapacity: true)
        }

        for ch in query {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_") {
                flushCJK()
                asciiBuf.append(ch)
            } else if isCJK(ch) {
                flushASCII()
                cjkBuf.append(ch)
            } else {
                flushASCII()
                flushCJK()
            }
        }
        flushASCII()
        flushCJK()

        var seen = Set<String>()
        return terms.filter { seen.insert($0).inserted }.prefix(18).map { $0 }
    }

    static func ftsMatchExpression(terms: [String], requireAll: Bool) -> String {
        let escaped = terms.map { term in
            let safe = term.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(safe)\""
        }
        return escaped.joined(separator: requireAll ? " AND " : " OR ")
    }

    private static func isCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v)
            || (0x3400...0x4DBF).contains(v)
            || (0xF900...0xFAFF).contains(v)
            || (0x20000...0x2A6DF).contains(v)
    }
}

/// Splits multi-million-character books/PDFs/DOCX into page- and heading-anchored chunks.
enum ProjectLibraryChunker {
    struct Chunk: Equatable, Sendable {
        let index: Int
        let pageLabel: String
        let text: String
    }

    static let targetChunkChars = 900
    static let overlapChars = 110

    static func chunk(_ rawText: String) -> [Chunk] {
        let normalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var chunks: [Chunk] = []
        var currentLines: [String] = []
        var currentLen = 0
        var currentLabel = "第 1 节"
        var lastFootnoteSection = false

        func flush(withOverlap: Bool) {
            let body = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else {
                currentLines.removeAll(keepingCapacity: true)
                currentLen = 0
                return
            }
            let idx = chunks.count
            chunks.append(Chunk(index: idx, pageLabel: currentLabel, text: body))
            if withOverlap && body.count > overlapChars {
                let tail = String(body.suffix(overlapChars))
                currentLines = [tail]
                currentLen = tail.count
            } else {
                currentLines.removeAll(keepingCapacity: true)
                currentLen = 0
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let pageMarker = extractPDFPageLabel(trimmed) {
                if currentLen > 0 { flush(withOverlap: false) }
                currentLabel = pageMarker
                lastFootnoteSection = false
                currentLines.append(line)
                currentLen += line.count + 1
                continue
            }
            if trimmed == "## 脚注" || trimmed == "## 尾注" {
                if currentLen > 0 { flush(withOverlap: false) }
                currentLabel = trimmed == "## 脚注" ? "脚注区" : "尾注区"
                lastFootnoteSection = true
                currentLines.append(line)
                currentLen += line.count + 1
                continue
            }
            if !lastFootnoteSection, let heading = extractHeadingLabel(trimmed) {
                if currentLen >= 220 { flush(withOverlap: false) }
                currentLabel = heading
            }

            // Very long single lines (e.g. minified files or single-paragraph texts) get sub-sliced cleanly.
            if line.count > targetChunkChars * 2 {
                if currentLen > 0 { flush(withOverlap: false) }
                var start = line.startIndex
                while start < line.endIndex {
                    let end = line.index(start, offsetBy: targetChunkChars, limitedBy: line.endIndex) ?? line.endIndex
                    let slice = String(line[start..<end])
                    currentLines = [slice]
                    currentLen = slice.count
                    flush(withOverlap: false)
                    if end == line.endIndex { break }
                    start = line.index(end, offsetBy: -overlapChars, limitedBy: line.startIndex) ?? end
                }
                continue
            }

            currentLines.append(line)
            currentLen += line.count + 1
            if currentLen >= targetChunkChars {
                flush(withOverlap: true)
            }
        }
        flush(withOverlap: false)
        return chunks
    }

    private static func extractPDFPageLabel(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix("【PDF第"), let closeIdx = trimmed.firstIndex(of: "】") else { return nil }
        let inner = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeIdx])
        return inner.isEmpty ? nil : inner
    }

    private static func extractHeadingLabel(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix("#") else { return nil }
        let stripped = trimmed.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return nil }
        return String(stripped.prefix(28))
    }
}

/// Per-project local SQLite FTS5 literature warehouse supporting multi-million-character books
/// outside `conversations.json` with exact-phrase verification and page/section anchors.
final class ProjectLibraryStore: @unchecked Sendable {
    static let maxLibraryCharactersPerDocument = 5_000_000
    private let rootDirectory: URL
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(rootDirectory: URL = ProjectLibraryStore.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory
    }

    static func defaultRootDirectory() -> URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("QingJian/ProjectLibraries", isDirectory: true)
    }

    func databaseURL(for projectID: UUID) -> URL {
        rootDirectory.appendingPathComponent("\(projectID.uuidString).sqlite")
    }

    func hasDatabase(for projectID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: databaseURL(for: projectID).path)
    }

    func removeProjectDatabase(_ projectID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        let url = databaseURL(for: projectID)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
    }

    @discardableResult
    func ingestDocument(
        projectID: UUID,
        name: String,
        fileExtension: String,
        text: String,
        documentID: String = UUID().uuidString
    ) throws -> ProjectLibraryDocument {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectLibraryError.emptyContent }
        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        let safeName = cleanName.isEmpty ? "未命名文献" : cleanName
        let safeExt = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count <= Self.maxLibraryCharactersPerDocument else {
            throw ProjectLibraryError.unavailable("这份资料超过单份文献上限，请拆分后导入。原文没有截断保存。")
        }
        let bounded = trimmed
        let chunks = ProjectLibraryChunker.chunk(bounded)
        guard !chunks.isEmpty else { throw ProjectLibraryError.emptyContent }
        let now = Date()

        return try withDatabase(for: projectID) { db in
            try exec(db, "BEGIN IMMEDIATE")
            do {
                try runDelete(db, documentID: documentID)

                let insertDoc = try prepare(db, "INSERT INTO documents(id, name, file_ext, char_count, chunk_count, imported_at) VALUES (?,?,?,?,?,?)")
                defer { sqlite3_finalize(insertDoc) }
                bindText(insertDoc, 1, documentID)
                bindText(insertDoc, 2, safeName)
                bindText(insertDoc, 3, safeExt)
                sqlite3_bind_int64(insertDoc, 4, Int64(bounded.count))
                sqlite3_bind_int64(insertDoc, 5, Int64(chunks.count))
                sqlite3_bind_double(insertDoc, 6, now.timeIntervalSince1970)
                guard sqlite3_step(insertDoc) == SQLITE_DONE else {
                    throw ProjectLibraryError.unavailable("写入文献记录失败")
                }

                let insertChunk = try prepare(db, "INSERT INTO chunks(doc_id, chunk_index, page_label, text) VALUES (?,?,?,?)")
                defer { sqlite3_finalize(insertChunk) }
                let insertFTS = try prepare(db, "INSERT INTO chunks_fts(chunk_id, doc_id, tokenized_text) VALUES (?,?,?)")
                defer { sqlite3_finalize(insertFTS) }

                for chunk in chunks {
                    sqlite3_reset(insertChunk)
                    sqlite3_clear_bindings(insertChunk)
                    bindText(insertChunk, 1, documentID)
                    sqlite3_bind_int64(insertChunk, 2, Int64(chunk.index))
                    bindText(insertChunk, 3, chunk.pageLabel)
                    bindText(insertChunk, 4, chunk.text)
                    guard sqlite3_step(insertChunk) == SQLITE_DONE else {
                        throw ProjectLibraryError.unavailable("写入文献分块失败")
                    }
                    let rowID = sqlite3_last_insert_rowid(db)

                    let tokenized = ProjectLibraryTokenizer.tokenizeForIndex(chunk.text)
                    sqlite3_reset(insertFTS)
                    sqlite3_clear_bindings(insertFTS)
                    sqlite3_bind_int64(insertFTS, 1, rowID)
                    bindText(insertFTS, 2, documentID)
                    bindText(insertFTS, 3, tokenized)
                    guard sqlite3_step(insertFTS) == SQLITE_DONE else {
                        throw ProjectLibraryError.unavailable("写入全文检索索引失败")
                    }
                }

                try exec(db, "COMMIT")
                return ProjectLibraryDocument(
                    id: documentID,
                    name: safeName,
                    fileExtension: safeExt,
                    characterCount: bounded.count,
                    chunkCount: chunks.count,
                    importedAt: now
                )
            } catch {
                try? exec(db, "ROLLBACK")
                throw error
            }
        }
    }

    func listDocuments(projectID: UUID) throws -> [ProjectLibraryDocument] {
        guard hasDatabase(for: projectID) else { return [] }
        return try withDatabase(for: projectID) { db in
            let stmt = try prepare(db, "SELECT id, name, file_ext, char_count, chunk_count, imported_at FROM documents ORDER BY imported_at DESC")
            defer { sqlite3_finalize(stmt) }
            var result: [ProjectLibraryDocument] = []
            while try nextRow(stmt) {
                result.append(ProjectLibraryDocument(
                    id: columnText(stmt, 0),
                    name: columnText(stmt, 1),
                    fileExtension: columnText(stmt, 2),
                    characterCount: Int(sqlite3_column_int64(stmt, 3)),
                    chunkCount: Int(sqlite3_column_int64(stmt, 4)),
                    importedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                ))
            }
            return result
        }
    }

    func deleteDocument(projectID: UUID, documentID: String) throws {
        guard hasDatabase(for: projectID) else { return }
        try withDatabase(for: projectID) { db in
            try exec(db, "BEGIN IMMEDIATE")
            do {
                try runDelete(db, documentID: documentID)
                try exec(db, "COMMIT")
            } catch {
                try? exec(db, "ROLLBACK")
                throw error
            }
        }
    }

    func search(
        projectID: UUID,
        query: String,
        documentNameFilter: String? = nil,
        limit: Int = 8
    ) throws -> [ProjectLibraryHit] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty, hasDatabase(for: projectID) else { return [] }
        let safeLimit = max(1, min(20, limit))
        let terms = ProjectLibraryTokenizer.queryTerms(for: cleanQuery)
        let docFilter = documentNameFilter?.trimmingCharacters(in: .whitespacesAndNewlines)

        return try withDatabase(for: projectID) { db in
            // Select documents before limiting chunks, preserving Unicode filename matching.
            var filterIDs: String?
            if let docFilter, !docFilter.isEmpty {
                let names = try prepare(db, "SELECT id, name FROM documents")
                defer { sqlite3_finalize(names) }
                var ids: [String] = []
                while try nextRow(names) {
                    if columnText(names, 1).localizedCaseInsensitiveContains(docFilter) { ids.append(columnText(names, 0)) }
                }
                guard !ids.isEmpty else { return [] }
                filterIDs = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
            }
            let filterClause = filterIDs == nil ? "" : "AND c.doc_id IN (SELECT value FROM json_each(?3))"
            struct Candidate {
                let chunkRowID: Int64
                let docID: String
                let docName: String
                let chunkIndex: Int
                let pageLabel: String
                let text: String
                let bm25Rank: Double
            }

            func fetchFTS(requireAll: Bool) throws -> [Candidate] {
                guard !terms.isEmpty else { return [] }
                let expr = ProjectLibraryTokenizer.ftsMatchExpression(terms: terms, requireAll: requireAll)
                let sql = """
                SELECT c.id, c.doc_id, d.name, c.chunk_index, c.page_label, c.text, bm25(chunks_fts)
                FROM chunks_fts
                JOIN chunks c ON c.id = chunks_fts.chunk_id
                JOIN documents d ON d.id = c.doc_id
                WHERE chunks_fts MATCH ?1 \(filterClause)
                ORDER BY bm25(chunks_fts)
                LIMIT ?2
                """
                let stmt = try prepare(db, sql)
                defer { sqlite3_finalize(stmt) }
                bindText(stmt, 1, expr)
                sqlite3_bind_int64(stmt, 2, Int64(safeLimit * 8))
                if let filterIDs { bindText(stmt, 3, filterIDs) }
                var out: [Candidate] = []
                while try nextRow(stmt) {
                    let docName = columnText(stmt, 2)
                    out.append(Candidate(
                        chunkRowID: sqlite3_column_int64(stmt, 0),
                        docID: columnText(stmt, 1),
                        docName: docName,
                        chunkIndex: Int(sqlite3_column_int64(stmt, 3)),
                        pageLabel: columnText(stmt, 4),
                        text: columnText(stmt, 5),
                        bm25Rank: sqlite3_column_double(stmt, 6)
                    ))
                }
                return out
            }

            var candidates = try fetchFTS(requireAll: true)
            if candidates.count < safeLimit && terms.count > 1 {
                let broader = try fetchFTS(requireAll: false)
                var seen = Set(candidates.map(\.chunkRowID))
                for c in broader where seen.insert(c.chunkRowID).inserted {
                    candidates.append(c)
                }
            }

            // Exact substring fallback via LIKE in case punctuation/symbols bypassed FTS tokenization
            if candidates.isEmpty {
                let sql = """
                SELECT c.id, c.doc_id, d.name, c.chunk_index, c.page_label, c.text
                FROM chunks c
                JOIN documents d ON d.id = c.doc_id
                WHERE c.text LIKE ?1 ESCAPE '!' \(filterClause)
                LIMIT ?2
                """
                let stmt = try prepare(db, sql)
                defer { sqlite3_finalize(stmt) }
                let literal = cleanQuery.replacingOccurrences(of: "!", with: "!!").replacingOccurrences(of: "%", with: "!%").replacingOccurrences(of: "_", with: "!_")
                bindText(stmt, 1, "%\(literal)%")
                sqlite3_bind_int64(stmt, 2, Int64(safeLimit * 4))
                if let filterIDs { bindText(stmt, 3, filterIDs) }
                while try nextRow(stmt) {
                    let docName = columnText(stmt, 2)
                    candidates.append(Candidate(
                        chunkRowID: sqlite3_column_int64(stmt, 0),
                        docID: columnText(stmt, 1),
                        docName: docName,
                        chunkIndex: Int(sqlite3_column_int64(stmt, 3)),
                        pageLabel: columnText(stmt, 4),
                        text: columnText(stmt, 5),
                        bm25Rank: 0
                    ))
                }
            }

            let subKeywords = cleanQuery
                .components(separatedBy: CharacterSet.whitespacesAndNewlines)
                .filter { !$0.isEmpty }

            var scored: [ProjectLibraryHit] = candidates.map { c in
                let exact = c.text.localizedCaseInsensitiveContains(cleanQuery)
                var score = exact ? 100.0 : 0.0
                for kw in subKeywords where c.text.localizedCaseInsensitiveContains(kw) {
                    score += 18.0
                }
                // FTS5 bm25 is lower-is-better (often negative); invert gently into bonus
                score += max(-15.0, min(15.0, -c.bm25Rank))
                let excerpt = Self.makeExcerpt(from: c.text, query: cleanQuery, keywords: subKeywords)
                return ProjectLibraryHit(
                    id: "\(c.docID):\(c.chunkIndex)",
                    documentID: c.docID,
                    documentName: c.docName,
                    chunkIndex: c.chunkIndex,
                    pageLabel: c.pageLabel,
                    excerpt: excerpt,
                    exactMatch: exact,
                    score: score
                )
            }

            scored.sort {
                if $0.exactMatch != $1.exactMatch { return $0.exactMatch && !$1.exactMatch }
                if abs($0.score - $1.score) > 0.01 { return $0.score > $1.score }
                return $0.chunkIndex < $1.chunkIndex
            }
            return Array(scored.prefix(safeLimit))
        }
    }

    func readSection(projectID: UUID, documentID: String, chunkIndex: Int, window: Int = 1) throws -> String {
        guard hasDatabase(for: projectID) else { throw ProjectLibraryError.documentNotFound }
        let safeWindow = max(0, min(3, window))

        return try withDatabase(for: projectID) { db in
            let docStmt = try prepare(db, "SELECT name, chunk_count FROM documents WHERE id = ?")
            defer { sqlite3_finalize(docStmt) }
            bindText(docStmt, 1, documentID)
            guard sqlite3_step(docStmt) == SQLITE_ROW else {
                throw ProjectLibraryError.documentNotFound
            }
            let docName = columnText(docStmt, 0)
            let totalChunks = Int(sqlite3_column_int64(docStmt, 1))
            guard chunkIndex >= 0, chunkIndex < totalChunks else { throw ProjectLibraryError.documentNotFound }
            let lo = max(0, chunkIndex - safeWindow)
            let hi = chunkIndex + min(safeWindow, totalChunks - 1 - chunkIndex)

            let stmt = try prepare(db, "SELECT chunk_index, page_label, text FROM chunks WHERE doc_id = ? AND chunk_index BETWEEN ? AND ? ORDER BY chunk_index ASC")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, documentID)
            sqlite3_bind_int64(stmt, 2, Int64(lo))
            sqlite3_bind_int64(stmt, 3, Int64(hi))

            var sections: [String] = []
            while try nextRow(stmt) {
                let idx = Int(sqlite3_column_int64(stmt, 0))
                let label = columnText(stmt, 1)
                let body = columnText(stmt, 2)
                sections.append("【分块 \(idx + 1)/\(totalChunks) · \(label)】\n\(body)")
            }
            guard !sections.isEmpty else { throw ProjectLibraryError.documentNotFound }
            return "《\(docName)》（文献ID：\(documentID)）\n\n" + sections.joined(separator: "\n\n---\n\n")
        }
    }

    static func makeExcerpt(from text: String, query: String, keywords: [String]) -> String {
        let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
            ?? keywords.compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }.first
        guard let range else {
            return text.count <= 260 ? text : String(text.prefix(260)) + "…"
        }
        let start = text.index(range.lowerBound, offsetBy: -90, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 170, limitedBy: text.endIndex) ?? text.endIndex
        let prefix = start > text.startIndex ? "…" : ""
        let suffix = end < text.endIndex ? "…" : ""
        return prefix + String(text[start..<end]).replacingOccurrences(of: "\n\n", with: "\n") + suffix
    }

    // MARK: - SQLite Helpers

    private func withDatabase<T>(for projectID: UUID, _ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let url = databaseURL(for: projectID)
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let handle = db else {
            if let db { sqlite3_close(db) }
            throw ProjectLibraryError.unavailable("无法打开项目文献索引库")
        }
        defer { sqlite3_close(handle) }

        sqlite3_busy_timeout(handle, 3000)
        try exec(handle, "PRAGMA journal_mode=WAL")
        try exec(handle, "PRAGMA synchronous=NORMAL")
        try exec(handle, """
        CREATE TABLE IF NOT EXISTS documents (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            file_ext TEXT NOT NULL,
            char_count INTEGER NOT NULL,
            chunk_count INTEGER NOT NULL,
            imported_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS chunks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            doc_id TEXT NOT NULL,
            chunk_index INTEGER NOT NULL,
            page_label TEXT NOT NULL,
            text TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_chunks_doc ON chunks(doc_id, chunk_index);
        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
            chunk_id UNINDEXED,
            doc_id UNINDEXED,
            tokenized_text
        );
        """)
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
        return try body(handle)
    }

    private func runDelete(_ db: OpaquePointer, documentID: String) throws {
        let delFTS = try prepare(db, "DELETE FROM chunks_fts WHERE doc_id = ?")
        defer { sqlite3_finalize(delFTS) }
        bindText(delFTS, 1, documentID)
        _ = sqlite3_step(delFTS)

        let delChunks = try prepare(db, "DELETE FROM chunks WHERE doc_id = ?")
        defer { sqlite3_finalize(delChunks) }
        bindText(delChunks, 1, documentID)
        _ = sqlite3_step(delChunks)

        let delDoc = try prepare(db, "DELETE FROM documents WHERE id = ?")
        defer { sqlite3_finalize(delDoc) }
        bindText(delDoc, 1, documentID)
        _ = sqlite3_step(delDoc)
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "SQLite 错误"
            throw ProjectLibraryError.unavailable(msg)
        }
    }

    private func nextRow(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            throw ProjectLibraryError.unavailable(String(cString: sqlite3_errmsg(sqlite3_db_handle(statement))))
        }
    }

    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "SQLite prepare 失败"
            throw ProjectLibraryError.unavailable(msg)
        }
        return stmt
    }

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: ptr)
    }
}

/// Model-callable read-only tools for searching and reading the current project's
/// local SQLite literature library (and any inline project reference documents).
enum ProjectLibraryTools {
    static let names: Set<String> = [
        "project_list_docs",
        "project_search_docs",
        "project_read_doc_section"
    ]

    static let specs: [ToolSpec] = [
        ToolSpec(
            name: "project_list_docs",
            description: "列出当前项目文献库中的全部资料（含大体积本地检索文献与项目内附文档），返回文献 ID、名称、字数与分块数。",
            parameters: ToolSpec.object([], required: [])
        ),
        ToolSpec(
            name: "project_search_docs",
            description: "在当前项目文献库中按关键词或原句精准检索，返回命中位置（如 PDF 页码、章节或脚注区）与原句摘录。",
            parameters: ToolSpec.object([
                ("query", "string", "检索关键词、专有名词或原句片段（如 红白契、先尽亲邻）"),
                ("document_name", "string", "可选：按文献名称筛选"),
                ("limit", "integer", "可选：返回条数上限（默认 6，最多 15）")
            ], required: ["query"])
        ),
        ToolSpec(
            name: "project_read_doc_section",
            description: "按文献 ID 与分块编号精确读取原句段落及上下文，用于核对页码、引文与脚注细节。",
            parameters: ToolSpec.object([
                ("document_id", "string", "project_list_docs 或 project_search_docs 返回的文献 ID"),
                ("chunk_index", "integer", "从 0 开始的分块编号"),
                ("window", "integer", "可选：前后多读几个相邻分块（0～2，默认 1）")
            ], required: ["document_id", "chunk_index"])
        )
    ]

    static let systemNote = """
    当前项目配备了本地文献库工具（project_list_docs / project_search_docs / project_read_doc_section），支持按需精准检索百万字资料与页码出处。涉及项目内文献、专著、判词或代码引用时，请先搜索定位并读取原文片段核对后再下结论，切勿凭空编造页码或原句。
    """

    static func activityTitle(for call: ToolCall) -> String {
        let obj = (try? call.argumentObject()) ?? [:]
        switch call.name {
        case "project_list_docs":
            return "查看项目文献库目录"
        case "project_search_docs":
            let q = (obj["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return q.isEmpty ? "检索项目文献库" : "检索项目文献：\(String(q.prefix(24)))"
        case "project_read_doc_section":
            let idx = (obj["chunk_index"] as? Int) ?? 0
            return idx >= 0 && idx < Int.max ? "核对项目文献第 \(idx + 1) 节原文" : "核对项目文献原文"
        default:
            return "查阅项目文献"
        }
    }

    static func search(_ query: String, filter docFilter: String? = nil, limit: Int, projectID: UUID,
                       inlineDocuments: [ProjectDocument], store: ProjectLibraryStore) throws -> [ProjectLibraryHit] {
        var hits = try store.search(projectID: projectID, query: query, documentNameFilter: docFilter, limit: limit)
        // Also search inline project docs that may have isIncluded == false
        let subKeywords = query.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty }
        for doc in inlineDocuments {
            if let docFilter, !docFilter.isEmpty, !doc.name.localizedCaseInsensitiveContains(docFilter) { continue }
            let chunks = ProjectLibraryChunker.chunk(doc.text)
            for chunk in chunks {
                let exact = chunk.text.localizedCaseInsensitiveContains(query)
                let anyKw = !subKeywords.isEmpty && subKeywords.allSatisfy { chunk.text.localizedCaseInsensitiveContains($0) }
                guard exact || anyKw else { continue }
                hits.append(ProjectLibraryHit(
                    id: "inline:\(doc.id.uuidString):\(chunk.index)",
                    documentID: "inline:\(doc.id.uuidString)",
                    documentName: doc.name,
                    chunkIndex: chunk.index,
                    pageLabel: chunk.pageLabel,
                    excerpt: ProjectLibraryStore.makeExcerpt(from: chunk.text, query: query, keywords: subKeywords),
                    exactMatch: exact,
                    score: exact ? 98.0 : 40.0
                ))
            }
        }
        hits.sort {
            if $0.exactMatch != $1.exactMatch { return $0.exactMatch && !$1.exactMatch }
            return $0.score > $1.score
        }
        return Array(hits.prefix(limit))
    }

    static func execute(
        _ call: ToolCall,
        projectID: UUID,
        inlineDocuments: [ProjectDocument],
        store: ProjectLibraryStore
    ) throws -> String {
        let obj = try call.argumentObject()
        switch call.name {
        case "project_list_docs":
            let libraryDocs = try store.listDocuments(projectID: projectID)
            var lines: [String] = []
            if !libraryDocs.isEmpty {
                lines.append("【本地按需检索文献库（共 \(libraryDocs.count) 份）】")
                for doc in libraryDocs {
                    let ext = doc.fileExtension.isEmpty ? "" : ".\(doc.fileExtension)"
                    lines.append("- \(doc.name)\(ext) | ID: \(doc.id) | \(doc.characterCount.formatted()) 字 | \(doc.chunkCount) 个分块")
                }
            }
            if !inlineDocuments.isEmpty {
                lines.append("【项目随附参考资料（共 \(inlineDocuments.count) 份）】")
                for doc in inlineDocuments {
                    let tag = doc.isIncluded ? "已勾选随聊发送" : "仅按需查阅"
                    lines.append("- \(doc.name) | ID: inline:\(doc.id.uuidString) | \(doc.text.count.formatted()) 字 | \(tag)")
                }
            }
            if lines.isEmpty {
                return "当前项目文献库为空，尚未导入文献资料。"
            }
            return lines.joined(separator: "\n")

        case "project_search_docs":
            let query = (obj["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { throw ToolError.invalidArguments("请提供检索关键词 query。") }
            let docFilter = (obj["document_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let limit = max(1, min(15, (obj["limit"] as? Int) ?? 6))

            let top = try search(query, filter: docFilter, limit: limit, projectID: projectID,
                                 inlineDocuments: inlineDocuments, store: store)
            guard !top.isEmpty else {
                return "在当前项目文献库中没有找到与「\(query)」匹配的内容。可以尝试拆短关键词或调用 project_list_docs 查看全部文献。"
            }
            var out = ["在项目文献库中找到 \(top.count) 处匹配（关键词：\(query)）："]
            for (i, hit) in top.enumerated() {
                let exactTag = hit.exactMatch ? "精确命中" : "相关命中"
                out.append("""
                [\(i + 1)] 《\(hit.documentName)》· \(hit.pageLabel)（\(exactTag)）
                document_id: \(hit.documentID) | chunk_index: \(hit.chunkIndex)
                摘录：\(hit.excerpt)
                """)
            }
            return out.joined(separator: "\n\n")

        case "project_read_doc_section":
            let docID = (obj["document_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !docID.isEmpty else { throw ToolError.invalidArguments("缺少 document_id。") }
            let chunkIndex = (obj["chunk_index"] as? Int) ?? 0
            let window = max(0, min(2, (obj["window"] as? Int) ?? 1))
            if docID.hasPrefix("inline:") {
                let rawUUID = String(docID.dropFirst("inline:".count))
                guard let doc = inlineDocuments.first(where: { $0.id.uuidString.caseInsensitiveCompare(rawUUID) == .orderedSame }) else {
                    throw ProjectLibraryError.documentNotFound
                }
                let chunks = ProjectLibraryChunker.chunk(doc.text)
                guard chunks.indices.contains(chunkIndex) else { throw ProjectLibraryError.documentNotFound }
                let lo = max(0, chunkIndex - window)
                let hi = min(max(0, chunks.count - 1), chunkIndex + window)
                guard !chunks.isEmpty, lo <= hi else { throw ProjectLibraryError.documentNotFound }
                let body = (lo...hi).map { idx in
                    "【分块 \(idx + 1)/\(chunks.count) · \(chunks[idx].pageLabel)】\n\(chunks[idx].text)"
                }.joined(separator: "\n\n---\n\n")
                return "《\(doc.name)》（随附资料）\n\n\(body)"
            }
            return try store.readSection(projectID: projectID, documentID: docID, chunkIndex: chunkIndex, window: window)

        default:
            throw ToolError.unknownTool(call.name)
        }
    }
}
