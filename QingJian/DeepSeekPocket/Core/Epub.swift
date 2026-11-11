import Foundation
import Compression

// EPUB import (1.12.0). An EPUB is a ZIP of XHTML pages; the reading order is the
// spine of the package file named in META-INF/container.xml. Each page becomes text
// (headings and paragraphs on their own lines), and the pages become chapters.

enum ZipArchive {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localOffset: Int
    }

    /// The files of a ZIP, from its central directory. ZIP64 and encryption are not supported.
    static func entries(_ data: Data) throws -> [String: Entry] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw ChatError.server("这个文件不是有效的 EPUB。") }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        // The end record sits in the last 64 KB (it may carry a comment).
        var end = -1
        var at = bytes.count - 22
        while at >= max(0, bytes.count - 65_557) {
            if bytes[at] == 0x50, bytes[at + 1] == 0x4B, bytes[at + 2] == 0x05, bytes[at + 3] == 0x06 { end = at; break }
            at -= 1
        }
        guard end >= 0 else { throw ChatError.server("这个文件不是有效的 EPUB。") }
        let count = u16(end + 10)
        var offset = u32(end + 16)
        var result: [String: Entry] = [:]
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, u32(offset) == 0x02014B50 else { break }
            let flags = u16(offset + 8)
            let method = UInt16(u16(offset + 10))
            let compressed = u32(offset + 20)
            let size = u32(offset + 24)
            let nameLength = u16(offset + 28), extraLength = u16(offset + 30), commentLength = u16(offset + 32)
            let local = u32(offset + 42)
            guard offset + 46 + nameLength <= bytes.count else { break }
            let nameBytes = bytes[(offset + 46)..<(offset + 46 + nameLength)]
            let name = String(bytes: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self)
            if flags & 0x1 == 0 {
                result[name] = Entry(name: name, method: method, compressedSize: compressed, size: size, localOffset: local)
            }
            offset += 46 + nameLength + extraLength + commentLength
        }
        guard !result.isEmpty else { throw ChatError.server("这个 EPUB 里没有能读的内容。") }
        return result
    }

    static func read(_ entry: Entry, from data: Data) throws -> Data {
        let bytes = [UInt8](data[data.startIndex.advanced(by: entry.localOffset)...].prefix(30))
        guard bytes.count == 30, bytes[0] == 0x50, bytes[1] == 0x4B, bytes[2] == 0x03, bytes[3] == 0x04 else {
            throw ChatError.server("EPUB 里的 \(entry.name) 读不出来。")
        }
        let nameLength = Int(bytes[26]) | Int(bytes[27]) << 8
        let extraLength = Int(bytes[28]) | Int(bytes[29]) << 8
        let start = entry.localOffset + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.count else { throw ChatError.server("EPUB 文件不完整。") }
        let body = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))
        switch entry.method {
        case 0: return body
        case 8: return try inflate(body, size: entry.size)
        default: throw ChatError.server("EPUB 用了不支持的压缩方式。")
        }
    }

    // Raw DEFLATE, which is what Apple's COMPRESSION_ZLIB reads.
    private static func inflate(_ data: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        guard size <= 64 * 1024 * 1024 else { throw ChatError.server("EPUB 里有一个文件太大。") }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let to = target.bindMemory(to: UInt8.self).baseAddress,
                      let from = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(to, size, from, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw ChatError.server("EPUB 里有内容解压失败。") }
        return output.prefix(written)
    }
}

enum EpubBook {
    struct Page { let title: String?; let text: String }

