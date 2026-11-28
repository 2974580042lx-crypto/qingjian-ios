import Foundation
import CoreFoundation

// Small text helpers shared by file import, the project designer and memory.
// They lived with the bookshelf until 1.47 removed it.

enum PlainText {
    static let maximumBytes = 40 * 1024 * 1024

    /// UTF-8 first; much Chinese text found online is GB18030 (GBK) instead, some Big5.
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
}

// Model output that should be one JSON object, possibly wrapped in a code block or prose.
enum JSONExtraction {
    static func decode<T: Decodable>(_ text: String) throws -> T {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8) else { throw ChatError.invalidResponse }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ChatError.server("整理结果的格式不对，可以重试。") }
    }
}

// Collects a whole answer from a helper request that is not shown while it streams.
struct TextAccumulator {
    private(set) var content = ""
    private(set) var usage: TokenUsage?
    private(set) var finishReason: String?
    private var done = false
    let limit: Int
    init(limit: Int = 200_000) { self.limit = limit }
    mutating func consume(_ event: StreamEvent) {
        if content.count < limit { content += event.content }
        if let value = event.usage { usage = value }
        if let value = event.finishReason { finishReason = value }
        done = done || event.isDone
    }
    func result() throws -> String {
        guard done else { throw ChatError.incompleteStream }
        guard finishReason == "stop" else {
            throw ChatError.server(finishReason == "length" ? "这次整理超出了输出上限。" : "这次整理没有完整返回。")
        }
        return content
    }
}
