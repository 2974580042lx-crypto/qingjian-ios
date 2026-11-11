import Foundation

// A novel on the bookshelf (1.8.0). The model never reads the whole book in one
// request: the book is split into chapters, read a few chapters at a time into
// notes, and the notes are folded into one profile. Play then carries only the
// profile, a briefing for the chosen point in the story, and a few original
// passages found by keyword. The book's text lives in its own folder, not in
// conversations.json, so chat saves and backups stay small.

struct BookChapter: Codable, Equatable, Sendable {
    var title: String
    var text: String
}

// A run of chapters read in one request. Both ends are chapter indexes, inclusive.
struct BookSegment: Codable, Equatable, Sendable {
    var first: Int
    var last: Int
}

enum BookStatus: String, Codable, Sendable {
    case imported   // not read yet, or paused partway (see Book.readCount)
    case reading
    case ready
    case failed
}

struct BookQuote: Codable, Equatable, Sendable {
    var text: String
    var chapter: Int
}

struct BookCharacter: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var aliases: [String] = []
    var identity = ""
    var personality = ""
    var speech = ""
    var relationships = ""
    // What happens to them over the whole book. Never sent during play (spoilers);
    // the briefing for the chosen chapter tells the model where they stand.
    var arc = ""
    var quotes: [BookQuote] = []
    var firstChapter: Int?
    // From a deep read of this one character (1.10.0). Optional: older profiles lack them.
    var behavior: String?      // how they act in different situations
    var attitudes: String?     // how they treat different people
    var taboos: String?        // what they would never say or do
    var deepReadAt: Date?
    // Your own corrections from「这里不像」, sent with every conversation from then on.
    var corrections: [String]?
    var id: String { name }
    var allNames: [String] { [name] + aliases }
}

struct BookScene: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var chapter: Int
    var summary: String
    var characters: [String] = []
    var before: String?
    var paragraph: Int?
    var anchor: String?
}

struct BookTerm: Codable, Equatable, Sendable {
    var term: String
    var note: String
    var chapter: Int
}

struct BookStyle: Codable, Equatable, Sendable {
    var description = ""
    // Original passages, copied from the text itself rather than from the model.
    var excerpts: [String] = []
    // From a deep read of the style (1.10.0): signature habits, and what the author never writes.
    var signatures: [String]?
    var avoid: [String]?
    var deepReadAt: Date?
}

// Where you stopped in the reader (1.10.0).
struct BookBookmark: Codable, Equatable, Sendable {
    var chapter: Int
    var paragraph: Int
    var characterOffset: Int?
}

struct ReaderSavedMark: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var chapter: Int
    var paragraph: Int
    var excerpt: String
    var createdAt = Date()
    var note: String? = nil
}

// What one segment's reading produced.
struct SegmentNote: Codable, Equatable, Sendable {
    struct CharacterNote: Codable, Equatable, Sendable {
        var name: String
        var aliases: [String] = []
        var notes: String
        var quotes: [String] = []
    }
    var segment: BookSegment
    var plot: String
    var characters: [CharacterNote] = []
    var scenes: [BookScene] = []
    var terms: [BookTerm] = []
    var excerpts: [String] = []
}

struct BookProfile: Codable, Equatable, Sendable {
    var summary = ""
    var style = BookStyle()
    var characters: [BookCharacter] = []
    var scenes: [BookScene] = []
    var terms: [BookTerm] = []
}