    /// The book's title (if it has one) and its pages in reading order, as text.
    static func pages(from data: Data) throws -> (title: String?, pages: [Page]) {
        let entries = try ZipArchive.entries(data)
        func file(_ path: String) -> Data? {
            let clean = normalize(path)
            guard let entry = entries[clean] ?? entries.first(where: { $0.key.lowercased() == clean.lowercased() })?.value else { return nil }
            return try? ZipArchive.read(entry, from: data)
        }
        guard let container = file("META-INF/container.xml"), let opfPath = firstMatch(#"full-path\s*=\s*"([^"]+)""#, in: text(container)),
              let opfData = file(opfPath) else { throw ChatError.server("没找到这个 EPUB 的目录文件。") }
        let opf = text(opfData)
        let base = (opfPath as NSString).deletingLastPathComponent
        var manifest: [String: String] = [:]
        for item in matches(#"<(?:\w+:)?item\b[^>]*>"#, in: opf) {
            guard let id = attribute("id", in: item), let href = attribute("href", in: item) else { continue }
            let type = attribute("media-type", in: item) ?? ""
            if type.contains("html") || href.lowercased().hasSuffix("html") || href.lowercased().hasSuffix("htm") {
                manifest[id] = href
            }
        }
        var order = matches(#"<(?:\w+:)?itemref\b[^>]*>"#, in: opf).compactMap { attribute("idref", in: $0) }.compactMap { manifest[$0] }
        if order.isEmpty { order = manifest.values.sorted() }
        var pages: [Page] = []
        for href in order {
            let path = base.isEmpty ? href : base + "/" + href
            guard let page = file((path.removingPercentEncoding ?? path).components(separatedBy: "#")[0]) else { continue }
            let html = text(page)
            let body = plainText(fromHTML: html)
            guard !body.isEmpty else { continue }
            pages.append(Page(title: heading(in: html), text: body))
        }
        guard !pages.isEmpty else { throw ChatError.server("这个 EPUB 里没有读出文字，可能是图片版或加了版权保护。") }
        let title = firstMatch(#"<dc:title[^>]*>([^<]+)</dc:title>"#, in: opf).map(decodeEntities)
        return (title?.trimmingCharacters(in: .whitespacesAndNewlines), pages)
    }

    /// Chapters for the bookshelf. Pages whose text already has 第X章 headings are
    /// split by those; otherwise each page is a chapter, tiny pages (cover,
    /// copyright) folded into the next.
    static func chapters(from pages: [Page]) -> [BookChapter] {
        let joined = pages.map { page in
            if let title = page.title, !page.text.hasPrefix(title) { return title + "\n" + page.text }
            return page.text
        }.joined(separator: "\n")
        let byHeadings = ChapterSplitter.split(joined)
        if byHeadings.count >= max(2, pages.count / 2), byHeadings.first?.title.hasPrefix("第 ") != true { return byHeadings }
        var result: [BookChapter] = []
        var carry = ""
        for (index, page) in pages.enumerated() {
            let text = (carry.isEmpty ? "" : carry + "\n") + page.text
            if text.count < 200 && index < pages.count - 1 { carry = text; continue }
            carry = ""
            let title = page.title ?? "第 \(result.count + 1) 节"
            if text.count > ChapterSplitter.longestChapter {
                result.append(contentsOf: ChapterSplitter.parts(of: text, titled: { "\(title)（\($0)）" }))
            } else {
                result.append(BookChapter(title: String(title.prefix(40)), text: text))
            }
        }
        return result
    }

    // MARK: Text

    static func plainText(fromHTML html: String) -> String {
        var text = html
        for pattern in [#"(?is)<head\b.*?</head>"#, #"(?is)<script\b.*?</script>"#, #"(?is)<style\b.*?</style>"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)</?(p|div|h[1-6]|li|tr|blockquote|section|article)\b[^>]*>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return BookText.normalized(decodeEntities(text))
    }

    private static func heading(in html: String) -> String? {
        for pattern in [#"(?is)<h[1-3]\b[^>]*>(.*?)</h[1-3]>"#, #"(?is)<title\b[^>]*>(.*?)</title>"#] {
            if let raw = firstMatch(pattern, in: html) {
                let clean = decodeEntities(raw.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty && clean.count <= 40 { return clean }
            }
        }
        return nil
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
                                ("&ldquo;", "“"), ("&rdquo;", "”"), ("&lsquo;", "‘"), ("&rsquo;", "’"),
                                ("&hellip;", "…"), ("&mdash;", "—"), ("&middot;", "·"), ("&ensp;", " "), ("&emsp;", "　")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        if result.contains("&#"), let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") {
            let ns = result as NSString
            var out = ""
            var last = 0
            for match in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let hex = ns.substring(with: match.range(at: 1)) == "x"
                let digits = ns.substring(with: match.range(at: 2))
                if let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) { out.append(Character(scalar)) }
                last = match.range.upperBound
            }
            out += ns.substring(from: last)
            result = out
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private static func normalize(_ path: String) -> String {
        var parts: [String] = []
        for piece in path.components(separatedBy: "/") where !piece.isEmpty && piece != "." {
            if piece == ".." { _ = parts.popLast() } else { parts.append(piece) }
        }
        return parts.joined(separator: "/")
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        firstMatch("\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']", in: tag)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}
