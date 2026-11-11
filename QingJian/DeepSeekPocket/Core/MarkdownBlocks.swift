import Foundation

// Splits an answer into the blocks it is drawn with: paragraphs, headings,
// bulleted and numbered lists, quotes, dividers and code. Inline styling inside
// each block (bold, italic, links) is still parsed by AttributedString later.
// Every text-bearing block is told how many highlighter marks it may draw, so
// the per-answer limit holds across lists and quotes too.
enum TableAlignment: String, Equatable, Sendable { case leading, center, trailing }

enum MarkdownBlock: Equatable, Sendable {
    struct ListItem: Equatable, Sendable {
        var marker: String
        var text: String
        var level: Int
        var marks: Int
    }
    case paragraph(String, marks: Int)
    case heading(String, level: Int)
    case list([ListItem])
    case quote(String, marks: Int)
    // A pipe table: header cells, body rows (padded to the header's width) and
    // each column's alignment. Cells keep inline Markdown but draw no highlights.
    case table(header: [String], rows: [[String]], alignments: [TableAlignment])
    case divider
    case code(String)

    // While an answer streams, every new token used to re-read the whole answer line by
    // line. Finished paragraphs are now remembered, so only the one being written is
    // parsed again; a long answer no longer gets slower as it grows.
    nonisolated(unsafe) private static var chunkCache: [String: [MarkdownBlock]] = [:]
    private static let chunkLock = NSLock()
    private static func cachedChunk(_ chunk: String) -> [MarkdownBlock] {
        chunkLock.lock()
        if let hit = chunkCache[chunk] { chunkLock.unlock(); return hit }
        chunkLock.unlock()
        let parsed = parseChunk(chunk)
        chunkLock.lock()
        if chunkCache.count > 600 { chunkCache.removeAll(keepingCapacity: true) }
        chunkCache[chunk] = parsed
        chunkLock.unlock()
        return parsed
    }

    static func parse(_ content: String, markLimit: Int = HighlightMarks.perAnswer) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        for (index, segment) in content.components(separatedBy: "```").enumerated() {
            if !index.isMultiple(of: 2) { blocks.append(.code(segment)); continue }
            for chunk in segment.components(separatedBy: "\n\n") where !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(contentsOf: cachedChunk(chunk))
            }
        }
        return assignMarks(blocks, limit: markLimit)
    }

    private static func parseChunk(_ chunk: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var items: [ListItem] = []
        var quote: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"), marks: 0)); paragraph = [] }
            if !items.isEmpty { blocks.append(.list(items)); items = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"), marks: 0)); quote = [] }
        }
        let lines = chunk.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // A table: a row with pipes followed by a |---|---| line.
            if trimmed.contains("|"), index < lines.count, let alignments = separator(lines[index]) {
                let header = cells(trimmed)
                if header.count == alignments.count {
                    flush()
                    index += 1
                    var rows: [[String]] = []
                    while index < lines.count, lines[index].contains("|") {
                        var row = cells(lines[index].trimmingCharacters(in: .whitespaces))
                        row = Array(row.prefix(header.count)) + Array(repeating: "", count: max(0, header.count - row.count))
                        rows.append(row)
                        index += 1
                    }
                    blocks.append(.table(header: header, rows: rows, alignments: alignments))
                    continue
                }
            }
            if isDivider(trimmed) { flush(); blocks.append(.divider); continue }
            if let heading = heading(trimmed) { flush(); blocks.append(heading); continue }
            if trimmed.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let item = listItem(line) {
                if items.isEmpty { flush() }
                items.append(item)
                continue
            }
            // An indented line right after a list item continues that item.
            if !items.isEmpty, line.first == " " || line.first == "\t" {
                items[items.count - 1].text += "\n" + trimmed
                continue
            }
            if !items.isEmpty || !quote.isEmpty { flush() }
            paragraph.append(line)
        }
        flush()
        return blocks
    }

    /// The cells of one table row, without the outer pipes; "\\|" stays a literal pipe.
    static func cells(_ row: String) -> [String] {
        var text = row
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text.removeLast() }
        var result: [String] = [], current = "", escaped = false
        for character in text {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "|" { result.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(character)
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    /// The |:---|:---:|---:| line under a table header, as column alignments; nil if it is not one.
    static func separator(_ line: String) -> [TableAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return nil }
        let parts = cells(trimmed)
        var alignments: [TableAlignment] = []
        for part in parts {
            let clean = part.replacingOccurrences(of: " ", with: "")
            guard clean.count >= 2, clean.allSatisfy({ $0 == "-" || $0 == ":" }),
                  clean.dropFirst().dropLast().allSatisfy({ $0 == "-" }) else { return nil }
            let left = clean.hasPrefix(":"), right = clean.hasSuffix(":")
            alignments.append(left && right ? .center : right ? .trailing : .leading)
        }
        return alignments.isEmpty ? nil : alignments
    }

    static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(line.dropFirst(hashes).trimmingCharacters(in: .whitespaces), level: hashes)
    }

    static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop(while: { $0 == " " || $0 == "\t" })
        let level = min(indent / 2, 3)
        if let first = body.first, "-*+•".contains(first), body.dropFirst().first == " " {
            let text = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return ListItem(marker: level == 0 ? "•" : "◦", text: text, level: level, marks: 0)
        }
        let digits = body.prefix(while: \.isNumber)
        guard (1...3).contains(digits.count) else { return nil }
        let rest = body.dropFirst(digits.count)
        guard let dot = rest.first, dot == "." || dot == ")" || dot == "、", rest.dropFirst().first == " " || dot == "、" else { return nil }
        let text = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return ListItem(marker: "\(digits).", text: text, level: level, marks: 0)
    }

    /// Shares the answer's highlighter budget in reading order.
    private static func assignMarks(_ blocks: [MarkdownBlock], limit: Int) -> [MarkdownBlock] {
        var left = max(0, limit)
        func take(_ text: String) -> Int {
            let used = min(HighlightMarks.estimatedBoldCount(text), left)
            left -= used
            return used
        }
        return blocks.map { block in
            switch block {
            case .paragraph(let text, _): return .paragraph(text, marks: take(text))
            case .quote(let text, _): return .quote(text, marks: take(text))
            case .list(let items):
                return .list(items.map { item in var copy = item; copy.marks = take(item.text); return copy })
            default: return block
            }
        }
    }
}