struct Book: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var importedAt = Date()
    var characterCount: Int
    var chapterTitles: [String]
    var segments: [BookSegment]
    // One slot per segment; nil until that segment has been read.
    var notes: [SegmentNote?]
    var status: BookStatus = .imported
    var profile: BookProfile?
    var issue: String?
    var usage: TokenUsage?
    // Estimated yuan spent reading, summed per request at the time it ran.
    var cost: Double?
    var bookmark: BookBookmark?
    var readerMarks: [ReaderSavedMark]?
    var lastReadAt: Date?
    // Optional for older libraries. Small JPEGs travel with the complete shelf backup.
    var coverDesign: BookCoverDesign?
    var coverJPEG: Data?
    var coverRevision: UUID?
    var coverNote: String?

    // The model that writes the notes; nil is Flash (1.10.0). The profile is always V4 Pro.
    var sceneScanCompleted: [String]?
    var readingModel: DeepSeekModel?
    var notesModel: DeepSeekModel { readingModel ?? BookReading.readingModel }
    var readCount: Int { notes.compactMap { $0 }.count }
    var isReady: Bool { status == .ready && profile != nil }

    func chapterLabel(_ index: Int) -> String {
        guard chapterTitles.indices.contains(index) else { return "第 \(index + 1) 章" }
        return chapterTitles[index]
    }
}

// MARK: Import

enum BookText {
    static let maximumBytes = 40 * 1024 * 1024

    /// UTF-8 first; most novels found online are GB18030 (GBK) instead, some Big5.
    static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        if let text = String(data: data, encoding: .utf8) { return text }
        // CoreFoundation codes: GB 18030, Big5-HKSCS, Big5.
        for raw: UInt32 in [0x0632, 0x0A06, 0x0A03] {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(raw)))
            if let text = String(data: data, encoding: encoding), looksLikeText(text) { return text }
        }
        return nil
    }

    // A wrong legacy guess still "decodes"; real Chinese prose is mostly common Han characters.
    private static func looksLikeText(_ text: String) -> Bool {
        let sample = text.unicodeScalars.prefix(4000)
        guard !sample.isEmpty else { return false }
        let readable = sample.filter { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3000...0x303F).contains(scalar.value) ||
                (0xFF00...0xFFEF).contains(scalar.value) || scalar.value < 0x80
        }.count
        return Double(readable) / Double(sample.count) > 0.85
    }

    /// Unix line ends, no full-width indent, at most one blank line in a row.
    static func normalized(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        var blank = 0
        for raw in unified.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{3000}\u{00A0}\u{FEFF}")))
            if line.isEmpty {
                blank += 1
                if blank == 1 && !lines.isEmpty { lines.append("") }
            } else {
                blank = 0
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The file name without extension, minus the 《》 and site tags many downloads carry.
    static func title(fromFileName name: String) -> String {
        var title = (name as NSString).deletingPathExtension
        for mark in ["《", "》"] { title = title.replacingOccurrences(of: mark, with: "") }
        if let range = title.range(of: #"[（(\[【].*?[）)\]】]"#, options: .regularExpression), range.lowerBound != title.startIndex {
            title.removeSubrange(range)
        }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "未命名的书" : String(clean.prefix(60))
    }
}

// Decoding, splitting and encoding a whole novel takes seconds; it runs off the
// main thread so the file picker can close and the screen keeps responding.
enum BookImport {
    struct Prepared: Sendable {
        let title: String
        let chapters: [BookChapter]
        let segments: [BookSegment]
        let chaptersJSON: Data
    }

    static func prepare(_ data: Data, fileName: String) throws -> Prepared {
        guard data.count <= BookText.maximumBytes else { throw ChatError.server("这个文件超过 40 MB，请换一个小一些的版本。") }
        // An EPUB is a ZIP: "PK\u{3}\u{4}" at the start.
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) || fileName.lowercased().hasSuffix(".epub") {
            let book = try EpubBook.pages(from: data)
            let chapters = EpubBook.chapters(from: book.pages)
            guard chapters.reduce(0, { $0 + $1.text.count }) >= 500 else { throw ChatError.server("这个 EPUB 里的文字太少，不像是一本小说。") }
            let title = book.title.flatMap { $0.isEmpty ? nil : String($0.prefix(60)) } ?? BookText.title(fromFileName: fileName)
            return Prepared(title: title, chapters: chapters, segments: ChapterSplitter.segments(for: chapters),
                            chaptersJSON: try JSONEncoder().encode(chapters))
        }
        guard let raw = BookText.decode(data) else {
            throw ChatError.server("没能识别这个文件的编码。请确认它是 TXT 文字文件（UTF-8、GBK 或 Big5）。")
        }
        let text = BookText.normalized(raw)
        guard text.count >= 500 else { throw ChatError.server("这个文件里的文字太少，不像是一本小说。") }
        let chapters = ChapterSplitter.split(text)
        guard !chapters.isEmpty else { throw ChatError.server("没能从文件里分出章节。") }
        return Prepared(title: BookText.title(fromFileName: fileName), chapters: chapters,
                        segments: ChapterSplitter.segments(for: chapters), chaptersJSON: try JSONEncoder().encode(chapters))
    }
}

enum ChapterSplitter {
    // A heading is a short line of its own: 第十二章 …, 第3回, 楔子, Chapter 7 …
    static let headingPattern = #"^(第[0-9０-９零〇一二三四五六七八九十百千万两]+[章回节卷集部篇幕](?:[ 　:：·.、\-—].{0,30})?|(?:序章|序言|序|楔子|引子|尾声|后记|番外)(?:[ 　:：·.、\-—].{0,30})?|(?:Chapter|CHAPTER)\s*\d+.{0,30})$"#
    // Books without headings, and very long chapters, are cut into parts this size.
    static let fallbackLength = 8000
    static let longestChapter = 50000

    static func split(_ text: String) -> [BookChapter] {
        let lines = text.components(separatedBy: "\n")
        let regex = try? NSRegularExpression(pattern: headingPattern)
        func isHeading(_ line: String) -> Bool {
            guard line.count <= 40, let regex else { return false }
            return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        var chapters: [BookChapter] = []
        var title = "开篇"
        var body: [String] = []
        func close() {
            let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append(BookChapter(title: title, text: text))
            body = []
        }
        var headings = 0
        for line in lines {
            if isHeading(line) {
                close()
                title = line
                headings += 1
            } else {
                body.append(line)
            }
        }
        close()
        guard headings >= 2 else { return parts(of: text, titled: { "第 \($0) 段" }) }
        // A volume line ("第一卷 …") followed straight by a chapter heading has no text
        // of its own: its title joins the next chapter's.
        var merged: [BookChapter] = []
        var carried: String?
        for chapter in chapters {
            if chapter.text.count < 50 && chapter.title != "开篇" {
                carried = carried.map { $0 + " · " + chapter.title } ?? chapter.title
                continue
            }
            if chapter.title == "开篇" && chapter.text.count < 200 { continue }
            var next = chapter
            if let prefix = carried { next.title = prefix + " · " + chapter.title; carried = nil }
            merged.append(next)
        }
        var result: [BookChapter] = []
        for chapter in merged {
            if chapter.text.count > longestChapter {
                let title = chapter.title
                result.append(contentsOf: parts(of: chapter.text, titled: { "\(title)（\($0)）" }))
            } else {
                result.append(chapter)
            }
        }
        return result.isEmpty ? parts(of: text, titled: { "第 \($0) 段" }) : result
    }

    /// Cuts at paragraph ends near every `fallbackLength` characters.
    static func parts(of text: String, titled title: @escaping (Int) -> String) -> [BookChapter] {
        var result: [BookChapter] = []
        var current: [String] = []
        var length = 0
        func close() {
            guard !current.isEmpty else { return }
            result.append(BookChapter(title: title(result.count + 1), text: current.joined(separator: "\n")))
            current = []
            length = 0
        }
        for paragraph in text.components(separatedBy: "\n") {
            current.append(paragraph)
            length += paragraph.count + 1
            if length >= fallbackLength { close() }
        }
        close()
        return result.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Consecutive chapters grouped into reading requests of about `target` characters.
    // 25,000 characters a request since 1.11.0 (was 40,000): finer notes, and a time point
    // that lands closer to the chapter picked.
    static func segments(for chapters: [BookChapter], target: Int = 25000) -> [BookSegment] {
        var result: [BookSegment] = []
        var start = 0
        var length = 0
        for (index, chapter) in chapters.enumerated() {
            length += chapter.text.count
            if length >= target {
                result.append(BookSegment(first: start, last: index))
                start = index + 1
                length = 0
            }
        }
        if start < chapters.count {
            // A short tail joins the previous segment instead of costing a request of its own.
            if let previous = result.last, length < target / 4 {
                result[result.count - 1] = BookSegment(first: previous.first, last: chapters.count - 1)
            } else {
                result.append(BookSegment(first: start, last: chapters.count - 1))
            }
        }
        return result
    }
}

// MARK: Finding original passages

enum BookPassages {
    struct Paragraph: Sendable {
        let chapter: Int
        let text: String
    }

    static func paragraphs(of chapters: [BookChapter]) -> [Paragraph] {
        var result: [Paragraph] = []
        for (index, chapter) in chapters.enumerated() {
            for line in chapter.text.components(separatedBy: "\n") where line.count >= 8 {
                result.append(Paragraph(chapter: index, text: line))
            }
        }
        return result
    }

    /// The paragraph a model-quoted opening points at, grown to a readable length.
    /// Nil when the opening is not in the text, so nothing invented gets kept.
    static func locate(_ opening: String, in chapters: ArraySlice<BookChapter>) -> String? {
        let anchor = String(opening.trimmingCharacters(in: CharacterSet(charactersIn: " \n\"“”「」『』'‘’…")).prefix(12))
        guard anchor.count >= 6 else { return nil }
        for chapter in chapters {
            let lines = chapter.text.components(separatedBy: "\n")
            guard let start = lines.firstIndex(where: { $0.contains(anchor) }) else { continue }
            var text = lines[start]
            var next = start + 1
            while text.count < 150, next < lines.count {
                if !lines[next].isEmpty { text += "\n" + lines[next] }
                next += 1
            }
            return text.count > 420 ? String(text.prefix(420)) + "…" : text
        }
        return nil
    }

    /// Paragraphs where a character speaks (a name and a quotation mark), spread over
    /// the book up to `chapter`, longer ones and ones holding a known line first.
    static func characterPassages(names: [String], quotes: [String] = [], paragraphs: [Paragraph], upTo chapter: Int,
                                  limit: Int = 6) -> [String] {
        let marks = ["“", "「", "：\"", "\""]
        let keys = names.filter { $0.count >= 2 || names.count == 1 }
        let probes = quotes.map { String($0.prefix(8)) }.filter { $0.count >= 4 }
        let candidates = paragraphs.filter { paragraph in
            paragraph.chapter <= chapter && paragraph.text.count >= 30
                && keys.contains(where: { paragraph.text.contains($0) })
                && marks.contains(where: { paragraph.text.contains($0) })
        }
        guard !candidates.isEmpty else { return [] }
        // A few with known lines, then the rest evenly across the book.
        var picked = candidates.filter { paragraph in probes.contains(where: { paragraph.text.contains($0) }) }.prefix(limit / 2).map(\.text)
        let step = Double(candidates.count) / Double(limit)
        var index = 0.0
        while picked.count < limit && Int(index) < candidates.count {
            let text = candidates[Int(index)].text
            if !picked.contains(text) { picked.append(text) }
            index += max(1, step)
        }
        return picked.prefix(limit).map { $0.count > 360 ? String($0.prefix(360)) + "…" : $0 }
    }

    /// Narrative paragraphs spread over the whole book, for a deep read of the style.
    static func styleSamples(_ paragraphs: [Paragraph], count: Int = 30) -> [String] {
        let narrative = paragraphs.filter { (80...500).contains($0.text.count) }
        guard !narrative.isEmpty else { return [] }
        let step = max(1, narrative.count / count)
        return stride(from: step / 2, to: narrative.count, by: step).prefix(count).map { narrative[$0].text }
    }

    /// Whether a quoted line really occurs in the text (quotation marks aside).
    static func occurs(_ quote: String, in chapters: ArraySlice<BookChapter>) -> Bool {
        let core = quote.trimmingCharacters(in: CharacterSet(charactersIn: " \n\"“”「」『』'‘’"))
        let probe = String(core.prefix(10))
        guard probe.count >= 4 else { return false }
        return chapters.contains { $0.text.contains(probe) }
    }

    /// Terms from the book's vocabulary that the recent text mentions, and the
    /// paragraphs (up to `chapter`, so nothing later leaks in) that mention most of them.
    static func find(in text: String, vocabulary: [String], paragraphs: [Paragraph], upTo chapter: Int,
                     excluding exclude: Set<String>, limit: Int = 3) -> (terms: [String], passages: [String]) {
        var seen = Set<String>()
        let matched = vocabulary
            .filter { $0.count >= 2 && !exclude.contains($0) && text.contains($0) }
            .sorted { $0.count > $1.count }
            .filter { term in
                // "林黛玉" already covers "黛玉".
                guard !seen.contains(where: { $0.contains(term) }) else { return false }
                seen.insert(term)
                return true
            }
            .prefix(6)
        guard !matched.isEmpty else { return ([], []) }
        var scored: [(score: Int, chapter: Int, text: String)] = []
        for paragraph in paragraphs where paragraph.chapter <= chapter {
            let score = matched.reduce(0) { $0 + (paragraph.text.contains($1) ? 1 : 0) }
            guard score > 0 else { continue }
            scored.append((score * 10 + (paragraph.text.count >= 40 ? 1 : 0), paragraph.chapter, paragraph.text))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.chapter > $1.chapter }
        var passages: [String] = []
        for item in scored where passages.count < limit {
            let clipped = clip(item.text, around: matched.first(where: { item.text.contains($0) }) ?? "")
            if !passages.contains(clipped) { passages.append(clipped) }
        }
        return (Array(matched), passages)
    }

    private static func clip(_ text: String, around term: String, length: Int = 300) -> String {
        guard text.count > length else { return text }
        guard let range = text.range(of: term) else { return String(text.prefix(length)) + "…" }
        let offset = text.distance(from: text.startIndex, to: range.lowerBound)
        let start = max(0, min(offset - length / 3, text.count - length))
        let from = text.index(text.startIndex, offsetBy: start)
        let to = text.index(from, offsetBy: length)
        return (start > 0 ? "…" : "") + String(text[from..<to]) + (start + length < text.count ? "…" : "")
    }
}


// A bounded drawing recipe, never executable SVG, HTML, or model-supplied code.
struct BookCoverDesign: Codable, Equatable, Sendable {
    enum Motif: String, Codable, CaseIterable, Sendable { case waves, vines, diamonds, stars, orbits }
    var background: String
    var accent: String
    var motif: Motif
    var density: Int
    var seed: Int

    static func local(title: String, seed: Int? = nil) -> Self {
        let n = seed ?? title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let palettes = [("193B43", "D6BE85"), ("283951", "C6D7DF"), ("41303B", "D6AD91"),
                        ("24433B", "CCCF9E"), ("4A322B", "DCC293"), ("36304A", "C7BDDA")]
        let pair = palettes[abs(n % palettes.count)]
        return Self(background: pair.0, accent: pair.1, motif: Motif.allCases[abs(n % Motif.allCases.count)], density: 5, seed: n)
    }
    func validated() -> Self {
        func hex(_ text: String, fallback: String) -> String {
            let value = text.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
            return value.count == 6 && value.allSatisfy({ "0123456789ABCDEF".contains($0) }) ? value : fallback
        }
        var copy = self
        copy.background = hex(background, fallback: "193B43")
        copy.accent = hex(accent, fallback: "D6BE85")
        copy.density = min(7, max(4, density))
        copy.seed = min(65535, max(0, seed))
        return copy
    }
}
